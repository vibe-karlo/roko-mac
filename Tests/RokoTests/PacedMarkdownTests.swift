import XCTest
@testable import Roko

/// The summary's even pace (PacedMarkdown in SummaryPanel.swift).
@MainActor
final class PacedMarkdownTests: XCTestCase {
    func testTheLastCharacterDoesNotRunPastTheEnd() {
        // One character to go: the two-character minimum once went past it.
        XCTAssertEqual(PacedMarkdown.step(from: "Hello", towards: "Hello!"), "Hello!")
        XCTAssertEqual(PacedMarkdown.step(from: "", towards: "a"), "a")
        XCTAssertEqual(PacedMarkdown.step(from: "done", towards: "done"), "done")
    }

    func testItWalksToTheEndInWholeSteps() {
        let target = "A summary written a little at a time, with 🇭🇷 and é along the way."
        var shown = ""
        var frames = 0
        while shown != target {
            let next = PacedMarkdown.step(from: shown, towards: target)
            XCTAssertTrue(target.hasPrefix(next))
            XCTAssertGreaterThan(next.count, shown.count)
            shown = next
            frames += 1
            XCTAssertLessThan(frames, 100)
        }
    }
}
