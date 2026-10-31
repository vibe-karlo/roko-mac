import SwiftUI
import WebKit

// The player at the foot of the column, as Arc has it: the tab that played
// last, while it isn't the one on screen, with play and pause, and a click
// that takes you to it. Paused, it stays; it goes with its tab or its page.

extension Browser {
    /// The player's tab, in this space or a space parked beside it.
    var playerTab: Tab? {
        guard let id = player else { return nil }
        return tabs.first { $0.id == id } ?? parkedTabs.first { $0.id == id }
    }

    /// To the tab that is playing: its space first if it is in another.
    func goToPlayer() {
        guard let tab = playerTab else { return }
        if !tabs.contains(where: { $0.id == tab.id }),
           let space = parked.first(where: { $0.value.tabs.contains { $0.id == tab.id } })?.key {
            switchSpace(to: space)
        }
        if let here = tabs.first(where: { $0.id == tab.id }) { select(here) }
    }

    /// Play, or pause: every player on the page and in the frames that
    /// played, as a press on the video would.
    func togglePlayback(_ tab: Tab) {
        guard let web = tab.built else { return }
        if tab.noisy {
            web.pauseAllMediaPlayback()
            return
        }
        web.evaluateJavaScript(SideMediaPlayer.resume, in: nil, in: .page) { _ in }
        for frame in tab.media.frames {
            web.evaluateJavaScript(SideMediaPlayer.resume, in: frame, in: .page) { _ in }
        }
    }
}

struct SideMediaPlayer: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @Environment(\.greys) private var greys
    @State private var hovering = false

    /// The player that was playing, or the first that has played at all,
    /// played again.
    static let resume = """
        (() => {
          const all = [...document.querySelectorAll('video, audio')];
          const one = all.find(m => m.paused && m.currentTime > 0) || all.find(m => m.paused);
          if (one) { one.play().catch(() => {}); return true; }
          return false;
        })()
        """

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 10) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.label.isEmpty ? "Playing" : tab.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(tab.pageAddress?.displayHost ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { browser.togglePlayback(tab) } label: {
                Image(systemName: tab.noisy ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .symbolSwap()
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.noisy ? "Pause" : "Play")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 44)
        .background(shape.fill(hovering ? greys.wash : greys.hover))
        .contentShape(shape)
        .onTapGesture { browser.goToPlayer() }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help("Go to the tab")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playing: \(tab.label)")
    }
}
