import AppKit
import Observation
import SwiftUI

/// One row of the message list.
enum ListItem: Identifiable, Equatable {
    case section(String)
    /// A conversation: its newest message here, how many it holds, whether
    /// any of it is unread.
    case thread(Message, count: Int, unread: Bool)

    var id: String {
        switch self {
        case .section(let s): "s:\(s)"
        case .thread(let m, _, _): "t:\(m.account):\(m.threadID)"
        }
    }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var undo: (() -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@MainActor
@Observable
final class AppModel {

    static let shared = AppModel()

    let store = Store.shared
    let isDemo = ProcessInfo.processInfo.environment["POSTLINE_DEMO"] == "1"

    // MARK: State

    var accounts: [Account] = []
    /// nil = every account together.
    var accountFilter: String? { didSet { reload() } }
    var mailbox: Mailbox = .inbox { didSet { selecting = false; reload() } }
    /// A bucket opened from the Inbox ("Notifications"), or the Pinned stack.
    var searchText = "" { didSet { reload() } }
    var unreadOnly = false { didSet { reload() } }
    var searching = false

    private(set) var items: [ListItem] = []
    private(set) var counts: [Mailbox: Int] = [:]
    private(set) var totalInMailbox = 0
    var selection: String? { didSet { loadThread() } }
    private(set) var thread: [Message] = []
    var composing: Draft?
    var toast: Toast?
    var lastSync: Date?
    var importProgress: [String: SyncEngine.ImportProgress] = [:]
    var codes: [FoundCode] = []
    var error: String?
    var addingAccount = false
    /// Accounts with no Google sign-in (revoked, expired, or issued to
    /// another Google project). Settings offers to sign them in again.
    private(set) var signedOut: Set<String> = []
    /// The menu bar icon: shown for five minutes after new Primary mail or a
    /// code arrives, then gone. See `MenuIconClock`.
    private(set) var menuIcon = MenuIconClock()
    var menuIconVisible: Bool { menuIcon.visible }
    /// The new Primary mail the menu lists while the icon is up, newest first.
    private(set) var recentMail: [Message] = []
    private var menuIconTimer: Task<Void, Never>?
    /// Set by the window when it first appears; reopens it after a close.
    var openMainWindow: (() -> Void)?


    private var pendingSends: [UUID: Task<Void, Never>] = [:]
    private var reloadScheduled = false

    // MARK: Start

    func start() {
        if isDemo { DemoData.seedIfEmpty(store) }
        accounts = store.accounts()
        codes = store.recentCodes()
        reload()
        // Demo only: a shorter icon window, so the timing can be watched.
        if isDemo, let s = ProcessInfo.processInfo.environment["POSTLINE_MENU_ICON_SECONDS"].flatMap(Double.init) {
            menuIcon.length = s
        }
        Notifier.shared.setUp()
        Notifier.shared.open = { [weak self] account, id in self?.open(account: account, messageID: id) }
        Notifier.shared.foundCode = { [weak self] code in
            self?.codes.insert(code, at: 0)
            self?.codes = Array((self?.codes ?? []).prefix(5))
            self?.showCodeIcon()
        }
        Notifier.shared.newMail = { [weak self] messages in self?.showMailIcon(messages) }
        // Once the code is copied — from the notification or the menu — the
        // code's part is done. New mail, if any, keeps the icon up.
        Notifier.shared.copied = { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.codeCopied()
            }
        }
        guard !isDemo else {
            lastSync = Date()
            simulateArrivalIfAsked()
            return
        }
        Task {
            await SyncEngine.shared.setHandlers(
                onNewMail: { messages in
                    await MainActor.run {
                        let accounts = AppModel.shared.accounts
                        Notifier.shared.handle(messages, accounts: accounts)
                    }
                },
                onStoreChanged: {
                    await MainActor.run { AppModel.shared.scheduleReload() }
                })
            await SyncEngine.shared.startLive(for: accounts.map(\.email))
            await SyncEngine.shared.syncAll()
            await SyncEngine.shared.reconcileAll()
            lastSync = Date()
        }
        // Ask Gmail what changed every 5 seconds, beside the IMAP IDLE ping.
        // Measured on 2026-11-12: Gmail's IDLE ping came 7–47 s after a
        // message landed, and sometimes not at all, while a history check saw
        // it within the 5 s window. One history call per account costs 2 of
        // Gmail's 250 quota units a second, so this stays far inside the free
        // limits; it also catches changes outside the Inbox (sent from the
        // phone, archived on the web).
        Task {
            var tick = 0
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await SyncEngine.shared.syncAll()
                // Every two minutes, check the Inbox against Gmail itself.
                tick += 1
                if tick % 24 == 0 { await SyncEngine.shared.reconcileAll() }
                lastSync = Date()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task {
                await SyncEngine.shared.syncAll()
                await SyncEngine.shared.reconcileAll()
            }
        }
    }

    // MARK: Accounts

    /// Google sign-in, then the account starts empty and goes live. The
    /// caller asks about importing older mail afterwards.
    func connectAccount() async -> Account? {
        addingAccount = true
        defer { addingAccount = false }
        do {
            let profile = try await GoogleAuth.shared.signIn()
            let account = try await SyncEngine.shared.connect(profile)
            accounts = store.accounts()
            await SyncEngine.shared.startLive(for: accounts.map(\.email))
            lastSync = Date()
            reload()
            return account
        } catch is CancellationError {
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func refreshSignedOut() {
        signedOut = Set(accounts.map(\.email).filter { !GoogleAuth.shared.hasToken(for: $0) })
    }

    /// Signs an existing account in again. Its mail and sync position stay,
    /// so it catches up from where it stopped; nothing is imported.
    func signInAgain(_ account: Account) async {
        addingAccount = true
        defer { addingAccount = false }
        do {
            let profile = try await GoogleAuth.shared.signIn(hint: account.email)
            _ = try await SyncEngine.shared.connect(profile)
            accounts = store.accounts()
            refreshSignedOut()
            // Its live connection may be waiting out a two-minute retry.
            await SyncEngine.shared.stopLive(profile.email)
            await SyncEngine.shared.startLive(for: accounts.map(\.email))
            await SyncEngine.shared.sync(profile.email)
            await SyncEngine.shared.reconcile(profile.email)
            lastSync = Date()
            reload()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    enum ImportRange: String, CaseIterable, Identifiable {
        case none, week, month, quarter, year, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "Don't import"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .quarter: "Last 3 months"
            case .year: "Last year"
            case .all: "Everything"
            }
        }
        var query: String? {
            switch self {
            case .none, .all: nil
            case .week: "newer_than:7d"
            case .month: "newer_than:30d"
            case .quarter: "newer_than:3m"
            case .year: "newer_than:1y"
            }
        }
    }

    func startImport(_ email: String, range: ImportRange) {
        guard range != .none else { return }
        importProgress[email] = .init(done: 0, total: 0)
        Task {
            do {
                try await SyncEngine.shared.importMessages(email, query: range.query) { p in
                    await MainActor.run { AppModel.shared.importProgress[email] = p }
                }
                if var a = store.accounts().first(where: { $0.email == email }) {
                    a.importedSince = range == .all ? .distantPast : Date()
                    store.save(a)
                }
            } catch {
                self.error = "Import stopped: \(error.localizedDescription)"
            }
            importProgress[email] = nil
            reload()
        }
    }

    func remove(_ account: Account) async {
        await SyncEngine.shared.stopLive(account.email)
        await GoogleAuth.shared.signOut(account.email)
        store.removeAccount(account.email)
        accounts = store.accounts()
        if accountFilter == account.email { accountFilter = nil }
        reload()
    }

    func account(_ email: String) -> Account? { accounts.first { $0.email == email } }

    /// The rail's Inbox and account icons: straight to that Inbox (all
    /// accounts when nil), leaving search, select mode or another tab.
    func showInbox(account: String?) {
        searchText = ""
        selecting = false
        if accountFilter != account { accountFilter = account }
        if mailbox != .inbox { mailbox = .inbox } else { reload() }
    }

    // MARK: List

    /// Coalesces bursts of store changes (an import page, a sync) into one
    /// reload per run-loop turn.
    func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    func reload() {
        let account = accountFilter
        for box in Mailbox.allCases {
            counts[box] = box == .inbox || box == .other
                ? store.count(in: box, account: account, unreadOnly: true)
                : box == .drafts ? store.count(in: .drafts, account: account) : 0
        }
        totalInMailbox = store.count(in: mailbox, account: account)

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = threads(store.search(query, account: account)).map { .thread($0.0, count: $0.1, unread: $0.2) }
            keepSelectionValid()
            return
        }

        // One list per mailbox, every email in it, newest first. The Inbox
        // is everything in Gmail's Inbox from every account — people,
        // notifications, newsletters, invitations together (owner,
        // 2026-11-12: "I have to look to different areas"; the Spark groups
        // and then rail icons were both tried and dropped).
        var messages = store.messages(in: mailbox, account: account)
        if unreadOnly { messages = messages.filter(\.isUnread) }
        items = withSections(threads(messages))
        keepSelectionValid()
        if selection != nil { thread = currentThread() }
    }

    /// One entry per conversation, newest first.
    private func threads(_ messages: [Message]) -> [(Message, Int, Bool)] {
        var order: [String] = []
        var groups: [String: [Message]] = [:]
        for m in messages {
            let key = "\(m.account):\(m.threadID)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(m)
        }
        return order.compactMap { key in
            // Search returns best match first, so pick the newest by date.
            guard let list = groups[key], let newest = list.max(by: { $0.date < $1.date }) else { return nil }
            return (newest, list.count, list.contains(where: \.isUnread))
        }
    }

    private func withSections(_ threads: [(Message, Int, Bool)]) -> [ListItem] {
        var out: [ListItem] = []
        var last = ""
        for t in threads {
            let s = When.section(t.0.date)
            if s != last { out.append(.section(s)); last = s }
            out.append(.thread(t.0, count: t.1, unread: t.2))
        }
        return out
    }

    private func keepSelectionValid() {
        guard let selection else { return }
        let present = items.contains { if case .thread(let m, _, _) = $0 { return m.id == selection || m.threadID == thread.first?.threadID }; return false }
        if !present && !thread.isEmpty && store.message(selection) == nil { self.selection = nil }
    }

    var threadIDsInList: [Message] {
        items.compactMap { if case .thread(let m, _, _) = $0 { return m }; return nil }
    }

    // MARK: Reading

    private func currentThread() -> [Message] {
        guard let selection, let m = store.message(selection) else { return [] }
        return store.thread(m.threadID, account: m.account)
    }

    private func loadThread() {
        thread = currentThread()
        guard let first = thread.last else { return }
        // A conversation that arrived as a lone reply: fetch the rest.
        if thread.count == 1, first.references != nil, !isDemo {
            Task { await SyncEngine.shared.completeThread(first.threadID, email: first.account) }
        }
        commit(changes(thread.filter(\.isUnread)) { $0.isUnread = false })
    }

    /// Brings the window forward, reopening it if it was closed.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    // MARK: Menu bar icon

    /// A code arrived: the icon is up for five minutes, or until it's copied.
    func showCodeIcon() {
        menuIcon.code(at: Date())
        refreshMenuIcon()
        Log.write("menu bar icon: code, up for \(Int(menuIcon.length)) s")
    }

    /// New Primary mail arrived: the icon is up for five minutes from the
    /// latest one.
    func showMailIcon(_ messages: [Message]) {
        guard !messages.isEmpty else { return }
        let fresh = messages.sorted { $0.date > $1.date }
        recentMail = Array((fresh + recentMail.filter { old in !fresh.contains { $0.id == old.id } }).prefix(5))
        menuIcon.mail(at: Date())
        refreshMenuIcon()
        Log.write("menu bar icon: \(messages.count) new Primary email(s), up for \(Int(menuIcon.length)) s")
    }

    func codeCopied() {
        guard menuIcon.showsCode else { return }
        menuIcon.codeDone()
        refreshMenuIcon()
    }

    /// "Hide this icon", or the icon dragged off the menu bar.
    func hideMenuIcon() {
        guard menuIcon.visible else { return }
        menuIcon.clear()
        refreshMenuIcon()
    }

    /// Drops what has run out, then wakes at the next deadline to look again.
    private func refreshMenuIcon() {
        // Write only on a real change: every write redraws the menu bar.
        var clock = menuIcon
        clock.expire(at: Date())
        if clock != menuIcon { menuIcon = clock }
        if !menuIcon.showsMail, !recentMail.isEmpty { recentMail = [] }
        menuIconTimer?.cancel()
        guard let next = menuIcon.nextChange else { return }
        menuIconTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled else { return }
            self?.refreshMenuIcon()
        }
    }

    /// Demo only: `POSTLINE_SIMULATE_MAIL=<seconds>` and
    /// `POSTLINE_SIMULATE_CODE=<seconds>` hand one sample email (a plain one,
    /// or the sign-in code) to the new-mail path after a delay, so the menu
    /// bar icon can be tested without sending real mail.
    private func simulateArrivalIfAsked() {
        let env = ProcessInfo.processInfo.environment
        let inbox = store.messages(in: .inbox, account: nil, limit: 50).compactMap { store.message($0.id) }
        func hasCode(_ m: Message) -> Bool { CodeFinder.find(subject: m.subject, text: m.bodyText, html: m.bodyHTML) != nil }
        for (key, wantsCode) in [("POSTLINE_SIMULATE_MAIL", false), ("POSTLINE_SIMULATE_CODE", true)] {
            guard let s = env[key].flatMap(Double.init) else { continue }
            guard let sample = inbox.first(where: { hasCode($0) == wantsCode }) else {
                Log.write("demo: no sample email for \(key)"); continue
            }
            Task {
                try? await Task.sleep(for: .seconds(s))
                Log.write("demo: simulating an arrival from \(sample.senderLabel)")
                var m = sample
                m.id = "simulated-\(UUID().uuidString)"
                m.date = Date()
                Notifier.shared.handle([m], accounts: accounts)
            }
        }
    }

    func open(account: String, messageID: String) {
        showMainWindow()
        searchText = ""
        if let m = store.message(messageID) {
            mailbox = m.isInInbox ? .inbox : .archive
            selection = messageID
        }
    }

    func select(_ item: ListItem) {
        switch item {
        case .thread(let m, _, _): selection = m.id
        case .section: break
        }
    }

    func move(_ delta: Int) {
        let list = threadIDsInList
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == selection || $0.threadID == thread.first?.threadID } ?? (delta > 0 ? -1 : list.count)
        let next = max(0, min(list.count - 1, idx + delta))
        selection = list[next].id
    }

    // MARK: Actions (on screen first, the provider in the background)

    var selectedThread: [Message] { thread }

    func archive() { archive(thread) }
    func archive(_ messages: [Message], title: String = "Archived") {
        act(on: messages, title: title) { $0.roles.subtract([.inbox]); $0.roles.insert(.archive) }
    }
    func moveToInbox() {
        act(on: thread, title: "Moved to Inbox") { $0.roles.subtract([.trash, .spam, .archive]); $0.roles.insert(.inbox) }
    }
    func markSpam() {
        act(on: thread, title: "Marked as spam") { $0.roles.subtract([.inbox, .archive]); $0.roles.insert(.spam) }
    }

    func trash() { trash(thread) }
    func trash(_ messages: [Message], title: String = "Moved to Trash") {
        act(on: messages, title: title) { $0.roles.subtract([.inbox, .archive]); $0.roles.insert(.trash) }
    }

    func toggleUnread() {
        guard !thread.isEmpty else { return }
        if thread.contains(where: \.isUnread) { commit(changes(thread) { $0.isUnread = false }) }
        else if let last = thread.last { commit(changes([last]) { $0.isUnread = true }) }
    }

    func togglePin() {
        guard let last = thread.last else { return }
        let pinned = thread.contains(where: \.isFlagged)
        if pinned { commit(changes(thread) { $0.isFlagged = false }) }
        else { commit(changes([last]) { $0.isFlagged = true }) }
        toast = Toast(text: pinned ? "Unpinned" : "Pinned")
    }

    /// Moves messages somewhere (archive, Trash, back to the Inbox) with a
    /// toast whose Undo puts back exactly what each message had.
    private func act(on messages: [Message], title: String, _ edit: (inout MailState) -> Void) {
        guard !messages.isEmpty else { return }
        // Only the open conversation moves the reader on; a swiped or batch
        // row elsewhere in the list leaves what you're reading alone.
        let wasOpen = isOpen(messages)
        if wasOpen { advanceSelection() }
        let made = changes(messages, edit)
        let request = commit(made)
        toast = Toast(text: title) { [weak self] in
            guard let self else { return }
            // Wait for the original change to reach the provider first; sent
            // in parallel, the undo could land before it and be overwritten.
            self.commit(made.map(\.reversed), after: request)
            if wasOpen { self.selection = messages.last?.id }
            self.reload()
        }
    }

    /// One message's state before and after an action.
    private struct StateChange: Sendable {
        let id: String
        let account: String
        let before: MailState
        let after: MailState
        var reversed: StateChange { StateChange(id: id, account: account, before: after, after: before) }
    }

    /// What an edit does to each message, as the provider will report it.
    /// Messages it leaves as they were are dropped.
    private func changes(_ messages: [Message], _ edit: (inout MailState) -> Void) -> [StateChange] {
        messages.compactMap { m in
            var state = m.state
            edit(&state)
            // Every account is Gmail for now; the provider step routes this.
            state = GmailMapping.normalised(state, to: m.to, account: m.account)
            return state == m.state ? nil : StateChange(id: m.id, account: m.account, before: m.state, after: state)
        }
    }

    /// Shows the changes at once, then sends them to the provider, after an
    /// earlier request has finished when one is given.
    @discardableResult
    private func commit(_ changes: [StateChange], after earlier: Task<Void, Never>? = nil) -> Task<Void, Never>? {
        guard !changes.isEmpty else { return nil }
        for c in changes { store.setState(c.id, c.after) }
        scheduleReload()
        guard !isDemo else { return nil }
        let remote = store.remoteIDs(for: changes.map(\.id))
        return Task {
            await earlier?.value
            for c in changes {
                guard let remoteID = remote[c.id] else { continue }
                do { try await GmailMapping.push(from: c.before, to: c.after, remoteID: remoteID, account: c.account) }
                catch { self.error = "Couldn't update Gmail: \(error.localizedDescription)" }
            }
        }
    }

    private func isOpen(_ messages: [Message]) -> Bool {
        guard let open = thread.first else { return false }
        return messages.contains { $0.account == open.account && $0.threadID == open.threadID }
    }

    // MARK: Swipe and batch

    /// A conversation in the list, as a stable key.
    static func key(_ m: Message) -> String { "\(m.account):\(m.threadID)" }

    /// Every message of a conversation that belongs to the list being shown.
    private func messages(ofThreadKeys keys: Set<String>) -> [Message] {
        threadIDsInList.filter { keys.contains(Self.key($0)) }
            .flatMap { store.thread($0.threadID, account: $0.account) }
    }

    func swipeArchive(_ m: Message) { archive(messages(ofThreadKeys: [Self.key(m)])) }
    func swipeTrash(_ m: Message) { trash(messages(ofThreadKeys: [Self.key(m)])) }

    /// Selecting several conversations at once. Off while `selecting` is false.
    var selecting = false { didSet { if !selecting { batch = []; batchAnchor = nil } } }
    var batch: Set<String> = []
    private var batchAnchor: String?

    /// Click toggles one; Shift-click selects the range from the last click.
    func toggleBatch(_ m: Message, range: Bool = false) {
        selecting = true
        let key = Self.key(m)
        let keys = threadIDsInList.map(Self.key)
        if range, let anchor = batchAnchor, let a = keys.firstIndex(of: anchor), let b = keys.firstIndex(of: key) {
            batch.formUnion(keys[min(a, b)...max(a, b)])
        } else if batch.contains(key) {
            batch.remove(key)
        } else {
            batch.insert(key)
        }
        batchAnchor = key
    }

    func selectAll() {
        selecting = true
        let all = Set(threadIDsInList.map(Self.key))
        batch = batch == all ? [] : all
    }

    func batchArchive() {
        let n = batch.count
        archive(messages(ofThreadKeys: batch), title: "Archived \(n) conversation\(n == 1 ? "" : "s")")
        selecting = false
    }

    func batchTrash() {
        let n = batch.count
        trash(messages(ofThreadKeys: batch), title: "Moved \(n) conversation\(n == 1 ? "" : "s") to Trash")
        selecting = false
    }

    func batchMarkRead() {
        commit(changes(messages(ofThreadKeys: batch).filter(\.isUnread)) { $0.isUnread = false })
        selecting = false
    }

    /// After archiving, the next conversation down opens — the Spark flow.
    private func advanceSelection() {
        let list = threadIDsInList
        guard let idx = list.firstIndex(where: { $0.threadID == thread.first?.threadID }) else { selection = nil; return }
        let next = idx + 1 < list.count ? list[idx + 1] : (idx > 0 ? list[idx - 1] : nil)
        selection = next?.id
    }

    // MARK: Writing

    func compose() {
        guard let account = account(accountFilter ?? "") ?? accounts.first else { return }
        let from = account.sendAs.first ?? SendAs(email: account.email, name: account.name ?? "", isDefault: true)
        composing = Draft(account: account.email, from: from)
    }

    func reply(all: Bool = false, prefill: String? = nil) {
        guard let m = thread.last, let account = account(m.account) else { return }
        var draft = Draft.reply(to: m, all: all, account: account)
        if let prefill { draft.body = prefill + draft.body }
        composing = draft
    }

    // MARK: Suggested replies

    /// Suggestions per message id, so reopening a conversation is instant.
    private(set) var suggestions: [String: [String]] = [:]
    private var suggesting: Set<String> = []

    /// The message a reply would answer: the newest one, when it's from
    /// someone else and is a person writing (not a notification).
    func replyTarget(in messages: [Message]) -> Message? {
        guard let last = messages.last, last.category == .people else { return nil }
        let mine = Set(accounts.flatMap { [$0.email] + $0.sendAs.map(\.email) })
        return mine.contains(last.fromEmail) ? nil : last
    }

    func loadSuggestions(for m: Message) {
        guard Preferences.shared.suggestReplies, suggestions[m.id] == nil, !suggesting.contains(m.id) else { return }
        suggesting.insert(m.id)
        let me = account(m.account)?.name ?? "me"
        Task {
            let replies = await Writer.shared.replies(to: m, myName: me)
            suggestions[m.id] = replies
            suggesting.remove(m.id)
        }
    }

    func isSuggesting(_ id: String) -> Bool { suggesting.contains(id) }

    func forward() {
        guard let m = thread.last, let account = account(m.account) else { return }
        composing = Draft.forward(m, account: account)
    }

    /// Every address Postline can send from, across all accounts.
    var senders: [(account: String, from: SendAs)] {
        accounts.flatMap { a in
            (a.sendAs.isEmpty ? [SendAs(email: a.email, name: a.name ?? "", isDefault: true)] : a.sendAs).map { (a.email, $0) }
        }
    }

    /// Sends after a 5-second window in which Undo takes it back.
    func send(_ draft: Draft) {
        composing = nil
        let id = draft.id
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingSends[id] = nil
            if self.isDemo { self.toast = Toast(text: "Sent"); return }
            do {
                let mime = try draft.mime()
                _ = try await GmailAPI(email: draft.account).sendRaw(mime, threadID: draft.threadID)
                self.toast = Toast(text: "Sent")
                await SyncEngine.shared.sync(draft.account)
            } catch {
                self.error = "Couldn't send: \(error.localizedDescription)"
                self.composing = draft
            }
        }
        pendingSends[id] = task
        toast = Toast(text: "Sending…") { [weak self] in
            task.cancel()
            self?.pendingSends[id] = nil
            self?.composing = draft
        }
    }

    // MARK: Attachments

    func openAttachment(_ a: Attachment, of m: Message) {
        Task {
            do {
                let data: Data
                if isDemo { data = Data("Demo attachment".utf8) }
                else if let aid = a.attachmentID, let remoteID = store.remoteID(for: m.id) {
                    data = try await GmailAPI(email: m.account).attachment(messageID: remoteID, attachmentID: aid)
                }
                else { return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Postline/\(m.id)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(a.filename.isEmpty ? "attachment" : a.filename)
                try data.write(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                self.error = "Couldn't open \(a.filename): \(error.localizedDescription)"
            }
        }
    }
}
