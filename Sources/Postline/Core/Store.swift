import Foundation
import SQLite3

/// Every message Postline has seen, on this Mac, in one SQLite file.
///
/// This is where the speed comes from: opening, listing and searching mail
/// never wait on the network. Search is SQLite's FTS5 over subject, sender
/// and body.
///
/// The layout is the same for every provider:
/// * `messages`: one row per message, keyed by Postline's own ID, with its
///   roles (Inbox, Sent…) and flags as indexed columns. No bodies, so a list
///   reads small rows.
/// * `message_bodies`: the text and HTML, read when a message is opened.
/// * `message_tags`: everything else a provider says about a message
///   (Gmail's categories and labels), and later Postline's own sorting.
/// * `message_remote`: the provider's IDs for each message. Gmail's never
///   change; an IMAP message gets a new one when it moves folder, so the
///   local ID is what the rest of the app holds on to.
///
/// One connection, used from one serial queue. Every call is short (a single
/// indexed query), so the main thread may call straight in; the sync engine
/// writes in transactions of a page at a time.
final class Store: @unchecked Sendable {

    static let shared: Store = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = ProcessInfo.processInfo.environment["POSTLINE_DEMO"] == "1" ? "demo.sqlite" : "mail.sqlite"
        return Store(path: dir.appendingPathComponent(name).path)
    }()

    static let schemaVersion = 2

    private var db: OpaquePointer?
    private let path: String
    private let queue = DispatchQueue(label: "postline.store")
    private let key = DispatchSpecificKey<Bool>()

    init(path: String) {
        self.path = path
        queue.setSpecific(key: key, value: true)
        open()
        migrate()
    }

    deinit { sqlite3_close(db) }

    private func open() {
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    @discardableResult
    private func sync<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: key) == true ? body() : queue.sync(execute: body)
    }

    // MARK: Schema

    private static let schema = """
    CREATE TABLE IF NOT EXISTS accounts(
        email TEXT PRIMARY KEY, name TEXT, picture TEXT, history_id TEXT,
        imported_since REAL, send_as TEXT, position INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS messages(
        id TEXT PRIMARY KEY, account TEXT NOT NULL, thread_id TEXT NOT NULL,
        date REAL NOT NULL, from_name TEXT, from_email TEXT, to_list TEXT, cc_list TEXT,
        reply_to TEXT, subject TEXT, snippet TEXT, attachments TEXT, category TEXT NOT NULL,
        verified INTEGER NOT NULL DEFAULT 0, message_id_header TEXT, refs TEXT, list_unsubscribe TEXT,
        is_unread INTEGER NOT NULL DEFAULT 0, is_flagged INTEGER NOT NULL DEFAULT 0,
        in_inbox INTEGER NOT NULL DEFAULT 0, in_sent INTEGER NOT NULL DEFAULT 0,
        in_drafts INTEGER NOT NULL DEFAULT 0, in_trash INTEGER NOT NULL DEFAULT 0,
        in_spam INTEGER NOT NULL DEFAULT 0, in_archive INTEGER NOT NULL DEFAULT 0,
        primary_tab INTEGER);
    CREATE INDEX IF NOT EXISTS messages_date ON messages(date DESC);
    CREATE INDEX IF NOT EXISTS messages_thread ON messages(account, thread_id);
    CREATE INDEX IF NOT EXISTS messages_inbox ON messages(date DESC) WHERE in_inbox = 1;
    CREATE TABLE IF NOT EXISTS message_bodies(
        message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE, text TEXT, html TEXT);
    CREATE TABLE IF NOT EXISTS message_tags(
        message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE, tag TEXT NOT NULL,
        PRIMARY KEY(message_id, tag)) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS message_tags_tag ON message_tags(tag);
    CREATE TABLE IF NOT EXISTS message_remote(
        account TEXT NOT NULL, remote_id TEXT NOT NULL,
        message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        PRIMARY KEY(account, remote_id)) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS message_remote_message ON message_remote(message_id);
    CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
        subject, sender, body, tokenize = 'unicode61 remove_diacritics 2');
    CREATE TABLE IF NOT EXISTS codes(
        message_id TEXT PRIMARY KEY, code TEXT, sender TEXT, account TEXT, date REAL);
    """

    private func migrate() {
        let version = query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        guard version < Self.schemaVersion else { return }
        let tables = Set(query("SELECT name FROM sqlite_master WHERE type='table'") { $0.text(0) ?? "" })
        guard tables.contains("messages") else {
            exec(Self.schema)
            exec("PRAGMA user_version = \(Self.schemaVersion)")
            return
        }
        if migrateFromVersion1() { return }
        // A failed migration leaves a database the app cannot read. The copy
        // made before it started keeps the old mail; this one starts empty.
        Log.write("store: migration failed; the previous database is kept at \(backupPath)")
        sqlite3_close(db)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        open()
        exec(Self.schema)
        exec("PRAGMA user_version = \(Self.schemaVersion)")
    }

    private var backupPath: String {
        (path as NSString).deletingPathExtension + "-v1-backup.sqlite"
    }

    /// Version 1 kept Gmail's labels as one string per message and the bodies
    /// in the message row. Copies every message into the version 2 layout;
    /// the local ID is the Gmail ID it already had. A full copy of the old
    /// file is made first.
    private func migrateFromVersion1() -> Bool {
        if !FileManager.default.fileExists(atPath: backupPath) {
            guard run("VACUUM INTO ?", [backupPath]) else { return false }
        }
        guard exec("BEGIN") else { return false }
        let ok = exec("""
            ALTER TABLE messages RENAME TO messages_v1;
            DROP INDEX IF EXISTS messages_date;
            DROP INDEX IF EXISTS messages_thread;
            DROP TABLE IF EXISTS messages_fts;
            """)
            && exec(Self.schema)
            && copyVersion1Messages()
            && exec("DROP TABLE messages_v1; PRAGMA user_version = \(Self.schemaVersion);")
        guard ok, exec("COMMIT") else {
            exec("ROLLBACK")
            return false
        }
        Log.write("store: migrated to version \(Self.schemaVersion); the previous database is kept at \(backupPath)")
        return true
    }

    private func copyVersion1Messages() -> Bool {
        let sql = """
        SELECT id, account, thread_id, date, from_name, from_email, to_list, cc_list, reply_to, subject,
               snippet, body_text, body_html, labels, attachments, category, verified, message_id_header,
               refs, list_unsubscribe, primary_tab
        FROM messages_v1
        """
        let stmt = prepare(sql, [])
        defer { sqlite3_finalize(stmt) }
        guard stmt != nil else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = Row(stmt: stmt)
            let account = s.text(1) ?? ""
            let to = Self.lines(s.text(6))
            let labels = Set((s.text(13) ?? "").split(separator: " ").map(String.init))
            let m = Message(
                id: s.text(0) ?? "", account: account, threadID: s.text(2) ?? "",
                date: Date(timeIntervalSince1970: s.double(3) ?? 0),
                fromName: s.text(4) ?? "", fromEmail: s.text(5) ?? "", to: to, cc: Self.lines(s.text(7)),
                replyTo: s.text(8), subject: s.text(9) ?? "", snippet: s.text(10) ?? "",
                bodyText: s.text(11) ?? "", bodyHTML: s.text(12),
                state: GmailMapping.state(labels: labels, to: to, account: account),
                attachments: Self.decodeAttachments(s.text(14)),
                category: MailCategory(rawValue: s.text(15) ?? "") ?? .people,
                verified: s.int(16) == 1, messageIDHeader: s.text(17), references: s.text(18),
                listUnsubscribe: s.text(19))
            guard write(m), run("INSERT INTO message_remote(account, remote_id, message_id) VALUES(?,?,?)", [account, m.id, m.id])
            else { return false }
            if let primary = s.double(20) {
                run("UPDATE messages SET primary_tab=? WHERE id=?", [Int(primary), m.id])
            }
        }
        return true
    }

    // MARK: Accounts

    func accounts() -> [Account] {
        sync {
            query("SELECT email, name, picture, history_id, imported_since, send_as FROM accounts ORDER BY position, email") { s in
                Account(email: s.text(0) ?? "", name: s.text(1), pictureURL: s.text(2).flatMap(URL.init(string:)),
                        historyID: s.text(3), importedSince: s.double(4).map(Date.init(timeIntervalSince1970:)),
                        sendAs: s.text(5).flatMap { try? JSONDecoder().decode([SendAs].self, from: Data($0.utf8)) } ?? [])
            }
        }
    }

    func save(_ a: Account) {
        sync {
            let sendAs = (try? JSONEncoder().encode(a.sendAs)).map { String(decoding: $0, as: UTF8.self) }
            run("""
            INSERT INTO accounts(email, name, picture, history_id, imported_since, send_as, position)
            VALUES(?,?,?,?,?,?, (SELECT COALESCE(MAX(position),0)+1 FROM accounts))
            ON CONFLICT(email) DO UPDATE SET name=excluded.name, picture=excluded.picture,
              history_id=excluded.history_id, imported_since=excluded.imported_since, send_as=excluded.send_as
            """, [a.email, a.name, a.pictureURL?.absoluteString, a.historyID,
                  a.importedSince?.timeIntervalSince1970, sendAs])
        }
    }

    func removeAccount(_ email: String) {
        sync {
            exec("BEGIN")
            run("DELETE FROM message_search WHERE rowid IN (SELECT rowid FROM messages WHERE account=?)", [email])
            run("DELETE FROM messages WHERE account=?", [email])
            run("DELETE FROM message_remote WHERE account=?", [email])
            run("DELETE FROM codes WHERE account=?", [email])
            run("DELETE FROM accounts WHERE email=?", [email])
            exec("COMMIT")
        }
    }

    // MARK: Writing messages

    /// Saves messages a provider delivered. A message the store already has
    /// (the same provider ID) keeps its local ID and is updated; a new one is
    /// given a local ID. Returns the messages with their local IDs, in order.
    @discardableResult
    func ingest(_ fetched: [FetchedMessage]) -> [Message] {
        guard !fetched.isEmpty else { return [] }
        return sync {
            exec("BEGIN")
            var saved: [Message] = []
            for f in fetched {
                var m = f.message
                m.id = localIDLocked(account: m.account, remoteID: f.remoteID) ?? UUID().uuidString.lowercased()
                write(m)
                run("INSERT OR IGNORE INTO message_remote(account, remote_id, message_id) VALUES(?,?,?)",
                    [m.account, f.remoteID, m.id])
                saved.append(m)
            }
            exec("COMMIT")
            return saved
        }
    }

    private static let writeColumns = [
        "id", "account", "thread_id", "date", "from_name", "from_email", "to_list", "cc_list", "reply_to",
        "subject", "snippet", "attachments", "category", "verified", "message_id_header", "refs",
        "list_unsubscribe", "is_unread", "is_flagged"
    ] + MailboxRole.allCases.map(\.column)

    /// One message into `messages`, its body, tags and search entry. An
    /// update keeps the row (and so its search entry's rowid) in place.
    @discardableResult
    private func write(_ m: Message) -> Bool {
        let columns = Self.writeColumns
        let updates = columns.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ", ")
        let sql = """
        INSERT INTO messages(\(columns.joined(separator: ", "))) VALUES(\(columns.map { _ in "?" }.joined(separator: ",")))
        ON CONFLICT(id) DO UPDATE SET \(updates)
        """
        let values: [Any?] = [
            m.id, m.account, m.threadID, m.date.timeIntervalSince1970, m.fromName, m.fromEmail,
            m.to.joined(separator: "\n"), m.cc.joined(separator: "\n"), m.replyTo, m.subject, m.snippet,
            (try? JSONEncoder().encode(m.attachments)).map { String(decoding: $0, as: UTF8.self) },
            m.category.rawValue, m.verified, m.messageIDHeader, m.references, m.listUnsubscribe,
            m.state.isUnread, m.state.isFlagged
        ] + MailboxRole.allCases.map { m.state.roles.contains($0) }
        guard run(sql, values),
              run("INSERT OR REPLACE INTO message_bodies(message_id, text, html) VALUES(?,?,?)", [m.id, m.bodyText, m.bodyHTML]),
              writeTags(m.id, m.state.tags),
              let rowid = query("SELECT rowid FROM messages WHERE id=?", [m.id], { $0.int(0) }).first
        else { return false }
        return run("DELETE FROM message_search WHERE rowid=?", [rowid])
            && run("INSERT INTO message_search(rowid, subject, sender, body) VALUES(?,?,?,?)",
                   [rowid, m.subject, "\(m.fromName) \(m.fromEmail)", String(m.bodyText.prefix(20_000))])
    }

    @discardableResult
    private func writeTags(_ id: String, _ tags: Set<String>) -> Bool {
        guard run("DELETE FROM message_tags WHERE message_id=?", [id]) else { return false }
        for tag in tags.sorted() {
            guard run("INSERT INTO message_tags(message_id, tag) VALUES(?,?)", [id, tag]) else { return false }
        }
        return true
    }

    /// A message's roles, flags and tags, as a provider now reports them or
    /// as an action left them.
    func setState(_ id: String, _ state: MailState) {
        sync {
            let assignments = (["is_unread", "is_flagged"] + MailboxRole.allCases.map(\.column)).map { "\($0)=?" }
            let values: [Any?] = [state.isUnread, state.isFlagged] + MailboxRole.allCases.map { state.roles.contains($0) } + [id]
            exec("BEGIN")
            run("UPDATE messages SET \(assignments.joined(separator: ", ")) WHERE id=?", values)
            writeTags(id, state.tags)
            exec("COMMIT")
        }
    }

    func setDate(_ id: String, _ date: Date) {
        sync { run("UPDATE messages SET date=? WHERE id=?", [date.timeIntervalSince1970, id]) }
    }

    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        sync {
            exec("BEGIN")
            for id in ids {
                run("DELETE FROM message_search WHERE rowid IN (SELECT rowid FROM messages WHERE id=?)", [id])
                run("DELETE FROM messages WHERE id=?", [id])
            }
            exec("COMMIT")
        }
    }

    /// Records Gmail's Primary tab for an account: the listed messages
    /// (Gmail IDs) are Primary, every other Inbox message since `since` is not.
    func markPrimary(account: String, primary remoteIDs: Set<String>, since: Date) {
        // An empty answer is no answer. Gmail's `category:primary` search
        // found nothing on either of the owner's accounts, although 150 of
        // their 400 Inbox messages carry the Primary label, and marking all
        // 400 "not Primary" left the Inbox empty (2026-11-27). The messages go
        // back to being sorted by their own category labels instead.
        guard !remoteIDs.isEmpty else {
            sync {
                run("UPDATE messages SET primary_tab = NULL WHERE account=? AND in_inbox = 1 AND date >= ?",
                    [account, since.timeIntervalSince1970])
            }
            return
        }
        sync {
            run("""
            UPDATE messages SET primary_tab = CASE WHEN id IN (
                SELECT message_id FROM message_remote WHERE account=? AND remote_id IN (SELECT value FROM json_each(?))
            ) THEN 1 ELSE 0 END
            WHERE account=? AND in_inbox = 1 AND date >= ?
            """, [account, Self.json(Array(remoteIDs)), account, since.timeIntervalSince1970])
        }
    }

    // MARK: Provider IDs

    /// The local ID for a provider's message ID, if the store has it.
    func localID(account: String, remoteID: String) -> String? {
        sync { localIDLocked(account: account, remoteID: remoteID) }
    }

    private func localIDLocked(account: String, remoteID: String) -> String? {
        query("SELECT message_id FROM message_remote WHERE account=? AND remote_id=?", [account, remoteID]) { $0.text(0) }
            .first ?? nil
    }

    /// Provider ID → local ID, for the ones the store has.
    func localIDs(account: String, remoteIDs: [String]) -> [String: String] {
        guard !remoteIDs.isEmpty else { return [:] }
        return sync {
            Dictionary(query("""
                SELECT remote_id, message_id FROM message_remote
                WHERE account=? AND remote_id IN (SELECT value FROM json_each(?))
                """, [account, Self.json(remoteIDs)]) { ($0.text(0) ?? "", $0.text(1) ?? "") },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// Local ID → the provider's ID, for actions sent to the provider.
    func remoteIDs(for localIDs: [String]) -> [String: String] {
        guard !localIDs.isEmpty else { return [:] }
        return sync {
            Dictionary(query("""
                SELECT message_id, remote_id FROM message_remote
                WHERE message_id IN (SELECT value FROM json_each(?))
                """, [Self.json(localIDs)]) { ($0.text(0) ?? "", $0.text(1) ?? "") },
                uniquingKeysWith: { first, _ in first })
        }
    }

    func remoteID(for localID: String) -> String? { remoteIDs(for: [localID])[localID] }

    /// The provider IDs of the messages the store has in a conversation.
    func threadRemoteIDs(_ threadID: String, account: String) -> Set<String> {
        sync {
            Set(query("""
                SELECT r.remote_id FROM message_remote r JOIN messages m ON m.id = r.message_id
                WHERE m.account=? AND m.thread_id=?
                """, [account, threadID]) { $0.text(0) ?? "" })
        }
    }

    // MARK: Reading messages

    private static let summaryColumns = ([
        "id", "account", "thread_id", "date", "from_name", "from_email", "to_list", "cc_list", "reply_to",
        "subject", "snippet", "attachments", "category", "verified", "message_id_header", "refs",
        "list_unsubscribe", "is_unread", "is_flagged"
    ] + MailboxRole.allCases.map(\.column)).map { "messages.\($0)" }.joined(separator: ", ")
        + ", (SELECT group_concat(tag, char(10)) FROM message_tags t WHERE t.message_id = messages.id)"

    private static let withBody = "\(summaryColumns), b.text, b.html FROM messages LEFT JOIN message_bodies b ON b.message_id = messages.id"

    /// One message, with its body.
    func message(_ id: String) -> Message? {
        sync { query("SELECT \(Self.withBody) WHERE messages.id=?", [id], Self.row).first }
    }

    /// A mailbox, newest first, without bodies.
    func messages(in mailbox: Mailbox, account: String?, limit: Int = 600) -> [Message] {
        sync {
            var sql = "SELECT \(Self.summaryColumns) FROM messages WHERE \(mailbox.predicate)"
            var args: [Any?] = []
            if let account { sql += " AND account=?"; args.append(account) }
            sql += " ORDER BY date DESC LIMIT \(limit)"
            return query(sql, args, Self.row)
        }
    }

    /// A conversation, oldest first, with bodies. Drafts are left out.
    func thread(_ threadID: String, account: String) -> [Message] {
        sync {
            query("SELECT \(Self.withBody) WHERE messages.account=? AND messages.thread_id=? AND messages.in_drafts = 0 ORDER BY messages.date ASC",
                  [account, threadID], Self.row)
        }
    }

    func count(in mailbox: Mailbox, account: String?, unreadOnly: Bool = false) -> Int {
        sync {
            var sql = "SELECT COUNT(*) FROM messages WHERE \(mailbox.predicate)"
            var args: [Any?] = []
            if unreadOnly { sql += " AND is_unread = 1" }
            if let account { sql += " AND account=?"; args.append(account) }
            return query(sql, args) { $0.int(0) }.first ?? 0
        }
    }

    /// Full-text search over mail saved on this Mac — never the server.
    /// Each word is matched as a prefix, so "inv" finds "invoice".
    func search(_ text: String, account: String?, limit: Int = 200) -> [Message] {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
        guard !words.isEmpty else { return [] }
        return sync {
            var sql = """
            SELECT \(Self.summaryColumns)
            FROM message_search JOIN messages ON messages.rowid = message_search.rowid
            WHERE message_search MATCH ? AND messages.in_trash = 0 AND messages.in_spam = 0
            """
            var args: [Any?] = [words.joined(separator: " ")]
            if let account { sql += " AND messages.account=?"; args.append(account) }
            sql += " ORDER BY bm25(message_search, 6.0, 3.0, 1.0) + (julianday('now') - julianday(messages.date, 'unixepoch')) / 365.0 LIMIT \(limit)"
            return query(sql, args, Self.row)
        }
    }

    // MARK: Codes

    func saveCode(_ c: FoundCode) {
        sync { run("INSERT OR REPLACE INTO codes(message_id, code, sender, account, date) VALUES(?,?,?,?,?)",
                   [c.messageID, c.code, c.sender, c.account, c.date.timeIntervalSince1970]) }
    }

    func recentCodes(limit: Int = 5) -> [FoundCode] {
        sync {
            query("SELECT code, sender, message_id, account, date FROM codes ORDER BY date DESC LIMIT \(limit)") { s in
                FoundCode(code: s.text(0) ?? "", sender: s.text(1) ?? "", messageID: s.text(2) ?? "",
                          account: s.text(3) ?? "", date: Date(timeIntervalSince1970: s.double(4) ?? 0))
            }
        }
    }

    // MARK: Row mapping

    /// Columns as `summaryColumns` lists them, then optionally the body.
    private static func row(_ s: Row) -> Message {
        let roleStart: Int32 = 19
        var roles: Set<MailboxRole> = []
        for (offset, role) in MailboxRole.allCases.enumerated() where s.int(roleStart + Int32(offset)) == 1 {
            roles.insert(role)
        }
        let tagsColumn = roleStart + Int32(MailboxRole.allCases.count)
        let bodyColumn = tagsColumn + 1
        let hasBody = s.columnCount > bodyColumn
        return Message(
            id: s.text(0) ?? "", account: s.text(1) ?? "", threadID: s.text(2) ?? "",
            date: Date(timeIntervalSince1970: s.double(3) ?? 0),
            fromName: s.text(4) ?? "", fromEmail: s.text(5) ?? "",
            to: lines(s.text(6)), cc: lines(s.text(7)),
            replyTo: s.text(8), subject: s.text(9) ?? "", snippet: s.text(10) ?? "",
            bodyText: hasBody ? s.text(bodyColumn) ?? "" : "",
            bodyHTML: hasBody ? s.text(bodyColumn + 1) : nil,
            state: MailState(roles: roles, isUnread: s.int(17) == 1, isFlagged: s.int(18) == 1,
                             tags: Set(lines(s.text(tagsColumn)))),
            attachments: decodeAttachments(s.text(11)),
            category: MailCategory(rawValue: s.text(12) ?? "") ?? .people,
            verified: s.int(13) == 1, messageIDHeader: s.text(14), references: s.text(15),
            listUnsubscribe: s.text(16))
    }

    private static func lines(_ s: String?) -> [String] {
        (s ?? "").split(separator: "\n").map(String.init)
    }

    private static func decodeAttachments(_ s: String?) -> [Attachment] {
        s.flatMap { try? JSONDecoder().decode([Attachment].self, from: Data($0.utf8)) } ?? []
    }

    private static func json(_ values: [String]) -> String {
        (try? JSONEncoder().encode(values)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    // MARK: SQLite plumbing

    struct Row {
        let stmt: OpaquePointer?
        var columnCount: Int32 { sqlite3_column_count(stmt) }
        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func double(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Postline: SQL error \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(80))")
            return nil
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            default: sqlite3_bind_text(stmt, idx, "\(arg!)", -1, Self.transient)
            }
        }
        return stmt
    }

    @discardableResult
    private func run(_ sql: String, _ args: [Any?] = []) -> Bool {
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard stmt != nil else { return false }
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("Postline: SQL step error \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func query<T>(_ sql: String, _ args: [Any?] = [], _ map: (Row) -> T) -> [T] {
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            if let err {
                NSLog("Postline: SQL exec error \(String(cString: err))")
                sqlite3_free(err)
            }
            return false
        }
        return true
    }
}
