import Foundation
import SQLite3

/// Every message Postline has seen, on this Mac, in one SQLite file.
///
/// This is where the speed comes from: opening, listing and searching mail
/// never wait on the network. Bodies are stored with the message, so a click
/// reads one row. Search is SQLite's FTS5 over subject, sender and body.
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

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "postline.store")
    private let key = DispatchSpecificKey<Bool>()

    init(path: String) {
        queue.setSpecific(key: key, value: true)
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        migrate()
    }

    deinit { sqlite3_close(db) }

    private func sync<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: key) == true ? body() : queue.sync(execute: body)
    }

    // MARK: Schema

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS accounts(
            email TEXT PRIMARY KEY, name TEXT, picture TEXT, history_id TEXT,
            imported_since REAL, send_as TEXT, position INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS messages(
            id TEXT PRIMARY KEY, account TEXT NOT NULL, thread_id TEXT NOT NULL,
            date REAL NOT NULL, from_name TEXT, from_email TEXT, to_list TEXT, cc_list TEXT,
            reply_to TEXT, subject TEXT, snippet TEXT, body_text TEXT, body_html TEXT,
            labels TEXT NOT NULL, attachments TEXT, category TEXT NOT NULL,
            verified INTEGER NOT NULL DEFAULT 0, message_id_header TEXT, refs TEXT,
            list_unsubscribe TEXT);
        CREATE INDEX IF NOT EXISTS messages_date ON messages(date DESC);
        CREATE INDEX IF NOT EXISTS messages_thread ON messages(account, thread_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            id UNINDEXED, subject, sender, body, tokenize = 'unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS codes(
            message_id TEXT PRIMARY KEY, code TEXT, sender TEXT, account TEXT, date REAL);
        """)
        // Added 2026-11-13: Gmail's own answer to "is this in Primary?"
        // (1 / 0, NULL until asked).
        let columns = query("PRAGMA table_info(messages)") { $0.text(1) ?? "" }
        if !columns.contains("primary_tab") { exec("ALTER TABLE messages ADD COLUMN primary_tab INTEGER") }
    }

    /// Records Gmail's Primary tab for an account: the listed ids are
    /// Primary, every other Inbox message since `since` is not.
    func markPrimary(account: String, primary: Set<String>, since: Date) {
        let list = primary.filter { $0.allSatisfy { $0.isHexDigit } }.map { "'\($0)'" }.joined(separator: ",")
        sync {
            run("UPDATE messages SET primary_tab = CASE WHEN id IN (\(list.isEmpty ? "''" : list)) THEN 1 ELSE 0 END WHERE account=? AND labels LIKE '% INBOX %' AND date >= ?",
                [account, since.timeIntervalSince1970])
        }
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
            run("DELETE FROM messages_fts WHERE id IN (SELECT id FROM messages WHERE account=?)", [email])
            run("DELETE FROM messages WHERE account=?", [email])
            run("DELETE FROM codes WHERE account=?", [email])
            run("DELETE FROM accounts WHERE email=?", [email])
            exec("COMMIT")
        }
    }

    // MARK: Messages

    private static let columns = """
    id, account, thread_id, date, from_name, from_email, to_list, cc_list, reply_to, subject,
    snippet, body_text, body_html, labels, attachments, category, verified, message_id_header,
    refs, list_unsubscribe
    """

    func upsert(_ messages: [Message]) {
        guard !messages.isEmpty else { return }
        sync {
            exec("BEGIN")
            for m in messages {
                run("INSERT OR REPLACE INTO messages(\(Self.columns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    m.id, m.account, m.threadID, m.date.timeIntervalSince1970, m.fromName, m.fromEmail,
                    m.to.joined(separator: "\n"), m.cc.joined(separator: "\n"), m.replyTo, m.subject,
                    m.snippet, m.bodyText, m.bodyHTML, Self.encode(m.labels),
                    (try? JSONEncoder().encode(m.attachments)).map { String(decoding: $0, as: UTF8.self) },
                    m.category.rawValue, m.verified ? 1 : 0, m.messageIDHeader, m.references, m.listUnsubscribe
                ])
                run("DELETE FROM messages_fts WHERE id=?", [m.id])
                run("INSERT INTO messages_fts(id, subject, sender, body) VALUES(?,?,?,?)",
                    [m.id, m.subject, "\(m.fromName) \(m.fromEmail)", String(m.bodyText.prefix(20_000))])
            }
            exec("COMMIT")
        }
    }

    /// Labels are stored as " A B C " so a mailbox is one LIKE on an index-free
    /// but tiny column; a personal mailbox stays well inside a millisecond.
    static func encode(_ labels: Set<String>) -> String { " " + labels.sorted().joined(separator: " ") + " " }
    static func decode(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    func setDate(_ id: String, _ date: Date) {
        sync { run("UPDATE messages SET date=? WHERE id=?", [date.timeIntervalSince1970, id]) }
    }

    func setLabels(_ id: String, _ labels: Set<String>) {
        sync { run("UPDATE messages SET labels=? WHERE id=?", [Self.encode(labels), id]) }
    }

    func delete(ids: [String]) {
        sync {
            exec("BEGIN")
            for id in ids {
                run("DELETE FROM messages WHERE id=?", [id])
                run("DELETE FROM messages_fts WHERE id=?", [id])
            }
            exec("COMMIT")
        }
    }

    func has(_ id: String) -> Bool {
        sync { query("SELECT 1 FROM messages WHERE id=?", [id]) { _ in true }.first ?? false }
    }

    func message(_ id: String) -> Message? {
        sync { query("SELECT \(Self.columns) FROM messages WHERE id=?", [id], Self.row).first }
    }

    func messages(in mailbox: Mailbox, account: String?, limit: Int = 600) -> [Message] {
        sync {
            var sql = "SELECT \(Self.columns) FROM messages WHERE \(mailbox.predicate)"
            var args: [Any?] = []
            if let account { sql += " AND account=?"; args.append(account) }
            sql += " ORDER BY date DESC LIMIT \(limit)"
            return query(sql, args, Self.row)
        }
    }

    func thread(_ threadID: String, account: String) -> [Message] {
        sync {
            query("SELECT \(Self.columns) FROM messages WHERE account=? AND thread_id=? AND labels NOT LIKE '% DRAFT %' ORDER BY date ASC",
                  [account, threadID], Self.row)
        }
    }

    func threadMessageIDs(_ threadID: String, account: String) -> Set<String> {
        sync { Set(query("SELECT id FROM messages WHERE account=? AND thread_id=?", [account, threadID]) { $0.text(0) ?? "" }) }
    }

    func count(in mailbox: Mailbox, account: String?, unreadOnly: Bool = false) -> Int {
        sync {
            var sql = "SELECT COUNT(*) FROM messages WHERE \(mailbox.predicate)"
            var args: [Any?] = []
            if unreadOnly { sql += " AND labels LIKE '% UNREAD %'" }
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
            SELECT \(Self.columns.split(separator: ",").map { "m." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", "))
            FROM messages_fts f JOIN messages m ON m.id = f.id
            WHERE messages_fts MATCH ? AND m.labels NOT LIKE '% TRASH %' AND m.labels NOT LIKE '% SPAM %'
            """
            var args: [Any?] = [words.joined(separator: " ")]
            if let account { sql += " AND m.account=?"; args.append(account) }
            sql += " ORDER BY bm25(messages_fts, 0.0, 6.0, 3.0, 1.0) + (julianday('now') - julianday(m.date, 'unixepoch')) / 365.0 LIMIT \(limit)"
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

    private static func row(_ s: Row) -> Message {
        Message(
            id: s.text(0) ?? "", account: s.text(1) ?? "", threadID: s.text(2) ?? "",
            date: Date(timeIntervalSince1970: s.double(3) ?? 0),
            fromName: s.text(4) ?? "", fromEmail: s.text(5) ?? "",
            to: (s.text(6) ?? "").split(separator: "\n").map(String.init),
            cc: (s.text(7) ?? "").split(separator: "\n").map(String.init),
            replyTo: s.text(8), subject: s.text(9) ?? "", snippet: s.text(10) ?? "",
            bodyText: s.text(11) ?? "", bodyHTML: s.text(12), labels: decode(s.text(13) ?? ""),
            attachments: s.text(14).flatMap { try? JSONDecoder().decode([Attachment].self, from: Data($0.utf8)) } ?? [],
            category: MailCategory(rawValue: s.text(15) ?? "") ?? .people,
            verified: s.int(16) == 1, messageIDHeader: s.text(17), references: s.text(18),
            listUnsubscribe: s.text(19))
    }

    // MARK: SQLite plumbing

    struct Row {
        let stmt: OpaquePointer?
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

    private func run(_ sql: String, _ args: [Any?] = []) {
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE, stmt != nil {
            NSLog("Postline: SQL step error \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func query<T>(_ sql: String, _ args: [Any?] = [], _ map: (Row) -> T) -> [T] {
        let stmt = prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            NSLog("Postline: SQL exec error \(String(cString: err))")
            sqlite3_free(err)
        }
    }
}
