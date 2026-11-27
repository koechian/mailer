import SwiftUI

/// The reader card: the conversation's actions along the top, then each
/// message — earlier ones folded to a line, the newest open — as in the
/// reference's second screen.
struct ReaderView: View {
    @Bindable var model: AppModel
    @State private var expanded: Set<String> = []

    var body: some View {
        if let last = model.thread.last {
            VStack(spacing: 0) {
                ActionBar(model: model, message: last)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(last.subject.isEmpty ? "(no subject)" : last.subject)
                            .font(.subjectTitle)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 28)
                            .padding(.top, 24)
                            .padding(.bottom, 8)
                        ForEach(model.thread) { m in
                            if m.id == last.id || expanded.contains(m.id) {
                                MessageBlock(model: model, message: m, isLast: m.id == last.id)
                            } else {
                                CollapsedMessage(message: m) { expanded.insert(m.id) }
                            }
                        }
                        if let target = model.replyTarget(in: model.thread), Preferences.shared.suggestReplies {
                            SuggestedReplies(model: model, message: target)
                                .padding(.horizontal, 28)
                                .padding(.top, 20)
                        }
                        ReplyBar(model: model)
                            .padding(.horizontal, 28)
                            .padding(.top, 14)
                            .padding(.bottom, 28)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onChange(of: last.threadID) { _, _ in expanded = [] }
        } else {
            EmptyReader(model: model)
        }
    }
}

// MARK: - Actions

struct ActionBar: View {
    let model: AppModel
    let message: Message

    var body: some View {
        HStack(spacing: 6) {
            if message.isInInbox {
                IconButton(icon: .archive, help: "Archive (E)", bordered: true) { model.archive() }
            } else {
                IconButton(icon: .inbox, help: "Move to Inbox", bordered: true) { model.moveToInbox() }
            }
            IconButton(icon: .trash, help: "Move to Trash (#)", bordered: true) { model.trash() }
            IconButton(icon: .markUnread, help: model.thread.contains(where: \.isUnread) ? "Mark as read (U)" : "Mark as unread (U)", bordered: true) { model.toggleUnread() }
            IconButton(icon: .pin, help: model.thread.contains(where: \.isFlagged) ? "Unpin (S)" : "Pin (S)",
                       tint: model.thread.contains(where: \.isFlagged) ? Theme.Hue.amber.fill : Theme.muted, bordered: true) { model.togglePin() }
            Menu {
                Button("Mark as spam") { model.markSpam() }
                if let unsubscribe = unsubscribeURL {
                    Button("Unsubscribe") { NSWorkspace.shared.open(unsubscribe) }
                }
                Button("Open in Gmail") {
                    if let url = URL(string: "https://mail.google.com/mail/u/?authuser=\(message.account)#all/\(message.threadID)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Copy sender's address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.fromEmail, forType: .string)
                }
            } label: {
                IconView(.more, size: 18).foregroundStyle(Theme.muted)
                    .frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.line))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More")

            Spacer()
            IconButton(icon: .reply, help: "Reply (R)") { model.reply() }
            IconButton(icon: .forward, help: "Forward (F)") { model.forward() }
        }
        // The first button's edge lines up with the subject and body below.
        .padding(.horizontal, 28)
        .frame(height: 58)
    }

    /// A web unsubscribe link from the List-Unsubscribe header.
    private var unsubscribeURL: URL? {
        guard let raw = message.listUnsubscribe else { return nil }
        let links = raw.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) }
        return links.first { $0.hasPrefix("http") }.flatMap(URL.init(string:))
    }
}

// MARK: - A message

struct MessageBlock: View {
    let model: AppModel
    let message: Message
    let isLast: Bool
    @State private var htmlHeight: CGFloat = 80
    @State private var showDetails = false
    /// Remote images loaded for this email only, while they are off in Settings.
    @State private var remoteContentOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
            if !files.isEmpty { attachments }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) { if !isLast { Hairline().padding(.horizontal, 28) } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(email: message.fromEmail, name: message.fromName, account: message.account, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.senderLabel).font(.ui(15, .semibold)).foregroundStyle(Theme.ink)
                    if message.verified { VerifiedBadge(size: 15) }
                }
                HStack(spacing: 4) {
                    Text("From:").foregroundStyle(Theme.muted)
                    Text(message.fromEmail).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                .font(.callout)
                Button { showDetails.toggle() } label: {
                    HStack(spacing: 3) {
                        Text("To: " + recipients).lineLimit(1)
                        IconView(.chevronDown, size: 11).rotationEffect(.degrees(showDetails ? 180 : 0))
                    }
                    .font(.caption).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                if showDetails {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(message.to + message.cc, id: \.self) { Text($0) }
                        Text("Account: \(message.account)")
                    }
                    .font(.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            Text(When.long(message.date)).font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var recipients: String {
        let names = (message.to + message.cc).map { raw -> String in
            let (name, email) = MessageParser.splitAddress(raw)
            if model.accounts.contains(where: { $0.email == email.lowercased() || $0.sendAs.contains { $0.email == email.lowercased() } }) { return "me" }
            return name.isEmpty ? email : name
        }
        return names.isEmpty ? "me" : names.joined(separator: ", ")
    }

    @Environment(\.colorScheme) private var scheme

    @ViewBuilder private var content: some View {
        if let html = message.bodyHTML, !html.isEmpty {
            // Mail is designed on white. In light mode it sits straight on the
            // card; in dark mode it gets a rounded sheet of paper with room
            // around it rather than a hard white block.
            let paper = scheme == .dark
            let allowsRemote = remoteContentOnce || Preferences.shared.loadRemoteImages
            if !allowsRemote, HTMLView.referencesRemoteContent(html) {
                RemoteContentBar { remoteContentOnce = true }
            }
            HTMLView(html: html, allowsRemoteContent: allowsRemote, height: $htmlHeight)
                .frame(height: htmlHeight)
                .frame(maxWidth: .infinity)
                .padding(paper ? 20 : 0)
                .background(paper ? Color.white : .clear)
                .clipShape(RoundedRectangle(cornerRadius: paper ? Theme.Radius.card : 0, style: .continuous))
        } else {
            Text(message.bodyText.isEmpty ? message.snippet : message.bodyText)
                .font(.body)
                .foregroundStyle(Theme.body)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var files: [Attachment] {
        message.attachments.filter { !$0.filename.isEmpty && !$0.mimeType.hasPrefix("text/calendar") }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attachments").font(.calloutStrong).foregroundStyle(Theme.ink)
            FlowLayout(spacing: 8, lineSpacing: 8, maxLines: 10) {
                ForEach(files, id: \.partID) { a in
                    AttachmentChip(attachment: a) { model.openAttachment(a, of: message) }
                }
            }
        }
    }
}

/// Shown above an email whose remote images are blocked (remote images are
/// off in Settings), with a button to load them for this email.
struct RemoteContentBar: View {
    let loadImages: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconView(.shield, size: 15).foregroundStyle(Theme.muted)
            Text("Remote images are blocked.")
                .font(.caption).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Button("Load images", action: loadImages)
                .buttonStyle(QuietButtonStyle(height: 28, fullWidth: false))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card(radius: Theme.Radius.control)
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                FileBadge(filename: attachment.filename, size: 30, radius: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename).font(.calloutStrong).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: 150, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(hovering ? Theme.fill : Theme.fillHover))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(attachment.filename)")
    }

}

/// The coloured file-type square: "PDF" on red, "XLSX" on green… Shared by the
/// reader's attachment chips and the files shown in inbox rows.
struct FileBadge: View {
    let filename: String
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(hue.tint)
            .frame(width: size, height: size)
            .overlay(Text(ext).font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(hue.ink)
                .minimumScaleFactor(0.7).lineLimit(1).padding(.horizontal, 1))
    }

    private var ext: String {
        let e = (filename as NSString).pathExtension.uppercased()
        return e.isEmpty ? "FILE" : String(e.prefix(4))
    }

    private var hue: Theme.Hue {
        switch ext {
        case "PDF": .red
        case "DOC", "DOCX", "PAGE": .blue
        case "XLS", "XLSX", "CSV", "NUMB": .green
        case "PPT", "PPTX", "KEY": .orange
        case "PNG", "JPG", "JPEG", "GIF", "HEIC", "WEBP", "SVG": .violet
        case "ZIP", "RAR", "7Z": .amber
        default: .slate
        }
    }
}

struct CollapsedMessage: View {
    let message: Message
    let expand: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 12) {
                AvatarView(email: message.fromEmail, name: message.fromName, account: message.account, size: 28)
                Text(message.senderLabel).font(.calloutStrong).foregroundStyle(Theme.ink).lineLimit(1)
                Text(message.snippet).font(.callout).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                Text(When.short(message.date)).font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 28)
            .frame(height: 52)
            .background(hovering ? Theme.fillHover : .clear)
            .overlay(alignment: .bottom) { Hairline().padding(.horizontal, 28) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Earlier message from \(message.senderLabel). Show.")
    }
}

/// Reply / Reply all / Forward under the conversation, Notion Mail style.
struct ReplyBar: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Button { model.reply() } label: { Label { Text("Reply") } icon: { IconView(.reply, size: 15) } }
                .buttonStyle(QuietButtonStyle(height: 34, fullWidth: false))
            if (model.thread.last?.to.count ?? 0) + (model.thread.last?.cc.count ?? 0) > 1 {
                Button { model.reply(all: true) } label: { Label { Text("Reply all") } icon: { IconView(.reply, size: 15) } }
                    .buttonStyle(QuietButtonStyle(height: 34, fullWidth: false))
            }
            Button { model.forward() } label: { Label { Text("Forward") } icon: { IconView(.forward, size: 15) } }
                .buttonStyle(QuietButtonStyle(height: 34, fullWidth: false))
        }
    }
}

struct EmptyReader: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.fill)
                .frame(width: 64, height: 64)
                .overlay(IconView(.mailOpen, size: 30).foregroundStyle(Theme.muted2))
            Text("Select a conversation").font(.bodyStrong).foregroundStyle(Theme.ink)
            VStack(spacing: 6) {
                shortcut("J  K", "Next and previous")
                shortcut("E", "Archive")
                shortcut("R", "Reply")
                shortcut("C", "Compose")
                shortcut("/", "Search")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(keys).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.body)
                .padding(.horizontal, 6).frame(minWidth: 44, minHeight: 22)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
            Text(label).font(.callout).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading)
        }
    }
}


/// Gmail-style quick replies under the newest message: three faint chips in
/// a plain human voice, written on this Mac. Click one to start a reply with
/// it, then edit as you like.
struct SuggestedReplies: View {
    let model: AppModel
    let message: Message

    var body: some View {
        let replies = model.suggestions[message.id] ?? []
        HStack(spacing: 8) {
            if replies.isEmpty && model.isSuggesting(message.id) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Theme.fill)
                        .frame(width: [132, 104, 150][i], height: 34)
                        .opacity(0.7)
                }
                .transition(.opacity)
            }
            ForEach(replies, id: \.self) { reply in
                SuggestionChip(text: reply) { model.reply(prefill: reply) }
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(Theme.Motion.fade, value: replies)
        .task(id: message.id) { model.loadSuggestions(for: message) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested replies")
    }
}

struct SuggestionChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(hovering ? Theme.fill : Theme.card))
                .overlay(Capsule().strokeBorder(Theme.line))
                // Low opacity until you reach for it, as in Gmail.
                .opacity(hovering ? 1 : 0.62)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
        .help("Reply with this — you can edit it first")
    }
}
