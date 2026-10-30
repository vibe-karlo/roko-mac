import XCTest
@testable import Roko

/// The ⌘T launcher's answers, from the iPhone app (Answers/): what is
/// answered, what is left alone, and what each answer says.
final class AnswersTests: XCTestCase {
    func testSums() {
        XCTAssertEqual(Calculator.answer("2+2")?.result, "4")
        XCTAssertEqual(Calculator.answer("15% of 80")?.result, "12")
        XCTAssertEqual(Calculator.answer("square root of 625")?.result, "25")
    }

    func testUnits() {
        let miles = Calculator.answer("5 km in miles")
        XCTAssertNotNil(miles)
        XCTAssertTrue(miles?.result.hasSuffix("mi") ?? false, miles?.result ?? "")
        XCTAssertNotNil(Calculator.answer("100 f to c"))
    }

    func testCurrencyAtTheEurosFixedRates() {
        // Needs no download: the Deutschmark's rate to the euro is fixed.
        let answer = Calculator.answer("195.583 dem in eur")
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer?.result.contains("100") ?? false, answer?.result ?? "")
    }

    func testTimeSomewhere() {
        XCTAssertNotNil(Calculator.answer("time in tokyo"))
    }

    func testAddressesAndWordsAreLeftAlone() {
        for typed in ["github.com", "roko", "news", "2026", "how to bake bread", "apple.com/mac"] {
            XCTAssertNil(Calculator.answer(typed), typed)
        }
    }
}
