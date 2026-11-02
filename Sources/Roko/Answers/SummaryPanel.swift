import SwiftUI

// Summarize Page (⇧⌘Y, View › Summarize Page): roko's summary from the
// iPhone, in a panel over the page's right side, so the page stays in view
// beside what it says. Apple Intelligence writes it, privately; Claude where
// Apple's models fall short and a key is set (SummaryModel, Answers/AI). The
// summary is shaped by what the page is (a recipe, a review, a story) and
// laid out by MarkdownText, as on the iPhone.

/// One page's summary, while its panel is open.
@MainActor
final class PageSummary: Identifiable {
    let id = UUID()
    let tab: Tab.ID
    /// The address it was asked for: the panel goes when the tab goes elsewhere.
    let address: URL?
    let model: SummaryModel

    init(tab: Tab, address: URL?, model: SummaryModel) {
        self.tab = tab.id
        self.address = address
        self.model = model
    }
}

extension Browser {
    /// View › Summarize Page, ⇧⌘Y.
    func summarizePage() { toggleSummary() }

    /// The summary of the page in front, or away again if it is up.
    func toggleSummary() {
        guard let tab = active, tab.isWeb, let web = tab.built,
              let address = tab.pageAddress, ["http", "https"].contains(address.scheme?.lowercased() ?? "")
        else {
            announce("Summaries work on web pages")
            return
        }
        if let open = summary, open.tab == tab.id {
            closeSummary()
            return
        }
        summary?.model.cancel()
        let model = SummaryModel(title: tab.label, host: address.displayHost, snapshot: nil)
        withAnimation(Motion.settle) { summary = PageSummary(tab: tab, address: address, model: model) }
        model.start(webView: web, url: address)
    }

    func closeSummary() {
        summary?.model.cancel()
        withAnimation(Motion.settle) { summary = nil }
    }
}

/// The panel: what the page is, then the summary as it is written, then who
/// wrote it.
struct SummaryPanel: View {
    static let width: CGFloat = 380
    @ObservedObject var browser: Browser
    let summary: PageSummary

    private var model: SummaryModel { summary.model }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)
            if model.isWorking {
                progress.padding(.horizontal, 20).padding(.bottom, 10)
                    .transition(.opacity)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case .failed(let why) = model.phase {
                        Text(why)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !model.text.isEmpty {
                        PacedMarkdown(text: model.text, streaming: model.phase == .writing)
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: SummaryPanel.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.raised, in: shape)
        .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
        // Cast from above, tight: lifted off the page, not floating on a cloud.
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        // The progress line going once words come: it fades, and the words
        // below rise into its place rather than jumping.
        .animation(Motion.settle, value: model.isWorking)
        .onExitCommand { browser.closeSummary() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title.isEmpty ? model.host : model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text([model.host, model.readingTime].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { browser.closeSummary() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .help("Close (Esc)")
        }
    }

    /// While the page is read and the first words come: what is happening,
    /// over a track that fills, end to end, as it goes.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.phase == .reading ? "Reading the page" : "Writing the summary")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.edge)
                    Capsule().fill(Theme.secondaryInk.opacity(0.7))
                        .frame(width: max(4, geometry.size.width * model.progress))
                }
            }
            .frame(height: 3)
            .animation(Motion.own(.easeInOut(duration: 0.6)), value: model.progress)
        }
    }

    @ViewBuilder
    private var footer: some View {
        let words = [model.engine.isEmpty ? nil : model.engine, model.note].compactMap { $0 }
        if model.phase == .done, !words.isEmpty {
            Text(words.joined(separator: "  ·  "))
                .font(.system(size: 11))
                .foregroundStyle(Theme.faintInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }
}

/// The summary as it is shown: catching up with what the model has written at
/// an even pace, a few letters a frame, rather than in the bursts it arrives
/// in. Streamed straight through, a line sat still, then jumped by half a
/// sentence and pushed everything under it down at once, twenty times a
/// second. The further behind it is, the faster it goes, so it is never more
/// than a moment behind; a summary already written shows whole at once.
struct PacedMarkdown: View {
    let text: String
    let streaming: Bool
    @State private var shown: String?
    /// What has been written so far, as the loop below reads it: the view's
    /// own `text` is the one it was made with.
    @State private var written = ""
    @State private var pacing: Task<Void, Never>?

    var body: some View {
        let shown = shown ?? text
        MarkdownText(markdown: shown, isStreaming: streaming || shown.count < text.count, anchor: "summary")
            .onChange(of: text, initial: true) { _, text in pace(to: text) }
            .onDisappear { pacing?.cancel() }
    }

    private func pace(to text: String) {
        written = text
        // Nothing to pace: written before it opened, or motion kept still.
        guard streaming || shown != nil, !Motion.reduced else {
            shown = nil
            return
        }
        let now = shown ?? ""
        // The model wrote its words over (Apple's do, now and then): taken as they are.
        guard text.hasPrefix(now) else {
            shown = text
            return
        }
        if shown == nil { shown = "" }
        guard pacing == nil else { return }
        pacing = Task { @MainActor in
            let frame: Duration = Motion.light ? .milliseconds(50) : .milliseconds(33)
            while !Task.isCancelled, let here = shown, here.count < written.count {
                let target = written
                guard target.hasPrefix(here) else { shown = target; break }
                shown = Self.step(from: here, towards: target)
                try? await Task.sleep(for: frame)
            }
            pacing = nil
        }
    }

    /// The next frame's text: a seventh of what is still to come, two
    /// characters at least, never past the end.
    static func step(from here: String, towards target: String) -> String {
        let behind = target.count - here.count
        guard behind > 0 else { return target }
        let start = target.index(target.startIndex, offsetBy: here.count)
        var end = target.index(start, offsetBy: max(2, behind / 7), limitedBy: target.endIndex) ?? target.endIndex
        // Whole words where one ends close by: half a word drawn, then
        // the rest, made the line flicker as it wrapped.
        if let space = target[end...].prefix(10).firstIndex(where: \.isWhitespace) { end = space }
        return String(target[..<end])
    }
}
