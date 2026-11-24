import SwiftUI

/// The list card: a title row (the mailbox, an open bucket with a way back,
/// or search results) and the rows.
struct MessageList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if model.items.isEmpty {
                EmptyList(model: model)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.items) { item in
                                row(item).id(item.id)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: model.selection) { _, id in
                        guard let id, let item = model.items.first(where: { if case .thread(let m, _, _) = $0 { return m.id == id }; return false }) else { return }
                        withAnimation(Theme.Motion.quick) { proxy.scrollTo(item.id) }
                    }
                }
            }
        }
        .card(radius: Theme.Radius.inPanel)
    }

    @ViewBuilder private var header: some View {
        if model.selecting { batchBar } else { titleBar }
    }

    /// The reference's checkbox beside the list title: click it to start
    /// selecting conversations.
    private var titleBar: some View {
        HStack(spacing: 10) {
            Checkbox(state: .off) { model.selecting = true }
                .help("Select conversations")
            if !model.searchText.isEmpty {
                Text("Results for “\(model.searchText)”").font(.bodyStrong).foregroundStyle(Theme.ink).lineLimit(1)
            } else {
                Text(model.mailbox.title).font(.bodyStrong).foregroundStyle(Theme.ink)
            }
            Spacer()
            Menu {
                Picker("Show", selection: $model.unreadOnly) {
                    Text("All mail").tag(false)
                    Text("Unread only").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                IconView(.filter, size: 17).foregroundStyle(model.unreadOnly ? Theme.accent : Theme.muted)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.unreadOnly ? "Showing unread only" : "Filter")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    /// Select mode: how many, then Mark read · Archive · Delete, and Done.
    private var batchBar: some View {
        let all = model.threadIDsInList.count
        let n = model.batch.count
        return HStack(spacing: 6) {
            Checkbox(state: n == 0 ? .off : n == all ? .on : .mixed) { model.selectAll() }
                .help(n == all ? "Deselect all (⌘A)" : "Select all (⌘A)")
                .padding(.trailing, 4)
            Text(n == 0 ? "Select" : "\(n) selected").font(.bodyStrong).foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            IconButton(icon: .mailOpen, help: "Mark as read", size: 17) { model.batchMarkRead() }.disabled(n == 0)
            IconButton(icon: .archive, help: "Archive (E)", size: 17) { model.batchArchive() }.disabled(n == 0)
            IconButton(icon: .trash, help: "Delete (#)", size: 17, tint: n == 0 ? Theme.muted : Theme.red) { model.batchTrash() }
                .disabled(n == 0)
            Button("Done") { model.selecting = false }
                .buttonStyle(.plain).font(.calloutStrong).foregroundStyle(Theme.accent)
                .keyboardShortcut(.escape, modifiers: [])
                .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .opacity(n == 0 ? 0.98 : 1)
    }

    @ViewBuilder
    private func row(_ item: ListItem) -> some View {
        switch item {
        case .section(let title):
            Text(title)
                .font(.captionStrong)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        case .thread(let m, let count, let unread):
            SwipeableRow(message: m, enabled: !model.selecting) {
                ThreadRow(message: m, count: count, unread: unread,
                          selected: !model.selecting && model.thread.first?.threadID == m.threadID && model.thread.first?.account == m.account,
                          checkbox: model.selecting ? (model.batch.contains(AppModel.key(m)) ? .on : .off) : nil)
            }
            .onTapGesture {
                // ⌘-click picks several; ⇧-click a range; in select mode a
                // plain click ticks the row.
                let flags = NSEvent.modifierFlags
                if model.selecting || flags.contains(.command) || flags.contains(.shift) {
                    model.toggleBatch(m, range: flags.contains(.shift))
                } else {
                    model.select(item)
                }
            }
            .contextMenu { contextMenu(for: m) }
        }
    }

    @ViewBuilder
    private func contextMenu(for m: Message) -> some View {
        Button("Open") { model.selection = m.id }
        Divider()
        Button("Reply") { model.selection = m.id; model.reply() }
        Button("Forward") { model.selection = m.id; model.forward() }
        Divider()
        Button(m.isUnread ? "Mark as read" : "Mark as unread") { model.selection = m.id; model.toggleUnread() }
        Button(m.isStarred ? "Unpin" : "Pin") { model.selection = m.id; model.togglePin() }
        Button("Archive") { model.swipeArchive(m) }
        Button("Move to Trash") { model.swipeTrash(m) }
        Divider()
        Button("Select") { model.toggleBatch(m) }
    }
}

// MARK: - Rows

/// One conversation, as the reference draws it: avatar, name with the
/// verified tick and the time, the address, then two lines of the mail.
struct ThreadRow: View {
    let message: Message
    let count: Int
    let unread: Bool
    let selected: Bool
    var checkbox: Checkbox.State? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let checkbox {
                Checkbox(state: checkbox) {}
                    .allowsHitTesting(false)
                    .frame(height: 36)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            AvatarView(email: avatarEmail, name: avatarName, account: message.account, size: 36)
                .overlay(alignment: .topLeading) {
                    if unread {
                        Circle().fill(Theme.unreadDot).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Theme.card, lineWidth: 1.5))
                            .offset(x: -2, y: -1)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(displayName)
                        .font(.ui(14, unread ? .semibold : .medium))
                        .foregroundStyle(unread ? Theme.ink : Theme.body)
                        .lineLimit(1)
                    if message.verified { VerifiedBadge(size: 13) }
                    if count > 1 {
                        Text("\(count)").font(.captionStrong).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 6)
                    Text(When.short(message.date))
                        .font(.caption)
                        .foregroundStyle(unread ? Theme.ink : Theme.muted)
                        .monospacedDigit()
                }
                Text(avatarEmail)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                (Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .foregroundStyle(unread ? Theme.ink : Theme.body)
                    .fontWeight(unread ? .medium : .regular)
                 + Text("  ") + Text(message.snippet).foregroundStyle(Theme.muted))
                    .font(.callout)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .padding(.top, 5)
                // Attachments as files, the way the reader shows them, so a
                // row says what's attached without opening it (owner,
                // 2026-11-25). Two fit the row; the rest are counted.
                if !files.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(files.prefix(2), id: \.partID) { RowFile(attachment: $0) }
                        if files.count > 2 {
                            Text("+\(files.count - 2)").font(.captionStrong).foregroundStyle(Theme.muted)
                                .fixedSize()
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, Theme.Space.row)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected || checkbox == .on ? Theme.selected : hovering ? Theme.fillHover : Theme.card)
        .overlay(alignment: .bottom) { Hairline().padding(.leading, Theme.Space.row + 48) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var files: [Attachment] {
        message.attachments.filter { !$0.filename.isEmpty && !$0.mimeType.hasPrefix("text/calendar") }
    }

    /// In Sent, the row is about who it went to.
    private var isSent: Bool { message.labels.contains("SENT") && !message.labels.contains("INBOX") }
    private var avatarEmail: String {
        isSent ? MessageParser.splitAddress(message.to.first ?? "").1.lowercased() : message.fromEmail
    }
    private var avatarName: String {
        isSent ? MessageParser.splitAddress(message.to.first ?? "").0 : message.fromName
    }
    private var displayName: String {
        if isSent {
            let (name, email) = MessageParser.splitAddress(message.to.first ?? "")
            return "To: " + (name.isEmpty ? email : name)
        }
        return message.senderLabel
    }
}

/// One attached file in an inbox row: the type badge and the name. Selecting
/// the row shows it in full; the row itself isn't a place to open files.
private struct RowFile: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 6) {
            // 4 pt badge in an 8 pt pill with 4 pt padding: concentric.
            FileBadge(filename: attachment.filename, size: 18, radius: 4)
            Text(attachment.filename)
                .font(.caption)
                .foregroundStyle(Theme.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 96, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.fillHover))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Left-to-right wrapping, cut after `maxLines` so a bucket row keeps its height.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var maxLines: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 300, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: proposal.width ?? 300, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        var placed = Set<Int>()
        for row in rows {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
                placed.insert(i)
            }
            y += row.height + lineSpacing
        }
        // Anything past the last line is parked out of sight at zero size.
        for i in subviews.indices where !placed.contains(i) {
            subviews[i].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], height: CGFloat)] {
        var rows: [(indices: [Int], height: CGFloat)] = []
        var current: [Int] = []
        var x: CGFloat = 0
        var h: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append((current, h))
                if rows.count == maxLines { return rows }
                current = []; x = 0; h = 0
            }
            current.append(i)
            x += size.width + spacing
            h = max(h, size.height)
        }
        if !current.isEmpty, rows.count < maxLines { rows.append((current, h)) }
        return rows
    }
}

// MARK: - Empty

struct EmptyList: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            IconView(model.searchText.isEmpty ? model.mailbox.icon : .search, size: 28).foregroundStyle(Theme.muted2)
            Text(title).font(.bodyStrong).foregroundStyle(Theme.ink)
            Text(detail).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var title: String {
        if !model.searchText.isEmpty { return "Nothing found" }
        if model.mailbox == .inbox { return model.accounts.isEmpty && !model.isDemo ? "No accounts yet" : "All caught up" }
        return "Nothing in \(model.mailbox.title)"
    }

    private var detail: String {
        if !model.searchText.isEmpty { return "Search looks through mail saved on this Mac. Import older mail from Settings to search further back." }
        if model.mailbox == .inbox { return "New mail appears here the moment Gmail receives it." }
        return "Mail here shows up as it arrives or when you import older mail."
    }
}
