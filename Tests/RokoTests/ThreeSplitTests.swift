import AppKit
import XCTest
@testable import Roko

/// Split View with three pages (TabSplit.most): a third joins two, one of
/// three closing leaves the other two side by side, and the shares hold.
@MainActor
final class ThreeSplitTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "three-split-\(getpid())", 1)
        }
        super.setUp()
    }

    func testAThirdJoinsTwoAndStopsAtThree() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs.filter { !$0.isBlank }
        browser.select(tabs[0])
        browser.openInSplit(tabs[1])
        XCTAssertEqual(browser.activeSplit?.tabs.count, 2)
        browser.openInSplit(tabs[2])
        let split = try XCTUnwrap(browser.activeSplit)
        XCTAssertEqual(split.tabs, [tabs[0].id, tabs[1].id, tabs[2].id])
        XCTAssertEqual(split.sizes, TabSplit.even(3))
        // In the row they stand together, the first as the split's place.
        XCTAssertEqual(browser.displayedTabs.filter { split.contains($0.id) }.map(\.id), [tabs[0].id])
        XCTAssertTrue(Browser.holds(split, in: browser.tabs))
        // A fourth makes no fourth page.
        browser.addToSplit(tabs[3])
        XCTAssertEqual(browser.activeSplit?.tabs.count, 3)
    }

    func testOneOfThreeClosingLeavesTwo() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs.filter { !$0.isBlank }
        browser.select(tabs[0])
        browser.openInSplit(tabs[1])
        browser.openInSplit(tabs[2])
        browser.close(tabs[1])
        let split = try XCTUnwrap(browser.activeSplit)
        XCTAssertEqual(split.tabs, [tabs[0].id, tabs[2].id])
        XCTAssertEqual(split.sizes.reduce(0, +), 1, accuracy: 0.0001)
        browser.separateSplit()
        XCTAssertNil(browser.activeSplit)
    }

    func testSharesOfThreeStayWholeAndNoneTooNarrow() {
        let sizes = TabSplit.clamp([0.9, 0.05, 0.05])
        XCTAssertEqual(sizes.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertTrue(sizes.allSatisfy { $0 >= 0.1 })
        var split = TabSplit(tabs: [UUID(), UUID(), UUID()], sizes: [0.5, 0.25, 0.25])
        split.remove(split.tabs[0])
        XCTAssertEqual(split.sizes, [0.5, 0.5])
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        browser.record.rows = [:]
        browser.parked = [:]
        browser.tabGroups = []
        browser.prefs.splitView = true
        browser.prefs.usesTabGroups = false
        for number in 1...4 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "https://three-\(number).example/")!, title: "Tab \(number)")
        }
        return browser
    }
}
