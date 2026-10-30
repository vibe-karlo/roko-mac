import Foundation

// roko's own sync, from the Mac: the to-dos and shopping lists of roko on
// iPhone, through roko's server, the same records the Raycast extension reads
// (Browser/Today/RokoSync.swift on the iPhone, Raycast/src/sync.ts). The key
// is the iPhone's (Settings › Mac sync there: Copy Key), kept in this Mac's
// keychain. The whole space is read when a list page opens, then what changed
// every few seconds while one is showing; a change goes up at once, with the
// time it was made, and the later change wins.
//
// A record's data is kept whole, as the iPhone wrote it: a change made here
// sets only what it means to set, and every field the Mac doesn't show (an
// item's aisle, a habit) goes back up as it came.

/// One thing in the space: its id, when it last changed, and its data.
struct SpaceThing: Identifiable {
    let id: String
    var updated: Double
    var data: [String: Any]

    func string(_ key: String) -> String? { data[key] as? String }
    func bool(_ key: String) -> Bool { data[key] as? Bool ?? false }
    func number(_ key: String) -> Double? { (data[key] as? NSNumber)?.doubleValue }
}

@MainActor
final class RokoSpace: ObservableObject {
    static let shared = RokoSpace()
    static let server = URL(string: "https://roko-share.roko-browser.workers.dev")!

    @Published private(set) var todos: [SpaceThing] = []
    @Published private(set) var shopping: [SpaceThing] = []
    /// Pages put aside to read later (ReadLater keeps its own list from these).
    @Published private(set) var later: [SpaceThing] = []
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false
    /// Bumped when the key changes, so pages read `connected` again.
    @Published private(set) var keyRevision = 0

    private var since = 0
    private var poller: Task<Void, Never>?
    /// Pages showing a list: polled only while there is one.
    private var watchers = 0

    var connected: Bool { previewing || (Keychain.syncKey ?? "").contains(".") }
    /// For a picture of the pages with lists of the test's own, never the
    /// keychain's key.
    var previewing = false

    /// The test's lists, put in place without a server.
    func preview(todos: [SpaceThing], shopping: [SpaceThing]) {
        previewing = true
        self.todos = todos
        self.shopping = shopping
        loaded = true
    }

    // MARK: The key

    /// A key pasted from the iPhone: "<space>.<secret>". True when it reads.
    func join(_ key: String) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^[A-Za-z0-9]{10}\.[A-Za-z0-9_-]{16,}$"#, options: .regularExpression) != nil else {
            problem = "That isn't a roko sync key. On your iPhone: roko › Settings › Mac sync › Copy Key."
            return false
        }
        let before = Keychain.syncKey
        Keychain.syncKey = key
        reset()
        await refresh()
        if problem != nil {
            Keychain.syncKey = before
            reset()
            return false
        }
        keyRevision += 1
        return true
    }

    func leave() {
        Keychain.syncKey = nil
        reset()
        keyRevision += 1
    }

    private func reset() {
        since = 0
        todos = []
        shopping = []
        later = []
        loaded = false
        problem = nil
    }

    // MARK: Reading

    /// A list page appeared: read now, and every few seconds while it shows.
    func watch() {
        watchers += 1
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        poller?.cancel()
        poller = nil
    }

    /// What changed since the last read, put in place.
    func refresh() async {
        guard connected, !previewing else { return }
        var more = true
        do {
            while more {
                let page = try await call("/api/sync?since=\(since)")
                for change in page["changes"] as? [[String: Any]] ?? [] { apply(change) }
                since = page["seq"] as? Int ?? since
                more = page["more"] as? Bool ?? false
            }
            problem = nil
            loaded = true
        } catch {
            problem = error.localizedDescription
        }
    }

    private func apply(_ change: [String: Any]) {
        guard let kind = change["kind"] as? String, let id = change["id"] as? String else { return }
        let deleted = change["deleted"] as? Bool ?? false
        let data = change["data"] as? [String: Any]
        let updated = (change["updated"] as? NSNumber)?.doubleValue ?? 0
        func merge(_ list: inout [SpaceThing]) {
            list.removeAll { $0.id == id }
            if !deleted, let data { list.append(SpaceThing(id: id, updated: updated, data: data)) }
        }
        switch kind {
        case "todo": merge(&todos)
        case "shopping": merge(&shopping)
        case "later": merge(&later)
        default: break
        }
    }

    // MARK: Writing

    /// A thing changed here: in place at once, then up to the server.
    func put(_ kind: String, id: String, data: [String: Any]) {
        let updated = Date.now.timeIntervalSince1970 * 1000
        apply(["kind": kind, "id": id, "data": data, "updated": updated])
        send([["kind": kind, "id": id, "data": data, "updated": updated]])
    }

    func remove(_ kind: String, id: String) {
        let updated = Date.now.timeIntervalSince1970 * 1000
        apply(["kind": kind, "id": id, "deleted": true, "updated": updated])
        send([["kind": kind, "id": id, "deleted": true, "updated": updated]])
    }

    func put(_ kind: String, _ things: [(id: String, data: [String: Any])]) {
        let updated = Date.now.timeIntervalSince1970 * 1000
        let changes = things.map { ["kind": kind, "id": $0.id, "data": $0.data, "updated": updated] as [String: Any] }
        changes.forEach(apply)
        send(changes)
    }

    private func send(_ changes: [[String: Any]]) {
        guard connected, !changes.isEmpty, let body = try? JSONSerialization.data(withJSONObject: ["changes": changes]) else { return }
        Task {
            do {
                _ = try await call("/api/sync", method: "POST", body: body)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    static func newID() -> String { UUID().uuidString.lowercased() }
    nonisolated static var now: Double { Date.now.timeIntervalSince1970 * 1000 }

    // MARK: The server

    private struct ServerError: LocalizedError {
        let errorDescription: String?
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    private func call(_ path: String, method: String = "GET", body: Data? = nil) async throws -> [String: Any] {
        guard let key = Keychain.syncKey, let url = URL(string: Self.server.absoluteString + path) else {
            throw ServerError(errorDescription: "No sync key")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        let (data, response) = try await Self.session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ServerError(errorDescription: json["error"] as? String
                              ?? (status == 401 || status == 404 ? "roko's server doesn't know this key" : "roko's server answered \(status)"))
        }
        return json
    }
}

// MARK: - Days, as roko writes them

enum SpaceDay {
    /// "2026-10-30", a number of days from today.
    static func string(_ offset: Int = 0, from now: Date = .now) -> String {
        let day = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func string(of milliseconds: Double?) -> String? {
        guard let milliseconds else { return nil }
        return string(0, from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    /// "Thu 6 Nov" for a day further off.
    static func short(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// A to-do as typed, as roko reads one on the iPhone and in Raycast: "call
/// the dentist tomorrow at 15" is for tomorrow at 15:00, "pay rent someday"
/// for someday, anything else for today. English and Croatian.
enum TodoWords {
    static func parse(_ typed: String, now: Date = .now) -> [String: Any]? {
        var title = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var day: String? = SpaceDay.string(0, from: now)
        var time: String?
        if let clock = title.firstMatch(of: /(?i)\s+(?:at|u)\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?\s*$/),
           var hour = Int(clock.1) {
            let half = clock.3.map { String($0).lowercased() }
            if half == "pm", hour < 12 { hour += 12 }
            if half == "am", hour == 12 { hour = 0 }
            if hour < 24 {
                time = String(format: "%02d:%@", hour, clock.2.map(String.init) ?? "00")
                title = String(title[..<clock.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        let words = /(?i)(?:^|\s+)(today|danas|tomorrow|sutra|someday|jednom)$/
        let leading = /(?i)^(today|danas|tomorrow|sutra|someday|jednom)\s+/
        if let when = title.firstMatch(of: words) ?? title.firstMatch(of: leading) {
            let word = when.1.lowercased()
            if word == "tomorrow" || word == "sutra" { day = SpaceDay.string(1, from: now) }
            if word == "someday" || word == "jednom" { day = nil; time = nil }
            title.removeSubrange(when.range)
            title = title.trimmingCharacters(in: .whitespaces)
        }
        guard let first = title.first else { return nil }
        title = first.uppercased() + title.dropFirst()
        var data: [String: Any] = ["title": title, "week": false, "done": false, "created": RokoSpace.now]
        data["day"] = day ?? NSNull()
        data["time"] = time ?? NSNull()
        return data
    }
}

/// Things to buy, as roko lists them.
enum ShoppingWords {
    static let shops: [(id: String, name: String)] = [("grocery", "Groceries"), ("drugstore", "Drugstore"), ("pharmacy", "Pharmacy")]

    /// The walk through a shop, as roko orders its aisles, and their names.
    static let aisles: [(id: String, name: String)] = [
        ("produce", "Fruit and vegetables"), ("bakery", "Bread and bakery"), ("meat", "Meat and fish"),
        ("dairy", "Dairy and eggs"), ("frozen", "Frozen"), ("pantry", "Pantry"),
        ("breakfast", "Coffee, tea and breakfast"), ("sweets", "Sweets and snacks"), ("drinks", "Drinks"),
        ("household", "Household"), ("personal", "Personal care"), ("baby", "Baby"), ("pets", "Pets"),
        ("medicine", "Medicines and health"), ("other", "Other"),
    ]

    static func aisleName(_ id: String?) -> String {
        guard let id else { return "Sorting on your iPhone" }
        return aisles.first { $0.id == id }?.name ?? "Other"
    }

    /// The list an item is on: the one it was put on by hand, else where its
    /// aisle is bought, else groceries.
    static func shop(of item: SpaceThing) -> String {
        if let pinned = item.string("pinned"), !pinned.isEmpty { return pinned }
        return item.string("shop") ?? "grocery"
    }

    /// "milk, eggs and bread" is three; "mlijeko, jaja i kruh" too.
    static func split(_ typed: String) -> [String] {
        typed.split(separator: /,|;|\n|\s+(?:and|i)\s+/)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// How roko compares things to buy: "2x Mlijeko" and "mlijeko" are one.
    static func key(_ title: String) -> String {
        title.lowercased()
            .replacing(/^\d+\s*x\s*/, with: "")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
