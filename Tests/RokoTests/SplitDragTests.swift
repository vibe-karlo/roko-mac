import AppKit
import SwiftUI
import XCTest
@testable import Roko

/// A tab dragged out of the column onto a page, by real mouse events, in the
/// whole window (ContentView) placed far off every display: the side it is let
/// go on is the side it takes, with the column kept out or folded and slid out
/// over the page, and the tab carried is the tab that moves.
@MainActor
final class SplitDragTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.cancelTabEdit(); browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    override class func setUp() {
        setenv("SEARCH_PROBE", "split-drag-\(getpid())", 1)
        super.setUp()
    }

    func testRightEdgeTakesTheRight() async throws {
        let (browser, window, a, b) = try await setUp(folded: false)
        try await drag(b, toShare: 0.92, in: browser, window: window)
        XCTAssertEqual(browser.activeSplit?.tabs, [a.id, b.id], "Let go on the right, the tab carried is on the right")
    }

    func testLeftEdgeTakesTheLeft() async throws {
        let (browser, window, a, b) = try await setUp(folded: false)
        try await drag(b, toShare: 0.30, in: browser, window: window)
        XCTAssertEqual(browser.activeSplit?.tabs, [b.id, a.id], "Let go just right of the column, the tab carried is on the left")
    }

    func testFoldedColumnRightEdgeTakesTheRight() async throws {
        let (browser, window, a, b) = try await setUp(folded: true)
        try await drag(b, toShare: 0.92, in: browser, window: window)
        XCTAssertEqual(browser.activeSplit?.tabs, [a.id, b.id], "From the slid-out column, let go on the right: on the right")
    }

    func testFoldedColumnLeftEdgeTakesTheLeft() async throws {
        let (browser, window, a, b) = try await setUp(folded: true)
        try await drag(b, toShare: 0.30, in: browser, window: window)
        XCTAssertEqual(browser.activeSplit?.tabs, [b.id, a.id], "From the slid-out column, let go past it on the left: on the left")
    }

    func testLetGoOverTheColumnSplitsNothing() async throws {
        let (browser, window, _, b) = try await setUp(folded: true)
        try await drag(b, toShare: 0.05, in: browser, window: window)
        XCTAssertNil(browser.activeSplit, "Over the column lying on the page is still over the column")
    }

    // MARK: - the window and the drag

    private func setUp(folded: Bool) async throws -> (Browser, NSWindow, Roko.Tab, Roko.Tab) {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.sideHides, prefs.splitView, prefs.usesTabGroups, prefs.listsPins)
        restorePreferences = {
            (prefs.sidebar, prefs.sideHides, prefs.splitView, prefs.usesTabGroups, prefs.listsPins) = previous
        }
        prefs.sidebar = true
        prefs.sideHides = folded
        prefs.splitView = true
        prefs.usesTabGroups = false
        prefs.listsPins = false
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        for word in ["one", "two"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        let (a, b) = (browser.tabs[0], browser.tabs[1])
        browser.select(a)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1180, height: 780),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(browser: browser))
        window.orderFrontRegardless()
        browser.window = window
        windows.append(window)
        try await Task.sleep(for: .milliseconds(1500))
        window.displayIfNeeded()
        browser.folded = folded
        if folded { browser.peek(true) }
        try await Task.sleep(for: .milliseconds(500))
        return (browser, window, a, b)
    }

    /// From the middle of the tab's row to `share` of the window's width, on
    /// its middle line, in steps, resting there before letting go: the
    /// row's own drag gesture as it reports to TabDrag, with the pointer put
    /// where a hand would have it.
    private func drag(_ tab: Roko.Tab, toShare share: CGFloat, in browser: Browser, window: NSWindow) async throws {
        let row = try XCTUnwrap(TabDrag.shared.frame(row: tab, stage: false, in: browser), "the tab's row is in the column")
        let start = window.convertToScreen(NSRect(origin: NSPoint(x: row.midX, y: row.midY), size: .zero)).origin
        let end = window.convertToScreen(NSRect(origin: NSPoint(x: window.frame.width * share, y: window.frame.height / 2), size: .zero)).origin
        defer { TabDrag.shared.testPointer = nil }
        for step in 1...20 {
            let t = CGFloat(step) / 20
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            TabDrag.shared.testPointer = point
            _ = TabDrag.shared.update(browser: browser, tab: tab,
                                      translation: CGSize(width: point.x - start.x, height: start.y - point.y))
            try await Task.sleep(for: .milliseconds(16))
        }
        for _ in 0..<8 {
            _ = TabDrag.shared.update(browser: browser, tab: tab,
                                      translation: CGSize(width: end.x - start.x, height: start.y - end.y))
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(TabDrag.shared.carrying(in: browser), "the drag is under way")
        let finished = TabDrag.shared.finish(browser: browser, tab: tab)
        if case .stage(let target, let onLeft) = finished.drop {
            browser.pair(finished.source, with: target, onLeft: onLeft)
        }
        try await Task.sleep(for: .milliseconds(200))
    }

    private func send(_ type: NSEvent.EventType, _ point: NSPoint, _ window: NSWindow, pause: Int = 30) async throws {
        window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1)))
        try await Task.sleep(for: .milliseconds(pause))
    }
}
