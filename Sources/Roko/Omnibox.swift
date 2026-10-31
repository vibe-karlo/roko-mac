import SwiftUI
import AppKit

/// One field, in the middle, and the few places it thinks you mean. It takes
/// addresses and only addresses: type something that isn't a place and it
/// shivers and says so, rather than quietly handing your keystrokes to a
/// search engine.
struct Omnibox: View {
    @ObservedObject var browser: Browser
    /// What is typed and offered, which changes with every key (Browser.launcher).
    @ObservedObject private var launcher: LauncherState
    /// Raised over a page by ⌘L, rather than standing on an empty tab.
    let over: Bool

    /// The field's own height — the 22 of text and 14 of air above and below it
    /// that `field` lays out — so the list can sit below it without being
    /// stacked with it.
    private static let fieldHeight: CGFloat = 22 + 14 * 2

    @State private var shake: CGFloat = 0
    @State private var refused = false
    /// The arrow keys' mark, matched from row to row.
    @Namespace private var picked

    /// Sized to a pane of a split rather than to the window.
    var fitted = false

    init(browser: Browser, over: Bool, fitted: Bool = false) {
        self.browser = browser
        launcher = browser.launcher
        self.over = over
        self.fitted = fitted
    }

    var body: some View {
        Group {
            if fitted {
                GeometryReader { geometry in
                    content(width: min(Metrics.fieldWidth, max(0, geometry.size.width - 28)))
                }
            } else {
                content(width: Metrics.fieldWidth)
            }
        }
        .allowsHitTesting(browser.fieldShowing)
    }

    private func content(width: CGFloat) -> some View {
        ZStack {
            // Keep the container mounted: only the field scales, while the
            // page's cover fades without pulling its edges into view.
            if browser.fieldShowing {
                if over {
                    // The page is still there, just out of the way.
                    Rectangle()
                        .fill(Palette.ground.opacity(0.74))
                        .ignoresSafeArea(.all, edges: fitted ? [] : .all)
                        .onTapGesture { browser.dismiss() }
                        .transition(.opacity)
                }

                field
                    .frame(width: width)
                    // One card for the field and what it offers, as Dia has
                    // it: drawn behind the field and hanging below it, so a
                    // list that grows never lifts the field out from under
                    // what is being typed.
                    .background(alignment: .top) { card(width: width) }
                // Lifted a little above centre: dead centre reads as low,
                // because the strip at the top isn't part of what the eye is
                // measuring.
                .padding(.bottom, 60)
                // Down into place and in, not scaled: the field's text is
                // AppKit's and doesn't scale, so the card grew around words
                // that stood still.
                .transition(.offset(y: -8).combined(with: .opacity))
                // The list's arrival and its leaving are animated from here,
                // briefly: nothing that changes the suggestions does it inside
                // an animation of its own. Its rows follow what was typed or
                // pasted at once.
                .animation(Motion.quick, value: listShown)
                .animation(Motion.settle, value: refused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listShown: Bool { !browser.offers.isEmpty || browser.siteOffer != nil }

    /// The card: the field's place, then the list and what Return does.
    private func card(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 0) {
            Color.clear.frame(height: Self.fieldHeight)
            if listShown {
                list
                    .transition(.opacity)
                footer
            }
        }
        .frame(width: width)
        .background {
            ZStack {
                // A slow, almost invisible breath under the field. It is
                // the only thing on an empty tab, and a thing that never
                // moves at all reads as a picture of an app rather than
                // an app.
                Breath()
                // Cast from above and kept close, by the card's shape alone:
                // on the card as a whole, every word in it cast one too.
                shape.fill(Palette.ground)
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            }
        }
        .overlay(
            shape.strokeBorder(refused ? Color.red.opacity(0.35) : Palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var field: some View {
        HStack(spacing: 10) {
            if let site = browser.siteChip {
                SiteChip(site: site)
                    .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
            } else {
                lead
            }
            AddressField(browser: browser)
        }
            .animation(Motion.quick, value: browser.siteChip)
            .frame(height: 22)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .modifier(Shake(travel: shake))
            .onAppear {
                shake = 0
                refused = false
            }
            .onChange(of: browser.refusals) { _, _ in
                shake = 0
                refused = true
                withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
            }
            .onChange(of: browser.typed) { _, _ in
                withAnimation(Motion.quick) { refused = false }
            }
    }

    /// Before what is typed: the site the top row would open, when it is a
    /// place this Mac has the icon of, or the glass.
    @ViewBuilder
    private var lead: some View {
        let top = browser.offers.first
        if !browser.typed.isEmpty, let top, top.kind != .search, top.kind != .suggested,
           let icon = Favicons.shared.cached(for: top.url) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 16, height: 16)
        }
    }

    /// What it thinks you mean, under the field. Before anything is typed,
    /// the tabs you were on latest and the sites you go to most, under a word
    /// each.
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let site = browser.siteOffer {
                SiteOfferRow(site: site)
                    .contentShape(Rectangle())
                    .onTapGesture { _ = browser.lockSiteOffer() }
            }
            ForEach(Array(browser.offers.enumerated()), id: \.element.id) { index, offer in
                if let heading = heading(at: index) {
                    Text(heading)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 14)
                        .padding(.top, index == 0 ? 2 : 12)
                        .padding(.bottom, 4)
                }
                Row(offer: offer, picked: browser.picked == index, glide: picked)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.take(offer) }
                    // On an empty field, as the card opens: the rows come in
                    // one after another, quickly. Never while typing, where
                    // they follow each key at once.
                    .transition(browser.typed.isEmpty && !Motion.reduced
                                ? .opacity.combined(with: .offset(y: 5))
                                    .animation(.easeOut(duration: 0.18).delay(Double(min(index, 8)) * 0.018))
                                : .identity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    /// Only before anything is typed: where the recent tabs start, and where
    /// the frequent sites do.
    private func heading(at index: Int) -> String? {
        guard browser.typed.isEmpty, browser.offers.indices.contains(index) else { return nil }
        let kind = browser.offers[index].kind
        let before = index > 0 ? browser.offers[index - 1].kind : nil
        if kind == .open, before != .open { return "Recent tabs" }
        if kind == .visited, before != .visited { return "Frequent" }
        if kind.isCommand, !(before?.isCommand ?? false) { return "Your lists" }
        return nil
    }

    /// What Return does with the row it would take, at the card's foot.
    @ViewBuilder
    private var footer: some View {
        let chosen = browser.picked.flatMap { browser.offers.indices.contains($0) ? browser.offers[$0] : nil }
            ?? (browser.typed.isEmpty ? nil : browser.offers.first)
        if let chosen {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(Self.action(for: chosen))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
        } else {
            Color.clear.frame(height: 8)
        }
    }

    private static func action(for offer: Suggestion) -> String {
        if offer.tab != nil { return "Switch to tab" }
        switch offer.kind {
        case .search, .suggested: return "Search"
        case .answer: return "Copy"
        case .browse: return "Browse for me"
        case .command(let command): return [.todos, .shopping, .later].contains(command) ? "Open" : "Run"
        default: return "Open"
        }
    }

    /// One row of a list of places, here and under the field in the tab.
    struct Row: View {
        let offer: Suggestion
        /// Where the arrow keys have walked to. The pointer gets its own,
        /// quieter mark, and changes nothing but the look of the row.
        let picked: Bool
        /// The list's, so the arrow keys' mark glides from row to row.
        var glide: Namespace.ID? = nil

        @State private var hovering = false

        /// Somewhere to go, rather than a search, an answer or a command.
        private var isPlace: Bool {
            switch offer.kind {
            case .open, .visited, .bookmark, .known: true
            default: false
            }
        }

        /// The site's icon for a place, when this Mac has it, or a globe;
        /// the glass for a search; a mark of its own for the rest.
        @ViewBuilder
        private var icon: some View {
            switch offer.kind {
            case .search, .open, .visited, .bookmark, .known:
                // Nothing is fetched for a site that isn't known: the glass or
                // the globe is what the row wears until then.
                if let image = Favicons.shared.cached(for: offer.url) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    symbol(offer.kind == .search ? "magnifyingglass" : "globe")
                }
            case .suggested:
                // The engine's own words: always the glass, so they read
                // as searches rather than places.
                symbol("magnifyingglass")
            case .command(let command):
                symbol(command == .todos ? "checklist" : command == .shopping ? "cart" : command == .later ? "bookmark" : "command")
            case .browse:
                symbol("text.magnifyingglass")
            case .answer:
                // Worked out, not found: the equals sign, as quiet as the rest.
                symbol("equal")
            }
        }

        private func symbol(_ name: String) -> some View {
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
        }

        var body: some View {
            HStack(spacing: 10) {
                icon
                    .frame(width: 16, height: 16)
                if isPlace, !offer.title.isEmpty {
                    // A place reads as what it is, then where: its title, then
                    // its address quieter beside it, as Yab and Dia have them.
                    Text(offer.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(Address.withoutWWW(offer.key))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    // The row reads as 1.0.4's did, without the www; the key
                    // itself keeps it, for completing and going there.
                    Text(offer.kind == .suggested || offer.kind == .answer || offer.kind == .browse ? offer.key : Address.withoutWWW(offer.key))
                        // An answer is the thing being read: a step heavier.
                        .font(.system(size: 13.5, weight: offer.kind == .answer ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if !offer.title.isEmpty {
                        Text(offer.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 22)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if picked, let glide {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.wash)
                        .matchedGeometryEffect(id: "picked", in: glide)
                } else if picked {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.wash)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// A site's icon when this Mac has it, or a glass.
private struct SiteIcon: View {
    let site: SearchSite
    var body: some View {
        let host = site.host.split(separator: "/").first.map(String.init) ?? site.host
        if let icon = Favicons.shared.cached(host) ?? Favicons.shared.cached("www." + host) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 14, height: 14)
        }
    }
}

/// The site Tab put in the field: its icon and name, in the field's grey,
/// before what is typed.
private struct SiteChip: View {
    let site: SearchSite
    var body: some View {
        HStack(spacing: 6) {
            SiteIcon(site: site)
            Text(site.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching \(site.name)")
    }
}

/// "Search Reddit", first in the list, with the key that takes it.
private struct SiteOfferRow: View {
    let site: SearchSite
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(site: site)
            Text("Search \(site.name)")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("Tab")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            if hovering { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.hover) }
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search \(site.name), press Tab")
    }
}

/// The breath under the field: a soft shape of ink, blurred, moved by Core
/// Animation. Animated by SwiftUI, it was drawn again on the main thread
/// every frame for as long as an empty tab was showing — 18% of a core with
/// the window doing nothing (24 Sep 2026). As a layer's shadow, breathed by
/// Core Animation, it is played in the render server and costs the app
/// nothing; and it is a layer, not a second SwiftUI view to build before
/// the first frame.
private struct Breath: NSViewRepresentable {
    /// As dark as the shape it replaces, 5% ink blurred by 26: a shadow of
    /// the same radius comes out at 0.7 of the darkness at equal strength,
    /// measured on pictures of both (24 Sep 2026), so 7%.
    static let strength: Swift.Float = 0.07

    func makeNSView(context: Context) -> NSView { Lung() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Lung: NSView {
        private let glow = CALayer()
        private var breathed: CGSize = .zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            glow.shadowOpacity = Breath.strength
            glow.shadowOffset = .zero
            glow.shadowRadius = 26
            layer?.addSublayer(glow)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The ink is the look's: light on a dark window, dark on a light one.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance { glow.shadowColor = Palette.NS.ink.cgColor }
        }

        override func layout() {
            super.layout()
            guard bounds.size != breathed, bounds.width > 0 else { return }
            breathed = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.bounds = bounds
            glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
            glow.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 26, cornerHeight: 26, transform: nil)
            effectiveAppearance.performAsCurrentDrawingAppearance { glow.shadowColor = Palette.NS.ink.cgColor }
            CATransaction.commit()
            // From 0.97 to 1.03, from 0.65 to full, 2.6 s each way, for as
            // long as the field is there. Started once: the card growing as
            // its list comes lays it out every frame, and adding it again
            // each time restarted the breath, a dip under the field.
            guard glow.animation(forKey: "breath") == nil, !Motion.reduced else { return }
            let size = CABasicAnimation(keyPath: "transform.scale")
            size.fromValue = 0.97
            size.toValue = 1.03
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.65
            fade.toValue = 1.0
            let both = CAAnimationGroup()
            both.animations = [size, fade]
            both.duration = 2.6
            both.autoreverses = true
            both.repeatCount = .infinity
            both.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(both, forKey: "breath")
        }
    }
}

/// The field itself, in AppKit.
///
/// SwiftUI's TextField can hold a string and nothing else, and the whole point
/// here is the part you didn't type: the rest of the address, already there and
/// selected, so carrying on typing replaces it and Return accepts it. That
/// needs a real text field and its delegate.
struct AddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    /// The field follows a walk through the list (Browser.completed).
    @ObservedObject private var launcher: LauncherState

    init(browser: Browser) {
        self.browser = browser
        launcher = browser.launcher
    }

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15.5)
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // Scrolls with the caret, so a long address can be read and edited
        // all the way along rather than cut off at the field's edge.
        field.cell?.isScrollable = true
        // SwiftUI picks its own colour for a placeholder, and on a pale ground
        // that colour was near-white.
        field.placeholderAttributedString = NSAttributedString(
            string: "Enter a web address",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15.5),
                .foregroundColor: NSColor(Palette.ink.opacity(0.3)),
            ]
        )
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser

        // Only when something other than typing changed it — ⌘L arriving with
        // an address, a walk through the list, a submit clearing it.
        //
        // Comparing against the field's own text instead would undo every
        // backspace: deleting leaves the field shorter than what the browser
        // still considers complete, and the next update would helpfully type
        // it back in. That is a field you cannot shorten, and it reads exactly
        // like one that has stopped responding.
        let want = browser.completed
        if want != coordinator.synced {
            coordinator.synced = want
            field.stringValue = want
            coordinator.select(from: browser.typed.count, in: field)
        }

        if coordinator.answered != browser.focusRequest {
            coordinator.answered = browser.focusRequest
            DispatchQueue.main.async { coordinator.focus(field) }
        }
    }

    /// The field, told when it lands in a window.
    ///
    /// SwiftUI makes the view and updates it before it is in one, and with
    /// Split View on it comes only once the stage has said where the page is,
    /// a turn of the run loop later. Asked for the keys before then, the
    /// field had no window to ask: the request went nowhere and nothing asked
    /// again, so ⌘T left a field with no caret and typing that went nowhere
    /// until it was clicked. Now the request waits for the window.
    final class Field: NSTextField {
        var arrived: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let arrived else { return }
            self.arrived = nil
            arrived()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var answered = -1
        /// The last value pushed in from the browser side, so an update can
        /// tell a change worth applying from one it made itself.
        var synced = ""

        /// A backspace has to be allowed to actually take a letter off. Without
        /// this the field puts the same letter straight back as a completion
        /// and the address can never be shortened.
        private var deleting = false

        init(browser: Browser) {
            self.browser = browser
        }

        /// The keys to the field, now if it is in a window, or the moment it is.
        @MainActor func focus(_ field: Field) {
            guard let window = field.window else {
                field.arrived = { [weak self, weak field] in
                    DispatchQueue.main.async {
                        guard let self, let field, self.browser.fieldShowing else { return }
                        self.focus(field)
                    }
                }
                return
            }
            field.arrived = nil
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            defer { browser.fieldFocused(in: window) }
            // The system paints selected text as a block of accent colour,
            // which over this pale field is the loudest thing in the
            // window. A tenth of the ink says "selected" quietly enough.
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // A draft come back to its blank tab is carried on, not typed
            // over: the caret after it. An address ⌘L raises is selected whole.
            if browser.active?.isBlank == true, !browser.typed.isEmpty {
                select(from: browser.typed.count, in: field)
            } else {
                editor.selectAll(nil)
            }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue

            browser.typed = text
            guard !deleting, let ending = browser.ending else {
                if deleting { browser.stopCompleting() }
                deleting = false
                synced = browser.completed
                return
            }
            deleting = false

            field.stringValue = text + ending
            synced = field.stringValue
            select(from: text.count, in: field)
        }

        /// The part after the caret, shown as selected, so the next keystroke
        /// replaces it and Return takes it.
        func select(from start: Int, in field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            let length = field.stringValue.count
            guard start <= length else { return }
            editor.selectedRange = NSRange(location: start, length: length - start)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                browser.submit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                browser.walk(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                browser.walk(-1)
                return true
            case #selector(NSResponder.deleteWordBackward(_:)):
                // ⌥⌫ over an offered ending lets go of it and takes the last
                // word typed, as it does with no ending there. Left to the
                // text view it would only take the selected ending.
                deleting = true
                let selected = textView.selectedRange()
                guard browser.ending != nil, selected.length > 0,
                      NSMaxRange(selected) == (textView.string as NSString).length
                else { return false }
                textView.delete(nil)
                deleting = true
                textView.deleteWordBackward(nil)
                return true
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty && browser.siteChip != nil:
                // ⌫ on an empty field takes the site out of it.
                browser.siteChip = nil
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordForward(_:)):
                deleting = true
                return false
            default:
                return false
            }
        }
    }
}
