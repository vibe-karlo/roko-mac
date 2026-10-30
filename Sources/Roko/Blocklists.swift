import WebKit

// roko's blocking, the same as on the iPhone: EasyList, EasyPrivacy, the
// cookie-notice and annoyance lists (built by Scripts/build_blocklists.py in
// the iOS repository, copied into Resources/Blocking), enforced inside WebKit
// as content rule lists; element hiding served page by page (CosmeticFilter);
// and cookie pop-ups answered with "reject" (ConsentHandler, DuckDuckGo's
// Autoconsent). It sits under Shield: Shield's switch and its sites paused
// are this one's too.

@MainActor
final class Blocklists {
    static let shared = Blocklists()

    enum Category: String, CaseIterable {
        case ads, privacy, cookies, popups

        var title: String {
            switch self {
            case .ads: "Ads"
            case .privacy: "Trackers"
            case .cookies: "Cookie notices"
            case .popups: "Pop-ups"
            }
        }
    }

    private var compiled: [Category: WKContentRuleList] = [:]
    /// Each tab's controller, and the site it was last set up for, so the
    /// lists can join tabs that opened before they were ready, and a switch
    /// in Settings reaches every open page.
    private let hosts = NSMapTable<WKUserContentController, NSString>.weakToStrongObjects()
    /// What each controller was last given, as roko on iPhone keeps it: the
    /// same again (most pages of most sites) changes nothing, where taking
    /// four lists off and putting them back made WebKit redo its work.
    private let given = NSMapTable<WKUserContentController, NSString>.weakToStrongObjects()
    private let handled = NSHashTable<WKUserContentController>.weakObjects()
    private lazy var loading = Task { await load() }

    private init() {}

    /// The file shipped in the app (build.sh copies Resources/Blocking), or
    /// none, as in a test run: then nothing here blocks anything.
    nonisolated static func resource(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
    }

    // MARK: Settings

    /// Each kind on unless switched off; all of them only while Shield is on.
    func isEnabled(_ category: Category) -> Bool {
        Store.settings.object(forKey: "block.\(category.rawValue)") as? Bool ?? true
    }

    func setEnabled(_ category: Category, _ on: Bool) {
        Store.settings.set(on, forKey: "block.\(category.rawValue)")
        refresh()
    }

    /// Blocking anything at all on this site: Shield on, and not paused here.
    func blocks(on host: String?) -> Bool {
        Shield.shared.enabled && !Shield.shared.isPaused(on: host)
    }

    // MARK: Lifecycle

    /// Loads the compiled lists from WebKit's store, compiling from the app's
    /// files only when they changed. Started at launch; safe to call again.
    func start() {
        _ = loading
    }

    private func load() async {
        guard let store = WKContentRuleListStore.default() else { return }
        Task { await CosmeticFilter.shared.load() }
        var current: Set<String> = []
        for category in Category.allCases {
            guard let url = Self.resource(category.rawValue, "json") else { continue }
            let hostsFile = Self.resource("\(category.rawValue)-hosts", "txt")
            let identifier = Self.identifier(for: category, files: [url, hostsFile])
            current.insert(identifier)
            if let list = try? await store.contentRuleList(forIdentifier: identifier) {
                compiled[category] = list
                continue
            }
            do {
                let json = try await Task.detached(priority: .utility) {
                    try Self.rules(json: url, hosts: hostsFile)
                }.value
                compiled[category] = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            } catch {
                NSLog("roko: the \(category.rawValue) list didn't compile: \(error)")
            }
        }
        // Lists from earlier builds go; Shield's own list is Shield's.
        for identifier in await store.availableIdentifiers() ?? []
        where identifier.hasPrefix("roko-") && !current.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
        refresh()
    }

    /// A list's rules as WebKit takes them: its plain hosts (shipped one per
    /// line, a fifth of the size as JSON) made into block rules, then the rest,
    /// whose exceptions must come last. Only when compiling, once per update.
    nonisolated static func rules(json: URL, hosts: URL?) throws -> String {
        let rest = try String(contentsOf: json, encoding: .utf8)
        guard let hosts, let text = try? String(contentsOf: hosts, encoding: .utf8) else { return rest }
        var out = "["
        out.reserveCapacity(rest.utf8.count + text.utf8.count * 4)
        var any = false
        for host in text.split(separator: "\n") where !host.isEmpty {
            if any { out += "," }
            any = true
            out += #"{"trigger":{"url-filter":"^[^:]+://+([^/]+\\.)?"#
            out += host.replacingOccurrences(of: ".", with: #"\\."#)
            out += #"[/:?&=]"},"action":{"type":"block"}}"#
        }
        let others = rest.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()  // without its "["
        return out + (others.first == "]" || !any ? "" : ",") + others
    }

    private static func identifier(for category: Category, files: [URL?]) -> String {
        let size = files.compactMap { $0 }.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "roko-\(category.rawValue)-\(build)-\(size)"
    }

    // MARK: Wiring

    /// Once per controller, as a tab is built: the two message handlers the
    /// page scripts answer to. A controller shared by several tabs (extension
    /// pages) is only given them once.
    func install(in controller: WKUserContentController) {
        guard !handled.contains(controller) else { return }
        handled.add(controller)
        controller.addScriptMessageHandler(CosmeticFilter.shared, contentWorld: CosmeticFilter.world, name: CosmeticFilter.handlerName)
        controller.addScriptMessageHandler(ConsentHandler.shared, contentWorld: ConsentHandler.world, name: ConsentHandler.handlerName)
        tune(controller, for: nil)
    }

    /// Before each page (Shield.tune): the lists go on or off for the site
    /// this tab is heading to. Rule lists can't be scoped to a site from
    /// outside, so each navigation sets them for where it is going.
    func tune(_ controller: WKUserContentController, for host: String?) {
        hosts.setObject((host ?? "") as NSString, forKey: controller)
        let blocking = blocks(on: host)
        // A site that only works with its cookies accepted gets its consent
        // platform back: the cookie list blocks many of them, and a blocked
        // one can't be accepted. Its notice is still answered, with accept.
        let accepts = host.map { ConsentHandler.shared.acceptance(for: $0) != nil } ?? false
        let wanted = compiled.keys.filter { blocking && isEnabled($0) && !($0 == .cookies && accepts) }
            .map(\.rawValue).sorted()
        let signature = "\(compiled.keys.map(\.rawValue).sorted())|\(wanted)" as NSString
        guard given.object(forKey: controller) != signature else { return }
        given.setObject(signature, forKey: controller)
        for (category, list) in compiled {
            controller.remove(list)
            guard blocking, isEnabled(category), !(category == .cookies && accepts) else { continue }
            controller.add(list)
        }
    }

    /// The page scripts for a page on `host` (Tab.arm adds them with the rest).
    func scripts(for host: String?) -> [WKUserScript] {
        guard blocks(on: host) else { return [] }
        var scripts: [WKUserScript] = []
        // Cookie notices are answered, not just hidden: hidden, a site keeps
        // asking, and often keeps the page locked or its content held back.
        if isEnabled(.cookies) { scripts += ConsentHandler.shared.scripts }
        if isEnabled(.ads) || isEnabled(.cookies) || isEnabled(.popups), let hiding = CosmeticFilter.shared.script {
            scripts.append(hiding)
        }
        return scripts
    }

    /// Settings changed, or the lists became ready: every open tab again, for
    /// the site it is on. Page scripts follow with the next page.
    func refresh() {
        for controller in hosts.keyEnumerator().allObjects.compactMap({ $0 as? WKUserContentController }) {
            let host = hosts.object(forKey: controller).map(String.init)
            tune(controller, for: host?.isEmpty == false ? host : nil)
        }
    }
}

/// Serves element-hiding rules page by page. WebKit applies every site-agnostic
/// hiding rule in a content rule list to every page as one huge stylesheet,
/// which measurably delays first paint; here a page only receives the few
/// selectors whose id or class it actually contains (cosmetic-filter.js).
@MainActor
final class CosmeticFilter: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = CosmeticFilter()
    static let world = WKContentWorld.world(name: "cosmetic")
    static let handlerName = "cosmetic"

    /// One list's hiding rules, read off the main thread from the lines
    /// build_blocklists.py writes ("key<TAB>selector", then sections each
    /// opened by a \u{1} line). Substrings of the file's text, so reading
    /// copies nothing.
    private nonisolated struct Index: Sendable {
        var keyed: [Substring: [Substring]] = [:]
        var always: [Substring] = []
        var scoped: [Substring: [Substring]] = [:]
        var untouched: [Substring] = []

        init(text: String) {
            var section = 0
            for line in text.split(separator: "\n") {
                if line.first == "\u{1}" {
                    section += 1
                    continue
                }
                switch section {
                case 0, 2:
                    guard let tab = line.firstIndex(of: "\t") else { continue }
                    let key = line[..<tab], selector = line[line.index(after: tab)...]
                    if section == 0 { keyed[key, default: []].append(selector) } else { scoped[key, default: []].append(selector) }
                case 1: always.append(line)
                default: untouched.append(line)
                }
            }
        }
    }

    private var indexes: [Blocklists.Category: Index] = [:]
    private lazy var loading = Task { await decodeAll() }

    lazy var script: WKUserScript? = {
        guard let url = Blocklists.resource("cosmetic-filter", "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
    }()

    func load() async {
        await loading.value
    }

    private func decodeAll() async {
        let files = Blocklists.Category.allCases.compactMap { category in
            Blocklists.resource("\(category.rawValue)-hide", "txt").map { (category, $0) }
        }
        await withTaskGroup(of: (Blocklists.Category, Index?).self) { group in
            for (category, url) in files {
                group.addTask(priority: .userInitiated) {
                    (category, (try? String(contentsOf: url, encoding: .utf8)).map(Index.init(text:)))
                }
            }
            for await (category, index) in group { indexes[category] = index }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let keys = body["keys"] as? [String] else {
            return (nil, nil)
        }
        await load()
        let host = (body["host"] as? String ?? "").lowercased()
        guard Blocklists.shared.blocks(on: host) else { return (nil, nil) }
        let isFirst = body["first"] as? Bool ?? false
        let hosts = Self.suffixes(of: host)

        var selectors: [Substring] = []
        // Cookie notices are faded out rather than removed: the consent script
        // has to find a notice to answer it, and a removed one can't be found.
        // The page script removes them for good a little later.
        var faded: [Substring] = []
        // Overlays (cookie notices, pop-ups) often lock page scrolling; the page
        // script checks these against the page and unlocks it if one was hidden.
        var overlays: [Substring] = []
        // Whether the page script may fold away ad boxes left empty by blocking.
        var collapseAds = false
        for category in Blocklists.Category.allCases where Blocklists.shared.isEnabled(category) {
            guard let index = indexes[category],
                  !hosts.contains(where: { index.untouched.contains(Substring($0)) }) else { continue }
            if category == .ads { collapseAds = true }
            var found: [Substring] = []
            if isFirst {
                found += index.always
                for host in hosts { found += index.scoped[Substring(host)] ?? [] }
            }
            for key in keys { found += index.keyed[Substring(key)] ?? [] }
            if category == .cookies { faded += found } else { selectors += found }
            if category == .cookies || category == .popups { overlays += found }
        }
        // One rule per selector, so a selector WebKit can't parse only drops itself.
        // Under :root, one step more specific than the page's own rules: a site
        // whose stylesheet loads later and shows the same element with
        // !important can't undo it. Not for pseudo-elements, which :is() can't hold.
        let css = selectors.map { ($0.contains("::") ? String($0) : ":root :is(\($0))") + "{display:none!important}" }
            .joined(separator: "\n")
        return (["css": css, "faded": faded.map(String.init), "overlays": overlays.map(String.init),
                 "collapseAds": isFirst && collapseAds], nil)
    }

    /// "news.bbc.co.uk" → ["news.bbc.co.uk", "bbc.co.uk", "co.uk", "uk"].
    private static func suffixes(of host: String) -> [String] {
        var parts = host.split(separator: ".")
        var result: [String] = []
        while !parts.isEmpty {
            result.append(parts.joined(separator: "."))
            parts.removeFirst()
        }
        return result
    }
}

/// roko's side of the cookie pop-up scripts (built from DuckDuckGo's
/// Autoconsent): decides how each pop-up is answered, runs the few rule steps
/// that need the page's own scripts, and accepts cookies on a site only when
/// it doesn't work without them. A site where that happened is remembered,
/// and from then on accepted straight away.
@MainActor
final class ConsentHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ConsentHandler()
    static let world = WKContentWorld.world(name: "consent")
    static let handlerName = "consent"

    /// Why cookies are accepted on a site.
    enum Reason: String {
        /// Rejecting didn't get past the pop-up (a cookie wall).
        case wall
        /// After rejecting, the page held content back until cookies were accepted.
        case content
        /// Chosen by hand.
        case chosen
    }

    /// How often each page has been reloaded to unblock it, so a site that
    /// stays broken can't make roko reload it again and again.
    private var attempts: [String: Int] = [:]
    private static let acceptKey = "consent.acceptedHosts"

    lazy var scripts: [WKUserScript] = [("consent-main", true), ("consent-frame", false)].compactMap { name, mainOnly in
        guard let url = Blocklists.resource(name, "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // At the start, so Autoconsent can keep a known pop-up hidden while it answers it.
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: mainOnly, in: Self.world)
    }

    // MARK: Per-site choice

    /// Whether cookies are accepted on this site, and why; nil means rejected.
    func acceptance(for host: String) -> Reason? {
        (Store.settings.dictionary(forKey: Self.acceptKey)?[Self.normalize(host)] as? String).flatMap(Reason.init)
    }

    func setAccepted(_ reason: Reason?, for host: String) {
        var hosts = Store.settings.dictionary(forKey: Self.acceptKey) ?? [:]
        hosts[Self.normalize(host)] = reason?.rawValue
        Store.settings.set(hosts, forKey: Self.acceptKey)
    }

    private static func normalize(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Said at the foot of the window, so a page that let its notice through
    /// is never a mystery.
    private func say(_ host: String, _ reason: Reason, in webView: WKWebView) {
        let site = Self.normalize(host)
        let why = reason == .wall ? "it won't open without them" : "it held the page back without them"
        (webView.navigationDelegate as? Browser)?.announce("Cookies accepted on \(site): \(why)")
    }

    // MARK: Messages

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView else { return (nil, nil) }
        // Decided for the site you're on, also when the pop-up sits in a frame.
        let host = webView.url?.host() ?? message.frameInfo.request.url?.host() ?? ""

        switch type {
        case "popupFound":
            return (["type": acceptance(for: host) == nil ? "optOut" : "optIn"], nil)

        case "eval":
            // A rule step that needs the page's own script, such as a platform's API.
            let id = body["id"] as? String ?? ""
            let code = body["code"] as? String ?? "false"
            // At most a second: a platform API that never calls back left the
            // step waiting, and Autoconsent, waiting for every rule, never got
            // as far as the pop-up right there on the page.
            let result = try? await webView.callAsyncJavaScript("""
                try {
                    return !!(await Promise.race([(async () => (\(code)))(), new Promise(done => setTimeout(() => done(false), 1000))]));
                } catch (e) { return false; }
                """, in: message.frameInfo, contentWorld: .page)
            return (["type": "evalResp", "id": id, "result": (result as? Bool) ?? false], nil)

        case "rokoWall":
            setAccepted(.wall, for: host)
            say(host, .wall, in: webView)
            return (["type": "optIn"], nil)

        case "rokoBlocked":
            if acceptance(for: host) == nil {
                setAccepted(.content, for: host)
                say(host, .content, in: webView)
            }
            // Through the platform's own API first: the content usually comes
            // back at once, with no reload.
            let accepted = (try? await webView.evaluateJavaScript(Self.acceptAll, in: nil, contentWorld: .page)) as? Int ?? 0
            if accepted > 0 { return (["type": "rokoRecheck"], nil) }
            await recover(webView, host: host)
            return (nil, nil)

        case "rokoPlatform":
            // Answered through the platform's API, as this site is answered.
            let accept = acceptance(for: host) != nil
            let answered = (try? await webView.evaluateJavaScript(Self.answerNotice(accept),
                                                                  in: nil, contentWorld: .page)) as? Int ?? 0
            return (["answered": answered > 0, "accepted": accept && answered > 0], nil)

        case "rokoStillBlocked":
            await recover(webView, host: host)
            return (nil, nil)

        default:
            return (nil, nil)
        }
    }

    /// Content still held back once cookies are accepted. First a plain
    /// reload: the site is now marked as accepted, so its consent platform is
    /// no longer blocked, shows its pop-up, and gets accepted. If that isn't
    /// enough, the site is keeping an earlier "rejected" in its cookies or
    /// storage and won't ask again: forget this site's data and load it
    /// afresh. Each at most once per page.
    private func recover(_ webView: WKWebView, host: String) async {
        guard let url = webView.url?.absoluteString else { return }
        let attempt = attempts[url, default: 0]
        attempts[url] = attempt + 1
        switch attempt {
        case 0:
            webView.reload()
        case 1:
            let store = webView.configuration.websiteDataStore
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await store.dataRecords(ofTypes: types).filter { record in
                host == record.displayName || host.hasSuffix("." + record.displayName)
            }
            await store.removeData(ofTypes: types, for: records)
            webView.reload()
        default:
            break
        }
    }

    /// A platform's notice that's showing, answered through its API: for pages
    /// that scramble the names rules look for. Answers 1 if one was.
    private static func answerNotice(_ accept: Bool) -> String {
        """
        (() => {
          try {
            const d = window.Didomi;
            if (d && d.notice && typeof d.notice.isVisible === 'function' && d.notice.isVisible()) {
              \(accept ? "d.setUserAgreeToAll()" : "d.setUserDisagreeToAll()");
              if (d.notice.isVisible()) d.notice.hide();
              return 1;
            }
          } catch (e) {}
          return 0;
        })()
        """
    }

    /// "Accept all" through the consent platforms' own APIs, in the page's
    /// world. Answers how many it reached.
    private static let acceptAll = """
        (() => {
          let reached = 0;
          const tryIt = (test, act) => { try { if (test()) { act(); reached++; } } catch (e) {} };
          tryIt(() => window.OneTrust && OneTrust.AllowAll, () => OneTrust.AllowAll());
          tryIt(() => window.Cookiebot && Cookiebot.submitCustomConsent, () => Cookiebot.submitCustomConsent(true, true, true));
          tryIt(() => window.UC_UI && UC_UI.acceptAllConsents, () => UC_UI.acceptAllConsents());
          tryIt(() => window.__ucCmp && __ucCmp.acceptAllConsents, () => __ucCmp.acceptAllConsents());
          tryIt(() => window.Didomi && Didomi.setUserAgreeToAll, () => Didomi.setUserAgreeToAll());
          tryIt(() => window.klaro && klaro.getManager, () => { const m = klaro.getManager(); m.changeAll(true); m.saveAndApplyConsents(); });
          tryIt(() => typeof window.cmplz_accept_all === 'function', () => cmplz_accept_all());
          tryIt(() => window.tarteaucitron && tarteaucitron.userInterface, () => tarteaucitron.userInterface.respondAll(true));
          tryIt(() => window._iub && _iub.cs && _iub.cs.api && _iub.cs.api.acceptAll, () => _iub.cs.api.acceptAll());
          tryIt(() => typeof window.__cmp === 'function' && typeof __cmp('getCMPData') === 'object', () => __cmp('setConsent', 1));
          return reached;
        })()
        """
}
