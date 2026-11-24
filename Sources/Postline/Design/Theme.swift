import SwiftUI
import AppKit

/// Postline's design language: Cued's tokens (the owner's own app — clean,
/// slightly cool greys on white, one signature blue, hierarchy from size and
/// weight rather than boxes) laid out the way the owner's two reference
/// screens are: a grey canvas, an icon rail, one white panel, a list card and
/// a reader card with hairline rings.
///
/// Corner radii are concentric everywhere one rounded box sits inside
/// another: inner radius = outer radius − the gap between them. The panel is
/// 24; the list and reader cards sit 12 inside it, so they are 12. Controls
/// (tabs, buttons, fields) are 8; the rail's 40-pt buttons are 10 and its
/// 36-pt logo tile 9, the same proportion.
enum Theme {

    // MARK: Ground
    static let canvas    = Color(light: 0xF3F3F4, dark: 0x161618)
    static let panel     = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let card      = Color(light: 0xFFFFFF, dark: 0x1F1F21)
    /// Soft fills: the selected tab, hovered rows, chips.
    static let fill      = Color(light: 0xF4F4F5, dark: 0x2A2A2D)
    static let fillHover = Color(light: 0xF7F7F8, dark: 0x252528)
    static let selected  = Color(light: 0xF2F2F4, dark: 0x2C2C30)

    // MARK: Ink
    static let ink    = Color(light: 0x18181B, dark: 0xF2F2F4)
    static let body   = Color(light: 0x52525B, dark: 0xB4B4BC)
    static let muted  = Color(light: 0x71717A, dark: 0xA1A1A8)
    static let muted2 = Color(light: 0xA1A1AA, dark: 0x6E6E75)

    // MARK: Lines
    static let line   = Color(light: 0xECECEE, dark: 0x2F2F33)
    static let ring   = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.075)

    // MARK: Colour
    /// Cued's signature blue: selection, focus, the primary action in dialogs.
    static let accent     = Color(light: 0x4B84F3, dark: 0x5B8EF5)
    static let accentTint = Color(light: 0xEDF3FE, dark: 0x1F2C45)
    /// The reference's verified tick.
    static let verified   = Color(hex: 0x3A9BF4)
    /// The near-black Compose button.
    static let primary      = Color(light: 0x232326, dark: 0xF2F2F4)
    static let primaryHover = Color(light: 0x34343A, dark: 0xFFFFFF)
    static let onPrimary    = Color(light: 0xFFFFFF, dark: 0x18181B)
    static let unreadDot  = Color(light: 0x4B84F3, dark: 0x5B8EF5)
    static let red        = Color(light: 0xD6504A, dark: 0xF06A63)
    static let green      = Color(light: 0x2E9E66, dark: 0x4CC38A)
    static let marker     = Color(light: 0xFFE680, dark: 0x6B5810)
    /// Blue text on the blue tint: 5.6:1 where the accent itself is 3.4:1.
    static let accentInk  = Color(light: 0x2B5FC7, dark: 0x8DB0FF)

    /// Cued's hue palette: avatars without a photo, and the bucket tiles.
    enum Hue: CaseIterable {
        case blue, violet, pink, orange, amber, green, teal, red, slate
        var fill: Color {
            switch self {
            case .blue: Color(hex: 0x5B8DEF); case .violet: Color(hex: 0x9B7BF0); case .pink: Color(hex: 0xE66BAA)
            case .orange: Color(hex: 0xF08A4B); case .amber: Color(hex: 0xE0A21A); case .green: Color(hex: 0x3FAF6C)
            case .teal: Color(hex: 0x2BA89A); case .red: Color(hex: 0xE86464); case .slate: Color(hex: 0x7C8799)
            }
        }
        var tint: Color {
            switch self {
            case .blue: Color(light: 0xE8F0FE, dark: 0x1E2A44); case .violet: Color(light: 0xF1EAFE, dark: 0x2A2242)
            case .pink: Color(light: 0xFCE8F3, dark: 0x3D1F31); case .orange: Color(light: 0xFFEDDF, dark: 0x3D2718)
            case .amber: Color(light: 0xFEF3D7, dark: 0x3A2E14); case .green: Color(light: 0xE2F5E8, dark: 0x183322)
            case .teal: Color(light: 0xDDF4F1, dark: 0x163532); case .red: Color(light: 0xFDE7E7, dark: 0x3D1D1D)
            case .slate: Color(light: 0xEDEFF3, dark: 0x262B33)
            }
        }
        var ink: Color {
            switch self {
            case .blue: Color(light: 0x1D4ED8, dark: 0x93C5FD); case .violet: Color(light: 0x6D28D9, dark: 0xC4B5FD)
            case .pink: Color(light: 0xBE185D, dark: 0xF9A8D4); case .orange: Color(light: 0xC2410C, dark: 0xFDBA74)
            case .amber: Color(light: 0xA16207, dark: 0xFCD34D); case .green: Color(light: 0x15803D, dark: 0x86EFAC)
            case .teal: Color(light: 0x0F766E, dark: 0x5EEAD4); case .red: Color(light: 0xB91C1C, dark: 0xFCA5A5)
            case .slate: Color(light: 0x475569, dark: 0xCBD5E1)
            }
        }
        /// A stable colour for an address, so a person keeps their colour.
        static func of(_ key: String) -> Hue {
            let sum = key.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return allCases[sum % allCases.count]
        }
    }

    // MARK: Geometry
    enum Radius {
        static let window: CGFloat = 32
        static let panel: CGFloat = 24
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let chip: CGFloat = 10
        static let tile: CGFloat = 9
    }

    enum Space {
        static let windowInset: CGFloat = 10
        /// The gap between the panel's edge and the cards — and so the panel
        /// radius minus the card radius.
        static let panelPad: CGFloat = 12
        static let rail: CGFloat = 72
        static let listWidth: CGFloat = 372
        static let row: CGFloat = 16
    }

    // MARK: Motion (Cued's house springs)
    enum Motion {
        static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
        static let quick  = Animation.spring(response: 0.20, dampingFraction: 0.86)
        static let fade   = Animation.easeOut(duration: 0.13)
    }
}

// MARK: - Typography

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// One scale. Anything else in the window is a bug.
    static let pageTitle   = ui(15, .medium)
    static let subjectTitle = ui(21, .semibold)
    static let senderName  = ui(14, .semibold)
    static let rowName     = ui(14, .semibold)
    static let body        = ui(14)
    static let bodyStrong  = ui(14, .medium)
    static let callout     = ui(13)
    static let calloutStrong = ui(13, .medium)
    static let caption     = ui(12)
    static let captionStrong = ui(12, .medium)
}

// MARK: - Colour helpers (from Cued)

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
