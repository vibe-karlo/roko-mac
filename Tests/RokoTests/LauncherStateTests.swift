import AppKit
import Combine
import XCTest
@testable import Roko

/// Typing in ⌘T changes the field's own state, never the browser's: the
/// window, every tab's row and the menu bar watch the browser, and each key
/// used to redraw them all (Browser.launcher, Browser.swipe).
@MainActor
final class LauncherStateTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "launcher-state-\(getpid())", 1)
        }
        super.setUp()
    }

    func testTypingAndWalkingTheListLeaveTheBrowserAlone() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.launch()
        var browserChanges = 0, fieldChanges = 0
        let watching = [
            browser.objectWillChange.sink { _ in browserChanges += 1 },
            browser.launcher.objectWillChange.sink { _ in fieldChanges += 1 },
        ]
        for prefix in ["g", "gi", "git", "gith", "githu", "github"] { browser.typed = prefix }
        browser.picked = 0
        browser.picked = nil
        browser.spaceSwipe = 40
        browser.spaceSwipe = 0
        XCTAssertGreaterThan(fieldChanges, 6)
        XCTAssertEqual(browserChanges, 0)
        _ = watching
    }

    func testAPreloadedTopHitIsHandedOverAndOtherwiseLetGo() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let url = URL(string: "https://preload.example/")!
        let waiting = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.prepare(waiting)
        waiting.restore(url: url, title: "Preloaded")
        browser.preloaded = (waiting, url)
        // Another address: a tab of its own, the preload still waiting.
        let other = browser.open(URL(string: "https://elsewhere.example/")!, foreground: true)
        XCTAssertFalse(other === waiting)
        XCTAssertNotNil(browser.preloaded)
        // Its own address: the same tab, now in the row and in front.
        let opened = browser.open(url, foreground: true)
        XCTAssertTrue(opened === waiting)
        XCTAssertNil(browser.preloaded)
        XCTAssertEqual(browser.activeID, waiting.id)
        XCTAssertTrue(browser.tabs.contains { $0.id == waiting.id })
        // Let go: nothing waits.
        let spare = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.preloaded = (spare, url)
        browser.dropPreload()
        XCTAssertNil(browser.preloaded)
    }

    func testTheSpareIsTakenOnlyForItsOwnSpace() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let spare = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.prepare(spare)
        browser.spare = (spare, browser.spaceID)
        let opened = browser.open(URL(string: "https://spare.example/")!, foreground: true)
        XCTAssertTrue(opened === spare)
        XCTAssertNil(browser.spare)
        // Another space's spare has the wrong sign-ins: let go, not used.
        let stranger = Tab(configuration: Web.configuration(space: UUID()))
        browser.spare = (stranger, UUID())
        let other = browser.open(URL(string: "https://other.example/")!, foreground: true)
        XCTAssertFalse(other === stranger)
        XCTAssertNil(browser.spare)
    }
}
