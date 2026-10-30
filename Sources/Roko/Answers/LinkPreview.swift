import AppKit
import FoundationModels
import SwiftUI

// Link previews, as Arc's: hold Shift over a link and a card says what is on
// the other end before you go: its site, its title, and the gist in a few
// short points, written by Apple's model on this Mac. The page is fetched
// on its own, without your cookies, and never opened. The card goes when
// the pointer leaves the link; a click still opens it as ever.
// Settings › Browsing › "Hold Shift over a link to preview it".

/// One link's preview, while its card is up.
@MainActor
final class LinkPreview: ObservableObject, Identifiable {
    enum Phase: Equatable { case reading, writing, done, failed(String) }

    let id = UUID()
    let tab: Tab.ID
    let url: URL
    @Published private(set) var title = ""
    @Published private(set) var gist = ""
    @Published private(set) var phase: Phase = .reading
    private var task: Task<Void, Never>?

    init(tab: Tab.ID, url: URL) {
        self.tab = tab
        self.url = url
        task = Task { await run() }
    }

    func cancel() { task?.cancel() }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpAdditionalHeaders = ["Accept": "text/html"]
        return URLSession(configuration: configuration)
    }()

    private func run() async {
        guard let (data, response) = try? await Self.session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
              let html = String(data: data.prefix(1_500_000), encoding: .utf8) ?? String(data: data.prefix(1_500_000), encoding: .isoLatin1)
        else {
            if !Task.isCancelled { phase = .failed("Couldn't reach the page") }
            return
        }
        guard !Task.isCancelled else { return }
        title = Self.meta("og:title", in: html) ?? Self.tag("title", in: html) ?? url.displayHost
        let description = Self.meta("og:description", in: html) ?? Self.meta("description", in: html)
        let text = WebResearcher.articleText(html, limit: 5_000)
        guard SystemLanguageModel.default.isAvailable, text.count > 200 else {
            gist = description ?? ""
            phase = gist.isEmpty ? .failed("Nothing to preview on this page") : .done
            return
        }
        phase = .writing
        do {
            let model = LanguageModelSession(instructions: """
                You preview a web page for someone deciding whether to open it. Three lines, each \
                starting with "- ", each at most 14 words: what the page is and the two things most \
                worth knowing. Only facts from the page, in the page's language. No preamble.
                """)
            let stream = model.streamResponse(to: "Title: \(title)\nSite: \(url.displayHost)\n\n\(text)")
            for try await snapshot in stream {
                guard !Task.isCancelled else { return }
                gist = snapshot.content
            }
            phase = .done
        } catch {
            if Task.isCancelled { return }
            gist = description ?? ""
            phase = gist.isEmpty ? .failed("Couldn't preview this page") : .done
        }
    }

    private static func meta(_ name: String, in html: String) -> String? {
        let pattern = #"<meta[^>]+(?:property|name)=["']\#(NSRegularExpression.escapedPattern(for: name))["'][^>]+content=["']([^"']+)["']"#
        return WebResearcher.matches(pattern, in: html).first.map { WebResearcher.plain($0[0]) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func tag(_ name: String, in html: String) -> String? {
        WebResearcher.matches("<\(name)[^>]*>([\\s\\S]*?)</\(name)>", in: html).first
            .map { WebResearcher.plain($0[0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension Browser {
    /// The pointer on a link, or off one (Tab.onLink): with Shift held, its
    /// preview; off the link, the preview goes.
    func hoverChanged(_ tab: Tab, _ address: String?) {
        let url = address.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        hovered = url.map { (tab.id, $0) }
        if let preview = linkPreview, preview.url != url { closeLinkPreview() }
        if url != nil, NSEvent.modifierFlags.contains(.shift) { previewHoveredLink() }
    }

    /// Shift pressed, or a link reached with it held: the hovered link's card.
    func previewHoveredLink() {
        guard prefs.linkPreviews, let hovered, linkPreview?.url != hovered.url,
              tabs.first(where: { $0.id == hovered.tab })?.shy != true else { return }
        linkPreview?.cancel()
        withAnimation(Motion.quick) { linkPreview = LinkPreview(tab: hovered.tab, url: hovered.url) }
    }

    func closeLinkPreview() {
        linkPreview?.cancel()
        withAnimation(Motion.quick) { linkPreview = nil }
    }
}

/// Shift, anywhere in the app: a link already under the pointer is previewed.
@MainActor
enum LinkPreviewKey {
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            if event.modifierFlags.contains(.shift), let browser = Browsers.front ?? Browsers.primary {
                browser.previewHoveredLink()
            }
            return event
        }
    }
}

/// The card: the site, the title, and the gist as it is written.
struct LinkPreviewCard: View {
    static let width: CGFloat = 340
    @ObservedObject var preview: LinkPreview

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let icon = Favicons.shared.cached(for: preview.url) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Text(preview.url.displayHost)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            if !preview.title.isEmpty {
                Text(preview.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch preview.phase {
            case .failed(let why):
                Text(why)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryInk)
            case .reading where preview.gist.isEmpty, .writing where preview.gist.isEmpty:
                Text(preview.phase == .reading ? "Reading the page…" : "Writing the gist…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryInk)
            default:
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(Self.lines(preview.gist).enumerated()), id: \.offset) { _, line in
                        // A wrapped line starts under the words, not the dot.
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("·").foregroundStyle(Theme.faintInk)
                            Text(line).foregroundStyle(Theme.bodyInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 12.5))
                .lineSpacing(2)
            }
        }
        .padding(14)
        .frame(width: LinkPreviewCard.width, alignment: .leading)
        .background {
            // Cast by the card's shape alone, short and from above.
            shape.fill(Theme.raised)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
        .allowsHitTesting(false)
    }

    /// The model's "- " lines, without their dashes.
    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        }
        .filter { !$0.isEmpty }
    }
}
