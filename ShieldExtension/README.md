# roko Shield for Dia

roko's blocking as a Chrome extension, for Dia or any other Chromium browser (Chrome, Arc, Brave,
Edge). It is built from the same files roko ships, so it blocks what roko blocks:

- **Ads and trackers**: EasyList, EasyPrivacy and Shield's own short list, as Chrome's network
  rules.
- **Cookie notices**: answered with "reject" by roko's cookie script (DuckDuckGo's Autoconsent).
  A site that won't open without cookies, or holds the page back, gets them accepted. The popup
  says so, and "Reject instead" takes it back.
- **Pop-ups and nags**: Fanboy's annoyance lists. Pop-up windows to ad sites are closed as they
  open.
- **Hidden leftovers**: element hiding is served page by page, and ad boxes left empty are folded
  away.
- **YouTube's ads**: taken out of the player's data, with a muted 16× fallback, as in roko.
- **Hide Distracting Items**: Hide something… in the popup, ⌘⇧H, or Hide this in the right-click
  menu. What you point at goes for good on that site and stays off as pages load. ⌘Z while pointing
  brings back the last one, and Esc stops. The popup lists what's hidden: rest on a line to see that
  thing outlined on the page, then Restore it. Private windows keep their hides for the tab only.
  These are your own choices, so they stay whether Shield is on, off or paused.

As in roko, it shows no counter. The toolbar's Eclipse is black where Shield is on (light on a
dark toolbar) and opens into a grey ring where it is paused or off.

## Install in Dia

```bash
python3 ShieldExtension/build.py
```

1. Open `chrome://extensions` in Dia.
2. Turn on Developer mode.
3. Choose Load unpacked and pick `build/roko-shield`.

⌘⇧H is only a suggestion: Chrome's `chrome://extensions/shortcuts` changes it, and the popup
shows whichever key is set.

If you have another blocker installed (Dia's uBlock Origin Lite, say), turn it off: two blockers
block everything twice and break more sites.

## How it is made

- `build.py` turns `Resources/Blocking` into `build/roko-shield`:
  - Each WebKit rule is rewritten in Chrome's rule syntax: 22,010 rules, inside the 30,000 Chrome
    guarantees an extension. It prints what, if anything, couldn't be carried over.
  - The hiding lists become JSON indexes.
  - roko's page scripts are copied as they are.
- `src/bridge.js` lets those page scripts talk to `src/background.js` where in roko they talk to
  the app. `background.js` answers as `Blocklists.swift` does.
- `build_snippets.sh` rebuilds `src/consent-snippets.js`, Autoconsent's page steps (MPL-2.0), when
  roko's Autoconsent version changes.
- `make_icons.py` draws the toolbar icons from roko's Eclipse.
- Hide Distracting Items' pointing script is copied by `build.py` from `Curtain.swift` (Search's,
  MIT), with `describe()` and `isOn()` added. `src/veils.js` puts hides back on before a page draws,
  and `src/picker-keys.js` adds Esc, ⌘Z and the line at the foot of the page.
- Shield's own list and the YouTube scripts are copied from `Shield.swift` and `YouTubeAds.swift`.
  When those change, update `build.py` and `src/youtube-*.js` to match.

## Test

```bash
npm i playwright-core && npx playwright-core install chromium
node ShieldExtension/test.mjs
```

The test runs a hidden Chromium against pages served from localhost. It checks that:

- ad hosts and trackers are refused, and the site's own requests load;
- hiding works, including on a site with a strict content security policy;
- empty ad boxes fold away, and boxes with real text stay;
- a pop-up window to an ad site is closed;
- a paused site loads untouched;
- turning it off everywhere takes every list off;
- Hide Distracting Items hides what you point at, keeps it across a reload, undoes with ⌘Z, stops
  with Esc, names what a right-click was over, and peeks and restores from the popup.

## Licences

- EasyList, EasyPrivacy and Fanboy's lists: their authors' terms (GPL-3.0 / CC BY-SA 3.0).
- Autoconsent: MPL-2.0.
- The rest: MIT, as roko.
