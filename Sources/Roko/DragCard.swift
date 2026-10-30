import AppKit
import SwiftUI

/// A tab carried out of its row: its mark and name, under the hand, until it
/// is let go. In the row a tab already moves with the pointer, but only along
/// the row; once the hand leaves the row for a page (to split it) or for
/// another window, nothing there showed that a tab was coming, and a split
/// appeared out of nowhere. TabDrag shows this card the moment the pointer
/// leaves the row and puts it away when it comes back or the drag ends.
///
/// A window of its own, above everything and blind to the mouse, so it can
/// follow the hand over the pages, the sidebar and out of the window alike.
@MainActor
final class DragCard {
    private let panel: NSPanel
    private let size: NSSize
    /// Air around the card inside its window, more than the shadow casts, so
    /// the shadow is never cut by the window's edge.
    private static let pad: CGFloat = 14
    /// Where the hand holds it: this far into the card from its leading
    /// edge, on its middle line, over the mark, as if picked up by it.
    private static let grip: CGFloat = 22

    init(tab: Tab, over window: NSWindow) {
        let host = NSHostingView(rootView: DragCardView(tab: tab).padding(DragCard.pad))
        size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = window.effectiveAppearance
        panel.contentView = host
        panel.alphaValue = 0
    }

    /// Under the hand at `point`, in screen coordinates; shown the first time.
    func move(to point: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: (point.x - DragCard.pad - DragCard.grip).rounded(),
                                     y: (point.y - size.height / 2).rounded()))
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    /// Put away: quickly, so a drop never waits on it.
    func close() {
        let panel = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

/// The card itself: the row's own mark and name, on the column's ground,
/// with an edge in its own ink and a short shadow cast downward.
private struct DragCardView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 8) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 15)
            Text(tab.label.isEmpty ? "New Tab" : tab.label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 34)
        .background(shape.fill(Palette.ground))
        .overlay { shape.strokeBorder(Palette.ink.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
    }
}
