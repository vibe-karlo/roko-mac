import SwiftUI

/// The address at the top of the column, under the window's buttons, as Arc
/// has it: where the page in front is, its site with a lock for a secure
/// one, or an invitation on an empty tab. A click opens the field over the
/// page with the address in it, as ⌘L does.
struct SideAddressBar: View {
    @ObservedObject var browser: Browser
    @Environment(\.greys) private var greys
    @State private var hovering: Bool
    @State private var copied = false

    /// `hovering`: drawn as under the pointer, for a picture of it.
    init(browser: Browser, hovering: Bool = false) {
        self.browser = browser
        _hovering = State(initialValue: hovering)
    }

    static let height: CGFloat = 32

    private var url: URL? {
        guard let tab = browser.active, !tab.isBlank else { return nil }
        return tab.shownURL
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 7) {
            // The address: a click opens the field with it, as ⌘L does.
            Button { browser.edit() } label: {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 12)
                    Text(words)
                        .font(.system(size: 12.5))
                        .foregroundStyle(url == nil ? Palette.muted : Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url?.absoluteString ?? "Open an address (⌘L)")
            .accessibilityLabel(url.map { "Address: \($0.absoluteString)" } ?? "Open an address")

            // Copy the link, as ⇧⌘C does: there while the pointer is on the
            // bar, a tick for a moment once it is copied.
            if url != nil, browser.active?.page == nil, hovering || copied {
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "link")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? Palette.ink : Palette.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy link (⇧⌘C)")
                .accessibilityLabel("Copy link")
                .transition(.opacity)
            }

            // Summarize the page, as ⇧⌘Y does: always there on a web page,
            // as Dia keeps its chat beside the address, so it is found
            // without knowing the key. roko's Eclipse, in ink while the
            // summary is up.
            if summarizable {
                Button { browser.toggleSummary() } label: {
                    Logomark()
                        .fill(summaryOpen ? Palette.ink : Palette.muted, style: FillStyle(eoFill: true))
                        .frame(width: 12, height: 12)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(summaryOpen ? "Close the summary (⇧⌘Y)" : "Summarize this page (⇧⌘Y)")
                .accessibilityLabel(summaryOpen ? "Close the summary" : "Summarize this page")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: SideAddressBar.height)
        .animation(Motion.quick, value: summaryOpen)
        .background(shape.fill(hovering ? greys.wash : greys.hover))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: copied)
    }

    /// A web page in front, the only kind a summary is made of.
    private var summarizable: Bool {
        guard let tab = browser.active, tab.isWeb, tab.page == nil,
              let scheme = tab.pageAddress?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private var summaryOpen: Bool {
        guard let summary = browser.summary else { return false }
        return summary.tab == browser.activeID
    }

    private func copy() {
        browser.copyAddress()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    /// The lock for a secure page; the glass where there is none yet.
    private var symbol: String {
        guard let url else { return "magnifyingglass" }
        if let page = browser.active?.page { return page.symbol }
        return url.scheme?.lowercased() == "https" ? "lock.fill" : "globe"
    }

    /// The site alone, without the www, as Arc shows it; an internal page by
    /// its name.
    private var words: String {
        guard let url else { return "Search or enter address" }
        if let page = browser.active?.page { return page.title }
        return url.displayHost
    }
}
