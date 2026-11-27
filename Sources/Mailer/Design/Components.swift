import SwiftUI

// MARK: - Avatar

/// A round photo or logo, or initials on the address's own colour.
struct AvatarView: View {
    let email: String
    let name: String
    var account: String? = nil
    var picture: URL? = nil
    var size: CGFloat = 36

    var body: some View {
        let image = Avatars.shared.image(for: email, account: account, picture: picture)
        ZStack {
            if let image {
                // Logos are often transparent squares: give them a white bed
                // and a little room so they read as a badge, not a crop.
                Circle().fill(.white)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: isLogo ? .fit : .fill)
                    .frame(width: isLogo ? size * 0.64 : size, height: isLogo ? size * 0.64 : size)
                    .clipShape(Circle())
            } else {
                let hue = Theme.Hue.of(email)
                Circle().fill(hue.fill)
                Text(Self.initials(name.isEmpty ? email : name))
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Theme.ring, lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// A company sender whose avatar is its domain logo, not a face.
    private var isLogo: Bool { Avatars.shared.isLogo(email) }

    static func initials(_ s: String) -> String {
        let words = s.replacingOccurrences(of: "\"", with: "").split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.joined().isEmpty ? "?" : letters.joined()
    }
}

// MARK: - Verified tick

struct VerifiedBadge: View {
    var size: CGFloat = 15
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size))
            .foregroundStyle(.white, Theme.verified)
            .help("Verified sender: Gmail confirmed this mail really comes from this domain (DMARC).")
            .accessibilityLabel("Verified sender")
    }
}

// MARK: - Buttons

/// The near-black Compose button from the reference.
struct PrimaryButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.calloutStrong)
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? Theme.primaryHover : Theme.primary))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Theme.Motion.quick, value: configuration.isPressed)
            .animation(Theme.Motion.fade, value: hovering)
    }
}

/// Blue filled button for dialogs and onboarding (Cued's primary).
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.calloutStrong)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(enabled ? (configuration.isPressed ? Theme.accent.opacity(0.85) : hovering ? Theme.accent.opacity(0.92) : Theme.accent) : Theme.accent.opacity(0.4)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A quiet bordered button: secondary actions in dialogs and onboarding.
struct QuietButtonStyle: ButtonStyle {
    @State private var hovering = false
    var height: CGFloat = 36
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.calloutStrong)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(configuration.isPressed ? Theme.selected : hovering ? Theme.fillHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// An icon-only button with a hover bed and a tooltip that names it.
struct IconButton: View {
    let icon: Icon
    let help: String
    var size: CGFloat = 18
    var tint: Color = Theme.muted
    var bordered = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            IconView(icon, size: size)
                .foregroundStyle(hovering ? Theme.ink : tint)
                .frame(width: bordered ? 34 : 30, height: bordered ? 34 : 30)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(hovering ? Theme.fill : .clear))
                .overlay {
                    if bordered {
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.line)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(Theme.Motion.fade, value: hovering)
    }
}

// MARK: - Card

extension View {
    /// The reference's card: white, a hairline ring, a concentric radius.
    func card(radius: CGFloat = Theme.Radius.card) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? 20 : 1)
    }
}

// MARK: - Dates

enum When {
    /// "05:16" today, "Yesterday", "June 29" this year, "29 Jun 2025" before.
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return d.formatted(.dateTime.month(.wide).day()) }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func section(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return d.formatted(.dateTime.month(.wide)) }
        return d.formatted(.dateTime.month(.wide).year())
    }

    static func long(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Checkbox

/// The reference's square checkbox: an 18-pt rounded square, blue when on.
struct Checkbox: View {
    enum State: Equatable { case off, on, mixed }
    let state: State
    let action: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            // 6, not the +4 everything else got: at 9 this 18 pt box turned
            // into a circle and read as a radio button (2026-11-25).
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(state == .off ? (hovering ? Theme.fill : Theme.card) : Theme.accent)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(state == .off ? Theme.muted2 : .clear, lineWidth: 1.5))
                .overlay {
                    switch state {
                    case .on: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    case .mixed: Capsule().fill(.white).frame(width: 8, height: 2)
                    case .off: EmptyView()
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(state == .on ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }
}
