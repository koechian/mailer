import SwiftUI
import UniformTypeIdentifiers

/// Writing a message, in the reader card's place (Notion Mail does the same):
/// From (any account or "Send mail as" address), To, Cc, Subject, the text,
/// and Send — which waits five seconds so Undo can take it back.
struct ComposeView: View {
    let model: AppModel
    @State var draft: Draft
    @State private var showCc = false
    @FocusState private var focus: Field?

    enum Field { case to, cc, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.bodyStrong).foregroundStyle(Theme.ink)
                Spacer()
                IconButton(icon: .close, help: "Discard (Esc)") { model.composing = nil }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            Hairline()

            fromRow
            Hairline().padding(.leading, 20)
            field("To", text: $draft.to, focus: .to) {
                if !showCc {
                    Button("Cc") { showCc = true; focus = .cc }
                        .buttonStyle(.plain).font(.calloutStrong).foregroundStyle(Theme.muted)
                }
            }
            if showCc {
                Hairline().padding(.leading, 20)
                field("Cc", text: $draft.cc, focus: .cc) { EmptyView() }
            }
            Hairline().padding(.leading, 20)
            field("Subject", text: $draft.subject, focus: .subject) { EmptyView() }
            Hairline()

            SmartEditor(text: $draft.body,
                        replyingTo: draft.inReplyTo == nil ? nil : model.thread.last.map { Writer.newestPart(of: $0.bodyText) },
                        focusOnAppear: !draft.to.isEmpty)

            if !draft.attachments.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8, maxLines: 4) {
                    ForEach(draft.attachments, id: \.self) { url in
                        HStack(spacing: 6) {
                            IconView(.attachment, size: 13).foregroundStyle(Theme.muted)
                            Text(url.lastPathComponent).font(.callout).foregroundStyle(Theme.ink).lineLimit(1)
                            Button { draft.attachments.removeAll { $0 == url } } label: {
                                IconView(.close, size: 12).foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain).help("Remove")
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.fill))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                Button {
                    model.send(draft)
                } label: {
                    HStack(spacing: 7) { IconView(.sent, size: 15); Text("Send") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!draft.isSendable)
                .keyboardShortcut(.return, modifiers: .command)
                // Never a keyboard-focus target: the space bar must not be
                // able to send (it did once, 2026-11-12). ⌘↩ or a click only.
                .focusable(false)
                .help("Send (⌘↩)")
                IconButton(icon: .attachment, help: "Attach files") { attach() }
                Spacer()
                Text("⌘↩ to send").font(.caption).foregroundStyle(Theme.muted2)
            }
            // Send starts on the same line as the field labels above it.
            .padding(.horizontal, 20)
            .frame(height: 60)
        }
        .onAppear {
            showCc = !draft.cc.isEmpty
            if draft.to.isEmpty { focus = .to }
            Task { await Writer.shared.warmUp() }
        }
        .onChange(of: draft) { _, d in model.composing = d }
    }

    private var title: String {
        if draft.inReplyTo != nil { return "Reply" }
        if draft.subject.hasPrefix("Fwd:") { return "Forward" }
        return "New email"
    }

    private var fromRow: some View {
        HStack(spacing: 10) {
            Text("From").font(.callout).foregroundStyle(Theme.muted).frame(width: 56, alignment: .leading)
            Menu {
                ForEach(model.senders, id: \.from.email) { sender in
                    Button {
                        draft.account = sender.account
                        draft.from = sender.from
                    } label: {
                        Text(sender.from.name.isEmpty ? sender.from.email : "\(sender.from.name) <\(sender.from.email)>")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    AvatarView(email: draft.from.email, name: draft.from.name, account: draft.account, size: 20)
                    Text(draft.from.name.isEmpty ? draft.from.email : "\(draft.from.name)  \(draft.from.email)")
                        .font(.callout).foregroundStyle(Theme.ink)
                    IconView(.chevronDown, size: 12).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
    }

    private func field<Trailing: View>(_ label: String, text: Binding<String>, focus f: Field, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).foregroundStyle(Theme.muted).frame(width: 56, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .focused($focus, equals: f)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { draft.attachments += panel.urls }
    }
}
