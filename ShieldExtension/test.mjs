// Checks a built roko Shield in a hidden Chromium: the lists load, requests
// to ad hosts are refused, hiding and empty-slot folding work, a site paused
// loads untouched, a pop-up window to an ad host is closed, and Hide
// Distracting Items hides, keeps, undoes, peeks and restores. Then what roko
// learned from its real-site test: anti-adblock and pay-or-consent walls, frames,
// a page that refuses to show, uBlock Origin's site rules, looping videos.
//
//   python3 ShieldExtension/build.py
//   node ShieldExtension/test.mjs          (needs playwright-core and its chromium:
//                                           npm i playwright-core && npx playwright-core install chromium)
//
// Everything is served from localhost; nothing here touches the network.

import { chromium } from "playwright-core";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const extension = path.resolve(here, "..", "build", "roko-shield");

const PAGE = `<!doctype html><meta charset="utf-8"><title>fixture</title>
<style>body{font:16px system-ui;margin:20px} .box{height:250px;background:#eee;margin:10px 0}</style>
<p id="story">A story worth reading, with words in it.</p>
<aside id="related" aria-label="Related stories" style="height:120px;background:#ddd">Related stories</aside>
<div class="newsletter-box" style="height:80px;background:#ccc">Sign up for our newsletter</div>
<div id="AdBillboard" class="box">billboard</div>
<ins class="adsbygoogle box"></ins>
<div class="post-ad-container box">Advertisement</div>
<div class="box" id="real">A real paragraph that is not an ad at all, and says so at length.</div>
`;

const LONG = "<p>" + "Words a reader came for, one paragraph after another. ".repeat(40) + "</p>";
const WORDS = "We and our partners use cookies and personal data for tracking.";
const PAGES = {
  // A site's own "disable your ad blocker" wall, drawn after it loads, and an
  // article on the same subject that must stay.
  "/wall": `<!doctype html><meta charset="utf-8"><article id="article">Why people use an ad blocker: ${LONG}</article>
    <script>addEventListener("load", () => setTimeout(() => {
      document.body.style.overflow = "hidden";
      document.body.insertAdjacentHTML("beforeend", '<div id="backdrop" style="position:fixed;inset:0;background:#0008"></div>' +
        '<div id="nag" style="position:fixed;top:20%;left:10%;width:80%;height:40%;background:#fff">Please disable your ad blocker to keep reading.</div>');
    }, 200));</script>`,
  // Pay or consent, which no rule knows: yes, or a subscription.
  "/paid": `<!doctype html><meta charset="utf-8">${LONG}<div style="position:fixed;inset:0;background:#fff">${WORDS}
    <button id="yes" onclick="this.dataset.pressed=1">Accept and continue</button><button>Subscribe</button></div>`,
  // A wall in another language that asks twice ("press again to continue, 1/2").
  "/twice": `<!doctype html><meta charset="utf-8">${LONG}<div id="wall" style="position:fixed;inset:0;background:#fff">Cookie e dati personali.
    <button id="yes" onclick="this.dataset.presses=(+this.dataset.presses||0)+1;if(this.dataset.presses==='2')document.querySelector('#wall').remove();document.title=this.dataset.presses">Accetta e continua</button><button>Rifiuta e abbonati</button></div>`,
  // A no that leads to an account form, a no's own page (accept or pay), and a sign-up page that's neither.
  "/account": `<!doctype html><meta charset="utf-8">${LONG}<div style="position:fixed;inset:0;background:#fff">${WORDS}
    <button id="yes" onclick="this.dataset.pressed=1">Agree</button><button>Disagree and create account</button></div>`,
  "/preview": `<!doctype html><meta charset="utf-8"><body>We need your consent to use your personal data for advertising.
    <button id="yes" onclick="this.dataset.pressed=1">Accept and continue</button><button>Subscribe</button>`,
  "/signup": `<!doctype html><meta charset="utf-8"><body>Create your profile. You consent to our use of personal data.
    <input type="email"><button id="yes" onclick="this.dataset.pressed=1">I agree</button><button>Subscribe</button>`,
  // Pinned along the bottom: one picture and nothing else, and a real toolbar.
  "/strip": `<!doctype html><meta charset="utf-8">${LONG}<div id="strip" style="position:fixed;bottom:0;left:0;width:100%;height:90px"><img src="/banner-photo.png" width="320" height="90"></div>
    <div id="toolbar" style="position:fixed;bottom:100px;left:0;width:100%;height:50px"><img src="/logo.png" width="40" height="40">Menu</div>`,
  // The same wall in a frame on any address, and an ad frame with nothing to answer.
  "/framed": `<!doctype html><meta charset="utf-8"><body>${WORDS}<button id="yes" onclick="this.dataset.pressed=1">Accept</button><button>Subscribe</button>`,
  "/ad-frame": `<!doctype html><meta charset="utf-8"><body>An ad`,
  "/frames": `<!doctype html><meta charset="utf-8"><body style="margin:0">${LONG}<iframe id="wall" src="/framed" style="position:fixed;inset:0;width:100%;height:100%;border:0"></iframe>
    <iframe id="ad" src="/ad-frame" width="300" height="250"></iframe>`,
  // A page that keeps nothing once its ads fail.
  "/refuses": `<!doctype html><meta charset="utf-8"><body>A header<div class="adblockwall"></div>A footer`,
  // A looping video far down the page.
  "/loop": `<!doctype html><meta charset="utf-8"><div style="height:6000px"></div><video id="loop" muted loop autoplay src="/loop.mp4"></video>`,
};

const server = http.createServer((req, res) => {
  res.setHeader("content-type", "text/html");
  if (PAGES[req.url]) return res.end(PAGES[req.url]);
  // A site that allows no inline styles at all.
  if (req.url.startsWith("/strict")) res.setHeader("content-security-policy", "default-src 'self'; style-src 'self'");
  res.end(req.url.startsWith("/ok") ? "ok" : PAGE);
}).listen(0);
const port = server.address().port;
const origin = `http://localhost:${port}`;
const at = (host, path) => `http://${host}.localhost:${port}${path}`;

// Hosts on one list only, so a check shows which list did it.
const lines = (name) => fs.readFileSync(path.join(here, "lists", name), "utf8").split("\n").filter(Boolean);
const only = (name, others) => {
  const taken = new Set(others.flatMap(lines));
  return lines(name).find((host) => !taken.has(host) && /\.(com|net)$/.test(host));
};
const adHost = only("ads-hosts.txt", ["privacy-hosts.txt", "cookies-hosts.txt", "popups-hosts.txt"]);
const trackerHost = only("privacy-hosts.txt", ["ads-hosts.txt", "cookies-hosts.txt", "popups-hosts.txt"]);

// Two sites with a site rule, served from here: one named, one "name.*". Each
// rule sets a variable to true, which shows it ran before anything else could.
const rules = lines("site-scripts.txt").map((line) => line.split("\t"));
const simple = (wild) => rules.map(([key, calls]) => [key, /^\[\["set","(\w+)","true"\]\]$/.exec(calls)?.[1]])
  .find(([key, name]) => name && (wild ? key.endsWith(".*") : key.endsWith(".com")));
const [namedKey, namedVar] = simple(false), [wildKey, wildVar] = simple(true);
const namedSite = "www." + namedKey;
const wildSite = wildKey.replace(".*", ".example");

const profile = fs.mkdtempSync(path.join(os.tmpdir(), "roko-shield-"));
const context = await chromium.launchPersistentContext(profile, {
  channel: "chromium",
  headless: true,
  args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`,
    `--host-resolver-rules=MAP ${namedSite} 127.0.0.1:${port}, MAP ${wildSite} 127.0.0.1:${port}, MAP plain.example 127.0.0.1:${port}`],
});

let failures = 0;
const check = (ok, what) => {
  console.log(`${ok ? "ok  " : "FAIL"}  ${what}`);
  if (!ok) failures++;
};

try {
  const worker = context.serviceWorkers()[0] || (await context.waitForEvent("serviceworker"));
  // Let onInstalled finish registering the scripts and rules.
  await worker.evaluate(async () => {
    for (let i = 0; i < 50; i++) {
      if ((await chrome.scripting.getRegisteredContentScripts()).length) return;
      await new Promise((r) => setTimeout(r, 100));
    }
  });
  const enabled = await worker.evaluate(() => chrome.declarativeNetRequest.getEnabledRulesets());
  check(["shield", "ads", "privacy", "cookies", "popups"].every((id) => enabled.includes(id)), `all five lists on (${enabled.join(", ")})`);
  const scripts = await worker.evaluate(async () => (await chrome.scripting.getRegisteredContentScripts()).map((s) => s.id));
  check(["consent-load", "hiding", "youtube-page", "site-any"].every((id) => scripts.includes(id)) && !scripts.includes("consent-main"),
    `page scripts registered, cookie rules only on request (${scripts.length})`);

  const page = await context.newPage();
  await page.goto(origin + "/");

  // Refused by the extension is ERR_BLOCKED_BY_CLIENT; anything else (loaded,
  // or no network here) is not refused.
  const fetched = async (url) => {
    const failed = new Promise((done) => {
      const look = (request) => {
        if (request.url() !== url) return;
        page.off("requestfailed", look);
        done(request.failure()?.errorText || "");
      };
      page.on("requestfailed", look);
      setTimeout(() => done(""), 4000);
    });
    const loaded = await page.evaluate((u) => fetch(u, { mode: "no-cors" }).then(() => true, () => false), url);
    if (loaded) return "loaded";
    return (await failed).includes("BLOCKED_BY_CLIENT") ? "refused" : "not refused";
  };
  check((await fetched("https://securepubads.g.doubleclick.net/tag/js/gpt.js")) === "refused", "an ad host is refused");
  check((await fetched("https://www.google-analytics.com/analytics.js")) === "refused", "a tracker is refused");
  check((await fetched(origin + "/ok")) === "loaded", "the site's own request loads");

  const shown = (selector) => page.evaluate((s) => getComputedStyle(document.querySelector(s)).display !== "none", selector);
  await page.waitForTimeout(800);
  check(!(await shown("#AdBillboard")), "EasyList's #AdBillboard hidden");
  check(!(await shown("ins.adsbygoogle")), "Shield's .adsbygoogle slot hidden");
  check(await shown("#story"), "the story stays");
  await page.waitForTimeout(2500);
  check(await page.evaluate(() => document.querySelector(".post-ad-container").hasAttribute("data-roko-empty-ad")), "an empty ad box folded away");
  check(await shown("#real"), "a box with real text stays");

  // Hiding holds on a page whose policy refuses inline styles.
  await page.goto(origin + "/strict");
  await page.waitForTimeout(800);
  check(!(await shown("#AdBillboard")), "hidden under a strict content security policy");
  await page.goto(origin + "/");

  // A pop-up window to an ad host, opened by the page, is closed.
  const opened = context.waitForEvent("page");
  await page.evaluate(() => window.open("https://www.adcash.com/script/pop_packcpm.php?k=1", "_blank"));
  const popup = await opened;
  await page.waitForTimeout(1500);
  check(popup.isClosed(), "an ad pop-up window is closed");

  // Paused on this site: nothing refused, nothing hidden.
  const settings = await context.newPage();
  const id = new URL(worker.url()).host;
  await settings.goto(`chrome-extension://${id}/popup.html`);
  await settings.evaluate(() => chrome.runtime.sendMessage({ to: "change", body: { paused: ["localhost"] } }));
  await page.reload();
  await page.waitForTimeout(800);
  check((await fetched("https://securepubads.g.doubleclick.net/tag/js/gpt.js")) !== "refused", "paused: the ad host isn't refused");
  check(await shown("#AdBillboard"), "paused: nothing hidden");
  await settings.evaluate(() => chrome.runtime.sendMessage({ to: "change", body: { paused: [] } }));

  // Hide Distracting Items: point, and it goes for good on this site.
  await page.goto(origin + "/");
  const tabId = await settings.evaluate(async (url) => (await chrome.tabs.query({})).find((t) => t.url?.startsWith(url)).id, origin);
  check(await settings.evaluate((id) => chrome.runtime.sendMessage({ to: "pick", body: { tabId: id } }), tabId), "pointing starts on the page");
  const box = await page.locator("#related").boundingBox();
  await page.mouse.move(box.x + 20, box.y + 20);
  await page.mouse.move(box.x + 30, box.y + 30);
  await page.mouse.down(); await page.mouse.up();
  await page.waitForTimeout(600);
  check(!(await shown("#related")), "the pointed-at sidebar is hidden");
  const stored = await worker.evaluate(() => chrome.storage.local.get("hidden:localhost"));
  const kept = stored["hidden:localhost"] || [];
  check(kept.length === 1 && kept[0].selector === "#related" && kept[0].label === "Related stories", `kept for the site (${JSON.stringify(kept[0] || {})})`);
  check(await page.evaluate(() => /Hidden on this site/.test(document.documentElement.innerText)), "the page says it's hidden and how to undo");
  await page.keyboard.press(process.platform === "darwin" ? "Meta+z" : "Control+z");
  await page.waitForTimeout(600);
  check(await shown("#related"), "⌘Z brings it back");
  await page.mouse.move(box.x + 25, box.y + 25);
  await page.mouse.down(); await page.mouse.up();
  await page.waitForTimeout(400);
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
  await page.click(".newsletter-box");
  await page.waitForTimeout(400);
  check(await shown(".newsletter-box") && await page.evaluate(() => document.documentElement.style.cursor === ""), "Escape stops pointing");
  await page.reload();
  check(await page.evaluate(() => {
    const el = document.querySelector("#related");
    return el && getComputedStyle(el).display === "none";
  }), "still hidden as the page loads again");

  // Hide this, from the right-click menu: what the menu was opened over.
  await page.locator(".newsletter-box").dispatchEvent("contextmenu");
  const described = await worker.evaluate(async (id) => {
    await chrome.scripting.executeScript({ target: { tabId: id, frameIds: [0] }, files: ["bridge.js", "picker.js", "picker-keys.js"] });
    const [r] = await chrome.scripting.executeScript({ target: { tabId: id, frameIds: [0] },
      func: () => window.__officeVeil.describe(globalThis.__rokoContextTarget) });
    return r.result;
  }, tabId);
  check(described && described.selector === "div.newsletter-box", `right-click names the element (${described && described.selector})`);

  // The popup's list: resting on a line shows it, Restore brings it back.
  const popup2 = await context.newPage();
  await popup2.addInitScript(([id, url]) => { chrome.tabs.query = async () => [{ id, url }]; }, [tabId, origin + "/"]);
  await popup2.goto(`chrome-extension://${id}/popup.html`);
  await popup2.waitForTimeout(500);
  check(await popup2.locator(".veil").count() === 1, "the popup lists what's hidden here");
  await popup2.hover(".veil");
  await page.waitForTimeout(500);
  check(await shown("#related") && await page.evaluate(() => getComputedStyle(document.querySelector("#related")).outlineStyle === "solid"),
    "resting on the line shows it, outlined");
  await popup2.mouse.move(150, 5);
  await page.waitForTimeout(500);
  check(!(await shown("#related")), "leaving the list hides it again");
  await popup2.hover(".veil");
  await popup2.click(".veil .inline");
  await page.waitForTimeout(500);
  check(await shown("#related") && await popup2.locator(".veil").count() === 0, "Restore brings it back for good");
  await popup2.close();

  // What roko learned from its real-site test.
  const storage = (key) => worker.evaluate(async (k) => (await chrome.storage.local.get(k))[k], key);
  // Refused by the extension or not, by a request of one kind.
  const reach = async (pg, url, kind = "fetch") => {
    const failed = new Promise((done) => {
      const look = (request) => {
        if (request.url() !== url) return;
        pg.off("requestfailed", look);
        done(request.failure()?.errorText || "");
      };
      pg.on("requestfailed", look);
      setTimeout(() => done(""), 2500);
    });
    await pg.evaluate(([u, k]) => {
      if (k === "image") new Image().src = u; else fetch(u, { mode: "no-cors" }).catch(() => {});
    }, [url, kind]);
    return (await failed).includes("BLOCKED_BY_CLIENT");
  };
  const ad = `https://${adHost}/banner.gif`, tracker = `https://${trackerHost}/collect`;
  // A consent platform only the cookie list stops: another list's rule may match a host too.
  const cookieHost = await worker.evaluate(async (hosts) => {
    for (const host of hosts) {
      const { matchedRules } = await chrome.declarativeNetRequest.testMatchOutcome({
        url: `https://${host}/cmp.js`, type: "xmlhttprequest", initiator: "http://paid.localhost/", tabId: -1 });
      if (matchedRules.length && matchedRules.every((rule) => rule.rulesetId === "cookies")) return host;
    }
  }, lines("cookies-hosts.txt"));
  const consentTool = `https://${cookieHost}/cmp.js`;

  // "Disable your ad blocker": gone with its backdrop, the page scrolls, the article stays.
  const walled = await context.newPage();
  await walled.goto(at("nag", "/wall"));
  await walled.waitForTimeout(2200);
  const wall = await walled.evaluate(() => ({
    nag: getComputedStyle(document.querySelector("#nag")).display,
    backdrop: getComputedStyle(document.querySelector("#backdrop")).display,
    article: getComputedStyle(document.querySelector("#article")).display,
    overflow: getComputedStyle(document.body).overflow,
  }));
  check(wall.nag === "none" && wall.backdrop === "none", "an anti-adblock wall goes, with its backdrop");
  check(wall.article !== "none" && wall.overflow === "auto", "the page scrolls again, and an article about ad blockers stays");
  await walled.close();

  // Pay or consent, with no rule for it: yes is pressed, remembered, and the cookie list comes off here only.
  const paid = await context.newPage();
  await paid.goto(at("paid", "/paid"));
  check(await reach(paid, consentTool), "before a wall is answered, the cookie list blocks its platform");
  await paid.waitForTimeout(2500);
  check(await paid.evaluate(() => document.querySelector("#yes").dataset.pressed === "1"), "a pay-or-consent wall is answered with yes");
  check((await storage("accepted"))["paid.localhost"] === "wall", "and remembered for the site");
  // Chrome settles a page's allowances as it loads: from the next load on.
  await paid.reload();
  check(!(await reach(paid, consentTool)), "cookies accepted: the cookie list is off on that site");
  check(await reach(paid, ad, "image") && await reach(paid, tracker), "with its ads and trackers still blocked");
  await paid.close();

  const twice = await context.newPage();
  await twice.goto(at("twice", "/twice"));
  await twice.waitForTimeout(3500);
  check(await twice.title() === "2" && await twice.locator("#wall").count() === 0, "a wall that asks twice is pressed twice, in Italian");
  await twice.close();

  for (const [host, path, pressed, what] of [
    ["account", "/account", true, "a no that leads to an account form gets a yes"],
    ["preview", "/preview", true, "a no's own page, accept or pay, gets its accept pressed"],
    ["signup", "/signup", false, "a sign-up page that mentions consent isn't taken for a wall"],
  ]) {
    const tab = await context.newPage();
    await tab.goto(at(host, path));
    await tab.waitForTimeout(2500);
    check(await tab.evaluate(() => document.querySelector("#yes").dataset.pressed === "1") === pressed, what);
    await tab.close();
  }

  const strip = await context.newPage();
  await strip.goto(at("strip", "/strip"));
  await strip.waitForTimeout(2000);
  const folded = await strip.evaluate(() => ["strip", "toolbar"].map((id) => document.getElementById(id).hasAttribute("data-roko-empty-ad")));
  check(folded[0], "a lone picture pinned along the bottom folds away");
  check(!folded[1], "and a pinned bar with words stays");
  await strip.close();

  // The same in a frame on any address, while an ad frame isn't sent the rules at all.
  const framed = await context.newPage();
  await framed.goto(at("frames", "/frames"));
  await framed.waitForTimeout(2500);
  check(await framed.frameLocator("#wall").locator("#yes").evaluate((b) => b.dataset.pressed === "1"), "a wall in a frame covering the page is answered");
  const frameTab = await worker.evaluate(async (host) => (await chrome.tabs.query({})).find((t) => t.url?.includes(host)).id, "frames.localhost");
  const sent = await worker.evaluate(async (id) => (await chrome.scripting.executeScript({ target: { tabId: id, allFrames: true },
    func: () => [location.pathname, !!globalThis.webkit] })).map((r) => r.result), frameTab);
  check(sent.find(([p]) => p === "/ad-frame")?.[1] === false && sent.find(([p]) => p === "/framed")?.[1] === true, "an ad frame isn't sent the cookie rules");
  await framed.close();

  // A page that refuses to show: its ad scripts first, then its ads, each with a reload.
  const refusing = await context.newPage();
  await refusing.goto(at("refuses", "/refuses"));
  check(await reach(refusing, ad, "image") && await reach(refusing, ad), "a page's ads are blocked to begin with");
  await refusing.waitForTimeout(9000);
  check((await storage("softAds")).includes("refuses.localhost"), "a page that shows nothing gets its ad scripts first");
  check(!(await reach(refusing, ad)), "its ad requests go through");
  check(await reach(refusing, ad, "image"), "its ad pictures stay blocked");
  await refusing.waitForTimeout(8500);
  check((await storage("adsAllowed")).includes("refuses.localhost"), "still nothing: its ads are let through");
  check(!(await reach(refusing, ad, "image")), "its ad pictures load");
  check(await reach(refusing, tracker), "its trackers stay blocked");
  const note = await context.newPage();
  await note.addInitScript(([id, url]) => { chrome.tabs.query = async () => [{ id, url }]; chrome.tabs.reload = () => {}; },
    [await worker.evaluate(async (host) => (await chrome.tabs.query({})).find((t) => t.url?.includes(host)).id, "refuses.localhost"), at("refuses", "/refuses")]);
  await note.goto(`chrome-extension://${id}/popup.html`);
  await note.waitForTimeout(400);
  check(await note.isVisible("#ads") && !/Ads/.test(await note.textContent("#status")), "the popup says ads are allowed there, and doesn't claim otherwise");
  await note.click("#block-ads");
  await note.waitForTimeout(400);
  check(!(await note.isVisible("#ads")) && (await storage("adsKept")).includes("refuses.localhost"), "Block again takes it back");
  await note.close();
  await refusing.reload();
  await refusing.waitForTimeout(8500);
  check((await storage("softAds")).length === 0 && (await storage("adsAllowed")).length === 0, "and the page doesn't win it back");
  await refusing.close();

  // uBlock Origin's site rules: before the page runs, on sites with a rule only.
  const ruled = await context.newPage();
  const planted = (name) => ruled.evaluate((n) => window[n] === true, name);
  await ruled.goto(`http://${namedSite}/`);
  check(await planted(namedVar), `a named site's rule runs (${namedSite})`);
  await ruled.goto(`http://${wildSite}/`);
  check(await planted(wildVar), `a "name.*" rule runs on any ending (${wildSite})`);
  await ruled.goto("http://plain.example/");
  check(!(await planted(namedVar)) && !(await planted(wildVar)), "a site with no rule is untouched");
  await settings.evaluate((site) => chrome.runtime.sendMessage({ to: "change", body: { adsAllowed: [site] } }), namedKey);
  await ruled.goto(`http://${namedSite}/`);
  check(!(await planted(namedVar)), "nor where its ads are let through");
  await settings.evaluate(() => chrome.runtime.sendMessage({ to: "change", body: { adsAllowed: [] } }));
  await ruled.close();

  // A video that loops by itself waits until it's near the screen.
  const looped = await context.newPage();
  await looped.goto(at("loop", "/loop"));
  await looped.waitForTimeout(800);
  check(await looped.evaluate(() => !document.querySelector("#loop").hasAttribute("src")), "a looping video far down the page holds off");
  await looped.evaluate(() => document.querySelector("#loop").scrollIntoView());
  await looped.waitForTimeout(500);
  check(await looped.evaluate(() => document.querySelector("#loop").hasAttribute("src")), "and comes back near the screen");
  await looped.close();

  // The toolbar's mark follows the browser's light or dark, as the pages report it.
  const dark = await context.newPage();
  await dark.emulateMedia({ colorScheme: "dark" });
  await dark.goto(origin + "/");
  await dark.waitForTimeout(600);
  check((await worker.evaluate(() => chrome.storage.session.get("dark"))).dark === true, "a dark browser gets the light mark");
  await dark.emulateMedia({ colorScheme: "light" });
  await dark.waitForTimeout(600);
  check((await worker.evaluate(() => chrome.storage.session.get("dark"))).dark === false, "and back to black in light");
  await dark.close();

  // Off everywhere: the lists go off with it.
  await settings.evaluate(() => chrome.runtime.sendMessage({ to: "change", body: { on: false } }));
  const off = await worker.evaluate(() => chrome.declarativeNetRequest.getEnabledRulesets());
  check(off.length === 0, "off everywhere: no list on");
  await settings.evaluate(() => chrome.runtime.sendMessage({ to: "change", body: { on: true } }));
} finally {
  await context.close();
  server.close();
  fs.rmSync(profile, { recursive: true, force: true });
}

console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
