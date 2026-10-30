import XCTest
@testable import Roko

/// Notify Me's reading and comparing (Watch/Watcher.swift), without a model.
@MainActor
final class NotifyMeTests: XCTestCase {
    func testAPageReadAsLinesWithItsOffersAndSizes() {
        let html = """
            <html><head><script type="application/ld+json">
            {"@type":"Product","name":"Linen shirt","offers":{"@type":"Offer","price":"39.95","priceCurrency":"EUR","availability":"https://schema.org/OutOfStock"}}
            </script></head><body><nav><p>Menu</p></nav>
            <h1>Linen shirt</h1><p>A shirt for warm days, made of washed linen.</p>
            <select><option>S</option><option disabled>M</option></select></body></html>
            """
        let lines = PageLines.lines(from: html)
        XCTAssertTrue(lines.contains("Product: Linen shirt"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Offer:") && $0.contains("sold out") && $0.contains("39.95 EUR") })
        XCTAssertTrue(lines.contains("Option: M (unavailable)"))
        XCTAssertTrue(lines.contains("A shirt for warm days, made of washed linen."))
        XCTAssertFalse(lines.contains("Menu"))
    }

    func testAReadingFromAnotherVersionIsTakenAfresh() async {
        var watch = Watch(url: "https://shop.example/a", title: "A")
        watch.snapshot = "old line"
        watch.readingVersion = PageLines.version - 1
        let checked = await Watcher.compare(watch, with: ["new line one", "new line two"])
        XCTAssertEqual(checked.snapshot, "new line one\nnew line two")
        XCTAssertEqual(checked.readingVersion, PageLines.version)
        XCTAssertNil(checked.lastNews)
    }

    func testAPageFarShorterThanBeforeIsNotThePage() async {
        var watch = Watch(url: "https://shop.example/a", title: "A")
        watch.snapshot = (1...40).map { "A long enough line of real text, number \($0)" }.joined(separator: "\n")
        watch.readingVersion = PageLines.version
        let checked = await Watcher.compare(watch, with: ["Access denied"])
        XCTAssertEqual(checked.snapshot, watch.snapshot)
        XCTAssertNil(checked.lastNews)
    }

    func testWithoutAModelANewLineAboutItCounts() {
        XCTAssertTrue(WatchJudge.guess(lookFor: "size M", added: ["Option: size M"]).happened)
        XCTAssertFalse(WatchJudge.guess(lookFor: "size M", added: ["Free delivery"]).happened)
    }
}
