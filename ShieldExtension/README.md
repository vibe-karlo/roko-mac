# roko Shield for Dia

roko's blocking as a Chrome extension, for Dia or any other Chromium browser (Chrome, Arc, Brave,
Edge). It is built from what roko on iPhone ships, so it blocks what roko blocks:

- **Ads and trackers**: EasyList, EasyPrivacy and Shield's own short list, as Chrome's network
  rules. A page you open yourself is never blocked, even an ad company's own site; its ads elsewhere
  are.
- **Cookie notices**: answered with "reject" by roko's cookie script (DuckDuckGo's Autoconsent),
  which loads after the page rather than before it. A site that won't open without cookies, or holds
  the page back, gets them accepted, and so does a wall whose only other way past is a subscription,
  whether or not a rule knows it. The popup says so, and "Reject instead" takes it back.
- **Anti-adblock walls**: uBlock Origin's site rules change a page before it runs so its wall never
  comes up, on about 8,200 sites. Where there's no rule, a "disable your ad blocker" box is known by
  what it says and how it sits, and goes with its backdrop.
- **A page that refuses to show**: its ad scripts are let through first, then, if that isn't enough,
  its ads, each with a reload. Trackers and pop-ups stay handled. The popup says so, and "Block again"
  takes it back for good.
- **Pop-ups and nags**: Fanboy's annoyance lists. Pop-up windows to ad sites are closed as they
  open.
- **Hidden leftovers**: element hiding is served page by page, and ad boxes left empty are folded
  away, as is a lone picture pinned along the bottom. Muted videos that loop by themselves wait until
  they're near the screen.
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

- `pull_lists.sh` copies roko's lists and page scripts from the iOS repository's `main` into `lists/`.
  Run it, then `build.py`, to catch up with roko. roko for Mac has its own copy in `Resources/Blocking`.
- `build.py` turns `lists/` into `build/roko-shield`:
  - Each WebKit rule is rewritten in Chrome's rule syntax: about 22,200 rules, inside the 30,000
    Chrome guarantees an extension. It prints what, if anything, couldn't be carried over.
  - The lists are given priorities, so one site can have the cookie list or the ad lists off while
    the rest stay on (`PRIORITY`; Chrome can't take a list off one site). An allowance holds from a
    page's next load. A site whose ads are let through has its cookie requests let through too, its
    notice still answered: two per-site steps can't be stacked both ways.
  - The hiding lists become JSON indexes.
  - The site rules are cut into 32 files, each loaded by Chrome only on the sites it names. `name.*`
    can't be a Chrome match pattern, so those 922 rules are one file on every page, which checks the
    site's name against a string and stops.
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

If Playwright's own Chromium is a different build from the one on this Mac, point `CHROMIUM` at the
one there.

The test runs a hidden Chromium against pages served from this machine. It checks that:

- ad hosts and trackers are refused, and the site's own requests load;
- hiding works, including on a site with a strict content security policy;
- empty ad boxes fold away, and boxes with real text stay;
- a pop-up window to an ad site is closed;
- a paused site loads untouched;
- turning it off everywhere takes every list off;
- Hide Distracting Items hides what you point at, keeps it across a reload, undoes with ⌘Z, stops
  with Esc, names what a right-click was over, and peeks and restores from the popup;
- anti-adblock and pay-or-consent walls go, also in a frame or on a page of their own, a sign-up page
  stays, and ad frames aren't sent the cookie rules;
- a page that refuses to show takes both steps, and "Block again" holds;
- site rules run on named and `name.*` sites only, looping videos wait, and a lone picture pinned
  along the bottom folds away.

## Not carried over from roko

- Reloading a page twice to be offered "Allow cookies": roko's own prompt, with no place in a toolbar
  popup yet.
- A page that crashes twice getting one more try without roko's changes: Chrome doesn't tell an
  extension that a tab crashed.
- The site rules' conditions were settled for WebKit on a phone (`Scripts/build_scriptlets.py` in the
  iOS repository). A few rules written only for Chromium aren't among them.

## Licences

Because it carries uBlock Origin's rules, roko Shield as a whole is GPL-3.0 ([LICENSE](LICENSE)), as
roko on iPhone is. Selling it stays allowed; its source has to stay available to whoever gets it.

- uBlock Origin's site rules (`lists/site-scripts.txt`): GPL-3.0.
- EasyList, EasyPrivacy and Fanboy's lists: GPL-3.0 or CC BY-SA 3.0.
- Autoconsent: MPL-2.0.
- The pointing script: from Search by Office Commun, MIT.
