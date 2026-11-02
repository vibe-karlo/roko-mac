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
//
// Chrome's network rules are the lists build.py made (rules/*.json), switched
// on and off as whole lists; a paused site gets one rule that lets its pages
// through; the page scripts are registered only while they are wanted and
// never on a paused site, as roko only gives a tab the scripts it should run.

import { snippets } from "./consent-snippets.js";

const KINDS = ["ads", "privacy", "cookies", "popups"];
const DEFAULTS = { on: true, kinds: { ads: true, privacy: true, cookies: true, popups: true }, paused: [], accepted: {} };
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

/** Off for this site, or for the site it is part of. */
function isPaused(state, site) {
  return !!site && state.paused.some((paused) => site === paused || site.endsWith("." + paused));
}

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

async function apply(state) {
  state = state || (await settings());
  const enable = [], disable = [];
  for (const id of ["shield", ...KINDS]) {
    (state.on && (id === "shield" || state.kinds[id]) ? enable : disable).push(id);
  }
  await chrome.declarativeNetRequest.updateEnabledRulesets({ enableRulesetIds: enable, disableRulesetIds: disable });

  const rules = [];
  for (const site of state.paused) {
    rules.push({
      id: rules.length + 1, priority: 100, action: { type: "allowAllRequests" },
      condition: { requestDomains: [site], resourceTypes: ["main_frame", "sub_frame"] },
    });
  }
  // A site that only works with its cookies accepted gets its consent
  // platform back: the cookie list blocks many of them, and a blocked one
  // can't be accepted. Its notice is still answered, with accept.
  const accepted = Object.keys(state.accepted);
  const consentHosts = await file("rules/consent-hosts.json");
  if (accepted.length && consentHosts?.length) {
    rules.push({
      id: rules.length + 1, priority: 3, action: { type: "allow" },
      condition: { initiatorDomains: accepted, requestDomains: consentHosts },
    });
  }
  const old = await chrome.declarativeNetRequest.getDynamicRules();
  await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: old.map((r) => r.id), addRules: rules });
  await register(state);
  await showIcons();
}

async function register(state) {
  const excluded = state.paused.flatMap((site) => [`*://${site}/*`, `*://*.${site}/*`]);
  const everywhere = { matches: ["http://*/*", "https://*/*"], runAt: "document_start", persistAcrossSessions: true };
  if (excluded.length) everywhere.excludeMatches = excluded;
  const scripts = [];
  if (state.on) {
    // Cookie notices are answered, not just hidden: hidden, a site keeps
    // asking, and often keeps the page locked or its content held back.
    if (state.kinds.cookies) {
      scripts.push({ ...everywhere, id: "consent-main", js: ["bridge.js", "consent-main.js"], allFrames: false });
      scripts.push({ ...everywhere, id: "consent-frame", js: ["bridge.js", "consent-frame.js"], allFrames: true });
    }
    if (state.kinds.ads || state.kinds.cookies || state.kinds.popups) {
      scripts.push({ ...everywhere, id: "hiding", js: ["bridge.js", "cosmetic-filter.js"], allFrames: false });
    }
    scripts.push({ ...everywhere, id: "slots", css: ["slots.css"], allFrames: true });
    for (const [index, entry] of ((await file("slots-by-site.json")) || []).entries()) {
      const matches = entry.sites.flatMap((site) => [`*://${site}/*`, `*://*.${site}/*`]);
      scripts.push({ ...everywhere, id: `slots-${index}`, css: [entry.css], matches, allFrames: true });
    }
    const youtube = { ...everywhere, matches: YOUTUBE.map((host) => `*://${host}/*`), allFrames: true };
    scripts.push({ ...youtube, id: "youtube-page", js: ["youtube-page.js"], world: "MAIN" });
    scripts.push({ ...youtube, id: "youtube-skip", js: ["youtube-skip.js"] });
  }
  await chrome.scripting.unregisterContentScripts();
  if (scripts.length) await chrome.scripting.registerContentScripts(scripts);
}

// The toolbar's mark: orange where Shield is on for the page, grey where it
// is off or paused, so a page that loads differently is never a mystery.
const icon = (name) => ({ 16: `icons/${name}-16.png`, 32: `icons/${name}-32.png`, 48: `icons/${name}-48.png` });
async function showIcon(tabId, url, state) {
  state = state || (await settings());
  const site = siteOf(url);
  const on = state.on && !(site && isPaused(state, site));
  await chrome.action.setIcon({ tabId, path: icon(on ? "on" : "off") }).catch(() => {});
}
async function showIcons() {
  const state = await settings();
  for (const tab of await chrome.tabs.query({})) showIcon(tab.id, tab.url, state);
}
chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
  if (info.url || info.status === "loading") showIcon(tabId, tab.url);
});

chrome.runtime.onInstalled.addListener(() => apply());
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

async function cosmetic(body, sender) {
  if (!body || !Array.isArray(body.keys) || !sender.tab) return null;
  const state = await settings();
  const host = String(body.host || "").toLowerCase();
  if (!state.on || isPaused(state, siteOf(sender.tab.url) || host)) return null;
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
    if (!state.kinds[kind]) continue;
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
    case "popupFound":
      return { type: acceptance(state, site) ? "optIn" : "optOut" };

    case "eval": {
      // A rule step that needs the page's own script, such as a platform's API.
      const result = await inPage(tab.id, sender.frameId, snippets[body.snippetId]);
      return { type: "evalResp", id: body.id, result: !!result };
    }

    case "rokoWall":
      await accept(site, "wall");
      return { type: "optIn" };

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

// MARK: Messages

async function popupState(body) {
  const state = await settings();
  const site = siteOf(body.url);
  return { state, site, paused: isPaused(state, site), accepted: acceptance(state, site) };
}

const handlers = {
  cosmetic,
  consent,
  state: popupState,
  change: (body) => change(body),
};

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  const handle = handlers[message?.to];
  // Only the extension's own pages may change what is on; pages only get answers.
  const ours = (sender.url || "").startsWith(chrome.runtime.getURL(""));
  if (!handle || (message.to === "change" || message.to === "state") && !ours) return false;
  handle(message.body, sender).then(reply, () => reply(null));
  return true;
});
