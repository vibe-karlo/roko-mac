// Checks a built roko Shield in a hidden Chromium: the lists load, requests
// to ad hosts are refused, hiding and empty-slot folding work, a site paused
// loads untouched, a pop-up window to an ad host is closed, and Hide
// Distracting Items hides, keeps, undoes, peeks and restores.
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

const server = http.createServer((req, res) => {
  res.setHeader("content-type", "text/html");
  // A site that allows no inline styles at all.
  if (req.url.startsWith("/strict")) res.setHeader("content-security-policy", "default-src 'self'; style-src 'self'");
  res.end(req.url.startsWith("/ok") ? "ok" : PAGE);
}).listen(0);
const origin = `http://localhost:${server.address().port}`;

const profile = fs.mkdtempSync(path.join(os.tmpdir(), "roko-shield-"));
const context = await chromium.launchPersistentContext(profile, {
  channel: "chromium",
  headless: true,
  args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
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
  check(["consent-main", "consent-frame", "hiding", "youtube-page"].every((id) => scripts.includes(id)), `page scripts registered (${scripts.length})`);

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
