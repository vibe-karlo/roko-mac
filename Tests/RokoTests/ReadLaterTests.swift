import XCTest
@testable import Roko

/// Read Later's records as the iPhone reads and writes them, and the
/// server's list put in place (Lists/ReadLater.swift).
@MainActor
final class ReadLaterTests: XCTestCase {
    func testARecordGoesThereAndBackAsTheIPhoneHasIt() throws {
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        let page = LaterPage(id: "6F1C2B8E-0000-4000-8000-000000000001", url: URL(string: "https://example.com/a")!,
                             title: "A page", site: "example.com", savedAt: saved, readAt: nil,
                             image: URL(string: "https://example.com/a.jpg"))
        let record = ReadLater.record(page)
        XCTAssertEqual(record["saved"] as? Int64, 1_790_000_000_000)
        XCTAssertTrue(record["read"] is NSNull)
        // What the server hands back is JSON: numbers come as NSNumber.
        let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: record)) as! [String: Any]
        let back = try XCTUnwrap(ReadLater.page(SpaceThing(id: page.id, updated: 0, data: json)))
        XCTAssertEqual(back, page)
    }

    func testOnlyWebAddressesComeIn() {
        XCTAssertNil(ReadLater.page(SpaceThing(id: "x", updated: 0, data: ["url": "javascript:alert(1)", "title": "x"])))
        XCTAssertNil(ReadLater.page(SpaceThing(id: "x", updated: 0, data: ["title": "no address"])))
    }

    func testTheSamePageWhateverItsFragment() {
        XCTAssertTrue(ReadLater.samePage(URL(string: "https://e.com/a#top")!, URL(string: "https://e.com/a")!))
        XCTAssertFalse(ReadLater.samePage(URL(string: "https://e.com/a?x=1")!, URL(string: "https://e.com/a")!))
    }
}
