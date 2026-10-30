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
            if model.isWorking { progress.padding(.horizontal, 20).padding(.bottom, 10) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case .failed(let why) = model.phase {
                        Text(why)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !model.text.isEmpty {
                        MarkdownText(markdown: model.text, isStreaming: model.phase == .writing, anchor: "summary")
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
            .animation(.easeInOut(duration: 0.6), value: model.progress)
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
