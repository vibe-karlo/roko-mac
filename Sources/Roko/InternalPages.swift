import AppKit
import SwiftUI

// roko's own pages — Settings, History, Downloads, Bookmarks, Passwords,
// Bring Things Over and Browse for Me — each in a tab of its own, as
// chrome://settings is in Chrome, rather than a card over the page. A tab
// is something you can leave open beside your work, come back to with ⌃Tab,
// put beside a page in Split View, and close with ⌘W like any other.
//
// One tab of each kind per window: asking again goes to the one already
// open. Each has an address of its own, roko://settings/privacy, which
// the field shows, the session keeps, and code can open directly. Nothing
// about them reaches WebKit: the tab holds no web view while it shows one.

/// Which of Search's own pages, and where inside it.
struct InternalPage: Equatable {
    enum Kind: String, CaseIterable {
        case settings, history, downloads, bookmarks, passwords
        case importing = "import"
        /// roko's Browse for Me: a question read up on the web and answered
        /// (Answers/BrowsePage.swift); the question is the detail.
        case browse
        /// roko on iPhone's to-dos and shopping lists (Lists/ListPages.swift).
        case todos, shopping
        /// Pages put aside, as roko on iPhone's Read Later (Lists/ReadLater.swift).
        case later
    }

    var kind: Kind
    /// Settings' section, or the browser Bring Things Over starts at.
    var detail: String?

    init(_ kind: Kind, _ detail: String? = nil) {
        self.kind = kind
        self.detail = detail?.isEmpty == true ? nil : detail
    }

    static let scheme = "roko"
    /// What these pages were called before roko was roko: a tab kept from
    /// then still opens as the page it was.
    static let formerScheme = "search"

    /// roko://settings, roko://settings/privacy, roko://import/Arc.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == InternalPage.scheme || scheme == InternalPage.formerScheme,
              let host = url.host()?.lowercased(), let kind = Kind(rawValue: host)
        else { return nil }
        let rest = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.init(kind, rest)
    }

    var url: URL {
        var text = "\(InternalPage.scheme)://\(kind.rawValue)"
        if let detail, let path = detail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            text += "/" + path
        }
        return URL(string: text) ?? URL(string: "\(InternalPage.scheme)://\(kind.rawValue)")!
    }

    var title: String {
        switch kind {
        case .settings: return "Settings"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .bookmarks: return "Bookmarks"
        case .passwords: return "Passwords"
        case .importing: return "Bring Things Over"
        case .browse: return detail ?? "Browse for Me"
        case .todos: return "To-dos"
        case .shopping: return "Shopping"
        case .later: return "Read Later"
        }
    }

    var symbol: String {
        switch kind {
        case .settings: return "gearshape"
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        case .bookmarks: return "book"
        case .passwords: return "key"
        case .importing: return "square.and.arrow.down"
        case .browse: return "text.magnifyingglass"
        case .todos: return "checklist"
        case .shopping: return "cart"
        case .later: return "bookmark"
        }
    }

    /// The tab's icon: the symbol, drawn as a template so it takes the
    /// colour of the row it sits in (see Mark).
    var glyph: NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        image?.isTemplate = true
        return image
    }
}

private struct AsTabKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when a panel is drawn as a page in a tab of its own rather than
    /// as a card over the page: the plate gives up its card, its shadow and
    /// its cross, and its lists take the height the window gives them.
    var asTab: Bool {
        get { self[AsTabKey.self] }
        set { self[AsTabKey.self] = newValue }
    }
}

/// A list's height: capped on a card, as tall as the window in a tab.
private struct ListHeight: ViewModifier {
    @Environment(\.asTab) private var asTab
    let cap: CGFloat

    func body(content: Content) -> some View {
        if asTab {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            content.frame(maxHeight: cap)
        }
    }
}

extension View {
    func listHeight(_ cap: CGFloat) -> some View { modifier(ListHeight(cap: cap)) }
}

/// One of Search's own pages, where a web page would be: on the stage, on
/// its card when pages are cards, in either pane of a pair.
struct InternalPageView: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let page: InternalPage
    var corner: CGFloat = 0

    var body: some View {
        content
            .environment(\.asTab, true)
            // Its own state for each kind: History's search box doesn't
            // follow you into Downloads.
            .id(page.kind)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            // In a pair, a click on this page makes it the one with the keys,
            // as a click on a web page does (see PageView.onKeys).
            .simultaneousGesture(TapGesture().onEnded {
                if browser.activeID != tab.id, browser.split(for: tab) != nil { browser.focusPane(tab) }
            })
            .transition(.opacity)
    }

    @ViewBuilder
    private var content: some View {
        switch page.kind {
        case .settings:
            SettingsPanel(browser: browser, prefs: browser.prefs, asked: page.detail)
        case .history:
            HistoryPanel(browser: browser)
        case .downloads:
            DownloadsPanel(browser: browser, loot: browser.loot)
        case .bookmarks:
            BookmarksPanel(browser: browser, bookmarks: browser.bookmarks)
        case .passwords:
            // The list is read each time the page is drawn, whichever way it
            // came: brought back from the last session, Settings › Passwords ›
            // Open… turning the Settings tab into it, Back or Forward. Here,
            // under `.id(page.kind)`, and not on the view around it, which a
            // tab going from one of these pages to another keeps: there it
            // ran once, and the page reached from Settings said "Nothing kept
            // yet" while the sign-in box offered the accounts.
            PasswordsPanel(browser: browser)
                .onAppear { browser.relist() }
        case .importing:
            ImportPanel(browser: browser)
        case .browse:
            BrowsePage(browser: browser, session: BrowseStore.shared.session(for: page.detail ?? ""))
        case .todos:
            TodosPage()
        case .shopping:
            ShoppingPage()
        case .later:
            ReadLaterPage(browser: browser)
        }
    }
}
