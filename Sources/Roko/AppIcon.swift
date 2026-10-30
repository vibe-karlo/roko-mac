import AppKit
import SwiftUI

// The Dock icon, picked in Settings › Appearance › Window, as Cra and the
// iPhone app have it: roko's Eclipse in the iPhone's colourways (Scripts/
// make_alternate_icons.swift in the iOS repository), or a picture of your own,
// fitted to Apple's icon grid so it sits with the icons beside it.
//
// While roko runs it is the app's icon. After it quits, the Dock asks roko's
// Dock tile plug-in (DockTile/RokoDockTile.m, built into Contents/PlugIns by
// build.sh), which draws the same file: app-icon.png, named in roko's
// defaults as appIconFile. The default icon is the bundle's own, Liquid Glass
// and all, so choosing it puts nothing in its place.

enum AppIconChoice: String, CaseIterable, Identifiable {
    case standard, orange, onOrange, own

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "roko"
        case .orange: return "Orange"
        case .onOrange: return "On orange"
        case .own: return "Yours"
        }
    }

    /// The tile's colour and the mark's, for the Eclipse colourways.
    var colours: (tile: NSColor, mark: NSColor)? {
        func hex(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        switch self {
        case .standard: return (hex(0x0E0E0F), hex(0xE7E7E4))
        case .orange: return (hex(0x0E0E0F), hex(0xFF5B1F))
        case .onOrange: return (hex(0xFF5B1F), hex(0x0E0E0F))
        case .own: return nil
        }
    }
}

@MainActor
enum AppIcon {
    /// The picture of your own, as chosen, already fitted to the grid.
    static var ownFile: URL { Store.file("app-icon-own.png") }
    /// What the Dock tile plug-in draws.
    static var shownFile: URL { Store.file("app-icon.png") }
    static let bundleID = "com.growthstudio.roko.mac" as CFString
    static let changed = Notification.Name("com.growthstudio.roko.mac.appIcon")

    /// Apple's grid on a 1024 canvas: the tile is 824 across, corners 22.37%.
    static func tile(in size: CGFloat) -> (rect: NSRect, path: NSBezierPath) {
        let s = size / 1024
        let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let radius = 824 * 0.2237 * s
        return (rect, NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius))
    }

    /// One choice's icon at `size` points, or nil for a picture not chosen yet.
    static func image(_ choice: AppIconChoice, size: CGFloat = 1024) -> NSImage? {
        if choice == .own {
            guard let own = NSImage(contentsOf: ownFile) else { return nil }
            own.size = NSSize(width: size, height: size)
            return own
        }
        guard let colours = choice.colours else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let (rect, path) = tile(in: size)
            // The Dock's own shadow, short and from above, as Icon/icon.swift casts it.
            NSGraphicsContext.saveGraphicsState()
            // Not on the small ones Settings shows: no Dock under them.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 14 * size / 1024
            shadow.shadowOffset = NSSize(width: 0, height: -8 * size / 1024)
            if size >= 256 { shadow.set() }
            colours.tile.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            colours.mark.setFill()
            eclipse(in: rect).fill()
            return true
        }
    }

    /// The Eclipse on a tile, as Icon/icon.swift draws it: 600 of the
    /// iPhone's 1024, so the same share of the Mac's tile.
    private static func eclipse(in tile: NSRect) -> NSBezierPath {
        let side = tile.width * 600 / 1024
        let scale = side / 600
        let origin = NSPoint(x: tile.midX - side / 2, y: tile.midY - side / 2)
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        path.appendOval(in: NSRect(x: origin.x, y: origin.y, width: side, height: side))
        let hole = 150 * scale
        path.appendOval(in: NSRect(x: origin.x + 244 * scale, y: origin.y + side / 2 - hole, width: hole * 2, height: hole * 2))
        return path
    }

    /// A picture of your own: filled into the tile's shape, cropped to a
    /// square from its middle, and kept. False when it isn't a picture.
    @discardableResult
    static func adopt(_ url: URL) -> Bool {
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return false }
        let fitted = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            let (rect, path) = tile(in: 1024)
            path.addClip()
            let scale = max(rect.width / source.size.width, rect.height / source.size.height)
            let drawn = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                   width: drawn.width, height: drawn.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        guard let data = png(fitted, pixels: 1024) else { return false }
        try? FileManager.default.createDirectory(at: ownFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: ownFile, options: .atomic)) != nil
    }

    /// The chosen icon put up: in the Dock now, and for the plug-in after quitting.
    static func apply(_ choice: AppIconChoice) {
        // A test run is not the app in the Dock, and its world is not the one
        // the plug-in reads.
        guard !Store.testing else { return }
        let image = choice == .standard ? nil : image(choice)
        NSApp.applicationIconImage = image
        if let image, let data = png(image, pixels: 512) {
            try? data.write(to: shownFile, options: .atomic)
            CFPreferencesSetAppValue("appIconFile" as CFString, shownFile.path as CFString, bundleID)
        } else {
            try? FileManager.default.removeItem(at: shownFile)
            CFPreferencesSetAppValue("appIconFile" as CFString, nil, bundleID)
        }
        CFPreferencesAppSynchronize(bundleID)
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, deliverImmediately: true)
    }

    private static func png(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Settings' row: the icons themselves, the one in use ringed, and for your
/// own a tile to click or drop a picture on.
struct AppIconPicker: View {
    @ObservedObject var prefs: Preferences
    /// Bumped when a new picture is kept, so its tile redraws.
    @State private var ownVersion = 0
    @State private var dropping = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(AppIconChoice.allCases) { choice in
                let on = prefs.appIcon == choice
                Button { pick(choice) } label: {
                    VStack(spacing: 6) {
                        tile(choice)
                            .frame(width: 52, height: 52)
                            .padding(4)
                            .overlay(
                                // The tile's own corner (11.6) carried out by the gap.
                                RoundedRectangle(cornerRadius: 15.6, style: .continuous)
                                    .strokeBorder(on ? Palette.ink : .clear, lineWidth: 2)
                            )
                        Text(choice.title)
                            .font(.system(size: 11.5, weight: on ? .medium : .regular))
                            .foregroundStyle(on ? Palette.ink : Palette.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice == .own ? "Your own picture" : "\(choice.title) icon")
                .accessibilityAddTraits(on ? .isSelected : [])
                .onDrop(of: [.fileURL], isTargeted: choice == .own ? $dropping : .constant(false)) { providers in
                    guard choice == .own else { return false }
                    return take(providers)
                }
            }
            if prefs.appIcon == .own {
                Button("Choose Image…") { choose() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 22)
            }
        }
    }

    @ViewBuilder
    private func tile(_ choice: AppIconChoice) -> some View {
        if let image = AppIcon.image(choice, size: 104) {
            // The icon's own 100-of-1024 margin is left out: the tile fills the frame.
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaleEffect(1024 / 824)
                .id(choice == .own ? ownVersion : 0)
        } else {
            // No picture yet: the tile's outline, waiting for one.
            RoundedRectangle(cornerRadius: 11.6, style: .continuous)
                .strokeBorder(dropping ? Palette.ink : Palette.muted.opacity(0.6),
                              style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
        }
    }

    private func pick(_ choice: AppIconChoice) {
        if choice == .own, AppIcon.image(.own) == nil { return choose() }
        withAnimation(Motion.settle) { prefs.appIcon = choice }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "A square picture works best. It's cut to the shape of a Mac icon."
        panel.prompt = "Use as Icon"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keep(url)
    }

    private func take(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in keep(url) }
        }
        return true
    }

    private func keep(_ url: URL) {
        guard AppIcon.adopt(url) else { NSSound.beep(); return }
        ownVersion += 1
        if prefs.appIcon == .own { AppIcon.apply(.own) } else { withAnimation(Motion.settle) { prefs.appIcon = .own } }
    }
}
