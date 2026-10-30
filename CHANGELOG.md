# Changelog

roko for Mac, from the day it was forked from [Search](https://github.com/driceroland/Search).
Newest first.

## 1.0.7 (30 October 2026)

### Learning and small comforts

- ⌘T learns what you pick for what you type. Take Linear for "lin" once and "lin" puts it on top,
  with Return going there. Fewer letters need two picks, a newer habit wins over an old one, and
  picks fade after a month untouched. Cleared with your history; private tabs teach nothing.
- App icon (Settings › Appearance › Window): roko's mark in the iPhone app's colourways, or a
  picture of your own cut to the Mac icon shape. A Dock tile plug-in keeps it in the Dock after
  roko quits.
- ⌘Z outside a text box reopens the last closed tab, as in Arc. Pages that use ⌘Z themselves
  (Figma, Google Docs) still get it first.

### Faster

- A spare web view waits in every window, so the next tab starts loading at once.
- Pages you leave are paused after five seconds, unless they are playing, on a call, downloading,
  allowed to notify, or kept awake by you.
- The last two pages you left stay in the window, hidden, so switching back is instant.
- History is read in the background at launch; tab rows find their folder and split directly.
- ⌘T: typing no longer redraws the window, and the top result can start loading after a short
  pause.
- Fixed: a crash inside WebKit when a profile's data was deleted before WebKit had started.

### New

- Read Later (⇧⌘L), synced with roko on iPhone.
- Notify Me: watch a page and get a notification when it changes in a way you described, judged
  by Apple Intelligence on your Mac.
- Hide Distracting Items, renamed from Search's own tool.
- Split View with three pages, and Arc-style folders inside folders.
- From Dia: Copy Link copies a clean link, a Summarize button in the address bar, Mute All Tabs,
  Close Tabs Below, and a frame tinted by the site's colour.
- To-dos and shopping lists from roko on iPhone, as pages of their own.
- From Arc: links from other apps open in their site's space on their own, a player at the foot
  of the sidebar, Tidy Tab Titles and Tidy Tabs, and link previews with Shift held.
- Arc's and Dia's keyboard shortcuts by default, every one changeable.
- roko's own pages at roko://.
- Summarize Page (⇧⌘Y) and Browse for Me, written by Apple Intelligence, or by Claude with your
  own API key.
- iCloud history shared with roko on iPhone (needs a build signed with your own team).
- The ⌘T launcher as one card over the page: recent tabs, frequent sites, history, bookmarks,
  commands, answers (sums, units, currencies, dates, the time somewhere) and search.
- The address at the top of the sidebar, as in Arc, with a copy-link button.
- Drag a tab to the side of its page to split it with the one before; a tab carried out of its
  row follows the pointer as a card.
- "Add to roko" on the Chrome Web Store.
- roko's blocking, as on iPhone: ads, trackers, cookie notices (answered with "reject") and
  annoyances, as WebKit content rules.

### Changed from Search

- Its own name, icon, bundle id, settings, data folder and keychain items, so it can sit beside
  Search on one Mac.
- Search's AI add-on, its updater and its old What's New are gone.
- A right or middle click on a tab no longer selects it.
