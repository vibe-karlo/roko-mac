import AppKit
import FoundationModels
import UserNotifications
import WebKit

// Notify Me, as roko on iPhone has it (Browser/Watch/Watcher.swift there,
// where the reading and judging below come from): say what to look for on
// the page on screen (or nothing, for anything new) and how often, and roko
// reads the page from then on and notifies you when it shows up. Apple's
// model on this Mac decides; nothing leaves it but the page's own request.
//
// A Mac app isn't woken to check as an iPhone app is: the pages are checked
// while roko is open, every few minutes for the ones due, and once at launch.
// Tabs › Notify Me…, or "notify me" in ⌘T.

/// How often a page is checked.
enum WatchFrequency: Int, CaseIterable, Identifiable {
    case hourly = 1, daily = 24, weekly = 168

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }
}

/// A page roko checks for you, with what to look for on it.
struct Watch: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String
    /// In your own words; empty means anything new.
    var lookFor = ""
    var everyHours = 24
    var createdAt = Date()
    var lastChecked: Date?
    /// The page as last read, one line per paragraph, item or offer.
    var snapshot = ""
    /// Its text only appears once its scripts run: read in a hidden web view.
    var needsRendering = false
    /// How the snapshot was read (PageLines.version): read another way, it is
    /// read afresh rather than compared.
    var readingVersion = 0
    /// The last thing it noticed.
    var lastNews: String?
    var lastNewsAt: Date?

    var host: String { URL(string: url)?.displayHost ?? url }

    var nextCheck: Date {
        (lastChecked ?? .distantPast).addingTimeInterval(Double(everyHours) * 3600)
    }
}

@MainActor
final class Watcher: ObservableObject {
    static let shared = Watcher()

    @Published private(set) var watches: [Watch] = []
    private var running = false
    private var timer: Timer?
    private var file: URL { Store.file("watches.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Watch].self, from: data) {
            watches = saved
        }
    }

    /// From launch: due pages now, then every ten minutes.
    func start() {
        guard timer == nil, !Store.testing else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { Task { await Watcher.shared.runDue() } }
        }
        Task { await runDue() }
    }

    func watch(for url: URL?) -> Watch? {
        guard let url else { return nil }
        return watches.first { $0.url == url.absoluteString }
    }

    /// A page watched from now on, or its watch changed; read as it is now,
    /// for later checks to compare with.
    func set(url: URL, title: String, lookFor: String, every frequency: WatchFrequency) {
        let lookFor = lookFor.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = watches.firstIndex(where: { $0.url == url.absoluteString }) {
            watches[index].lookFor = lookFor
            watches[index].everyHours = frequency.rawValue
            persist()
            return
        }
        var watch = Watch(url: url.absoluteString, title: title, lookFor: lookFor, everyHours: frequency.rawValue)
        watches.append(watch)
        persist()
        if !Store.testing { WatchNotifications.requestPermission() }
        Task {
            var lines = await PageLines.fetch(url)
            if lines.map(PageLines.isThin) ?? true, let rendered = await RenderedPage.lines(of: url),
               lines == nil || !PageLines.isThin(rendered) {
                lines = rendered
                watch.needsRendering = true
            }
            guard let index = watches.firstIndex(where: { $0.id == watch.id }) else { return }
            watches[index].snapshot = (lines ?? []).joined(separator: "\n")
            watches[index].needsRendering = watch.needsRendering
            watches[index].lastChecked = .now
            watches[index].readingVersion = PageLines.version
            persist()
        }
    }

    func stop(_ id: UUID) {
        watches.removeAll { $0.id == id }
        persist()
    }

    /// Every watch that's due, checked; `force`, all of them.
    func runDue(force: Bool = false) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let due = watches.filter { force || $0.nextCheck <= .now.addingTimeInterval(5 * 60) }
        for watch in due {
            guard let url = URL(string: watch.url) else { continue }
            var lines = await PageLines.fetch(url)
            if watch.needsRendering {
                if let plain = lines, !PageLines.isThin(plain) {
                    update(watch.id) {
                        $0.needsRendering = false
                        $0.snapshot = plain.joined(separator: "\n")
                        $0.readingVersion = PageLines.version
                        $0.lastChecked = .now
                    }
                    continue
                }
                lines = await RenderedPage.lines(of: url)
            }
            // Offline, or the page didn't load: still due, so next time.
            guard let lines, let current = watches.first(where: { $0.id == watch.id }) else { continue }
            let checked = await Self.compare(current, with: lines)
            update(watch.id) { $0 = checked }
        }
    }

    private func update(_ id: UUID, _ change: (inout Watch) -> Void) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        change(&watches[index])
        persist()
    }

    /// The page read again, against the last reading: what it says, and
    /// whether to notify.
    static func compare(_ watch: Watch, with lines: [String]) async -> Watch {
        var watch = watch
        let old = watch.snapshot.split(separator: "\n").map(String.init)
        watch.lastChecked = .now
        guard watch.readingVersion == PageLines.version else {
            watch.snapshot = lines.joined(separator: "\n")
            watch.readingVersion = PageLines.version
            return watch
        }
        // Far shorter than before: an error page or a wall, not the page.
        guard lines.joined().count * 3 >= old.joined().count else { return watch }
        watch.snapshot = lines.joined(separator: "\n")
        guard !old.isEmpty else { return watch }
        let before = Set(old), after = Set(lines)
        let added = lines.filter { !before.contains($0) }
        let removed = old.filter { !after.contains($0) }
        let verdict: (happened: Bool, notification: String)
        if watch.lookFor.isEmpty {
            // New lines of real text, not a time or a counter ticking on.
            let ticked = Set(removed.map(withoutDigits))
            let news = added.filter { $0.count >= 30 && !ticked.contains(withoutDigits($0)) }
            guard !news.isEmpty else { return watch }
            verdict = await WatchJudge.news(in: news) ?? WatchJudge.guess(lookFor: "", added: news)
        } else {
            guard !added.isEmpty || !removed.isEmpty else { return watch }
            verdict = await WatchJudge.becameTrue(watch.lookFor, before: old, now: lines, removed: removed, added: added)
                ?? WatchJudge.guess(lookFor: watch.lookFor, added: added)
        }
        guard verdict.happened, !verdict.notification.isEmpty else { return watch }
        watch.lastNews = verdict.notification
        watch.lastNewsAt = .now
        WatchNotifications.post(title: watch.title.isEmpty ? watch.host : watch.title, body: verdict.notification,
                                url: watch.url, thread: watch.host)
        return watch
    }

    nonisolated static func withoutDigits(_ line: String) -> String {
        String(line.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) })
    }

    private func persist() {
        let watches = watches
        let file = file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(watches) { try? data.write(to: file, options: .atomic) }
        }
    }
}

enum WatchNotifications {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A click opens the page (SiteNotifications.clicked).
    static func post(title: String, body: String, url: String, thread: String) {
        guard !Store.testing else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        content.userInfo = ["roko.watch": url]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: Reading

/// A page as Notify Me compares it: one line per paragraph, list item or
/// heading, plus what shops publish for search engines (product, price, stock)
/// and the choices on the page (sizes), marked when they can't be picked.
/// Plain HTTP and text, no web view, so it can run in the background.
nonisolated enum PageLines {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        // Always the page as it is now: a cached copy would hide the change.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ","),
        ]
        return URLSession(configuration: configuration)
    }()

    /// Bumped when the way pages are read changes (2: link text on pages of
    /// boxes), so a watch re-reads instead of announcing the change as news.
    static let version = 2

    @concurrent static func fetch(_ url: URL) async -> [String]? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (response.mimeType ?? "").contains("html") else { return nil }
        return lines(from: String(decoding: data, as: UTF8.self))
    }

    @concurrent static func parse(_ html: String) async -> [String] {
        lines(from: html)
    }

    /// Too little text to watch: the page writes it with scripts.
    static func isThin(_ lines: [String]) -> Bool {
        lines.joined().count < 300
    }

    static func lines(from html: String) -> [String] {
        var lines = productLines(html)
        for match in WebResearcher.matches(#"<option\b([^>]*)>([\s\S]*?)</option>"#, in: html) {
            let text = WebResearcher.plain(match[1])
            guard !text.isEmpty, text.count <= 60 else { continue }
            lines.append("Option: " + text + (match[0].contains("disabled") ? " (unavailable)" : ""))
        }
        var body = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        for match in WebResearcher.matches(#"<(p|li|h[1-6]|td|dt|dd|figcaption)\b[^>]*>([\s\S]*?)</\1>"#, in: body) {
            let text = WebResearcher.plain(match[1])
            if text.count >= 3 { lines.append(String(text.prefix(400))) }
        }
        // A page built of divs and links (glas-slavonije.hr) has no paragraphs
        // or headings at all: its headlines are the links' text.
        if isThin(lines) {
            for match in WebResearcher.matches(#"<a\b[^>]*>([\s\S]*?)</a>"#, in: body) {
                let text = WebResearcher.plain(match[0])
                if (25...400).contains(text.count) { lines.append(text) }
            }
        }
        // Each line once, in page order, up to a long article's worth.
        var seen: Set<String> = [], kept: [String] = [], length = 0
        for line in lines where seen.insert(line).inserted {
            kept.append(line)
            length += line.count
            if length > 30_000 { break }
        }
        return kept
    }

    /// Products and offers from the page's JSON-LD: "Offer: Linen shirt M 39.95 EUR InStock".
    private static func productLines(_ html: String) -> [String] {
        var lines: [String] = []
        for block in WebResearcher.matches(#"<script[^>]*application/ld\+json[^>]*>([\s\S]*?)</script>"#, in: html) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(block[0].utf8)) else { continue }
            collect(json, product: nil, into: &lines)
        }
        return lines
    }

    private static func collect(_ node: Any, product: String?, into lines: inout [String]) {
        if let list = node as? [Any] {
            for item in list { collect(item, product: product, into: &lines) }
            return
        }
        guard let object = node as? [String: Any] else { return }
        let types = (object["@type"] as? [String]) ?? [(object["@type"] as? String) ?? ""]
        var product = product
        if types.contains(where: { $0.contains("Product") }), let name = object["name"] as? String {
            product = name
            lines.append("Product: " + name)
        }
        if types.contains(where: { $0.contains("Offer") }) {
            let price = [(object["price"] ?? object["lowPrice"]).map { "\($0)" }, object["priceCurrency"] as? String]
                .compactMap { $0 }.joined(separator: " ")
            let parts = [object["name"] as? String ?? product, price, (object["availability"] as? String).map(stock)]
            lines.append("Offer: " + parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        }
        for (key, value) in object where key != "@context" && (value is [Any] || value is [String: Any]) {
            collect(value, product: product, into: &lines)
        }
    }

    /// "https://schema.org/OutOfStock" in words, so the line reads like the page does.
    private static func stock(_ availability: String) -> String {
        let value = availability.split(separator: "/").last.map(String.init) ?? availability
        return switch value {
        case "InStock", "InStoreOnly", "OnlineOnly": "in stock"
        case "OutOfStock", "SoldOut": "sold out"
        case "LimitedAvailability": "few left"
        case "PreOrder", "PreSale": "pre-order"
        case "BackOrder": "on back order"
        case "Discontinued": "discontinued"
        default: value
        }
    }
}

/// Reads a page whose text its scripts write, in a web view nobody sees,
/// with your cookies, as the page would open in a tab.
@MainActor
enum RenderedPage {
    static func lines(of url: URL) async -> [String]? {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: Web.configuration(space: Browsers.primary?.spaceID ?? UUID()))
        let loader = Loader()
        webView.navigationDelegate = loader
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard await loader.finished(within: 20) else { return nil }
        // Loaded is not written: give its scripts a moment to fill it in.
        try? await Task.sleep(for: .seconds(2))
        guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String else { return nil }
        return await PageLines.parse(html)
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func finished(within seconds: Double) async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish(false) }
            }
        }

        private func finish(_ loaded: Bool) {
            guard result == nil else { return }
            result = loaded
            continuation?.resume(returning: loaded)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(false)
        }
    }
}

// MARK: Judging

@Generable
nonisolated struct WatchNewsCheck {
    // Asked "is it real news?", the model turned down a new event listing.
    @Guide(description: "False only if the new lines are just ads, times, counters or page furniture; true for anything a reader would want to know about")
    var isNews: Bool
    @Guide(description: "The notification: one short sentence. No preamble.")
    var notification: String
}

@Generable
nonisolated struct WatchPageCheck {
    @Guide(description: "The line from the page that shows it, copied exactly; empty if no line does")
    var evidence: String
    @Guide(description: "True only if that line clearly shows it")
    var shows: Bool
    @Guide(description: "If it shows it, the notification: one short sentence. No preamble.")
    var notification: String
}

/// Whether a change is what you're waiting for, and the notification that
/// says so: Apple's on-device model, free and private, which apps may use for
/// a little while in the background too.
///
/// Asked "here's what was added and removed: did it happen?", the small model
/// mixed the two up and announced "back in stock" for a size that had just
/// sold out. So it answers plain questions about one version of the page at a
/// time, quoting the line it bases the answer on, and roko compares the answers.
enum WatchJudge {
    /// Anything new: whether the new lines are news, and the notification.
    static func news(in added: [String]) async -> (happened: Bool, notification: String)? {
        guard AppleModels.onDeviceAvailable else { return nil }
        let instructions = """
            You watch a web page for someone and tell them when something new appears on it: a new article, \
            post, event, product, listing or announcement. Ads, times, counters and layout are not news. You \
            get the lines that are new on the page. Write the notification as a person would say it: what it \
            is (a new article, a new event), then its headline or title in the page's own words. \
            \(language(of: added))
            """
        let session = LanguageModelSession(model: AppleModels.summarizing, instructions: instructions)
        let prompt = "New on the page:\n" + capped(added, 2_500)
        guard let response = try? await session.respond(to: prompt, generating: WatchNewsCheck.self) else { return nil }
        return (response.content.isNews, response.content.notification)
    }

    /// Whether what you're waiting for is on the page now and wasn't before.
    static func becameTrue(_ lookFor: String, before: [String], now: [String], removed: [String], added: [String]) async
        -> (happened: Bool, notification: String)? {
        guard AppleModels.onDeviceAvailable else { return nil }
        guard let current = await check(lookFor, on: relevant(now, changed: added, to: lookFor)) else { return nil }
        guard current.shows else { return (false, "") }
        // Already so before: what changed was something else (a price, a photo).
        let earlier = await check(lookFor, on: relevant(before, changed: removed, to: lookFor))
        if earlier?.shows == true { return (false, "") }
        return (true, current.notification.isEmpty ? readable(current.evidence, 140) : current.notification)
    }

    /// One version of the page: does it show it, and on which line. A line
    /// the model quotes that isn't on the page doesn't count.
    private static func check(_ lookFor: String, on lines: [String]) async -> (shows: Bool, evidence: String, notification: String)? {
        let instructions = """
            You check a web page for someone. Answer only from the page's lines, never from what you know. \
            Lines starting "Offer:" give a product, its price and whether it's in stock; "Option:" lines are \
            choices on the page, and "(unavailable)" means that one can't be picked. Write the notification as \
            a person would say it, with the page's own specifics, in the way of "Back in stock: the blue \
            jacket in size 40, 89 EUR". \(language(of: [lookFor] + lines.prefix(8)))
            """
        let session = LanguageModelSession(model: AppleModels.summarizing, instructions: instructions)
        let prompt = "Does this page show: \(lookFor)\n\nThe page:\n" + capped(lines, 2_500)
        guard let content = try? await session.respond(to: prompt, generating: WatchPageCheck.self).content else { return nil }
        let quoted = content.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let onPage = !quoted.isEmpty && lines.contains { $0.localizedCaseInsensitiveContains(quoted.prefix(40)) }
        return (content.shows && onPage, quoted, content.notification)
    }

    /// The lines worth showing the model: what changed, then what mentions
    /// what you're waiting for, then the page from the top (offers come first).
    private static func relevant(_ lines: [String], changed: [String], to lookFor: String) -> [String] {
        let words = keywords(lookFor)
        let mentioning = lines.filter { line in words.contains { line.lowercased().contains($0) } }
        var picked: [String] = [], seen: Set<String> = [], length = 0
        for line in changed + mentioning + lines where seen.insert(line).inserted {
            picked.append(line)
            length += line.count
            if length > 2_500 { break }
        }
        return picked
    }

    /// In the answer language, unless Apple's models write it badly (see WritingLanguage).
    private static func language(of lines: [String]) -> String {
        switch AnswerLanguage.target(for: lines.joined(separator: "\n")) {
        case .some(let language) where !language.appleWritesWell:
            "Write the notification in English, quoting names and headlines as they appear."
        case .some(let language): language.instruction
        case nil: "Write the notification in the language of the page."
        }
    }

    private static func keywords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map(String.init)
    }

    /// Without the model: new text for "anything new"; otherwise a new line
    /// that mentions what you're waiting for.
    static func guess(lookFor: String, added: [String]) -> (happened: Bool, notification: String) {
        if lookFor.isEmpty {
            guard let first = added.first else { return (false, "") }
            return (true, "New: " + readable(first, 120))
        }
        let words = keywords(lookFor)
        guard let line = added.first(where: { line in words.contains { line.lowercased().contains($0) } }) else {
            return (false, "")
        }
        return (true, readable(line, 140))
    }

    /// A line as it reads on the page, without the "Offer: " the reader adds.
    private static func readable(_ line: String, _ limit: Int) -> String {
        var line = line
        for mark in ["Offer: ", "Product: ", "Option: "] where line.hasPrefix(mark) { line.removeFirst(mark.count) }
        return String(line.prefix(limit))
    }

    private static func capped(_ lines: [String], _ limit: Int) -> String {
        String(lines.map { "- " + $0 }.joined(separator: "\n").prefix(limit))
    }
}

