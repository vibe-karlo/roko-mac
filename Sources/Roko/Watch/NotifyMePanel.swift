import SwiftUI

/// Notify Me for the page on screen: what to look for, how often, and the
/// other pages being watched, each with a way to stop.
struct NotifyMePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var watcher = Watcher.shared
    @State private var lookFor = ""
    @State private var frequency: WatchFrequency = .daily
    @FocusState private var focused: Bool

    private var url: URL? {
        guard let tab = browser.active, tab.isWeb, let url = tab.pageAddress,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private var existing: Watch? { watcher.watch(for: url) }

    var body: some View {
        Plate("Notify Me", width: 400, close: { browser.notifyingMe = false }) {
            VStack(alignment: .leading, spacing: 14) {
                if let url {
                    Text("roko reads \(url.displayHost) for you and tells you when it changes.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("", text: $lookFor, prompt: Text("Anything new").foregroundStyle(Palette.faint))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Palette.ink)
                                .focused($focused)
                                .onSubmit(save)
                            Text("Such as: size M in stock, a price under €50, a new article about Pula.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(12)
                    }
                    HStack {
                        Text("Check")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                        Spacer()
                        Segmented(options: WatchFrequency.allCases.map { ($0, $0.name) }, selection: $frequency)
                    }
                    if let news = existing?.lastNews, let at = existing?.lastNewsAt {
                        Text("Last noticed \(at.formatted(.relative(presentation: .named))): \(news)")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Card { Nothing("Open a web page to be told when it changes.") }
                }
                let others = watcher.watches.filter { $0.url != url?.absoluteString }
                if !others.isEmpty {
                    Caption("Also watching")
                    Card {
                        ForEach(Array(others.enumerated()), id: \.element.id) { index, watch in
                            if index > 0 { Rule() }
                            WatchRow(watch: watch, open: {
                                if let url = URL(string: watch.url) { browser.open(url, foreground: true) }
                                browser.notifyingMe = false
                            }, stop: { watcher.stop(watch.id) })
                        }
                    }
                }
            }
        } foot: {
            HStack(spacing: 8) {
                if url != nil {
                    Pill(existing == nil ? "Notify Me" : "Save", filled: true, action: save)
                }
                Spacer()
                // A quiet word, not a second button beside the first.
                if let existing {
                    Button("Stop watching") { watcher.stop(existing.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .onAppear {
            lookFor = existing?.lookFor ?? ""
            frequency = existing.flatMap { WatchFrequency(rawValue: $0.everyHours) } ?? .daily
            DispatchQueue.main.async { focused = true }
        }
    }

    private func save() {
        guard let url, let tab = browser.active else { return }
        watcher.set(url: url, title: tab.title, lookFor: lookFor, every: frequency)
        browser.notifyingMe = false
        browser.announce(lookFor.trimmingCharacters(in: .whitespaces).isEmpty
            ? "You'll hear when \(url.displayHost) has something new"
            : "You'll hear when \(url.displayHost) shows it")
    }
}

private struct WatchRow: View {
    let watch: Watch
    let open: () -> Void
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(watch.title.isEmpty ? watch.host : watch.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(watch.lookFor.isEmpty ? "\(watch.host) · anything new" : "\(watch.host) · \(watch.lookFor)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: stop) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop watching")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}
