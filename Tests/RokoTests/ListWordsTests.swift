import XCTest
@testable import Roko

/// To-dos and shopping as typed (Lists/RokoSpace.swift), read as roko on
/// iPhone and its Raycast extension read them.
final class ListWordsTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!

    func testATodoIsForTodayUnlessSaidOtherwise() throws {
        let todo = try XCTUnwrap(TodoWords.parse("buy flowers", now: now))
        XCTAssertEqual(todo["title"] as? String, "Buy flowers")
        XCTAssertEqual(todo["day"] as? String, "2026-10-30")
    }

    func testTomorrowAndATime() throws {
        let todo = try XCTUnwrap(TodoWords.parse("call the dentist tomorrow at 3pm", now: now))
        XCTAssertEqual(todo["title"] as? String, "Call the dentist")
        XCTAssertEqual(todo["day"] as? String, "2026-10-31")
        XCTAssertEqual(todo["time"] as? String, "15:00")
    }

    func testCroatianAndSomeday() throws {
        let sutra = try XCTUnwrap(TodoWords.parse("nazvati Petru sutra u 9", now: now))
        XCTAssertEqual(sutra["title"] as? String, "Nazvati Petru")
        XCTAssertEqual(sutra["day"] as? String, "2026-10-31")
        XCTAssertEqual(sutra["time"] as? String, "09:00")
        let someday = try XCTUnwrap(TodoWords.parse("paint the fence someday", now: now))
        XCTAssertTrue(someday["day"] is NSNull)
    }

    func testNothingTypedIsNoTodo() {
        XCTAssertNil(TodoWords.parse("   ", now: now))
    }

    func testShoppingSplitsAndCompares() {
        XCTAssertEqual(ShoppingWords.split("milk, eggs and bread"), ["Milk", "Eggs", "Bread"])
        XCTAssertEqual(ShoppingWords.split("mlijeko, jaja i kruh"), ["Mlijeko", "Jaja", "Kruh"])
        XCTAssertEqual(ShoppingWords.key("2x Mlijeko"), ShoppingWords.key("mlijeko"))
    }

    func testAnItemIsOnTheListItWasPutOnElseWhereItsAisleIsBought() {
        XCTAssertEqual(ShoppingWords.shop(of: SpaceThing(id: "a", updated: 0, data: ["title": "Aspirin", "pinned": "pharmacy"])), "pharmacy")
        XCTAssertEqual(ShoppingWords.shop(of: SpaceThing(id: "b", updated: 0, data: ["title": "Soap", "shop": "drugstore", "pinned": ""])), "drugstore")
        XCTAssertEqual(ShoppingWords.shop(of: SpaceThing(id: "c", updated: 0, data: ["title": "Milk"])), "grocery")
    }
}
