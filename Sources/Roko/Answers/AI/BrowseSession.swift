import Foundation
import WebKit

/// One Browse for Me page: a question and its answer, then each follow-up asked
/// from it as a new section below, answered with the page so far as context.
/// Also keeps the search engine's results for the latest question, so the page
/// can flip to them and back without losing either.
@MainActor
@Observable
final class BrowseSession: Identifiable {
    private(set) var turns: [BrowseForMeModel]
    init(question: String, context: [(question: String, answer: String)] = []) {
        let first = BrowseForMeModel(query: question, context: context)
        turns = [first]
        first.start()
    }

    var latest: BrowseForMeModel { turns[turns.count - 1] }

    /// Asks a follow-up: a new section at the end, with every finished answer
    /// before it as context.
    func ask(_ question: String) {
        let context = turns.compactMap { turn in turn.phase == .done ? (question: turn.query, answer: turn.plainAnswer) : nil }
        let turn = BrowseForMeModel(query: question, context: context)
        turns.append(turn)
        turn.start()
    }

    /// Rewords one question: its section and every one after it are asked again.
    func reask(_ turn: BrowseForMeModel, as question: String) {
        guard let index = turns.firstIndex(where: { $0 === turn }) else { return }
        turns[index...].forEach { $0.cancel() }
        turns.removeSubrange(index...)
        ask(question)
    }

    /// Stops every answer still being written: the page was closed.
    func cancel() {
        turns.forEach { $0.cancel() }
    }
}
