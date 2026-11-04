import AppKit

/// Every color, font, radius and timing the panel uses. Nothing in the UI code
/// picks a raw value, so the rules below hold by construction:
///
/// - One accent ("signal orange"), used for the selection bar, the caret,
///   matched letters and evidence highlights. Never for status or decoration.
/// - Text contrast (WCAG): ink 14.7:1 / 16.6:1, ink2 >= 5.5:1, ink3 >= 4.6:1
///   even on a selected row, accentText >= 4.7:1 (dark / light).
/// - Radii nest: panel 14 > content box 10 > row and tab 7 > keycap 4,
///   so an inner corner always sits concentric with its container.
/// - Motion (Corporate personality): 120 ms feedback, 180 ms enter, 110 ms exit,
///   one decelerating curve for everything that lands.
enum Theme {
    private static func dynamic(_ dark: NSColor, _ light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }

    static let surface = dynamic(hex(0x1F1F23, 0.94), hex(0xF6F6F7, 0.95))
    static let raise = dynamic(hex(0x2A2A2F), hex(0xFCFCFD))
    static let line = dynamic(NSColor(white: 1, alpha: 0.08), NSColor(white: 0, alpha: 0.09))
    static let ink = dynamic(hex(0xF2F2F4), hex(0x17171A))
    static let ink2 = dynamic(hex(0xF2F2F4, 0.66), hex(0x17171A, 0.76))
    static let ink3 = dynamic(hex(0xF2F2F4, 0.56), hex(0x17171A, 0.66))
    static let accent = dynamic(hex(0xFF6A3D), hex(0xE5532A))
    static let accentText = dynamic(hex(0xFF8A63), hex(0xB33A0C))
    static let selection = dynamic(hex(0xFF6A3D, 0.12), hex(0xE5532A, 0.10))
    static let hit = dynamic(hex(0xFF6A3D, 0.34), hex(0xE5532A, 0.28))
    static let keycap = dynamic(NSColor(white: 1, alpha: 0.08), NSColor(white: 0, alpha: 0.06))
    static let meterOff = dynamic(NSColor(white: 1, alpha: 0.16), NSColor(white: 0, alpha: 0.16))

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    enum Radius { static let panel: CGFloat = 14, box: CGFloat = 10, row: CGFloat = 7, cap: CGFloat = 4 }

    enum Motion {
        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        static var feedback: TimeInterval { reduced ? 0 : 0.12 }
        static var enter: TimeInterval { reduced ? 0 : 0.18 }
        static var exit: TimeInterval { reduced ? 0 : 0.11 }
        static let land = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)    // decelerate
        static let leave = CAMediaTimingFunction(controlPoints: 0.3, 0, 1, 1)   // accelerate
    }
}
