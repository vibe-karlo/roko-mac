// Hide Distracting Items: what you took off this site, put back on before the
// page has drawn, as roko's Curtain does, in the same "office-veil" sheet the
// pointing script's peek rebuilds. Read straight from storage, so a sleeping
// background never holds the page up. Your own choices: kept whether Shield
// is on, off or paused here.
(() => {
  if (window.top !== window || globalThis.__rokoVeils) return;
  globalThis.__rokoVeils = true;
  const key = "hidden:" + location.hostname.toLowerCase().replace(/^www\./, "");

  const show = (list) => {
    let sheet = document.getElementById("office-veil");
    const css = (list || []).map((veil) => `${veil.selector} { display: none !important; }`).join("\n");
    if (!css && !sheet) return;
    if (!sheet) {
      sheet = document.createElement("style");
      sheet.id = "office-veil";
      (document.head || document.documentElement).appendChild(sheet);
    }
    sheet.textContent = css;
  };
  chrome.storage.local.get(key).then((stored) => show(stored[key]), () => {});
  // Hidden or restored from another tab or the popup: this page follows.
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && key in changes) show(changes[key].newValue);
  });

  // The browser's light or dark, for the toolbar's mark (background.js), said
  // once per page and again when it changes.
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const tell = () => chrome.runtime.sendMessage({ to: "scheme", body: { dark: dark.matches } }).catch(() => {});
  tell();
  dark.addEventListener("change", tell);

  // For "Hide this" in the right-click menu: what the menu was opened over.
  addEventListener("contextmenu", (event) => { globalThis.__rokoContextTarget = event.target; }, true);
})();
