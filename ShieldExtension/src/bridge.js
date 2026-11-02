// roko's page scripts (cosmetic-filter.js, consent-main.js, consent-frame.js)
// speak to the app through WebKit's message handlers. In Chrome the same calls
// go to the extension's background, which answers as roko does. Content
// scripts run in a world of their own, so the page never sees this.
if (!globalThis.webkit?.messageHandlers?.cosmetic) {
  const to = (name) => ({ postMessage: (body) => chrome.runtime.sendMessage({ to: name, body }) });
  globalThis.webkit = { messageHandlers: { cosmetic: to("cosmetic"), consent: to("consent") } };
}
