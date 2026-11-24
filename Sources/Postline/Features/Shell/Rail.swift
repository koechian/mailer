import SwiftUI

/// The left rail: the accounts (all together, or
/// one at a time — Spark keeps them in the same place), recent codes, and
/// Settings at the bottom.
struct Rail: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var showCodes = false

    var body: some View {
        VStack(spacing: 10) {
            // Room for the window's traffic lights.
            // No logo here: the rail starts with the Inbox (owner, 2026-11-25).
            Color.clear.frame(height: 30)

            // The Inbox icon is "every account's Inbox", wherever you were —
            // one click, not this and then the Inbox tab (owner, 2026-11-12).
            railItem(selected: model.accountFilter == nil, help: "Inbox — all accounts") {
                IconView(.inbox, size: 19)
            } action: { model.showInbox(account: nil) }

            ForEach(model.accounts) { account in
                railItem(selected: model.accountFilter == account.email, help: account.email) {
                    AvatarView(email: account.email, name: account.displayName, account: account.email,
                               picture: account.pictureURL, size: 26)
                } action: { model.showInbox(account: account.email) }
            }

            Spacer()

            railItem(selected: showCodes, help: "Recent codes") {
                IconView(.key, size: 19)
            } action: { showCodes.toggle() }
            .popover(isPresented: $showCodes, arrowEdge: .trailing) { CodesPopover(model: model) }

            railItem(selected: false, help: "Settings (⌘,)") {
                IconView(.settings, size: 19)
            } action: { openSettings() }
            .padding(.bottom, 14)
        }
        .frame(width: Theme.Space.rail)
    }

    private func railItem<Content: View>(selected: Bool, help: String, @ViewBuilder content: () -> Content,
                                         action: @escaping () -> Void) -> some View {
        RailButton(selected: selected, help: help, content: content(), action: action)
    }
}

private struct RailButton<Content: View>: View {
    let selected: Bool
    let help: String
    let content: Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(selected || hovering ? Theme.ink : Theme.muted)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Theme.panel : hovering ? Theme.fill : .clear)
                        .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 2, y: 1)
                )
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.ring : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The last few one-time codes, one click to copy.
struct CodesPopover: View {
    let model: AppModel
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent codes").font(.calloutStrong).foregroundStyle(Theme.ink).padding(.bottom, 6)
            if model.codes.isEmpty {
                Text("Codes from new mail appear here, and in a notification with a Copy button.")
                    .font(.callout).foregroundStyle(Theme.muted).frame(width: 240, alignment: .leading)
            }
            ForEach(model.codes) { code in
                Button {
                    Notifier.shared.copy(code.code)
                    copied = code.id
                } label: {
                    HStack(spacing: 10) {
                        Text(code.code).font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(code.sender).font(.captionStrong).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(code.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 12)
                        Text(copied == code.id ? "Copied" : "Copy").font(.captionStrong)
                            .foregroundStyle(copied == code.id ? Theme.green : Theme.accent)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.fill))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
