import AppKit
import SwiftUI

/// roko's own colours, as on the iPhone (UI/Theme.swift there), for the
/// answers and summaries drawn by MarkdownText: the same ink, the same
/// greys, the same accent, light and dark.
enum Theme {
    static let canvas = Color(light: 0xE6E6E3, dark: 0x0E0E0F)
    static let raised = Color(light: 0xFCFCFB, dark: 0x252527)
    static let ink = Color(light: 0x0E0E0F, dark: 0xE7E7E4)
    static let secondaryInk = Color(light: 0x5C5C59, dark: 0x8C8C88)
    static let bodyInk = Color(light: 0x34342F, dark: 0xB8B8B3)
    static let faintInk = Color(light: 0x737370, dark: 0x7E7E7A)
    static let accent = Color(light: 0xE84A10, dark: 0xFF5B1F)
    static let edge = Color(light: 0x0E0E0F, dark: 0xE7E7E4).opacity(0.08)
}

extension Color {
    /// One colour for a light appearance and another for a dark one, followed
    /// as the window's appearance changes.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A row that is a button: only dimmed while pressed, as on the iPhone.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
