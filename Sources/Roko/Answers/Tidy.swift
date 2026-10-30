import Foundation
import FoundationModels

// Tidy, as Arc Max has it, written by Apple's model on this Mac, so no title
// or address leaves it:
//
//   Tidy Tab Titles: each loose tab's long title, shortened to the few words
//   that say what it is ("Pull requests · roko-mac · GitHub" → "roko-mac
//   PRs"), as its name; a tab you named yourself is left alone, and Rename
//   Tab gives any of them back their own.
//
//   Tidy Tabs: the loose tabs of the space, sorted into named groups by what
//   they are about; a group of one stays loose.
//
// Tabs menu, and "tidy titles" or "tidy tabs" typed into ⌘T.

@Generable(description: "Short names for browser tabs, in the order given")
struct TidyTitles {
    @Guide(description: "One short name per tab, two to four words, in the tab's own language, no site name unless it is the subject")
    var names: [String]
}

@Generable(description: "Browser tabs sorted into groups by topic")
struct TidyGroups {
    @Guide(description: "The groups, each with a short name and the numbers of its tabs")
    var groups: [TidyGroup]
}

@Generable(description: "One group of tabs")
struct TidyGroup {
    @Guide(description: "A short name for the group, one to three words")
    var name: String
    @Guide(description: "The numbers of the tabs in this group, as listed")
    var tabs: [Int]
}

@MainActor
enum Tidy {
    /// Whether this Mac has the model: Apple Intelligence on, and ready.
    static var available: Bool { SystemLanguageModel.default.isAvailable }

    /// The tabs worth tidying: loose web tabs in the space, not pinned, not
    /// private, not the bench's.
    static func loose(in browser: Browser) -> [Tab] {
        browser.tabs.filter { $0.pin == nil && $0.isWeb && !$0.shy && !$0.bench && browser.standsInRow($0) }
    }

    static func titles(in browser: Browser) {
        guard ready(browser) else { return }
        let tabs = loose(in: browser).filter { ($0.name ?? "").isEmpty && !$0.title.isEmpty }
        guard !tabs.isEmpty else { browser.announce("Nothing to tidy"); return }
        browser.announce("Tidying titles…")
        let list = tabs.enumerated().map { "\($0.offset + 1). \($0.element.title) (\($0.element.pageAddress?.displayHost ?? ""))" }
            .joined(separator: "\n")
        Task {
            do {
                let session = LanguageModelSession(instructions: """
                    You shorten browser tab titles so a narrow sidebar can show them. Keep what \
                    identifies the page; drop site names, separators and boilerplate.
                    """)
                let answer = try await session.respond(to: "Shorten each of these \(tabs.count) titles:\n\(list)",
                                                       generating: TidyTitles.self)
                var changed = 0
                for (tab, name) in zip(tabs, answer.content.names) {
                    let short = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !short.isEmpty, short.count < tab.title.count, (tab.name ?? "").isEmpty else { continue }
                    tab.name = short
                    changed += 1
                }
                browser.writeSessionSoon()
                browser.announce(changed == 0 ? "The titles were already short" : "Tidied \(changed) \(changed == 1 ? "title" : "titles")")
            } catch {
                browser.announce("Couldn't tidy the titles: \(error.localizedDescription)")
            }
        }
    }

    static func tabs(in browser: Browser) {
        guard ready(browser) else { return }
        let tabs = loose(in: browser).filter { browser.group(of: $0) == nil }
        guard tabs.count >= 3 else { browser.announce("Too few loose tabs to tidy"); return }
        browser.announce("Tidying tabs…")
        let list = tabs.enumerated().map { "\($0.offset + 1). \($0.element.label) (\($0.element.pageAddress?.displayHost ?? ""))" }
            .joined(separator: "\n")
        Task {
            do {
                let session = LanguageModelSession(instructions: """
                    You sort browser tabs into a few groups by what they are about, the way a person \
                    would tidy a desk: one task or topic per group. Two to five groups; a tab that fits \
                    nowhere is left out.
                    """)
                let answer = try await session.respond(to: "Sort these \(tabs.count) tabs:\n\(list)",
                                                       generating: TidyGroups.self)
                if !browser.prefs.usesTabGroups { browser.prefs.usesTabGroups = true }
                var made = 0
                var taken = Set<Int>()
                for group in answer.content.groups {
                    let members = group.tabs.filter { (1...tabs.count).contains($0) && !taken.contains($0) }
                    guard members.count >= 2 else { continue }
                    members.forEach { taken.insert($0) }
                    let first = tabs[members[0] - 1]
                    let id = browser.addTabGroup(containing: first)
                    browser.editingGroupID = nil
                    let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { browser.renameTabGroup(id, to: name) }
                    for number in members.dropFirst() { browser.move(tabs[number - 1], toGroup: id) }
                    made += 1
                }
                browser.announce(made == 0 ? "Nothing went together" : "Tidied into \(made) \(made == 1 ? "group" : "groups")")
            } catch {
                browser.announce("Couldn't tidy the tabs: \(error.localizedDescription)")
            }
        }
    }

    private static func ready(_ browser: Browser) -> Bool {
        guard available else {
            browser.announce("Tidying needs Apple Intelligence, on in System Settings")
            return false
        }
        return true
    }
}
