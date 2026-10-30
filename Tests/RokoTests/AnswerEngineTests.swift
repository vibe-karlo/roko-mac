import XCTest
@testable import Roko

/// roko's summary engine from the iPhone, on the Mac: a page's text, written
/// up by whichever engine this Mac has (Apple Intelligence, on-device, or
/// Claude with a key). Skipped where none is, and unless ROKO_LIVE_TESTS=1:
/// they read the web and wait on a model, a minute and more, and would slow
/// every ordinary run.
@MainActor
final class AnswerEngineTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROKO_LIVE_TESTS"] == "1",
                          "Live: ROKO_LIVE_TESTS=1 swift test --filter AnswerEngineTests")
    }

    func testSummarizesAnArticle() async throws {
        try XCTSkipUnless(AppleModels.cloudIfAvailable != nil || OnDeviceSummarizer.isAvailable || ClaudeClient.configured != nil,
                          "No model on this Mac")
        let text = (1...6).map { _ in """
            Espresso is coffee brewed by forcing a small amount of nearly boiling water under pressure through finely \
            ground coffee beans. It is generally thicker than coffee brewed by other methods, has a higher \
            concentration of suspended and dissolved solids, and has crema on top. As a result of the pressurized \
            brewing process, the flavours and chemicals in a typical cup of coffee are very concentrated.
            """ }.joined(separator: "\n\n")
        let page = ReadablePage(title: "Espresso", site: "Wikipedia", text: text, isArticle: true, declaredLanguage: "en")
        let model = SummaryModel(title: "Espresso", host: "en.wikipedia.org", snapshot: nil)
        await model.summarize(page)
        print("ENGINE \(model.engine) PHASE \(model.phase)\n\(model.text.prefix(600))")
        XCTAssertEqual(model.phase, .done, "\(model.phase)")
        XCTAssertFalse(model.text.isEmpty)
    }
}

extension AnswerEngineTests {
    func testBrowseForMeAnswersFromTheWeb() async throws {
        try XCTSkipUnless(AppleModels.cloudIfAvailable != nil || OnDeviceSummarizer.isAvailable || ClaudeClient.configured != nil,
                          "No model on this Mac")
        let turn = BrowseForMeModel(query: "how long to boil an egg soft")
        turn.start()
        for _ in 0..<180 where turn.phase != .done && !turn.phase.isFailure {
            try await Task.sleep(for: .milliseconds(500))
        }
        print("BROWSE \(turn.engine) PHASE \(turn.phase) SOURCES \(turn.sources.count) STEPS \(turn.steps.count)\n\(turn.answer.prefix(700))")
        XCTAssertEqual(turn.phase, .done, "\(turn.phase)")
        XCTAssertFalse(turn.answer.isEmpty)
    }
}
