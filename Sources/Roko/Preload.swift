import Foundation

// ⌘T's top hit loaded while you choose, as roko on iPhone does: a quarter of
// a second after the typing stops, when the first row is somewhere to go
// (somewhere you've been, a bookmark, a well-known site) rather than a
// search, its page starts loading in a tab nobody sees. Return on it hands
// that tab over, its page already on its way or there. Anything else (other
// words, another row, the launcher put away) lets it go.
//
// Never for a private tab, never in a test run, and only with Settings ›
// General › Load the top suggestion while you type on.

extension Browser {
    /// The offers changed (Browser.offers): the top one, loaded soon.
    func considerPreload() {
        preloadWork?.cancel()
        guard prefs.preloadsTopHit, !Store.testing, launching, active?.shy != true,
              !typed.trimmingCharacters(in: .whitespaces).isEmpty, let top = offers.first,
              [.visited, .bookmark, .known].contains(top.kind),
              ["http", "https"].contains(top.url.scheme?.lowercased() ?? "") else {
            if !launching || typed.isEmpty { dropPreload() }
            return
        }
        let url = top.url
        guard preloaded?.url != url else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, launching, offers.first?.url == url else { return }
            dropPreload()
            let tab = Tab(configuration: Web.configuration(space: spaceID))
            prepare(tab)
            tab.go(to: url)
            preloaded = (tab, url)
        }
        preloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The tab loading `url` for ⌘T, taken out of waiting; nil if none is.
    func takePreload(_ url: URL) -> Tab? {
        guard let ready = preloaded, ready.url == url else { return nil }
        preloaded = nil
        return ready.tab
    }

    func dropPreload() {
        preloadWork?.cancel()
        preloadWork = nil
        guard let ready = preloaded else { return }
        preloaded = nil
        ready.tab.close()
    }
}

// The spare: a tab with its web view (and so WebKit's processes for it)
// built ahead, for the next tab opened from the launcher, a link or another
// app, so it starts loading at once, as roko on iPhone keeps one. Built a
// moment after launch and a second after each is taken; let go of when the
// Mac is short of memory, and never kept for another space's sign-ins.

extension Browser {
    func takeSpare() -> Tab? {
        guard let ready = spare else { return nil }
        spare = nil
        guard ready.space == spaceID else {
            ready.tab.close()
            refillSpare()
            return nil
        }
        refillSpare()
        return ready.tab
    }

    func refillSpare(after delay: TimeInterval = 1) {
        guard !Store.testing, !isPopup else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, spare == nil, isOpen else { return }
            let tab = Tab(configuration: Web.configuration(space: spaceID))
            prepare(tab)
            _ = tab.web
            spare = (tab, spaceID)
        }
    }

    func dropSpare() {
        guard let ready = spare else { return }
        spare = nil
        ready.tab.close()
    }
}
