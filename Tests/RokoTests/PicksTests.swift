import AppKit
import XCTest
@testable import Roko

/// ⌘T learns what you pick for what you type (Picks.swift), as Cra's command
/// bar does.
@MainActor
final class PicksTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "picks-\(getpid())", 1)
        }
        super.setUp()
    }

    private func fresh() -> Picks {
        let picks = Picks(file: "picks-test-\(UUID().uuidString).json")
        return picks
    }

    func testOnePickIsEnoughForTheSameLetters() {
        let picks = fresh()
        let linear = URL(string: "https://linear.app/")!
        XCTAssertNil(picks.best(for: "lin"))
        picks.record("lin", url: linear, title: "Linear")
        XCTAssertEqual(picks.best(for: "lin")?.url, linear)
        // Case and spaces don't count.
        XCTAssertEqual(picks.best(for: " LIN ")?.url, linear)
        // Fewer letters need two picks; other letters, none.
        XCTAssertNil(picks.best(for: "li"))
        picks.record("lin", url: linear, title: "Linear")
        XCTAssertEqual(picks.best(for: "li")?.url, linear)
        XCTAssertNil(picks.best(for: "l"))
        XCTAssertNil(picks.best(for: "linx"))
    }

    func testTheLatestPickWinsAndOldPicksFade() {
        let picks = fresh()
        let linear = URL(string: "https://linear.app/")!
        let linkedin = URL(string: "https://www.linkedin.com/feed/")!
        for _ in 0..<3 { picks.record("lin", url: linear, title: "Linear") }
        picks.record("lin", url: linkedin, title: "LinkedIn")
        // Three for Linear halved to one and a half, against one: still Linear.
        XCTAssertEqual(picks.best(for: "lin")?.url, linear)
        picks.record("lin", url: linkedin, title: "LinkedIn")
        XCTAssertEqual(picks.best(for: "lin")?.url, linkedin)
        // Two months untouched: a single pick is no longer enough.
        let later = Date.now.addingTimeInterval(60 * 86_400)
        XCTAssertNil(picks.best(for: "lin", now: later))
    }

    func testForgettingThePageOrTheHistoryForgetsThePick() {
        let picks = fresh()
        let linear = URL(string: "https://linear.app/")!
        picks.record("lin", url: linear, title: "Linear")
        picks.forget(History.identity(for: linear))
        XCTAssertNil(picks.best(for: "lin"))
        picks.record("lin", url: linear, title: "Linear")
        picks.forget()
        XCTAssertNil(picks.best(for: "lin"))
        // A sentence is not a habit.
        picks.record(String(repeating: "word ", count: 12), url: linear, title: "Linear")
        XCTAssertTrue(picks.picks.isEmpty)
    }

    func testThePickedPageGoesOnTopAndReturnTakesIt() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let history = browser.history
        history.forget()
        let linkedin = URL(string: "https://www.linkedin.com/")!
        let linear = URL(string: "https://linear.app/")!
        let mail = URL(string: "https://mail.google.com/")!
        for _ in 0..<12 { history.record(linkedin, title: "LinkedIn") }
        history.record(linear, title: "Linear")
        history.record(mail, title: "Gmail")

        XCTAssertEqual(browser.placeOffers(for: "lin").offers.first?.url.host(), "www.linkedin.com")
        history.picks.record("lin", url: linear, title: "Linear")
        let (offers, ending) = browser.placeOffers(for: "lin")
        XCTAssertEqual(offers.first.map { History.identity(for: $0.url) }, History.identity(for: linear))
        // The field finishes towards the picked page, not the one under it.
        XCTAssertEqual(ending, "ear.app")

        // Letters that can't finish the picked page: no ending at all, and
        // Return still goes to it.
        history.picks.record("email", url: mail, title: "Gmail")
        let (mailOffers, mailEnding) = browser.placeOffers(for: "email")
        XCTAssertEqual(mailOffers.first?.url, mail)
        XCTAssertNil(mailEnding)

        browser.launch()
        browser.typed = "email"
        browser.submit()
        XCTAssertEqual(browser.active?.pageAddress.map(History.identity(for:)), History.identity(for: mail))
        history.forget()
    }

    func testReturnTeachesAndAPrivateTabDoesNot() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let history = browser.history
        history.forget()
        let linear = URL(string: "https://linear.app/")!
        history.record(linear, title: "Linear")
        browser.launch()
        browser.typed = "linea"
        browser.submit()
        XCTAssertEqual(history.picks.best(for: "linea")?.url.host(), "linear.app")
        history.forget()

        browser.newShyTab()
        history.record(linear, title: "Linear")
        browser.launch()
        browser.typed = "linea"
        browser.submit()
        XCTAssertNil(history.picks.best(for: "linea"))
        history.forget()
    }
}
