// Half a megabyte of cookie rules cost every page more than the rest of roko's
// work on it. So only this goes in up front, and asks for the rules once the
// page has loaded, or after 0.4 s on a page still loading (ConsentHandler on
// iPhone).
//
// A frame asks only if it can be a pop-up: its address matches a frame rule, or
// it holds one of the banners any frame may hold, or it covers the page with a
// button saying yes. An ad-heavy page has dozens of frames, and most have none.
(() => {
  const gate = window.top === window ? null : __FRAME_GATE__;
  let begun = false, asked = false;
  const ask = () => {
    if (asked) return;
    asked = true;
    chrome.runtime.sendMessage({ to: "consent", body: { type: "rokoLoad" } }).catch(() => {});
  };
  const coversPage = () => innerWidth >= 280 && innerHeight >= 300
    && /accept|agree|consent|allow|acept|aceit|accett|akzept|zustimm|prihvat|prihvać/i.test(
      [...document.querySelectorAll("button, [role=button]")].slice(0, 12).map((b) => b.innerText).join(" "));
  const wanted = () => !gate
    || (gate.patterns && new RegExp(gate.patterns).test(location.href))
    || (gate.selectors && document.querySelector(gate.selectors) !== null)
    || coversPage();
  const begin = () => {
    if (begun) return;
    begun = true;
    if (wanted()) return ask();
    // A frame's banner can be drawn a moment after the frame loads.
    if (gate) for (const delay of [1500, 4000, 8000]) setTimeout(() => { if (!asked && wanted()) ask(); }, delay);
  };
  if (document.readyState === "complete") return begin();
  addEventListener("load", begin, { once: true });
  setTimeout(begin, 400);
})();
