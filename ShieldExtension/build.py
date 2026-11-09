#!/usr/bin/env python3
"""Builds roko Shield, roko's blocking as a Chrome extension (for Dia, Chrome,
Arc, Brave or any other Chromium browser), from what roko on iPhone ships.
pull_lists.sh copies that from the iOS repository into lists/; this turns it:

  lists/<kind>.json       WebKit content rules  -> rules/<kind>.json
  lists/<kind>-hosts.txt  blocked hosts         -> the same rule file
  lists/<kind>-hide.txt   element hiding        -> hide/<kind>.json
  lists/site-scripts.*    uBlock Origin's site rules -> site-scripts/*.js
  lists/*.js              the page scripts, as they are

Chrome's rules (declarativeNetRequest) say what WebKit's say in a simpler
pattern language. Each WebKit pattern is rewritten into it where it can be;
the rest stay patterns, of which Chrome takes 1,000 per list. Rules Chrome
can't hold at all (data: and about: addresses) are counted and left out, and
rules for pop-up windows go to the extension's own pop-up check instead.

Run: python3 ShieldExtension/build.py     Out: build/roko-shield (load it unpacked)
"""

import json
import re
import shutil
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HERE = Path(__file__).resolve().parent
LISTS = HERE / "lists"
SRC = HERE / "src"
OUT = ROOT / "build" / "roko-shield"

KINDS = ["ads", "privacy", "cookies", "popups"]
SITE_SHARDS = 32

# A block rule's and an exception's priority, per list. WebKit's lists can be
# taken off one site at a time; Chrome's can't, but a site's rule of a higher
# priority beats everything below it, so the lists are stacked in the order they
# come off (background.js): cookies for a site that's accepted them, then ads
# for a site that shows nothing without them. Trackers and pop-ups stay on top.
PRIORITY = {"cookies": (1, 2), "shield": (4, 5), "ads": (4, 5), "privacy": (7, 8), "popups": (7, 8)}
MOST_PATTERNS = 1000          # Chrome's regexFilter limit per list
HOSTS_PER_RULE = 4000

# Shield's own short list (Shield.swift): third parties whose only job is to
# watch or to sell, YouTube's ad paths (YouTubeAds.swift), and the few ad slots
# that are reliably nothing else. Kept in step with those two files by hand.
UNWANTED = [
    "doubleclick.net", "googlesyndication.com", "googleadservices.com",
    "googletagservices.com", "google-analytics.com", "googletagmanager.com",
    "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
    "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
    "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
    "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
    "33across.com", "teads.tv", "moatads.com", "adroll.com",
    "scorecardresearch.com", "quantserve.com", "chartbeat.com",
    "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
    "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
    "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
    "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
]
YOUTUBE_PATHS = ["/api/stats/ads", "/pagead/", "/ptracking", "/get_midroll_info",
                 "/youtubei/v1/player/ad_break", "/pcs/activeview"]
YOUTUBE_SITES = ["youtube.com", "youtube-nocookie.com"]
SLOTS = [
    ".adsbygoogle", "ins.adsbygoogle", '[id^="google_ads_"]',
    '[id^="div-gpt-ad"]', '[id^="taboola-"]', "#taboola-below-article",
    'iframe[src*="doubleclick.net"]', 'iframe[src*="googlesyndication"]',
    'iframe[src*="amazon-adsystem"]',
    ".ad-slot", ".ad-slot-container", ".top-banner-ad-container",
    ".ad-leaderboard", ".ad-billboard", ".ad-giga", ".ad-mpu", ".ad-mrec",
    ".ad-unit", ".adunit", ".adslot", ".dfp-ad", ".gpt-ad", ".w_ad",
]
SLOTS_BY_SITE = [
    (["as.com", "elpais.com"], ".ad"),
    (["theguardian.com"], ".top-fronts-banner-ad-container"),
    (["independent.co.uk", "the-independent.com"], "#billboard-wrapper"),
    (["cnn.com"], ".ad-slot-header__wrapper"),
]

TYPES = {
    "document": ["main_frame", "sub_frame"], "svg-document": ["sub_frame"],
    "image": ["image"], "style-sheet": ["stylesheet"], "script": ["script"],
    "font": ["font"], "media": ["media"], "ping": ["ping"],
    "fetch": ["xmlhttprequest"], "websocket": ["websocket"], "other": ["other"],
    "raw": ["xmlhttprequest", "websocket", "other"],
}

HOST_ANCHORS = ["^[^:]+://+([^/]+\\.)?", "^https?://([^/]+\\.)?", "^https?://"]


def domain(name):
    """A WebKit domain ("*example.com" takes its subdomains, as Chrome's always do)."""
    name = name.lstrip("*").lower()
    try:
        return name.encode("idna").decode("ascii")
    except UnicodeError:
        return None


def url_filter(pattern):
    """The WebKit pattern in Chrome's urlFilter syntax, or None if it needs a regex."""
    out = ""
    rest = pattern
    for anchor in HOST_ANCHORS:
        if rest.startswith(anchor):
            out, rest = "||", rest[len(anchor):]
            break
    else:
        if rest.startswith("^"):
            out, rest = "|", rest[1:]
    i = 0
    while i < len(rest):
        c = rest[i]
        if rest.startswith("[/:?&=]", i) or rest.startswith("[:/]", i):
            out += "^"
            i += 7 if rest.startswith("[/:?&=]", i) else 4
        elif rest.startswith(".*", i):
            out += "*"
            i += 2
        elif c == "\\" and i + 1 < len(rest):
            nxt = rest[i + 1]
            if nxt in "*^|" or nxt.isalnum():
                return None   # a literal Chrome would read as special, or a class like \d
            out += nxt
            i += 2
        elif c == "$" and i == len(rest) - 1:
            out += "|"
            i += 1
        elif c in ".[]()+?{}|*^$\\":
            return None
        else:
            out += c
            i += 1
    if not out or out.startswith("||*") or not out.isascii():
        return None
    return out


def condition_for(trigger):
    cond = {}
    types = trigger.get("resource-type")
    if types:
        mapped = sorted({t for name in types if name != "popup" for t in TYPES.get(name, [])})
        if not mapped:
            return None
        cond["resourceTypes"] = mapped
    load = trigger.get("load-type")
    if load == ["third-party"]:
        cond["domainType"] = "thirdParty"
    elif load == ["first-party"]:
        cond["domainType"] = "firstParty"
    for webkit, chrome in (("if-domain", "initiatorDomains"), ("unless-domain", "excludedInitiatorDomains")):
        if webkit in trigger:
            names = sorted({d for d in map(domain, trigger[webkit]) if d})
            if not names:
                return None
            cond[chrome] = names
    return cond


def popup_entry(trigger, allow):
    """A pop-up rule as background.js checks it: the WebKit pattern is a JS regex."""
    entry = {"r": trigger["url-filter"]}
    if allow:
        entry["a"] = 1
    if "if-domain" in trigger:
        entry["i"] = [d for d in map(domain, trigger["if-domain"]) if d]
    if "unless-domain" in trigger:
        entry["u"] = [d for d in map(domain, trigger["unless-domain"]) if d]
    load = trigger.get("load-type")
    if load == ["third-party"]:
        entry["t"] = 3
    elif load == ["first-party"]:
        entry["t"] = 1
    return entry


class Ruleset:
    def __init__(self, name):
        self.name = name
        self.rules = []
        self.patterns = 0
        self.dropped = {"address scheme": 0, "too many patterns": 0, "nothing Chrome can match": 0}
        self.popups = []

    def add(self, condition, allow):
        self.rules.append({
            "id": len(self.rules) + 1,
            "priority": PRIORITY[self.name][1 if allow else 0],
            "action": {"type": "allow" if allow else "block"},
            "condition": condition,
        })

    def webkit(self, rule):
        trigger, kind = rule["trigger"], rule["action"]["type"]
        if kind not in ("block", "ignore-previous-rules"):
            return
        allow = kind == "ignore-previous-rules"
        pattern = trigger["url-filter"]
        types = trigger.get("resource-type") or []
        if "popup" in types:
            self.popups.append(popup_entry(trigger, allow))
            if types == ["popup"]:
                return
        if re.match(r"\^(data|blob|about|javascript|dddata):", pattern):
            self.dropped["address scheme"] += 1
            return
        cond = condition_for(trigger)
        if cond is None:
            self.dropped["nothing Chrome can match"] += 1
            return
        plain = url_filter(pattern)
        if plain is not None:
            if plain != "*":
                cond["urlFilter"] = plain
        else:
            if self.patterns >= MOST_PATTERNS:
                self.dropped["too many patterns"] += 1
                return
            self.patterns += 1
            cond["regexFilter"] = pattern
        self.add(cond, allow)

    def opened_pages_allowed(self):
        """A page you open yourself is never blocked, even an ad or tracking company's own
        site (ContentBlocker.swift): the page you went to, and its own frames. Their ads and
        frames on other sites stay blocked. Above this list's own blocks, as WebKit's last
        exception is."""
        self.add({"resourceTypes": ["main_frame"]}, allow=True)
        self.add({"resourceTypes": ["sub_frame"], "domainType": "firstParty"}, allow=True)

    def hosts(self, names):
        names = sorted({d for d in map(domain, names) if d})
        for start in range(0, len(names), HOSTS_PER_RULE):
            self.add({"requestDomains": names[start:start + HOSTS_PER_RULE]}, allow=False)


def shield_rules():
    rules = Ruleset("shield")
    rules.add({"requestDomains": UNWANTED, "domainType": "thirdParty"}, allow=False)
    for path in YOUTUBE_PATHS:
        for site in YOUTUBE_SITES[:1]:
            rules.add({"urlFilter": f"||{site}{path}"}, allow=False)
    rules.add({"urlFilter": "||youtube.com/api/stats/qoe?*adformat="}, allow=False)
    for target in ("||google.com/pagead/", "||imasdk.googleapis.com/"):
        rules.add({"urlFilter": target, "initiatorDomains": YOUTUBE_SITES}, allow=False)
    return rules


def hide_index(text):
    """build_blocklists.py's hiding file: "key<TAB>selector" lines, then
    sections each opened by a \\x01 line (always, by site, sites left alone)."""
    keyed, always, scoped, untouched = {}, [], {}, []
    section = 0
    for line in text.split("\n"):
        if not line:
            continue
        if line[0] == "\x01":
            section += 1
            continue
        if section in (0, 2):
            key, _, selector = line.partition("\t")
            if not selector:
                continue
            (keyed if section == 0 else scoped).setdefault(key, []).append(selector)
        elif section == 1:
            always.append(line)
        else:
            untouched.append(line)
    return {"keyed": keyed, "always": always, "scoped": scoped, "untouched": untouched}


def picker():
    """Hide Distracting Items' pointing script, taken from Curtain.swift as it
    is (Search's, MIT), with two doors added for the extension: describe(el),
    for "Hide this" in the right-click menu, and isOn(), for the shortcut."""
    swift = (ROOT / "Sources" / "Roko" / "Curtain.swift").read_text(encoding="utf-8")
    start = swift.index('    static let picker = """\n') + len('    static let picker = """\n')
    end = swift.index('\n    """', start)
    lines = swift[start:end].split("\n")
    body = "\n".join(line[4:] if line.startswith("    ") else line for line in lines)
    # Swift's string escapes: only \\ is used, for the regular expressions' backslashes.
    assert "\\(" not in body, "the picker grew a Swift interpolation"
    body = body.replace("\\\\", "\\")
    door = "  window.__officeVeil = {\n"
    assert door in body, "Curtain.swift's picker changed shape"
    body = body.replace(door, door +
        "    describe: function (el) { return { selector: selectorFor(el), label: name(el), note: shape(el) }; },\n"
        "    isOn: function () { return live; },\n", 1)
    return ("// Hide Distracting Items' pointing mode: Veiling.picker in Sources/Roko/Curtain.swift\n"
            "// (from Search by Office Commun, MIT), copied by build.py with describe() and isOn() added.\n"
            + body + "\n")


def site_scripts():
    """uBlock Origin's site rules, as roko's site-scripts.js runs them. SiteScripts
    in the iOS app looks a site up in one table as a tab navigates; a page's script
    has to be there before the page runs, so here the table is cut up and each piece
    goes in with the engine, loaded by Chrome itself only on the sites it names.

    "name.*" (any ending) can't be a Chrome match pattern, so those rules are one
    file that runs on every page, and stops at once on a site that isn't one."""
    engine = (LISTS / "site-scripts.js").read_text(encoding="utf-8")
    assert "__ROKO_CALLS__" in engine, "site-scripts.js changed shape"
    named = [{} for _ in range(SITE_SHARDS)]
    wild = {}
    for line in (LISTS / "site-scripts.txt").read_text(encoding="utf-8").split("\n"):
        key, _, calls = line.partition("\t")
        if not calls:
            continue
        if key.endswith(".*"):
            wild[key] = calls
        else:
            named[zlib.crc32(key.encode()) % SITE_SHARDS][key] = calls

    def script(rows):
        # The names first, as one string: on a page that isn't listed (every page,
        # for any.js) nothing else is built before it stops.
        names = "|" + "|".join(sorted(rows)) + "|"
        table = ",".join(f"{json.dumps(key)}:{calls}" for key, calls in sorted(rows.items()))
        return ("(() => {\n"
                f"  const names = {json.dumps(names)};\n"
                '  const found = [], labels = location.hostname.toLowerCase().split(".");\n'
                '  const look = (key) => { if (names.includes("|" + key + "|")) found.push(key); };\n'
                "  for (let start = 0; start < labels.length - 1; start++) {\n"
                "    const suffix = labels.slice(start);\n"
                '    look(suffix.join("."));\n'
                '    for (const cut of [1, 2]) if (suffix.length > cut) look(suffix.slice(0, -cut).join(".") + ".*");\n'
                "  }\n"
                "  if (!found.length) return;\n"
                f"  const table = {{{table}}};\n"
                "  const calls = found.flatMap((key) => table[key]);\n"
                + engine.replace("__ROKO_CALLS__", "calls") +
                "})();\n")

    out = OUT / "site-scripts"
    out.mkdir(parents=True, exist_ok=True)
    shards = []
    for index, rows in enumerate(named):
        if not rows:
            continue
        (out / f"{index}.js").write_text(script(rows), encoding="utf-8")
        shards.append({"js": f"site-scripts/{index}.js", "matches": [f"*://*.{key}/*" for key in sorted(rows)]})
    (out / "any.js").write_text(script(wild), encoding="utf-8")
    write_json(out / "shards.json", shards)
    return sum(len(rows) for rows in named), len(wild)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(SRC, OUT)

    rulesets = [shield_rules()]
    popups = {}
    for kind in KINDS:
        rules = Ruleset(kind)
        hosts = LISTS / f"{kind}-hosts.txt"
        if hosts.exists():
            rules.hosts(hosts.read_text(encoding="utf-8").split())
        for rule in json.loads((LISTS / f"{kind}.json").read_text(encoding="utf-8")):
            rules.webkit(rule)
        rulesets.append(rules)
        popups[kind] = rules.popups
        write_json(OUT / "hide" / f"{kind}.json", hide_index((LISTS / f"{kind}-hide.txt").read_text(encoding="utf-8")))

    for rules in rulesets:
        rules.opened_pages_allowed()
        write_json(OUT / "rules" / f"{rules.name}.json", rules.rules)
    write_json(OUT / "rules" / "popup-windows.json", popups)
    css = ",\n".join(SLOTS) + " { display: none !important; }\n"
    (OUT / "slots.css").write_text(css)
    sites = []
    for index, (names, selector) in enumerate(SLOTS_BY_SITE):
        (OUT / f"slots-{index}.css").write_text(f"{selector} {{ display: none !important; }}\n")
        sites.append({"sites": names, "css": f"slots-{index}.css"})
    write_json(OUT / "slots-by-site.json", sites)

    for name in ("cosmetic-filter.js", "consent-main.js", "consent-frame.js"):
        shutil.copy(LISTS / name, OUT / name)
    # The frames that can hold a cookie pop-up, in the small script that asks for the rules.
    gate = (LISTS / "consent-frame-gate.json").read_text(encoding="utf-8").strip()
    load = (SRC / "consent-load.js").read_text(encoding="utf-8")
    assert "__FRAME_GATE__" in load
    (OUT / "consent-load.js").write_text(load.replace("__FRAME_GATE__", gate), encoding="utf-8")
    sites_named, sites_wild = site_scripts()
    (OUT / "picker.js").write_text(picker())

    manifest = json.loads((SRC / "manifest.json").read_text())
    manifest["version"] = (ROOT / "VERSION").read_text().strip()
    manifest["declarative_net_request"] = {"rule_resources": [
        {"id": r.name, "enabled": True, "path": f"rules/{r.name}.json"} for r in rulesets
    ]}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    total = 0
    print(f"roko Shield {manifest['version']} -> {OUT.relative_to(ROOT)}")
    for rules in rulesets:
        total += len(rules.rules)
        lost = ", ".join(f"{n} {why}" for why, n in rules.dropped.items() if n)
        print(f"  {rules.name:8} {len(rules.rules):6} rules, {rules.patterns:4} patterns"
              f"{', pop-up rules ' + str(len(rules.popups)) if rules.popups else ''}"
              f"{'; left out: ' + lost if lost else ''}")
    print(f"  {total} rules in all (Chrome guarantees 30,000)")
    print(f"  site rules: {sites_named} named sites, {sites_wild} under any ending")
    print(f"  lists version {(LISTS / 'version.txt').read_text().strip()}")
    if total > 30000:
        sys.exit("Too many rules for Chrome's guaranteed share.")


if __name__ == "__main__":
    main()
