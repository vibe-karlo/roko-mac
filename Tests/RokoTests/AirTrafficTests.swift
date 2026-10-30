import XCTest
@testable import Roko

/// Links from other apps, into their site's space (AirTraffic.swift): where
/// it is pinned or open, then where you usually go to it, then here.
@MainActor
final class AirTrafficTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "air-traffic-\(getpid())", 1)
        setenv("ROKO_AIRTRAFFIC_TEST", "1", 1)
        super.setUp()
    }

    private func browser() -> (Browser, Space, Space) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.prefs.usesSpaces = true
        browser.prefs.airTraffic = true
        let home = Space.first()
        let work = Space(id: UUID(), name: "Work", colour: 0)
        browser.spaces = [home, work]
        AirTraffic.forget()
        return (browser, home, work)
    }

    func testAnUnknownSiteOpensHere() {
        let (browser, _, _) = browser()
        XCTAssertNil(AirTraffic.space(for: URL(string: "https://example.com/a")!, in: browser))
    }

    func testATabMovedThereTeachesWhereTheSiteGoes() {
        let (browser, _, work) = browser()
        AirTraffic.moved(URL(string: "https://www.figma.com/file/1")!, to: work.id)
        XCTAssertEqual(AirTraffic.space(for: URL(string: "https://figma.com/file/2")!, in: browser)?.id, work.id)
    }

    func testVisitsCountButASiteUsedEverywhereStaysPut() {
        let (browser, home, work) = browser()
        let url = URL(string: "https://github.com/x")!
        for _ in 0..<5 { AirTraffic.visited(url, in: work.id) }
        XCTAssertEqual(AirTraffic.space(for: url, in: browser)?.id, work.id)
        for _ in 0..<5 { AirTraffic.visited(url, in: home.id) }
        XCTAssertNil(AirTraffic.space(for: url, in: browser), "Half and half: no space is its place")
    }

    func testOpenHereWinsOverWhereItUsuallyGoes() {
        let (browser, _, work) = browser()
        let url = URL(string: "https://linear.app/team")!
        AirTraffic.moved(url, to: work.id)
        browser.tabs.first?.restore(url: url, title: "Linear")
        XCTAssertNil(AirTraffic.space(for: url, in: browser))
    }

    func testOffMeansHere() {
        let (browser, _, work) = browser()
        AirTraffic.moved(URL(string: "https://figma.com")!, to: work.id)
        browser.prefs.airTraffic = false
        XCTAssertNil(AirTraffic.space(for: URL(string: "https://figma.com/x")!, in: browser))
        browser.prefs.airTraffic = true
    }
}
