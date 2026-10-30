import Foundation

// Air Traffic Control, as Arc has it, but with no rules to write: a link from
// another app (Mail, Slack, a PDF) opens in the space its site belongs to.
// Where that is comes from what you already do:
//
//   1. a space that has the site pinned, then one that has it open;
//   2. the space you usually visit it in, learned as you browse: every visit
//      counts a little for the space it was in, and moving a tab to another
//      space counts a lot, since that is you saying where it goes;
//   3. otherwise, the space you are in.
//
// Only with spaces on and more than one of them, and only for links from
// other apps: a link clicked in a page stays where it was clicked. Settings
// › Spaces › "Links from other apps open in their site's space" turns it off.

@MainActor
enum AirTraffic {
    private static let key = "airTraffic.sites"
    /// Visits a space needs before it is the site's place, and the share of
    /// all its visits it must hold, so a site used everywhere stays put.
    private static let enough = 4
    private static let share = 0.6
    /// The most sites kept: the least used go first.
    private static let most = 600

    /// The site an address is on, as the routes are kept: the host without
    /// its www.
    static func site(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The space a link from another app should open in, when it isn't the
    /// one on screen; nil to open it where you are.
    static func space(for url: URL, in browser: Browser) -> Space? {
        guard browser.prefs.airTraffic, browser.prefs.usesSpaces, browser.spaces.count > 1,
              browser.active?.shy != true, let site = site(of: url) else { return nil }
        let spaces = browser.spaces
        func tabs(in space: Space) -> [Tab] {
            space.id == browser.spaceID ? browser.tabs : browser.parked[space.id]?.tabs ?? []
        }
        func has(_ tab: Tab) -> Bool { tab.pageAddress.flatMap(site(of:)) == site }
        // Pinned somewhere: that is its place, here included.
        if let pinned = spaces.first(where: { space in tabs(in: space).contains { $0.pin != nil && has($0) } }) {
            return pinned.id == browser.spaceID ? nil : pinned
        }
        // Open here: here. Open in one other space only: there.
        if tabs(in: spaces.first { $0.id == browser.spaceID } ?? spaces[0]).contains(where: has) { return nil }
        let open = spaces.filter { space in tabs(in: space).contains(where: has) }
        if open.count == 1 { return open[0] }
        // Where you usually go to it.
        let counts = (Store.settings.dictionary(forKey: key)?[site] as? [String: Int]) ?? [:]
        let total = counts.values.reduce(0, +)
        guard let (best, count) = counts.max(by: { $0.value < $1.value }), count >= enough,
              Double(count) / Double(max(total, 1)) >= share,
              best != browser.spaceID.uuidString,
              let space = spaces.first(where: { $0.id.uuidString == best }) else { return nil }
        return space
    }

    /// A page visited in a space: a little towards it being the site's place.
    static func visited(_ url: URL, in space: UUID) { count(url, in: space, by: 1) }

    /// A tab moved to a space by hand: a lot towards it.
    static func moved(_ url: URL, to space: UUID) { count(url, in: space, by: 6) }

    private static func count(_ url: URL, in space: UUID, by step: Int) {
        guard !Store.testing || ProcessInfo.processInfo.environment["ROKO_AIRTRAFFIC_TEST"] != nil,
              let site = site(of: url) else { return }
        var all = Store.settings.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
        var counts = all[site] ?? [:]
        counts[space.uuidString, default: 0] += step
        // Kept small: a site's counts halve once they grow large, so where
        // you go now outweighs where you went months ago.
        if counts.values.reduce(0, +) > 200 { counts = counts.mapValues { $0 / 2 }.filter { $0.value > 0 } }
        all[site] = counts
        if all.count > most {
            let least = all.sorted { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) }.prefix(all.count - most)
            for (site, _) in least { all[site] = nil }
        }
        Store.settings.set(all, forKey: key)
    }

    /// Forgotten with history: where you went is a list of where you have been.
    static func forget() {
        Store.settings.removeObject(forKey: key)
    }
}
