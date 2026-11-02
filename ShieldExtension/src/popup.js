// The popup: Shield for the site you're on, what you have hidden there, the
// four kinds for every site, and Shield itself. What it shows comes from the background (background.js),
// which also makes every change, so the rules and this agree.

const NAMES = { ads: "ads", privacy: "trackers", cookies: "cookie notices", popups: "pop-ups" };
const ACCEPTED = {
  wall: "Cookies accepted here: the site won't open without them.",
  content: "Cookies accepted here: the site held the page back without them.",
  chosen: "Cookies accepted here, as you chose.",
};

const $ = (id) => document.getElementById(id);
let tab = null;
let view = null;

// MARK: The Eclipse (AppIcon.eclipse: a disc of 600 with a hole of 150 at 394)

let masks = 0;
function eclipse(holder) {
  const size = Number(holder.dataset.eclipse);
  const id = `hole-${++masks}`;
  holder.innerHTML = `
    <svg width="${size}" height="${size}" viewBox="0 0 600 600" aria-hidden="true">
      <mask id="${id}"><rect width="600" height="600" fill="#fff"/><circle class="hole" cx="394" cy="300" r="150" fill="#000"/></mask>
      <circle class="disc" cx="300" cy="300" r="300" mask="url(#${id})"/>
    </svg>`;
}
/** Closed: the Eclipse. Open: its hole moved to the middle, a ring left. */
function setOpen(holder, open) {
  const hole = holder.querySelector(".hole");
  const ring = Number(holder.dataset.eclipse) >= 24 ? 236 : 222;
  hole.style.cx = open ? "300px" : "394px";
  hole.style.r = open ? `${ring}px` : "150px";
}

// MARK: Showing

function list(words) {
  if (words.length < 2) return words.join("");
  return `${words.slice(0, -1).join(", ")} and ${words.at(-1)}`;
}

function render() {
  const { state, site, paused, accepted } = view;
  const on = state.on;
  const here = on && site && !paused;
  const kinds = Object.keys(NAMES).filter((k) => state.kinds[k]);

  $("site").textContent = site || "This page";
  let status;
  if (!on) status = "Off on every site.";
  else if (!site) status = "roko Shield works on web pages.";
  else if (paused) status = "Paused. This site loads as it would without roko.";
  else if (!kinds.length) status = "Every kind is switched off.";
  else {
    const words = kinds.map((k) => NAMES[k]);
    words[0] = words[0][0].toUpperCase() + words[0].slice(1);
    status = `${list(words)} kept off.`;
  }
  $("status").textContent = status;

  const mark = document.querySelector(".mark");
  mark.classList.toggle("off", !here);
  setOpen(mark, !here);

  const pause = $("pause");
  if (!on) {
    pause.hidden = false;
    pause.textContent = "Turn on everywhere";
  } else {
    pause.hidden = !site;
    pause.textContent = paused ? `Resume on ${site}` : `Pause on ${site}`;
  }

  $("cookies").hidden = !(here && accepted && state.kinds.cookies);
  $("cookies-why").textContent = ACCEPTED[accepted] || "";

  $("kinds").classList.toggle("resting", !on);
  for (const row of document.querySelectorAll(".kind[data-kind]")) {
    const value = !!state.kinds[row.dataset.kind];
    row.setAttribute("aria-checked", String(value));
    row.tabIndex = on ? 0 : -1;
    setOpen(row.querySelector("[data-eclipse]"), !value);
  }
  $("foot").hidden = !on;
  renderHidden();
}

// Hide Distracting Items: your own, kept whether Shield is on, off or paused.
function renderHidden() {
  const { site, hidden, shortcut } = view;
  $("here").hidden = !site;
  $("pick-key").textContent = shortcut || "";
  const list = $("veils");
  list.replaceChildren(...(hidden || []).map((veil) => {
    const row = document.createElement("div");
    row.className = "veil";
    const what = document.createElement("span");
    what.className = "what";
    const label = document.createElement("span");
    label.textContent = veil.label;
    what.append(label);
    if (veil.note) {
      const note = document.createElement("span");
      note.className = "note";
      note.textContent = veil.note;
      what.append(note);
    }
    const back = document.createElement("button");
    back.type = "button";
    back.className = "inline";
    back.textContent = "Restore";
    back.setAttribute("aria-label", `Restore ${veil.label}`);
    back.addEventListener("click", () => restore({ selector: veil.selector }));
    const look = () => send("peek", { tabId: tab.id, selector: veil.selector });
    row.addEventListener("mouseenter", look);
    back.addEventListener("focus", look);
    row.append(what, back);
    return row;
  }));
  $("restore-all").hidden = (hidden || []).length < 2;
}

const send = (to, body) => chrome.runtime.sendMessage({ to, body });

async function restore(which) {
  await send("restore", { tabId: tab.id, ...which });
  await load();
}

async function load() {
  view = await chrome.runtime.sendMessage({ to: "state", body: { url: tab?.url } });
  render();
}

async function change(patch, { reload = false } = {}) {
  await chrome.runtime.sendMessage({ to: "change", body: patch });
  // Network rules hold for the page's next requests; the page itself
  // needs loading again to be with or without them throughout.
  if (reload && tab?.id != null) chrome.tabs.reload(tab.id);
  await load();
}

// MARK: Controls

$("pause").addEventListener("click", () => {
  const { state, site, paused } = view;
  if (!state.on) return change({ on: true }, { reload: true });
  if (!site) return;
  // A site paused because a parent domain was: resuming takes that one off.
  const kept = state.paused.filter((p) => !(site === p || site.endsWith("." + p)));
  change({ paused: paused ? kept : [...state.paused, site] }, { reload: true });
});

$("master").addEventListener("click", () => change({ on: false }, { reload: true }));

$("reject").addEventListener("click", () => {
  const accepted = { ...view.state.accepted };
  delete accepted[view.site];
  change({ accepted }, { reload: true });
});

$("pick").addEventListener("click", async () => {
  // Out of the way, so the page can be pointed at.
  if (await send("pick", { tabId: tab.id })) window.close();
});
$("restore-all").addEventListener("click", () => restore({ all: true }));
// Leaving the list puts the page back the way it was.
$("veils").addEventListener("mouseleave", () => send("peek", { tabId: tab.id, selector: null }));
$("veils").addEventListener("focusout", (event) => {
  if (!$("veils").contains(event.relatedTarget)) send("peek", { tabId: tab.id, selector: null });
});

for (const row of document.querySelectorAll(".kind[data-kind]")) {
  row.addEventListener("click", () => {
    const kind = row.dataset.kind;
    change({ kinds: { [kind]: !view.state.kinds[kind] } });
  });
}

// MARK: Start

document.querySelectorAll("[data-eclipse]").forEach(eclipse);
[tab] = await chrome.tabs.query({ active: true, currentWindow: true });
await load();
requestAnimationFrame(() => requestAnimationFrame(() => document.body.classList.add("ready")));
