// While pointing (picker.js, roko's own): Escape stops and ⌘Z puts the last
// one back, as in roko, and a line at the foot of the page says so, where
// roko says it at the foot of its window.
(() => {
  const veil = window.__officeVeil;
  if (!veil || veil.__keys) return;
  veil.__keys = true;
  const mac = /Mac/.test(navigator.platform);
  const undo = mac ? "⌘Z" : "Ctrl+Z";
  let line = null;

  const say = (text) => {
    if (!line) {
      line = document.createElement("div");
      line.style.cssText = "position:fixed;left:50%;bottom:18px;transform:translateX(-50%);" +
        "z-index:2147483647;pointer-events:none;max-width:calc(100vw - 32px);box-sizing:border-box;" +
        "font:500 12.5px/1.3 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;color:#fff;" +
        "background:#171717;padding:8px 13px;border-radius:8px;white-space:nowrap;overflow:hidden;" +
        "text-overflow:ellipsis";
      document.documentElement.appendChild(line);
    }
    line.textContent = text;
    line.style.display = text ? "block" : "none";
  };

  const keys = (event) => {
    const isUndo = (event.metaKey || event.ctrlKey) && !event.shiftKey && event.key.toLowerCase() === "z";
    if (event.key !== "Escape" && !isUndo) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.key === "Escape") return veil.off();
    chrome.runtime.sendMessage({ to: "veil", body: { undo: true } }).then((reply) => {
      say(reply && reply.back ? `${reply.back} is back.` : "Nothing left to bring back.");
    }, () => {});
  };

  // Each thing taken off is said, with the way back.
  const handler = globalThis.webkit.messageHandlers.officeVeil;
  const post = handler.postMessage;
  handler.postMessage = (body) => {
    const sent = post(body);
    if (body && body.selector) sent.then(() => say(`Hidden on this site. ${undo} brings it back, Esc stops.`), () => {});
    return sent;
  };

  const on = veil.on, off = veil.off;
  veil.on = function () {
    on.call(veil);
    addEventListener("keydown", keys, true);
    say("Click anything to hide it on this site. Esc stops.");
  };
  veil.off = function () {
    removeEventListener("keydown", keys, true);
    say("");
    off.call(veil);
  };
})();
