import AppKit
import XCTest
@testable import Roko

/// Arc's folders: a folder inside a folder, shown under it, folded away
/// with it, kept in the session, and its tabs moved up when it goes.
@MainActor
final class FolderTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "folders-\(getpid())", 1)
        }
        super.setUp()
    }

    func testAFolderInsideAFolder() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs.filter { !$0.isBlank }
        let outer = browser.addTabGroup(containing: tabs[0])
        let inner = try XCTUnwrap(browser.addFolder(inside: outer, containing: tabs[1]))
        XCTAssertEqual(browser.depth(of: inner), 1)
        XCTAssertEqual(browser.shownFolders.map(\.group.id), [outer, inner])
        XCTAssertEqual(browser.shownFolders.map(\.depth), [0, 1])
        // Folded, the outer folder hides the one inside it.
        browser.toggleTabGroup(outer)
        XCTAssertEqual(browser.shownFolders.map(\.group.id), [outer])
        browser.toggleTabGroup(outer)
        // Its only tab moved out, the outer folder stays for the inner one.
        browser.move(tabs[0], toGroup: nil)
        XCTAssertTrue(browser.tabGroups.contains { $0.id == outer })
        // Removed, the inner folder's tab goes up into the outer one.
        browser.removeTabGroup(inner)
        XCTAssertEqual(tabs[1].groupID, outer)
    }

    func testAFoldersParentIsSavedAndReadBack() throws {
        let group = TabGroup(id: UUID(), name: "Inside", collapsed: true, parent: UUID())
        let back = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(back, group)
        let old = try JSONDecoder().decode(TabGroup.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old"}"#.utf8))
        XCTAssertNil(old.parent)
    }

    func testClosingAFolderClosesTheFoldersInside() throws {
        let browser = makeBrowser()
        let tabs = browser.tabs.filter { !$0.isBlank }
        let outer = browser.addTabGroup(containing: tabs[0])
        let inner = try XCTUnwrap(browser.addFolder(inside: outer, containing: tabs[1]))
        browser.closeTabGroup(outer)
        XCTAssertFalse(browser.tabGroups.contains { $0.id == outer || $0.id == inner })
        XCTAssertFalse(browser.tabs.contains { $0.id == tabs[1].id })
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
        browser.prefs.usesTabGroups = true
        for number in 1...3 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "https://folder-\(number).example/")!, title: "Tab \(number)")
        }
        return browser
    }
}
