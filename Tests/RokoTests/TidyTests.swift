import XCTest
@testable import Roko

/// Tidy Tab Titles and Tidy Tabs with this Mac's model. Live: only with
/// ROKO_LIVE_TESTS=1 and Apple Intelligence on.
@MainActor
final class TidyTests: XCTestCase {
    override class func setUp() { setenv("SEARCH_PROBE", "tidy-\(getpid())", 1); super.setUp() }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROKO_LIVE_TESTS"] == "1" && Tidy.available, "Live and Apple Intelligence only")
    }

    private func browser() -> Browser {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let pages = [
            ("https://github.com/driceroland/Search/pulls", "Pull requests · driceroland/Search · GitHub"),
            ("https://github.com/driceroland/Search/issues/12", "Split view drag goes left · Issue #12 · driceroland/Search · GitHub"),
            ("https://www.booking.com/hotel/hr/split.html", "Hotel Park Split, Split (updated prices 2026) | Booking.com"),
            ("https://www.google.com/travel/flights/zagreb-split", "Cheap flights from Zagreb to Split - Google Flights"),
            ("https://en.wikipedia.org/wiki/Diocletian%27s_Palace", "Diocletian's Palace - Wikipedia"),
            ("https://developer.apple.com/documentation/foundationmodels", "Foundation Models | Apple Developer Documentation"),
        ]
        for (index, page) in pages.enumerated() {
            if index > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: page.0)!, title: page.1)
        }
        return browser
    }

    func testTitlesGetShorter() async throws {
        let browser = browser()
        Tidy.titles(in: browser)
        for _ in 0..<120 where browser.tabs.allSatisfy({ ($0.name ?? "").isEmpty }) { try await Task.sleep(for: .milliseconds(500)) }
        try await Task.sleep(for: .milliseconds(500))
        let named = browser.tabs.compactMap(\.name)
        print("TIDY titles: \(named)")
        XCTAssertGreaterThanOrEqual(named.count, 4)
        for tab in browser.tabs { if let name = tab.name { XCTAssertLessThan(name.count, tab.title.count) } }
    }

    func testTabsGoIntoGroups() async throws {
        let browser = browser()
        Tidy.tabs(in: browser)
        for _ in 0..<120 where browser.tabGroups.isEmpty { try await Task.sleep(for: .milliseconds(500)) }
        try await Task.sleep(for: .milliseconds(800))
        print("TIDY groups: \(browser.tabGroups.map { "\($0.name): \(browser.tabs(in: $0.id).map(\.title))" })")
        XCTAssertFalse(browser.tabGroups.isEmpty)
        for group in browser.tabGroups { XCTAssertGreaterThanOrEqual(browser.tabs(in: group.id).count, 2) }
    }
}
