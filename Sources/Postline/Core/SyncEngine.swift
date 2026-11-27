import Foundation

/// Keeps the Mac's copy of each account in step with Gmail.
///
/// * **New accounts start empty.** Connecting pins Gmail's history cursor at
///   "now"; only what arrives after that is downloaded, unless the person
///   chose to import older mail (7 days … everything) at onboarding or later.
/// * **Changes come from Gmail's history feed**: one cheap call returns every
///   message added, deleted or relabelled since the cursor. The live IMAP
///   connection triggers it the moment the Inbox changes; a 30-second timer
///   catches what happens outside the Inbox (sent from the phone, archived on
///   the web).
/// * **A reply in an old conversation brings the whole thread** — owner's
///   choice — so the reader never shows a lonely "Re:".
actor SyncEngine {

    static let shared = SyncEngine()

    struct ImportProgress: Sendable { var done: Int; var total: Int }

    /// Mail that just arrived, for notifications and code detection.
    var onNewMail: (@Sendable ([Message]) async -> Void)?
    /// Something in the store changed; the UI should reload what it shows.
    var onStoreChanged: (@Sendable () async -> Void)?

    private let store = Store.shared
    private var running: Set<String> = []
    private var rerun: Set<String> = []
    private var watchers: [String: LiveWatcher] = [:]
    /// Accounts Gmail told to slow down, and until when (2026-11-12: a burst
    /// of downloads hit Gmail's per-user limit; polling on every 5 s kept it
    /// there).
    private var pausedUntil: [String: Date] = [:]

    private func isPaused(_ email: String) -> Bool {
        if let until = pausedUntil[email], until > Date() { return true }
        pausedUntil[email] = nil
        return false
    }

    private func pause(_ email: String) {
        guard pausedUntil[email] == nil else { return }
        pausedUntil[email] = Date().addingTimeInterval(60)
        Log.write("\(email): Gmail asked to slow down — pausing this account for 60 s")
    }

    func setHandlers(onNewMail: @escaping @Sendable ([Message]) async -> Void,
                     onStoreChanged: @escaping @Sendable () async -> Void) {
        self.onNewMail = onNewMail
        self.onStoreChanged = onStoreChanged
    }

    // MARK: Accounts

    /// Pins the starting point for a freshly signed-in account. Nothing older
    /// is fetched here.
    func connect(_ profile: GoogleProfile) async throws -> Account {
        let api = GmailAPI(email: profile.email)
        let p = try await api.profile()
        var account = store.accounts().first { $0.email == profile.email }
            ?? Account(email: profile.email, name: profile.name, pictureURL: profile.pictureURL)
        account.name = profile.name ?? account.name
        account.pictureURL = profile.pictureURL ?? account.pictureURL
        if account.historyID == nil { account.historyID = p.historyId }
        account.sendAs = (try? await api.sendAs()) ?? [SendAs(email: profile.email, name: profile.name ?? "", isDefault: true)]
        store.save(account)
        return account
    }

    func startLive(for emails: [String]) async {
        for email in emails where watchers[email] == nil {
            let watcher = LiveWatcher(email: email) { [weak self] in await self?.sync(email) }
            watchers[email] = watcher
            await watcher.start()
        }
        for (email, watcher) in watchers where !emails.contains(email) {
            await watcher.stop()
            watchers[email] = nil
        }
    }

    func stopLive(_ email: String) async {
        await watchers[email]?.stop()
        watchers[email] = nil
    }

    // MARK: Incremental sync

    /// Applies everything Gmail changed since the account's cursor. Calls
    /// that arrive while one is running are folded into a single re-run.
    func sync(_ email: String) async {
        if isPaused(email) { return }
        if running.contains(email) { rerun.insert(email); return }
        running.insert(email)
        defer { running.remove(email) }
        repeat {
            rerun.remove(email)
            do { try await syncOnce(email) }
            catch GmailError.rateLimited { pause(email); return }
            catch {
                Log.write("sync \(email) failed — \(error.localizedDescription)")
            }
        } while rerun.contains(email)
    }

    func syncAll() async {
        for account in store.accounts() { await sync(account.email) }
    }

    private func syncOnce(_ email: String) async throws {
        guard var account = store.accounts().first(where: { $0.email == email }) else { return }
        let api = GmailAPI(email: email)
        guard let start = account.historyID else {
            account.historyID = try await api.profile().historyId
            store.save(account)
            return
        }

        var added: [String] = []
        var deleted: Set<String> = []
        // Each label change in Gmail's history carries the message's whole
        // label list at that moment, and history comes oldest first, so the
        // last list seen per message is its state now. Merging adds and
        // removes into two sets instead lost an Undo: "Inbox removed" then
        // "Inbox added" came out as removed (found testing, 2026-11-12).
        var labelEdits: [String: Set<String>] = [:]
        var page: String?
        var latest = start
        do {
            repeat {
                let h = try await api.history(since: start, pageToken: page)
                for item in h.history ?? [] {
                    added += (item.messagesAdded ?? []).map(\.message.id)
                    deleted.formUnion((item.messagesDeleted ?? []).map(\.message.id))
                    for change in (item.labelsAdded ?? []) + (item.labelsRemoved ?? []) {
                        labelEdits[change.message.id] = Set(change.message.labelIds ?? [])
                    }
                }
                if let id = h.historyId { latest = id }
                page = h.nextPageToken
            } while page != nil
        } catch GmailError.historyGone {
            // Offline for over a week: Gmail forgot the cursor. Start again from
            // now and fill the last two days so the Inbox isn't missing a gap.
            account.historyID = try await api.profile().historyId
            store.save(account)
            _ = try await importMessages(email, query: "newer_than:2d", progress: nil)
            await onStoreChanged?()
            return
        }

        // History speaks in Gmail IDs; the store maps them to local ones.
        // Label changes on mail we already have: apply locally, no download.
        let edited = store.localIDs(account: email, remoteIDs: Array(labelEdits.keys))
        var refetch: [String] = []
        for (remoteID, labels) in labelEdits where !deleted.contains(remoteID) {
            if let id = edited[remoteID], let m = store.message(id) {
                store.setState(id, GmailMapping.state(labels: labels, to: m.to, account: email))
            } else if labels.contains("INBOX") || labels.contains("STARRED") {
                // Old mail moved back into view (unarchived, starred on the
                // phone): fetch it now.
                refetch.append(remoteID)
            }
        }

        let candidates = Array(Set(added + refetch).subtracting(deleted))
        let alreadyHere = store.localIDs(account: email, remoteIDs: candidates)
        let fresh = try await fetch(candidates.filter { alreadyHere[$0] == nil }, email: email)
        let saved = store.ingest(fresh)
        store.delete(ids: Array(store.localIDs(account: email, remoteIDs: Array(deleted)).values))

        // Whole threads for replies to conversations we never downloaded.
        var completed: [FetchedMessage] = []
        for m in saved where m.references != nil {
            let known = store.threadRemoteIDs(m.threadID, account: email)
            if known.count <= 1, let thread = try? await api.thread(m.threadID) {
                let missing = (thread.messages ?? []).filter { !known.contains($0.id) }
                completed += missing.map { MessageParser.parse($0, account: email) }
            }
        }
        store.ingest(completed)

        if latest != start {
            account.historyID = latest
            store.save(account)
        }

        if !fresh.isEmpty || !deleted.isEmpty || !labelEdits.isEmpty || !completed.isEmpty {
            await onStoreChanged?()
        }
        // New Inbox mail: ask Gmail straight away whether it's Primary, so it
        // lands in the right tab within seconds rather than at the next check.
        if saved.contains(where: \.isInInbox),
           let recent = try? await api.list(query: "in:inbox category:primary newer_than:2d", pageToken: nil, max: 100) {
            store.markPrimary(account: email, primary: Set((recent.messages ?? []).map(\.id)),
                              since: Date().addingTimeInterval(-2 * 86400))
            await onStoreChanged?()
        }
        let addedIDs = Set(added)
        let arrived = zip(fresh, saved)
            .filter { addedIDs.contains($0.0.remoteID) && $0.1.isInInbox && $0.1.date.timeIntervalSinceNow > -15 * 60 }
            .map(\.1)
        if !arrived.isEmpty { await onNewMail?(arrived) }
    }

    // MARK: Import of older mail

    /// Downloads older mail matching a Gmail query (`newer_than:30d`, or nil
    /// for everything), skipping what is already on the Mac. Runs in the
    /// background; new mail keeps arriving while it works.
    @discardableResult
    func importMessages(_ email: String, query: String?, progress: (@Sendable (ImportProgress) async -> Void)?) async throws -> Int {
        let api = GmailAPI(email: email)
        var ids: [String] = []
        var page: String?
        repeat {
            let p = try await api.list(query: query.map { "\($0) -in:chats" } ?? "-in:chats", pageToken: page)
            ids += (p.messages ?? []).map(\.id)
            page = p.nextPageToken
        } while page != nil
        let alreadyHere = store.localIDs(account: email, remoteIDs: ids)
        ids = ids.filter { alreadyHere[$0] == nil }
        let total = ids.count
        var done = 0
        await progress?(ImportProgress(done: 0, total: total))
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            store.ingest(try await fetch(chunk, email: email))
            done += chunk.count
            await progress?(ImportProgress(done: done, total: total))
            await onStoreChanged?()
        }
        return total
    }

    // MARK: Fetching

    /// Full messages, four requests at a time — Gmail's per-user limit is
    /// tighter than its docs say (measured 2026-11-12), and four keeps an import from tripping it.
    ///
    /// Throws if any download failed for a reason other than the message
    /// being gone, after storing the ones that did arrive. The history cursor
    /// must not move past mail that never made it here: on a flaky hotspot
    /// the change list loaded, the downloads timed out, the failures were
    /// swallowed and the cursor moved on — that mail was skipped for good
    /// (2026-11-12, a 9:19 PM Google alert never appeared).
    private func fetch(_ ids: [String], email: String) async throws -> [FetchedMessage] {
        guard !ids.isEmpty else { return [] }
        let api = GmailAPI(email: email)
        var out: [FetchedMessage] = []
        var failure: Error?
        for batch in stride(from: 0, to: ids.count, by: 4).map({ Array(ids[$0..<min($0 + 4, ids.count)]) }) {
            let results = await withTaskGroup(of: Result<FetchedMessage?, Error>.self) { group in
                for id in batch {
                    group.addTask {
                        do { return .success(MessageParser.parse(try await api.message(id), account: email)) }
                        catch GmailError.notFound { return .success(nil) }   // deleted meanwhile: nothing to get
                        catch { return .failure(error) }
                    }
                }
                var collected: [Result<FetchedMessage?, Error>] = []
                for await r in group { collected.append(r) }
                return collected
            }
            for r in results {
                switch r {
                case .success(let m): if let m { out.append(m) }
                case .failure(let e): failure = e
                }
            }
        }
        if let failure {
            store.ingest(out)
            throw failure
        }
        return out
    }

    // MARK: Safety net

    /// Compares the Mac's Inbox with Gmail's real Inbox and repairs any
    /// difference: mail that never arrived, mail archived or moved back to the
    /// Inbox somewhere else (Gmail on the web, the phone). Gmail is the truth.
    /// Cheap — one list call, plus a label check only for what differs — so
    /// it runs at launch, on wake and every two minutes.
    func reconcile(_ email: String) async {
        if isPaused(email) { return }
        let api = GmailAPI(email: email)
        do {
            let page = try await api.list(query: "in:inbox", pageToken: nil, max: 200)
            let gmailInbox = Set((page.messages ?? []).map(\.id))
            // All of Gmail's Inbox here: Postline's Inbox (Primary) and Other.
            // Comparing against Primary alone made every Other email look
            // un-Inboxed, so each run re-fetched their labels — 38 requests
            // every two minutes, 353 runs, for nothing (measured 2026-11-14) —
            // and an Other email archived on the web never left.
            let local = store.messages(in: .inbox, account: email, limit: 400)
                + store.messages(in: .other, account: email, limit: 400)
            let remoteOf = store.remoteIDs(for: local.map(\.id))
            let localInbox = Set(local.compactMap { remoteOf[$0.id] })
            let known = store.localIDs(account: email, remoteIDs: Array(gmailInbox))
            func listed(_ m: Message) -> Bool { remoteOf[m.id].map(gmailInbox.contains) ?? false }

            // In Gmail's Inbox but missing here, or here without the Inbox label.
            let missing = gmailInbox.filter { known[$0] == nil }
            let relabel = gmailInbox.subtracting(missing).subtracting(localInbox)
            // Here in the Inbox, not in Gmail's (archived or deleted elsewhere).
            // Only within the window Gmail listed, so older mail isn't judged.
            let oldestListed = local.filter(listed).map(\.date).min() ?? .distantPast
            let gone = local.filter { !listed($0) && $0.date >= oldestListed }

            var changed = 0
            if !missing.isEmpty {
                // Gently: at most 40 a run; the rest come two minutes later.
                let fresh = try await fetch(Array(missing.prefix(40)), email: email)
                store.ingest(fresh)
                changed += fresh.count
            }
            // (Gmail ID, local ID) of each message whose labels need checking.
            let recheck = relabel.compactMap { remote in known[remote].map { (remote, $0) } }
                + gone.compactMap { m in remoteOf[m.id].map { ($0, m.id) } }
            for (remoteID, id) in recheck.prefix(40) {
                do {
                    let labels = Set(try await api.labels(remoteID))
                    let to = store.message(id)?.to ?? []
                    store.setState(id, GmailMapping.state(labels: labels, to: to, account: email))
                    changed += 1
                } catch GmailError.notFound {
                    store.delete(ids: [id])
                    changed += 1
                }
            }
            // Which of the Inbox is Gmail's Primary tab — Gmail's own answer.
            let primary = try await api.list(query: "in:inbox category:primary", pageToken: nil, max: 500)
            let primaryIDs = Set((primary.messages ?? []).map(\.id))
            let since = (primary.messages?.count ?? 0) < 500
                ? Date.distantPast
                : local.filter { remoteOf[$0.id].map(primaryIDs.contains) ?? false }.map(\.date).min() ?? Date()
            store.markPrimary(account: email, primary: primaryIDs, since: since)
            changed += 1   // always redraw: tabs may have moved

            if changed > 1 {
                Log.write("reconcile \(email): repaired \(changed) (missing \(missing.count), back in Inbox \(relabel.count), left Inbox \(gone.count))")
                await onStoreChanged?()
            }
        } catch GmailError.rateLimited {
            pause(email)
        } catch {
            Log.write("reconcile \(email) failed — \(error.localizedDescription)")
        }
    }

    func reconcileAll() async {
        for account in store.accounts() {
            await reconcile(account.email)
            await redateOnce(account.email)
        }
    }

    /// One pass over mail stored before arrival times were read from the
    /// Received: header: re-dates the Inbox, two requests at a time.
    private func redateOnce(_ email: String) async {
        let key = "redated.v1.\(email)"
        guard !UserDefaults.standard.bool(forKey: key), !isPaused(email) else { return }
        let api = GmailAPI(email: email)
        var moved = 0
        do {
            let inbox = store.messages(in: .inbox, account: email, limit: 400)
            let remoteOf = store.remoteIDs(for: inbox.map(\.id))
            for m in inbox {
                guard let remoteID = remoteOf[m.id] else { continue }
                let raw = try await api.arrival(remoteID)
                let headers = Dictionary((raw.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) },
                                         uniquingKeysWith: { first, _ in first })
                let date = MessageParser.arrivalDate(internalDate: raw.internalDate, headers: headers)
                if abs(date.timeIntervalSince(m.date)) > 60 { store.setDate(m.id, date); moved += 1 }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            UserDefaults.standard.set(true, forKey: key)
            Log.write("redate \(email): \(moved) emails moved to their real arrival time")
            if moved > 0 { await onStoreChanged?() }
        } catch GmailError.rateLimited {
            pause(email)
        } catch {
            Log.write("redate \(email) stopped — \(error.localizedDescription); will retry")
        }
    }

    /// Fetches a whole conversation on demand (opening an older thread).
    func completeThread(_ threadID: String, email: String) async {
        guard let thread = try? await GmailAPI(email: email).thread(threadID) else { return }
        let known = store.threadRemoteIDs(threadID, account: email)
        let missing = (thread.messages ?? []).filter { !known.contains($0.id) }.map { MessageParser.parse($0, account: email) }
        guard !missing.isEmpty else { return }
        store.ingest(missing)
        await onStoreChanged?()
    }
}
