import AppKit
import XCTest
@testable import Roko

/// What came over from Dia: the window tinted with the site's colour, Mute
/// All Tabs, and a pin's page made its home.
@MainActor
final class DiaTouchesTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "dia-touches-\(getpid())", 1)
        }
        super.setUp()
    }

    private func resolved(_ colour: NSColor, dark: Bool) -> NSColor {
        var out = colour
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = colour.usingColorSpace(.sRGB)!
        }
        return out
    }

    func testAGreyAskedForLeavesTheFrameGrey() {
        for site in [NSColor.white, .black, NSColor(white: 0.5, alpha: 1)] {
            XCTAssertTrue(SiteTint.blend(Palette.NS.frame, with: site) === Palette.NS.frame)
        }
        XCTAssertTrue(SiteTint.blend(Palette.NS.frame, with: nil) === Palette.NS.frame)
    }

    func testALoudColourArrivesQuietAtTheGreysLightness() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        for dark in [false, true] {
            let grey = resolved(Palette.NS.frame, dark: dark)
            let tinted = resolved(SiteTint.blend(Palette.NS.frame, with: red), dark: dark)
            // Redder than the grey, and nowhere near the red itself.
            XCTAssertGreaterThan(tinted.redComponent, tinted.greenComponent)
            let rgb = [tinted.redComponent, tinted.greenComponent, tinted.blueComponent]
            XCTAssertLessThan(rgb.max()! - rgb.min()!, 0.1)
            // Light stays light and dark stays dark, so the ink still reads.
            XCTAssertEqual(tinted.brightnessComponent, grey.brightnessComponent, accuracy: dark ? 0.16 : 0.06)
        }
    }

    func testMuteAllTabsAndBackAgain() {
        let browser = makeBrowser()
        browser.tabs[1].toggleMute()
        XCTAssertFalse(browser.allMuted)
        browser.toggleMuteAll()
        XCTAssertTrue(browser.tabs.filter(\.isWeb).allSatisfy(\.muted))
        XCTAssertTrue(browser.allMuted)
        browser.toggleMuteAll()
        XCTAssertTrue(browser.tabs.filter(\.isWeb).allSatisfy { !$0.muted })
    }

    func testAPinsPageMadeItsHome() throws {
        let browser = makeBrowser()
        let tab = browser.tabs[0]
        browser.pin(tab, listed: false)
        let home = try XCTUnwrap(tab.home)
        tab.restore(url: URL(string: "https://pin.example/elsewhere")!, title: "Elsewhere")
        browser.makeHome(tab)
        XCTAssertEqual(tab.home?.absoluteString, "https://pin.example/elsewhere")
        XCTAssertNotEqual(tab.home, home)
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
        for number in 1...3 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "https://dia-\(number).example/")!, title: "Tab \(number)")
        }
        return browser
    }
}
