// Checks a built roko Shield in a hidden Chromium: the lists load, requests
// to ad hosts are refused, hiding and empty-slot folding work, a site paused
// loads untouched, and a pop-up window to an ad host is closed.
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
<div id="AdBillboard" class="box">billboard</div>
<ins class="adsbygoogle box"></ins>
<div class="post-ad-container box">Advertisement</div>
<div class="box" id="real">A real paragraph that is not an ad at all, and says so at length.</div>`;

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
