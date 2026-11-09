// roko Shield's background: the part of roko that answers the page scripts
// (CosmeticFilter and ConsentHandler in Blocklists.swift), and the switches
// Shield and Settings › Blocking have in the app, here kept for the browser.
//
// What is on lives in chrome.storage.local:
//   on        Shield itself, for every site
//   kinds     ads, privacy (trackers), cookies (cookie notices), popups
//   paused    sites it is off for: the ones it broke
//   accepted  sites whose cookies are accepted, and why: "wall" (rejecting
//             didn't get past the pop-up), "content" (the page held content
//             back until they were)
//   softAds   sites that show nothing while their ads are blocked, tried with
//             their ad scripts let through (ContentBlocker.pageRefusedToShow)
//   adsAllowed  sites where that wasn't enough: their ads are let through
//   adsKept   sites you asked to keep blocking ads on regardless
//
// Chrome's network rules are the lists build.py made (rules/*.json), switched
// on and off as whole lists. One site can't have a list taken off, so a rule for
// that site is given a priority above the lists it lets through (build.py's
// PRIORITY). The page scripts are registered only while they are wanted and never
// on a paused site, as roko only gives a tab the scripts it should run.

import { snippets } from "./consent-snippets.js";

const KINDS = ["ads", "privacy", "cookies", "popups"];
const DEFAULTS = {
  on: true, kinds: { ads: true, privacy: true, cookies: true, popups: true }, paused: [], accepted: {},
  softAds: [], adsAllowed: [], adsKept: [],
};
// YouTubeAds.hosts: exact hosts, since accounts.youtube.com and the like have no player.
const YOUTUBE = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
  "youtube-nocookie.com", "www.youtube-nocookie.com"];

async function settings() {
  const stored = await chrome.storage.local.get(DEFAULTS);
  return { ...DEFAULTS, ...stored, kinds: { ...DEFAULTS.kinds, ...stored.kinds } };
}

async function change(patch) {
  const current = await settings();
  const next = { ...current, ...patch, kinds: { ...current.kinds, ...(patch.kinds || {}) } };
  await chrome.storage.local.set(next);
  await apply(next);
  return next;
}

/** "https://www.bbc.co.uk/news" → "bbc.co.uk"; nothing for pages that aren't web pages. */
function siteOf(url) {
  try {
    const { protocol, hostname } = new URL(url);
    if (protocol !== "http:" && protocol !== "https:") return null;
    const host = hostname.toLowerCase();
    return host.startsWith("www.") ? host.slice(4) : host;
  } catch (_) {
    return null;
  }
}

/** This site is in the list, or the site it is part of is. */
const listed = (list, site) => !!site && list.some((entry) => site === entry || site.endsWith("." + entry));
const isPaused = (state, site) => listed(state.paused, site);

function acceptance(state, site) {
  return site ? state.accepted[site] ?? null : null;
}

/** "news.bbc.co.uk" → ["news.bbc.co.uk", "bbc.co.uk", "co.uk", "uk"]. */
function suffixes(host) {
  const parts = host.split(".");
  return parts.map((_, i) => parts.slice(i).join("."));
}

const packaged = new Map();
function file(path) {
  if (!packaged.has(path)) {
    packaged.set(path, fetch(chrome.runtime.getURL(path)).then((r) => r.json()).catch(() => null));
  }
  return packaged.get(path);
}

// MARK: Lists and scripts

async function apply(state, force = false) {
  state = state || (await settings());
  const enable = [], disable = [];
  for (const id of ["shield", ...KINDS]) {
    (state.on && (id === "shield" || state.kinds[id]) ? enable : disable).push(id);
  }
  await chrome.declarativeNetRequest.updateEnabledRulesets({ enableRulesetIds: enable, disableRulesetIds: disable });

  const rules = [];
  const frames = ["main_frame", "sub_frame"];
  const pass = (priority, sites) => rules.push({
    id: rules.length + 1, priority, action: { type: "allowAllRequests" },
    condition: { requestDomains: sites, resourceTypes: frames },
  });
  for (const site of state.paused) pass(100, [site]);
  // A site that needs its cookies accepted gets its consent platform back: the
  // cookie list blocks many of them, and a blocked one can't be accepted. Its
  // notice is still answered, with accept. Above the cookie list only.
  const accepted = Object.keys(state.accepted);
  if (accepted.length) pass(3, accepted);
  // A page that shows nothing while its ads are blocked. First its ad scripts and
  // their requests, which is usually all an anti-adblock checks, while the ads'
  // pictures, frames and videos stay blocked; then its ads. Above the ad lists:
  // trackers and pop-ups stay handled, and its cookie notice is still answered.
  if (state.softAds.length) {
    rules.push({
      id: rules.length + 1, priority: 6, action: { type: "allow" },
      condition: { initiatorDomains: state.softAds, resourceTypes: ["script", "xmlhttprequest"] },
    });
  }
  if (state.adsAllowed.length) pass(6, state.adsAllowed);
  const old = await chrome.declarativeNetRequest.getDynamicRules();
  await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: old.map((r) => r.id), addRules: rules });
  await register(state, force);
  await showIcons();
}

async function register(state, force = false) {
  const paused = state.paused.flatMap((site) => [`*://${site}/*`, `*://*.${site}/*`]);
  const everywhere = { matches: ["http://*/*", "https://*/*"], runAt: "document_start", persistAcrossSessions: true };
  if (paused.length) everywhere.excludeMatches = paused;
  // What's only there because a site's ads are blocked goes where they aren't.
  const adSites = { ...everywhere };
  const adsLetThrough = state.adsAllowed.flatMap((site) => [`*://${site}/*`, `*://*.${site}/*`]);
  if (paused.length || adsLetThrough.length) adSites.excludeMatches = [...paused, ...adsLetThrough];
  const scripts = [];
  if (state.on) {
    // Cookie notices are answered, not just hidden: hidden, a site keeps
    // asking, and often keeps the page locked or its content held back. Only
    // this much at the start: it asks for the rules itself (consent-load.js).
    if (state.kinds.cookies) {
      scripts.push({ ...everywhere, id: "consent-load", js: ["consent-load.js"], runAt: "document_end", allFrames: true });
    }
    if (state.kinds.ads || state.kinds.cookies || state.kinds.popups) {
      scripts.push({ ...everywhere, id: "hiding", js: ["bridge.js", "cosmetic-filter.js"], allFrames: false });
    }
    scripts.push({ ...adSites, id: "slots", css: ["slots.css"], allFrames: true });
    for (const [index, entry] of ((await file("slots-by-site.json")) || []).entries()) {
      const matches = entry.sites.flatMap((site) => [`*://${site}/*`, `*://*.${site}/*`]);
      scripts.push({ ...adSites, id: `slots-${index}`, css: [entry.css], matches, allFrames: true });
    }
    const youtube = { ...adSites, matches: YOUTUBE.map((host) => `*://${host}/*`), allFrames: true };
    scripts.push({ ...youtube, id: "youtube-page", js: ["youtube-page.js"], world: "MAIN" });
    scripts.push({ ...youtube, id: "youtube-skip", js: ["youtube-skip.js"] });
    // uBlock Origin's site rules, so a site's anti-adblock never comes up: before
    // the page runs, in its own world, and only where its ads are blocked (it's
    // what their absence brings on). Each file loads only on the sites it names.
    if (state.kinds.ads) {
      const main = { ...adSites, world: "MAIN", allFrames: false };
      scripts.push({ ...main, id: "site-any", js: ["site-scripts/any.js"] });
      for (const [index, shard] of ((await file("site-scripts/shards.json")) || []).entries()) {
        scripts.push({ ...main, id: `site-${index}`, js: [shard.js], matches: shard.matches });
      }
    }
  }
  // Thousands of addresses: not done again for a change that doesn't touch them.
  const signature = JSON.stringify(scripts);
  const { registered } = await chrome.storage.local.get("registered");
  if (!force && registered === signature) return;
  await chrome.scripting.unregisterContentScripts();
  if (scripts.length) await chrome.scripting.registerContentScripts(scripts);
  await chrome.storage.local.set({ registered: signature });
}

// The toolbar's mark: black where Shield is on for the page (light on a dark
// toolbar), grey where it is off or paused, so a page that loads differently
// is never a mystery. Chrome can't tell an extension its theme, so the pages
// do (veils.js), and the last one heard is kept.
const icon = (name) => ({ 16: `icons/${name}-16.png`, 32: `icons/${name}-32.png`, 48: `icons/${name}-48.png` });
async function showIcon(tabId, url, state) {
  state = state || (await settings());
  const site = siteOf(url);
  const on = state.on && !(site && isPaused(state, site));
  const { dark } = await chrome.storage.session.get("dark");
  await chrome.action.setIcon({ tabId, path: icon(on ? (dark ? "on-dark" : "on") : "off") }).catch(() => {});
}
async function scheme(body) {
  const dark = !!body?.dark;
  if ((await chrome.storage.session.get("dark")).dark === dark) return null;
  await chrome.storage.session.set({ dark });
  await chrome.action.setIcon({ path: icon(dark ? "on-dark" : "on") }).catch(() => {});
  await showIcons();
  return null;
}
async function showIcons() {
  const state = await settings();
  for (const tab of await chrome.tabs.query({})) showIcon(tab.id, tab.url, state);
}
chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
  if (info.url || info.status === "loading") showIcon(tabId, tab.url);
});

chrome.runtime.onInstalled.addListener(() => { apply(null, true); menus(); });
chrome.runtime.onStartup.addListener(() => apply());

// MARK: Element hiding (CosmeticFilter)

const indexes = new Map();
function index(kind) {
  if (!indexes.has(kind)) {
    indexes.set(kind, file(`hide/${kind}.json`).then((raw) => raw && { ...raw, untouched: new Set(raw.untouched) }));
  }
  return indexes.get(kind);
}
const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key) ? object[key] : [];

/**
 * A site shows nothing while its ads are blocked. Two steps, each followed by a
 * reload, and each only if the last wasn't enough: its ad scripts may load, then,
 * since a page beats a blocked ad, its ads are let through, here only.
 */
async function pageRefused(tab) {
  const state = await settings();
  const site = siteOf(tab.url);
  if (!site || !state.on || !state.kinds.ads || isPaused(state, site)) return;
  if (listed(state.adsAllowed, site) || listed(state.adsKept, site)) return;
  if (listed(state.softAds, site)) {
    await change({ softAds: state.softAds.filter((s) => s !== site), adsAllowed: [...state.adsAllowed, site] });
  } else {
    await change({ softAds: [...state.softAds, site] });
  }
  await chrome.tabs.reload(tab.id);
}

async function cosmetic(body, sender) {
  if (!body || !sender.tab) return null;
  // The page script found and hid a site's own "disable your ad blocker" wall.
  if (body.wall) return null;
  if (body.refused) {
    if (sender.frameId === 0) await pageRefused(sender.tab);
    return null;
  }
  if (!Array.isArray(body.keys)) return null;
  const state = await settings();
  const host = String(body.host || "").toLowerCase();
  const here = siteOf(sender.tab.url) || host;
  if (!state.on || isPaused(state, here)) return null;
  const hosts = suffixes(host);
  const first = !!body.first;
  const selectors = [];
  // Cookie notices are faded out rather than removed: the consent script
  // has to find a notice to answer it, and a removed one can't be found.
  const faded = [];
  // Overlays often lock page scrolling; the page script unlocks it if one was hidden.
  const overlays = [];
  let collapseAds = false;
  for (const kind of KINDS) {
    if (!state.kinds[kind] || (kind === "ads" && listed(state.adsAllowed, here))) continue;
    const list = await index(kind);
    if (!list || hosts.some((h) => list.untouched.has(h))) continue;
    if (kind === "ads") collapseAds = true;
    const found = [];
    if (first) {
      found.push(...list.always);
      for (const h of hosts) found.push(...own(list.scoped, h));
    }
    for (const key of body.keys) found.push(...own(list.keyed, key));
    (kind === "cookies" ? faded : selectors).push(...found);
    if (kind === "cookies" || kind === "popups") overlays.push(...found);
  }
  // One rule per selector, so a selector the browser can't parse only drops
  // itself; under :root, one step more specific than the page's own rules.
  const css = selectors.map((s) => (s.includes("::") ? s : `:root :is(${s})`) + "{display:none!important}").join("\n");
  return { css, faded, overlays, collapseAds: first && collapseAds };
}

// MARK: Cookie pop-ups (ConsentHandler)

/** A function run in the page's own world, given at most `wait` ms. */
async function inPage(tabId, frameId, func, args = [], wait = 1000) {
  if (typeof func !== "function") return false;
  try {
    const run = chrome.scripting.executeScript({ target: { tabId, frameIds: [frameId] }, world: "MAIN", func, args });
    const late = new Promise((done) => setTimeout(() => done([{ result: false }]), wait));
    const [first] = await Promise.race([run, late]);
    return first?.result;
  } catch (_) {
    return false;
  }
}

async function accept(site, reason) {
  const state = await settings();
  if (state.accepted[site] === reason) return;
  await change({ accepted: { ...state.accepted, [site]: reason } });
}

async function consent(body, sender) {
  const tab = sender.tab;
  if (!body || !tab) return null;
  const state = await settings();
  // Decided for the site you're on, also when the pop-up sits in a frame.
  const site = siteOf(tab.url) || siteOf(sender.url);
  if (!state.on || !state.kinds.cookies || !site || isPaused(state, site)) return null;

  switch (body.type) {
    case "rokoLoad":
      // The rules, asked for by consent-load.js once the page is ready for them.
      await chrome.scripting.executeScript({
        target: { tabId: tab.id, frameIds: [sender.frameId] },
        files: ["bridge.js", sender.frameId === 0 ? "consent-main.js" : "consent-frame.js"],
      }).catch(() => {});
      return null;

    case "popupFound":
      return { type: acceptance(state, site) ? "optIn" : "optOut" };

    case "eval": {
      // A rule step that needs the page's own script, such as a platform's API.
      const result = await inPage(tab.id, sender.frameId, snippets[body.snippetId]);
      return { type: "evalResp", id: body.id, result: !!result };
    }

    case "rokoWall":
      await accept(site, "wall");
      // A wall answered by its buttons: a page that was held back behind it
      // (BILD's) often doesn't fill in until it's loaded with consent.
      if (body.cmp === "roko-paid-wall") setTimeout(() => fillIn(tab.id, tab.url, site), 3000);
      return { type: "optIn" };

    case "rokoFrameYes": {
      // A frame that is only a yes to cookies: pressed when the page around it is a wall
      // whose other way past costs money, as for a wall's yes on the page itself.
      if (sender.frameId === 0) return { press: false };
      if (acceptance(state, site)) return { press: true };
      let frameHost = "";
      try { frameHost = new URL(sender.url).host; } catch (e) {}
      if (!(await inPage(tab.id, 0, wallAround, [frameHost]))) return { press: false };
      await accept(site, "wall");
      return { press: true };
    }

    case "rokoSaved":
      return null;

    case "rokoBlocked": {
      if (!acceptance(state, site)) await accept(site, "content");
      // Through the platform's own API first: the content usually comes back
      // at once, with no reload.
      const reached = await inPage(tab.id, 0, acceptAll);
      if (reached > 0) return { type: "rokoRecheck" };
      await recover(tab, site);
      return null;
    }

    case "rokoPlatform": {
      const yes = !!acceptance(state, site);
      const answered = await inPage(tab.id, 0, answerNotice, [yes]);
      return { answered: answered > 0, accepted: yes && answered > 0 };
    }

    case "rokoStillBlocked":
      await recover(tab, site);
      return null;

    default:
      return null;
  }
}

// Whether the page is a wall a frame's yes belongs to: a short page about cookies whose
// other way past is paying (El Confidencial's /consent), or a big frame from the same
// place pinned over the page, holding the choices. Runs in the page.
function wallAround(frameHost) {
  const text = document.body ? document.body.innerText || "" : "";
  const pay = /subscri|suscri|abonn|abbon|\babo\b|\bpay\b|\bpaga|\bpago\b|bezahl|pretplat|assin|ad[- ]?free|werbefrei|sans pub|sin (anuncios|publi)|senza pubbl|contentpass/i;
  if (text.length < 4000 && /cookie/i.test(text) && pay.test(text)) return true;
  const pinned = (el) => {
    for (let node = el; node && node !== document.body; node = node.parentElement) {
      const p = getComputedStyle(node).position;
      if (p === "fixed" || p === "sticky") return true;
    }
    return false;
  };
  return [...document.querySelectorAll("iframe")].some((f) => {
    let from = "";
    try { from = new URL(f.src, location.href).host; } catch (e) {}
    const r = f.getBoundingClientRect();
    return from === frameHost && r.width >= innerWidth * 0.6 && r.height >= innerHeight * 0.5 && pinned(f);
  });
}

async function fillIn(tabId, url, site) {
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (!tab || tab.url !== url) return;
  const words = await inPage(tabId, 0, () => (document.body ? document.body.innerText.length : 0));
  if (typeof words === "number" && words < 1200) await recover(tab, site);
}

/**
 * Content still held back once cookies are accepted. First a plain reload:
 * the site is now accepted, so its consent platform is no longer blocked,
 * shows its pop-up, and gets accepted. If that isn't enough, the site keeps an
 * earlier "rejected" in its cookies or storage and won't ask again: forget
 * this site's data and load it afresh. Each at most once per page.
 */
async function recover(tab, site) {
  const key = "attempts " + tab.url;
  const attempt = (await chrome.storage.session.get(key))[key] || 0;
  await chrome.storage.session.set({ [key]: attempt + 1 });
  if (attempt === 0) {
    await chrome.tabs.reload(tab.id);
  } else if (attempt === 1) {
    const origins = [...new Set([new URL(tab.url).origin, `https://${site}`, `https://www.${site}`])];
    await chrome.browsingData.remove({ origins }, {
      cookies: true, localStorage: true, indexedDB: true, cacheStorage: true, serviceWorkers: true, fileSystems: true,
    }).catch(() => {});
    await chrome.tabs.reload(tab.id);
  }
}

// Both run in the page, so each carries everything it needs.

/** "Accept all" through the consent platforms' own APIs; how many it reached. */
function acceptAll() {
  let reached = 0;
  const tryIt = (test, act) => { try { if (test()) { act(); reached++; } } catch (e) {} };
  tryIt(() => window.OneTrust && OneTrust.AllowAll, () => OneTrust.AllowAll());
  tryIt(() => window.Cookiebot && Cookiebot.submitCustomConsent, () => Cookiebot.submitCustomConsent(true, true, true));
  tryIt(() => window.UC_UI && UC_UI.acceptAllConsents, () => UC_UI.acceptAllConsents());
  tryIt(() => window.__ucCmp && __ucCmp.acceptAllConsents, () => __ucCmp.acceptAllConsents());
  tryIt(() => window.Didomi && Didomi.setUserAgreeToAll, () => Didomi.setUserAgreeToAll());
  tryIt(() => window.klaro && klaro.getManager, () => { const m = klaro.getManager(); m.changeAll(true); m.saveAndApplyConsents(); });
  tryIt(() => typeof window.cmplz_accept_all === "function", () => cmplz_accept_all());
  tryIt(() => window.tarteaucitron && tarteaucitron.userInterface, () => tarteaucitron.userInterface.respondAll(true));
  tryIt(() => window._iub && _iub.cs && _iub.cs.api && _iub.cs.api.acceptAll, () => _iub.cs.api.acceptAll());
  tryIt(() => typeof window.__cmp === "function" && typeof __cmp("getCMPData") === "object", () => __cmp("setConsent", 1));
  return reached;
}

/** A platform's notice that's showing, answered through its API: 1 if one was. */
function answerNotice(yes) {
  try {
    const d = window.Didomi;
    if (d && d.notice && typeof d.notice.isVisible === "function" && d.notice.isVisible()) {
      if (yes) d.setUserAgreeToAll(); else d.setUserDisagreeToAll();
      if (d.notice.isVisible()) d.notice.hide();
      return 1;
    }
  } catch (e) {}
  return 0;
}

// MARK: Pop-up windows
//
// WebKit's lists block a pop-up window by its address; Chrome's rules can't
// tell a pop-up from any other page. So a tab a page opens is checked here
// against those rules (rules/popup-windows.json) for its first few seconds,
// and closed if it is one.

const opened = new Map();
let popupRules = null;

async function popupMatchers() {
  if (!popupRules) {
    const raw = (await file("rules/popup-windows.json")) || {};
    popupRules = {};
    for (const [kind, entries] of Object.entries(raw)) {
      popupRules[kind] = entries.flatMap((e) => {
        try { return [{ ...e, re: new RegExp(e.r, "i") }]; } catch (_) { return []; }
      });
    }
  }
  return popupRules;
}

const within = (host, domains) => domains.some((d) => host === d || host.endsWith("." + d));

function applies(rule, url, host, opener) {
  if (!rule.re.test(url)) return false;
  if (rule.i && !within(opener, rule.i)) return false;
  if (rule.u && within(opener, rule.u)) return false;
  if (rule.t) {
    const same = within(host, [opener]) || within(opener, [host.replace(/^www\./, "")]);
    if ((rule.t === 3) === same) return false;
  }
  return true;
}

async function unwantedPopup(state, url, opener) {
  const host = new URL(url).hostname.toLowerCase();
  const rules = await popupMatchers();
  for (const kind of KINDS) {
    if (!state.kinds[kind]) continue;
    const list = rules[kind] || [];
    if (list.some((r) => !r.a && applies(r, url, host, opener)) && !list.some((r) => r.a && applies(r, url, host, opener))) {
      return true;
    }
  }
  return false;
}

async function checkPopup(tabId, url) {
  const entry = opened.get(tabId);
  if (!entry || Date.now() > entry.until) return opened.delete(tabId);
  if (!/^https?:/i.test(url || "")) return;
  const state = await settings();
  if (!state.on || !entry.opener || isPaused(state, entry.opener)) return;
  if (await unwantedPopup(state, url, entry.opener)) {
    opened.delete(tabId);
    chrome.tabs.remove(tabId).catch(() => {});
  }
}

chrome.webNavigation.onCreatedNavigationTarget.addListener(async (details) => {
  let opener = null;
  try { opener = siteOf((await chrome.tabs.get(details.sourceTabId)).url); } catch (_) {}
  opened.set(details.tabId, { opener, until: Date.now() + 4000 });
  checkPopup(details.tabId, details.url);
});
chrome.webNavigation.onBeforeNavigate.addListener((details) => {
  if (details.frameId === 0 && opened.has(details.tabId)) checkPopup(details.tabId, details.url);
});
chrome.tabs.onRemoved.addListener((tabId) => opened.delete(tabId));

// MARK: Hide distracting items (Curtain.swift)
//
// What you point at goes, for good, on that site: kept per site under
// "hidden:<site>" as roko keeps hidden.json, and put back on by veils.js
// before each page draws. A private window writes nothing down: what it takes
// off stays with that tab only, as roko's private tabs do.

const hiddenKey = (site) => "hidden:" + site;
const rule = (selector) => `${selector} { display: none !important; }`;

async function veilsOn(site) {
  return site ? (await chrome.storage.local.get(hiddenKey(site)))[hiddenKey(site)] || [] : [];
}

async function passing(tabId) {
  const key = "passing:" + tabId;
  return (await chrome.storage.session.get(key))[key] || [];
}

/** The stylesheet for a tab's page; one selector may be left out, to peek at it. */
async function veilCSS(tab, spared = null) {
  const own = (await veilsOn(siteOf(tab.url))).map((v) => v.selector);
  const kept = tab.incognito ? [...own, ...(await passing(tab.id))] : own;
  return kept.filter((s) => s !== spared).map(rule).join("\n");
}

const topFrame = (tabId) => ({ tabId, frameIds: [0] });

/** The pointing script in the page, asleep until it is asked for. */
async function arm(tabId) {
  await chrome.scripting.executeScript({ target: topFrame(tabId), files: ["bridge.js", "picker.js", "picker-keys.js"] });
}

async function showVeils(tab, spared = null) {
  const css = await veilCSS(tab, spared);
  await chrome.scripting.executeScript({
    target: topFrame(tab.id), args: [css],
    func: (text) => {
      let sheet = document.getElementById("office-veil");
      if (!sheet) {
        sheet = document.createElement("style");
        sheet.id = "office-veil";
        (document.head || document.documentElement).appendChild(sheet);
      }
      sheet.textContent = text;
    },
  }).catch(() => {});
}

/** ⌘⇧H, or Hide something… in the popup: pointing on, or off again. */
async function togglePicking(tab, wanted = null) {
  if (!tab?.id || !siteOf(tab.url)) return false;
  try {
    await arm(tab.id);
    await chrome.scripting.executeScript({
      target: topFrame(tab.id), args: [wanted],
      func: (want) => {
        const veil = window.__officeVeil;
        if (want ?? !veil.isOn()) veil.on(); else veil.off();
      },
    });
    return true;
  } catch (_) {
    return false;
  }
}

async function hide(tab, picked) {
  const site = siteOf(tab.url);
  if (!site || !picked?.selector) return;
  if (tab.incognito) {
    const list = await passing(tab.id);
    if (!list.includes(picked.selector)) list.push(picked.selector);
    await chrome.storage.session.set({ ["passing:" + tab.id]: list });
  } else {
    const list = await veilsOn(site);
    if (list.some((v) => v.selector === picked.selector)) return;
    list.push({ selector: picked.selector, label: picked.label || picked.selector, note: picked.note || "", date: Date.now() });
    await chrome.storage.local.set({ [hiddenKey(site)]: list });
  }
  await showVeils(tab);
}

/** ⌘Z while pointing: the last thing taken off comes back. */
async function undoHiding(tab) {
  const site = siteOf(tab.url);
  if (tab.incognito) {
    const list = await passing(tab.id);
    if (!list.length) return null;
    list.pop();
    await chrome.storage.session.set({ ["passing:" + tab.id]: list });
    await showVeils(tab);
    return "It";
  }
  const list = await veilsOn(site);
  const back = list.pop();
  if (!back) return null;
  await chrome.storage.local.set({ [hiddenKey(site)]: list });
  await showVeils(tab);
  return back.label;
}

async function veil(body, sender) {
  if (!body || !sender.tab || sender.frameId !== 0) return null;
  if (body.selector) {
    await hide(sender.tab, body);
    return { hidden: true };
  }
  if (body.undo) return { back: await undoHiding(sender.tab) };
  return null;
}

async function restore(body) {
  const tab = await chrome.tabs.get(body.tabId).catch(() => null);
  const site = tab && siteOf(tab.url);
  if (!site) return null;
  const list = body.all ? [] : (await veilsOn(site)).filter((v) => v.selector !== body.selector);
  await chrome.storage.local.set({ [hiddenKey(site)]: list });
  await showVeils(tab);
  return list;
}

/**
 * The pointer resting on a row in the popup: that one thing back on the page,
 * outlined, and scrolled to. The sheet is rebuilt without it rather than
 * fought with another rule, so it comes back with the layout it had.
 */
async function peek(body) {
  const tab = await chrome.tabs.get(body.tabId).catch(() => null);
  if (!tab || !siteOf(tab.url)) return null;
  try {
    await arm(tab.id);
    const css = await veilCSS(tab, body.selector);
    await chrome.scripting.executeScript({
      target: topFrame(tab.id), args: [css, body.selector || null],
      func: (text, selector) => {
        if (selector) window.__officeVeil.peek(text, selector); else window.__officeVeil.unpeek(text);
      },
    });
  } catch (_) {}
  return null;
}

chrome.commands.onCommand.addListener((command, tab) => {
  if (command === "hide-items") togglePicking(tab);
});

function menus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: "hide-this", title: "Hide this",
      contexts: ["page", "image", "link", "video", "audio", "selection", "frame"],
      documentUrlPatterns: ["http://*/*", "https://*/*"],
    });
  });
}

// What the menu was opened over, or, inside an embed, the embed itself.
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== "hide-this" || !tab?.id) return;
  try {
    await arm(tab.id);
    const [found] = await chrome.scripting.executeScript({
      target: topFrame(tab.id), args: [info.frameId ? info.frameUrl || "" : null],
      func: (frameUrl) => {
        let el = globalThis.__rokoContextTarget;
        if (frameUrl !== null) el = [...document.querySelectorAll("iframe, frame")].find((f) => f.src === frameUrl) || null;
        if (el && el.nodeType !== 1) el = el.parentElement;
        if (!el || el === document.body || el === document.documentElement) return null;
        return window.__officeVeil.describe(el);
      },
    });
    if (found?.result) await hide(tab, found.result);
  } catch (_) {}
});

chrome.tabs.onRemoved.addListener((tabId) => chrome.storage.session.remove("passing:" + tabId));

// MARK: Messages

async function popupState(body) {
  const state = await settings();
  const site = siteOf(body.url);
  const shortcut = (await chrome.commands.getAll()).find((c) => c.name === "hide-items")?.shortcut || "";
  return { state, site, paused: isPaused(state, site), accepted: acceptance(state, site),
    adsAllowed: listed(state.adsAllowed, site), hidden: await veilsOn(site), shortcut };
}

const handlers = {
  cosmetic,
  consent,
  veil,
  scheme,
  state: popupState,
  change: (body) => change(body),
  pick: async (body) => togglePicking(await chrome.tabs.get(body.tabId).catch(() => null), true),
  restore,
  peek,
};
// Messages only the extension's own pages may send.
const OWN = new Set(["state", "change", "pick", "restore", "peek"]);

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  const handle = handlers[message?.to];
  // Only the extension's own pages may change what is on; pages only get answers.
  const ours = (sender.url || "").startsWith(chrome.runtime.getURL(""));
  if (!handle || OWN.has(message.to) && !ours) return false;
  handle(message.body, sender).then(reply, () => reply(null));
  return true;
});
