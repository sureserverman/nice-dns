// The colours of the custom parts (the status hero, the lookup path, the
// status tints and the brand green), light and dark, from the handoff pack's
// tokens.json. Everything else uses the system's semantic colours, so light
// and dark both work without a table.
import AppKit
import NiceDNSKit
import SwiftUI

enum Palette {
    /// A colour that follows the appearance: `light` and `dark` are 0xRRGGBB,
    /// with an alpha each (the dark tints are translucent).
    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        }))
    }

    /// The window, the cards on it and the switcher bar: three fills, so a card
    /// reads as a card in both appearances (tokens.json: window, card, toolbar).
    static let window = dynamic(0xFAFAFB, 0x232427)
    static let card = dynamic(0xFFFFFF, 0x2E2F33)
    static let toolbar = dynamic(0xFAFAFB, 0x2B2C30)
    /// The brand green: the tint of the window and the suggested button.
    static let accent = dynamic(0x0A7A5C, 0x4FD6A8)
    /// The text on a suggested button.
    static let onAccent = dynamic(0xFFFFFF, 0x0B2A20)
    /// The green of a link and of a passing count.
    static let accentText = dynamic(0x0A6B51, 0x4FD6A8)
    /// The track of a switch that is on.
    static let switchOn = dynamic(0x0A7A5C, 0x1E9C76)
    static let destructive = dynamic(0xB3261E, 0xFF9A8F)
    /// Output the command printed on stderr: muted, so a successful run's
    /// helper notes do not look like a failure.
    static let stderr = dynamic(0x8A5A00, 0xD9B46A)
    /// The inset behind raw records and output.
    static let inset = dynamic(0xF3F3F5, 0x1B1C1E)
    static let hairline = Color.primary.opacity(0.10)

    static func icon(_ t: Tone) -> Color {
        switch t {
        case .ok: return dynamic(0x0A7A5C, 0x4FD6A8)
        case .attention: return dynamic(0x8A4B00, 0xFFC861)
        case .down: return dynamic(0xB3261E, 0xFF8A80)
        case .neutral: return dynamic(0x5E6066, 0xC9CBD1)
        }
    }

    /// The text of a changed caption or a count in this tone.
    static func text(_ t: Tone) -> Color {
        switch t {
        case .ok: return accentText
        case .attention: return dynamic(0x6E3C00, 0xFFD98A)
        case .down: return dynamic(0x8C1D18, 0xFFB4AB)
        case .neutral: return .secondary
        }
    }

    /// The circle of the hero and the fill of a pill.
    static func tint(_ t: Tone) -> Color {
        switch t {
        case .ok: return dynamic(0xDDF3EA, 0x4FD6A8, darkAlpha: 0.16)
        case .attention: return dynamic(0xFFE7B0, 0xFFC861, darkAlpha: 0.18)
        case .down: return dynamic(0xFCE9E7, 0xFF8A80, darkAlpha: 0.18)
        case .neutral: return dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.12)
        }
    }

    static func nodeFill(_ t: Tone) -> Color {
        switch t {
        case .ok: return dynamic(0xF1FAF6, 0x4FD6A8, darkAlpha: 0.10)
        case .attention: return dynamic(0xFFF6E0, 0xFFC861, darkAlpha: 0.10)
        case .down: return dynamic(0xFDF1F0, 0xFF8A80, darkAlpha: 0.10)
        case .neutral: return .clear
        }
    }

    static func nodeBorder(_ t: Tone) -> Color {
        switch t {
        case .ok: return dynamic(0x8CCBB5, 0x2F8E72)
        case .attention: return dynamic(0xC98A1A, 0xB98A2E)
        case .down: return dynamic(0xD9807A, 0xB5574F)
        case .neutral: return dynamic(0xC9CBD1, 0x6B6E76)
        }
    }
}

extension Glyph {
    /// The menu-bar glyph's colour.
    var color: Color {
        switch self {
        case .grey: return .gray
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        }
    }
}
