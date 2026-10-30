import Combine
import Foundation
import WebKit

// Read Later, as roko on iPhone has it: a page put aside to read another
// time (⇧⌘L, Tabs › Save to Read Later, or "read later" in ⌘T), kept in a
// list of its own (roko://later) with its site and its share picture.
// Opening it marks it read.
//
// The list is this Mac's, in read-later.json. With roko sync set up (the
// iPhone's key, Lists/RokoSpace.swift) it is the iPhone's too: the same
// "later" records its RokoSync writes (Browser/Today/RokoSync.swift there),
// with no text in them, so a page saved here is read for its text over
// there when it arrives, as the iPhone does with any page saved elsewhere.

/// A page put aside.
struct LaterPage: Codable, Identifiable, Equatable {
    /// The iPhone's id for it, a UUID in capitals as it writes them.
    var id: String
    var url: URL
    var title: String
    var site: String
    var savedAt: Date
    /// Opened since it was saved.
    var readAt: Date?
    /// Its share picture, for the list.
    var image: URL?

    var isRead: Bool { readAt != nil }
}

@MainActor
final class ReadLater: ObservableObject {
    static let shared = ReadLater()

    /// Newest first.
    @Published private(set) var pages: [LaterPage] = []

    private struct Saved: Codable {
        var pages: [LaterPage]
        /// The ids the server has had: one of them gone from it was taken
        /// off on the iPhone, where one never there was saved here before
        /// sync was set up and is sent up.
        var seen: [String]
    }

    private var seen: Set<String> = []
    private var bag: Set<AnyCancellable> = []
    private var file: URL { Store.file("read-later.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            pages = saved.pages
            seen = Set(saved.seen)
        }
        let space = RokoSpace.shared
        space.$later
            .combineLatest(space.$loaded)
            .sink { [weak self] things, loaded in
                guard loaded, !space.previewing else { return }
                DispatchQueue.main.async { self?.pull(things) }
            }
            .store(in: &bag)
        // Another space joined, or sync left: what that one had says nothing
        // about this one.
        space.$keyRevision.dropFirst().sink { [weak self] _ in self?.seen = [] }.store(in: &bag)
    }

    var unread: [LaterPage] { pages.filter { !$0.isRead } }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return pages.contains { Self.samePage($0.url, url) }
    }

    // MARK: Saving

    /// The page in front put aside, with its title and share picture; what
    /// happened, for the line at the bottom.
    func save(_ tab: Tab) async -> String {
        guard let url = tab.pageAddress, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "Only web pages go to Read Later"
        }
        if contains(url) { return "Already in Read Later" }
        let image = await Self.shareImage(of: tab.built)
        // Saved twice while the first was still looking for its picture.
        if contains(url) { return "Already in Read Later" }
        let page = LaterPage(id: UUID().uuidString, url: url, title: tab.title.isEmpty ? url.displayHost : tab.title,
                             site: url.displayHost, savedAt: .now, image: image)
        pages.insert(page, at: 0)
        persist()
        send(page)
        return "Saved to Read Later"
    }

    /// The page's og:image or twitter:image, when it names one over https.
    private static func shareImage(of web: WKWebView?) async -> URL? {
        guard let web, let base = web.url else { return nil }
        let found = try? await web.evaluateJavaScript("""
            (document.querySelector('meta[property="og:image"],meta[name="og:image"],meta[name="twitter:image"],meta[property="twitter:image"]') || {}).content || ""
            """) as? String
        guard let found, !found.isEmpty, let url = URL(string: found, relativeTo: base)?.absoluteURL,
              url.scheme == "https" else { return nil }
        return url
    }

    // MARK: Changing

    /// A tab landed on a page: put aside and not yet read, it is now.
    func opened(_ url: URL?) {
        guard let url, let index = pages.firstIndex(where: { !$0.isRead && Self.samePage($0.url, url) }) else { return }
        pages[index].readAt = .now
        persist()
        send(pages[index])
    }

    func markRead(_ id: String, _ read: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }), pages[index].isRead != read else { return }
        pages[index].readAt = read ? .now : nil
        persist()
        send(pages[index])
    }

    func remove(_ id: String) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: index)
        persist()
        if RokoSpace.shared.connected { RokoSpace.shared.remove("later", id: id) }
    }

    // MARK: With the iPhone

    private func send(_ page: LaterPage) {
        guard RokoSpace.shared.connected else { return }
        RokoSpace.shared.put("later", id: page.id, data: Self.record(page))
    }

    /// The record the iPhone's LaterRecord reads: times in milliseconds.
    static func record(_ page: LaterPage) -> [String: Any] {
        var data: [String: Any] = [
            "url": page.url.absoluteString, "title": page.title, "site": page.site,
            "saved": Int64(page.savedAt.timeIntervalSince1970 * 1000),
        ]
        data["image"] = page.image?.absoluteString ?? NSNull()
        data["read"] = page.readAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull()
        return data
    }

    static func page(_ thing: SpaceThing) -> LaterPage? {
        guard let text = thing.string("url"), let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        func date(_ key: String) -> Date? { thing.number(key).map { Date(timeIntervalSince1970: $0 / 1000) } }
        return LaterPage(id: thing.id, url: url, title: thing.string("title") ?? url.displayHost,
                         site: thing.string("site") ?? url.displayHost, savedAt: date("saved") ?? .now,
                         readAt: date("read"), image: thing.string("image").flatMap(URL.init(string:)))
    }

    /// The server's list put in place: its pages as it has them, the ones
    /// taken off on the iPhone gone here, and the ones only here sent up.
    func pull(_ things: [SpaceThing]) {
        let theirs = Dictionary(things.compactMap { thing in Self.page(thing).map { ($0.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        var merged = pages.compactMap { page -> LaterPage? in
            if let there = theirs[page.id] { return there }
            return seen.contains(page.id) ? nil : page
        }
        let unsent = merged.filter { theirs[$0.id] == nil }
        for (id, page) in theirs where !merged.contains(where: { $0.id == id }) { merged.append(page) }
        merged.sort { $0.savedAt > $1.savedAt }
        seen.formUnion(theirs.keys)
        if merged != pages { pages = merged }
        persist()
        unsent.forEach(send)
    }

    private func persist() {
        let saved = Saved(pages: pages, seen: Array(seen))
        let file = file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// The same page whatever its fragment.
    static func samePage(_ a: URL, _ b: URL) -> Bool {
        func plain(_ url: URL) -> String {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            return parts?.string ?? url.absoluteString
        }
        return plain(a) == plain(b)
    }
}

extension Browser {
    /// ⇧⌘L, Tabs › Save to Read Later.
    func saveForLater() {
        guard let tab = active else { return }
        Task { announce(await ReadLater.shared.save(tab)) }
    }
}
