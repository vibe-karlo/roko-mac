import SwiftUI

// Browse for Me, from the iPhone: a question typed into ⌘T, read up on the
// web and answered, in a tab of its own (roko://browse/<question>, an
// InternalPage). The answer comes with numbered sources, which open as tabs,
// and the follow-ups worth asking next; a follow-up is answered below, with
// the page so far as context (BrowseSession, Answers/AI).

/// The sessions behind the open Browse for Me tabs, by question, so a tab
/// drawn again (switched to, or after a split) keeps its answer rather than
/// asking again. The latest few are kept.
@MainActor
final class BrowseStore {
    static let shared = BrowseStore()
    private var sessions: [(question: String, session: BrowseSession)] = []

    func session(for question: String) -> BrowseSession {
        if let kept = sessions.first(where: { $0.question == question }) { return kept.session }
        let session = BrowseSession(question: question)
        sessions.append((question, session))
        if sessions.count > 6 { sessions.removeFirst().session.cancel() }
        return session
    }
}

struct BrowsePage: View {
    @ObservedObject var browser: Browser
    let session: BrowseSession
    @State private var followUp = ""
    @FocusState private var asking: Bool

    /// The column the answer is read in: a line's comfortable length.
    private static let column: CGFloat = 680

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    ForEach(Array(session.turns.enumerated()), id: \.element.id) { index, turn in
                        TurnView(browser: browser, turn: turn, first: index == 0) { question in
                            session.ask(question)
                        }
                        .id(turn.id)
                    }
                    field
                }
                .frame(maxWidth: BrowsePage.column, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 48)
                .padding(.bottom, 64)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.turns.count) { _, _ in
                guard let last = session.turns.last else { return }
                withAnimation(Motion.settle) { scroller.scrollTo(last.id, anchor: .top) }
            }
        }
        .background(Theme.canvas)
    }

    /// A follow-up, answered below with what is already on the page.
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 10) {
            TextField("", text: $followUp, prompt: Text("Ask a follow-up").foregroundStyle(Theme.faintInk))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .focused($asking)
                .onSubmit(ask)
            if !followUp.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: ask) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .help("Ask (Return)")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.raised, in: shape)
        .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
        .opacity(session.latest.isWorking ? 0.5 : 1)
        .disabled(session.latest.isWorking)
    }

    private func ask() {
        let question = followUp.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        followUp = ""
        session.ask(question)
    }
}

/// One question and its answer.
private struct TurnView: View {
    @ObservedObject var browser: Browser
    let turn: BrowseForMeModel
    let first: Bool
    let ask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(turn.query)
                .font(.system(size: first ? 28 : 21, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if turn.isWorking { working }

            if case .failed(let why) = turn.phase {
                VStack(alignment: .leading, spacing: 10) {
                    Text(why)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { turn.retry() }
                        .buttonStyle(.link)
                }
            } else if !turn.answer.isEmpty {
                MarkdownText(markdown: turn.answer, isStreaming: turn.phase == .writing,
                             sources: turn.sources.map(\.url),
                             openSource: { url in browser.open(url, foreground: true, from: browser.active) },
                             anchor: "answer-\(turn.id)")
                    .textSelection(.enabled)
            }

            if turn.phase == .done, !turn.sources.isEmpty { sources }
            if !turn.followUps.isEmpty { followUps }
        }
    }

    /// What it is doing while there are no words yet: the search, then each
    /// page as it is read.
    private var working: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryInk)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.edge)
                    Capsule().fill(Theme.secondaryInk.opacity(0.7))
                        .frame(width: max(4, geometry.size.width * turn.progress))
                }
            }
            .frame(width: 220, height: 3)
            .animation(Motion.own(.easeInOut(duration: 0.6)), value: turn.progress)
            ForEach(turn.steps.suffix(6)) { step in
                HStack(spacing: 8) {
                    Mark(icon: Favicons.shared.cached(for: step.url), letter: String(step.url.displayHost.prefix(1)).uppercased(), size: 13)
                    Text(step.url.displayHost)
                        .font(.system(size: 12.5))
                        .foregroundStyle(step.state == .skipped ? Theme.faintInk : Theme.bodyInk)
                        .strikethrough(step.state == .skipped, color: Theme.faintInk)
                    if step.state == .reading {
                        Text("reading")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.faintInk)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: turn.steps)
    }

    private var status: String {
        switch turn.phase {
        case .searching(let what): what.isEmpty ? "Searching the web" : "Searching for \(what)"
        case .reading(let count): "Reading \(count) \(count == 1 ? "page" : "pages")"
        case .writing: "Writing the answer"
        default: ""
        }
    }

    /// The pages the answer stands on, numbered as its marks are.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 6)
            ForEach(Array(turn.sources.enumerated()), id: \.element.id) { index, source in
                Button { browser.open(source.url, foreground: true, from: browser.active) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.faintInk)
                            .frame(width: 16, alignment: .trailing)
                        Text(source.title.isEmpty ? source.url.displayHost : source.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.bodyInk)
                            .lineLimit(1)
                        Text(source.url.displayHost)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faintInk)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .help(source.url.absoluteString)
            }
        }
    }

    /// The questions worth asking next, each answered below when taken.
    private var followUps: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(turn.followUps, id: \.self) { question in
                Button { ask(question) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.faintInk)
                        Text(question)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }
}
