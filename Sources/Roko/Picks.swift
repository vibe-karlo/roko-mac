import Foundation

// What you pick for what you type, as Cra's command bar has it: type "lin",
// take Linear, and next time "lin" puts Linear on top and Return goes there,
// whatever else "lin" matches and however often you have been to it. One
// pick is enough for exactly the same letters; for fewer letters ("li"
// after picks under "lin") it takes two. The page picked latest for some
// letters wins over one picked more often before: a habit that changed is
// taken at its word.
//
// Per profile, beside its history (History.picks), and gone with it: clearing
// the history clears these, a page forgotten takes its picks along, and a
// private tab teaches nothing.

@MainActor
final class Picks {
    struct Pick: Codable, Equatable {
        var url: String
        var title: String
        /// How strongly these letters mean this page: one for each time it
        /// was taken, and less each time another page was.
        var weight: Double
        var last: Date
    }

    /// What was typed, as `key(_:)` keeps it, to the pages taken for it by
    /// History.identity.
    private(set) var picks: [String: [String: Pick]] = [:]
    private let fileName: String
    private var retired = false
    private var file: URL { Store.file(fileName) }

    /// Most kinds of letters kept; what goes is what was picked longest ago.
    static let most = 400

    init(file: String) {
        fileName = file
        if let data = try? Data(contentsOf: Store.file(file)),
           let read = try? JSONDecoder().decode([String: [String: Pick]].self, from: data) {
            picks = read
        }
    }

    /// Letters as they are compared: case and the spaces around and between
    /// words don't count, and a whole sentence is not a habit.
    nonisolated static func key(_ typed: String) -> String? {
        let words = typed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty, words.count <= 40 else { return nil }
        return words
    }

    /// `url` taken for `typed`.
    func record(_ typed: String, url: URL, title: String, now: Date = .now) {
        guard !retired, let key = Self.key(typed) else { return }
        let identity = History.identity(for: url)
        var taken = picks[key] ?? [:]
        for (other, var pick) in taken where other != identity {
            pick.weight *= 0.5
            taken[other] = pick.weight < 0.2 ? nil : pick
        }
        var pick = taken[identity] ?? Pick(url: url.absoluteString, title: title, weight: 0, last: now)
        pick.weight = min(pick.weight + 1, 20)
        pick.last = now
        if !title.isEmpty { pick.title = title }
        pick.url = url.absoluteString
        taken[identity] = pick
        picks[key] = taken
        if picks.count > Self.most {
            let oldest = picks.sorted { newest($0.value) < newest($1.value) }.prefix(picks.count - Self.most)
            oldest.forEach { picks[$0.key] = nil }
        }
        save()
    }

    /// The page these letters have come to mean, and how strongly: at least
    /// one for the same letters picked once, two for fewer letters.
    func best(for typed: String, now: Date = .now) -> (url: URL, title: String, strength: Double)? {
        guard let key = Self.key(typed) else { return nil }
        var found: (url: URL, title: String, strength: Double)?
        for (letters, taken) in picks {
            let share: Double
            if letters == key {
                share = 1
            } else if key.count >= 2, letters.hasPrefix(key) {
                share = 0.5
            } else {
                continue
            }
            for pick in taken.values {
                // Half as strong for each month since it was last taken,
                // after a week in which it holds.
                let months = max(0, now.timeIntervalSince(pick.last) - 7 * 86_400) / (30 * 86_400)
                let strength = pick.weight * share * pow(0.5, months)
                guard strength >= 1, strength > (found?.strength ?? 0), let url = URL(string: pick.url) else { continue }
                found = (url, pick.title, strength)
            }
        }
        return found
    }

    /// A page gone from the history: what was picked for it goes too.
    func forget(_ identity: String) {
        var changed = false
        for (letters, var taken) in picks where taken[identity] != nil {
            taken[identity] = nil
            picks[letters] = taken.isEmpty ? nil : taken
            changed = true
        }
        if changed { save() }
    }

    func forget() {
        picks = [:]
        save()
    }

    func retire() {
        retired = true
        picks = [:]
        Disk.remove(file)
    }

    private func newest(_ taken: [String: Pick]) -> Date {
        taken.values.map(\.last).max() ?? .distantPast
    }

    private func save() {
        guard !retired else { return }
        let snapshot = picks
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}
