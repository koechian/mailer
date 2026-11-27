import SwiftUI

/// The window, laid out as the owner's reference: a grey canvas with an icon
/// rail on the left, and one white panel holding a header, the mailbox tabs,
/// the message list card and the reader card.
struct MainView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Rail(model: model)
            panel
                .padding(.vertical, Theme.Space.windowInset)
                .padding(.trailing, Theme.Space.windowInset)
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { ToastView(model: model) }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            Hairline()
            MailboxBar(model: model)
            Hairline()
            HStack(alignment: .top, spacing: Theme.Space.panelPad) {
                MessageList(model: model)
                    .frame(width: Theme.Space.listWidth)
                Group {
                    if let draft = model.composing {
                        ComposeView(model: model, draft: draft)
                            .id(draft.id)
                    } else {
                        ReaderView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card(radius: Theme.Radius.inPanel)
            }
            .padding(.horizontal, Theme.Space.panelPad)
            .padding(.bottom, Theme.Space.panelPad)
            .padding(.top, Theme.Space.panelPad)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.ring).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

// MARK: - Header

/// "Inbox · 1,204 emails", search, and how fresh the mail is.
struct HeaderBar: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconView(model.mailbox.icon, size: 18).foregroundStyle(Theme.ink)
            Text(title).font(.pageTitle).foregroundStyle(Theme.ink)
            Circle().fill(Theme.muted2).frame(width: 4, height: 4)
            Text("\(model.totalInMailbox.formatted()) emails").font(.ui(15)).foregroundStyle(Theme.muted)
                .contentTransition(.numericText())
            Spacer(minLength: 16)
            importStatus
            searchField
        }
        .padding(.leading, Theme.Space.panelPad + 14)
        .padding(.trailing, 16)
        .frame(height: 58)
    }

    private var title: String {
        let base = model.mailbox.title
        if let account = model.accountFilter { return "\(base) · \(account)" }
        return base
    }

    @ViewBuilder private var importStatus: some View {
        if let (email, p) = model.importProgress.first {
            HStack(spacing: 6) {
                ProgressView(value: p.total == 0 ? 0 : Double(p.done) / Double(p.total))
                    .progressViewStyle(.linear).frame(width: 70).tint(Theme.accent)
                Text(p.total == 0 ? "Finding older mail…" : "Importing \(p.done)/\(p.total)")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .help("Importing older mail for \(email). New mail keeps arriving meanwhile.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            IconView(.search, size: 15).foregroundStyle(Theme.muted)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { IconView(.close, size: 13).foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain).help("Clear search")
            } else {
                Text("⌘F").font(.caption).foregroundStyle(Theme.muted2)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 230, height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
        .onReceive(NotificationCenter.default.publisher(for: .mailerFocusSearch)) { _ in searchFocused = true }
        // With the rail's logo gone the search field was the first thing
        // that could take focus, so the window opened typing into it and
        // J/K/E did nothing until a click (measured 2026-11-25). Start with
        // nothing focused; ⌘F and / still go to search.
        .task { try? await Task.sleep(for: .milliseconds(50)); searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

// MARK: - Mailbox tabs

/// Compose, then the mailboxes as tabs — the reference's second row.
struct MailboxBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Button { model.compose() } label: {
                HStack(spacing: 7) {
                    IconView(.compose, size: 16)
                    Text("Compose")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("n", modifiers: .command)
            .help("New email (⌘N or C)")
            .disabled(model.accounts.isEmpty && !model.isDemo)

            Hairline(vertical: true).padding(.horizontal, 10)

            ForEach([Mailbox.inbox, .other, .pinned, .sent, .drafts, .archive], id: \.self) { tab($0) }
            Hairline(vertical: true).padding(.horizontal, 10)
            ForEach([Mailbox.trash, .spam], id: \.self) { tab($0) }
            Spacer(minLength: 0)
        }
        // Compose's edge lines up with the list card below it.
        .padding(.horizontal, Theme.Space.panelPad)
        .frame(height: 56)
    }

    private func tab(_ box: Mailbox) -> some View {
        MailboxTab(box: box, selected: model.mailbox == box && model.searchText.isEmpty,
                   count: model.counts[box] ?? 0) {
            model.searchText = ""
            if model.mailbox != box { model.mailbox = box }
        }
    }
}

struct MailboxTab: View {
    let box: Mailbox
    let selected: Bool
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                IconView(box.icon, size: 16)
                Text(box.title).font(selected ? .calloutStrong : .callout)
                if count > 0 {
                    Text(count.formatted()).font(.captionStrong)
                        .foregroundStyle(selected ? Theme.ink : Theme.muted)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(selected || hovering ? Theme.ink : Theme.muted)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(selected ? Theme.fill : hovering ? Theme.fillHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(Theme.Motion.fade, value: hovering)
    }
}

// MARK: - Toast

struct ToastView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 14) {
                    Text(toast.text).font(.calloutStrong).foregroundStyle(Theme.onPrimary)
                    if let undo = toast.undo {
                        Button("Undo") { undo(); model.toast = nil }
                            .buttonStyle(.plain).font(.calloutStrong).foregroundStyle(Theme.onPrimary.opacity(0.7))
                            .keyboardShortcut("z", modifiers: .command)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Capsule().fill(Theme.primary))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if model.toast?.id == toast.id { model.toast = nil }
                }
            }
        }
        .padding(.bottom, 28)
        .animation(Theme.Motion.spring, value: model.toast)
    }
}

extension Notification.Name {
    static let mailerFocusSearch = Notification.Name("mailer.focusSearch")
}
