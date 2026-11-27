import XCTest
import OTPCore
import SQLite3
@testable import Postline

final class OTPTests: XCTestCase {
    func testFindsGoogleStyleCode() {
        let html = "<p>Use this code to finish signing in:</p><p style='font-size:28px;font-weight:600'>482913</p><p>The code expires in 10 minutes.</p>"
        XCTAssertEqual(OTPv2.detect(subject: "Your Google verification code", body: html, isHTML: true)?.value, "482913")
    }

    func testFindsPlainTextCodes() {
        let cases: [(String, String, String)] = [
            ("Sign in to Notion", "Your login code is 731904. It expires in 5 minutes.", "731904"),
            ("Sign in to Notion", "Your login code is 731-904. It expires in 5 minutes.", "731904"),
            ("Your code", "731904 is your verification code.", "731904"),
            ("Amazon", "Your one-time password is 551204", "551204"),
            ("Verify", "Use 4821 as your PIN to continue.", "4821")
        ]
        for (subject, body, expected) in cases {
            XCTAssertEqual(CodeFinder.find(subject: subject, text: body, html: nil)?.code, expected, body)
        }
    }

    func testIgnoresOrderNumbersPricesAndPhones() {
        for (subject, body) in [
            ("Your order #482913 has shipped", "Order 482913 total ₹1,299. Tracking 99887766."),
            ("Dinner on Friday?", "I booked a table for 8 at 2045 Main St."),
            ("Invoice", "Amount due $1299 for account 55102231. Pay by 2026."),
            ("Call me", "My phone is 98765 43210, code review at 4pm tomorrow")
        ] {
            XCTAssertNil(CodeFinder.find(subject: subject, text: body, html: nil), body)
        }
    }
}

final class ParserTests: XCTestCase {
    private func b64(_ s: String) -> String { Data(s.utf8).base64URLEncoded }

    private func raw(headers: [(String, String)], labels: [String], text: String? = "Hello", html: String? = nil, attachment: Bool = false) throws -> GmailAPI.RawMessage {
        var parts: [[String: Any]] = []
        if let text { parts.append(["partId": "0", "mimeType": "text/plain", "filename": "", "body": ["size": text.utf8.count, "data": b64(text)]]) }
        if let html { parts.append(["partId": "1", "mimeType": "text/html", "filename": "", "body": ["size": html.utf8.count, "data": b64(html)]]) }
        if attachment { parts.append(["partId": "2", "mimeType": "application/pdf", "filename": "invoice.pdf", "body": ["size": 1234, "attachmentId": "ATT"]]) }
        let json: [String: Any] = [
            "id": "m1", "threadId": "t1", "labelIds": labels, "snippet": "Hi &amp; welcome", "internalDate": "1700000000000",
            "payload": ["mimeType": "multipart/mixed", "headers": headers.map { ["name": $0.0, "value": $0.1] }, "parts": parts]
        ]
        return try JSONDecoder().decode(GmailAPI.RawMessage.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testParsesHeadersBodiesAndAttachments() throws {
        let m = MessageParser.parse(try raw(headers: [
            ("From", "\"Rico O.\" <Rico@Figma.com>"), ("To", "Harshit <h@x.com>, \"Doe, Jane\" <jane@x.com>"),
            ("Subject", "=?UTF-8?B?8J+OiSBXZWxjb21l?="), ("Authentication-Results", "mx.google.com; dkim=pass; spf=pass; dmarc=pass (p=REJECT)")
        ], labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], html: "<p>Hi</p>", attachment: true), account: "me@x.com").message
        XCTAssertEqual(m.fromName, "Rico O.")
        XCTAssertEqual(m.fromEmail, "rico@figma.com")
        XCTAssertEqual(m.to.count, 2, "a comma inside quotes must not split an address")
        XCTAssertEqual(m.subject, "🎉 Welcome")
        XCTAssertEqual(m.snippet, "Hi & welcome")
        XCTAssertEqual(m.bodyText, "Hello")
        XCTAssertEqual(m.bodyHTML, "<p>Hi</p>")
        XCTAssertEqual(m.attachments.first?.filename, "invoice.pdf")
        XCTAssertTrue(m.verified)
        XCTAssertTrue(m.isUnread)
        XCTAssertEqual(m.category, .people)
        XCTAssertEqual(m.date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testBuckets() throws {
        let promo = MessageParser.parse(try raw(headers: [("From", "Shop <deals@shop.com>"), ("Subject", "Sale")], labels: ["INBOX", "CATEGORY_PROMOTIONS"]), account: "a").message
        XCTAssertEqual(promo.category, .newsletters)
        let update = MessageParser.parse(try raw(headers: [("From", "GitHub <noreply@github.com>"), ("Subject", "Build passed")], labels: ["INBOX", "CATEGORY_UPDATES"]), account: "a").message
        XCTAssertEqual(update.category, .notifications)
        let list = MessageParser.parse(try raw(headers: [("From", "Substack <read@substack.com>"), ("Subject", "Weekly"), ("List-Unsubscribe", "<https://x>")], labels: ["INBOX"]), account: "a").message
        XCTAssertEqual(list.category, .newsletters)
        let invite = MessageParser.parse(try raw(headers: [("From", "Cal <a@cal.com>"), ("Subject", "Invitation: Review @ Thu")], labels: ["INBOX"]), account: "a").message
        XCTAssertEqual(invite.category, .invitations)
        let person = MessageParser.parse(try raw(headers: [("From", "Sam <sam@example.com>"), ("Subject", "Dinner?")], labels: ["INBOX"]), account: "a").message
        XCTAssertEqual(person.category, .people)
        XCTAssertFalse(person.verified)
    }

    func testFetchedMailUsesArrivalTime() {
        // Gmail's fetcher keeps the written time (3:54 PM) as internalDate; Received: has the real arrival (9:19 PM).
        let written = String(Int(MessageParser.parseRFC2822("Thu, 12 Nov 2026 10:24:50 +0000")!.timeIntervalSince1970 * 1000))
        let d = MessageParser.arrivalDate(internalDate: written, headers: ["received": "from pop.secureserver.net by mx.google.com with POP3 id x; Thu, 12 Nov 2026 07:49:12 -0800 (PST)"])
        XCTAssertEqual(d, MessageParser.parseRFC2822("Thu, 12 Nov 2026 15:49:12 +0000"))
        // Normal mail: Received ≈ internalDate, so internalDate stands.
        XCTAssertEqual(MessageParser.arrivalDate(internalDate: "1700000000000", headers: [:]), Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testHTMLOnlyMailGetsSearchableText() throws {
        let m = MessageParser.parse(try raw(headers: [("From", "x@y.com")], labels: ["INBOX"], text: nil,
                                            html: "<style>p{}</style><p>Your code&nbsp;is</p><b>123</b>"), account: "a").message
        XCTAssertEqual(m.bodyText, "Your code is\n 123")
    }
}

final class StoreTests: XCTestCase {
    private func fetched(_ id: String, labels: Set<String>, subject: String, body: String, minutesAgo: Double = 1,
                         thread: String? = nil, to: [String] = []) -> FetchedMessage {
        FetchedMessage(remoteID: id, message: Message(
            id: "", account: "me@x.com", threadID: thread ?? id, date: Date().addingTimeInterval(-minutesAgo * 60),
            fromName: "Rico", fromEmail: "rico@figma.com", to: to, cc: [], replyTo: nil, subject: subject,
            snippet: body, bodyText: body, bodyHTML: nil,
            state: GmailMapping.state(labels: labels, to: to, account: "me@x.com"), attachments: [], category: .people,
            verified: true, messageIDHeader: nil, references: nil, listUnsubscribe: nil))
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("postline-test-\(UUID()).sqlite").path
    }

    /// Provider IDs of a list of messages, for readable assertions.
    private func remote(_ messages: [Message], _ store: Store) -> [String] {
        let map = store.remoteIDs(for: messages.map(\.id))
        return messages.map { map[$0.id] ?? "?" }
    }

    func testMailboxesSearchAndState() throws {
        let store = Store(path: temporaryPath())
        store.save(Account(email: "me@x.com", name: "Me", pictureURL: nil, historyID: "42", sendAs: [SendAs(email: "hello@me.com", name: "Me", isDefault: true)]))
        XCTAssertEqual(store.accounts().first?.sendAs.first?.email, "hello@me.com")

        let saved = store.ingest([
            fetched("a", labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], subject: "Invoice for October", body: "Please find the invoice attached"),
            fetched("b", labels: ["SENT"], subject: "Re: Invoice", body: "Thanks!", minutesAgo: 2, thread: "a"),
            fetched("c", labels: ["TRASH"], subject: "Old invoice", body: "gone")
        ])
        XCTAssertEqual(remote(store.messages(in: .inbox, account: nil), store), ["a"])
        XCTAssertEqual(remote(store.messages(in: .sent, account: nil), store), ["b"])
        XCTAssertEqual(remote(store.messages(in: .trash, account: nil), store), ["c"])
        XCTAssertEqual(store.count(in: .inbox, account: nil, unreadOnly: true), 1)
        XCTAssertEqual(remote(store.thread("a", account: "me@x.com"), store), ["b", "a"])

        // Lists carry no bodies; a conversation does. Tags come back with both.
        let listed = try XCTUnwrap(store.messages(in: .inbox, account: nil).first)
        XCTAssertEqual(listed.bodyText, "")
        XCTAssertEqual(listed.state.tags, ["CATEGORY_PERSONAL"])
        XCTAssertEqual(store.thread("a", account: "me@x.com").last?.bodyText, "Please find the invoice attached")

        // Prefix search, and Trash stays out of results.
        XCTAssertEqual(Set(remote(store.search("invo", account: nil), store)), ["a", "b"])
        XCTAssertEqual(store.search("figma", account: nil).count, 2, "sender address is searchable")

        // Archive: the role goes, the mail moves, the tags stay.
        let a = saved[0]
        var archived = a.state
        archived.roles = [.archive]
        store.setState(a.id, archived)
        XCTAssertTrue(store.messages(in: .inbox, account: nil).isEmpty)
        XCTAssertEqual(store.messages(in: .archive, account: nil).map(\.id), [a.id])
        XCTAssertEqual(store.message(a.id)?.state.tags, ["CATEGORY_PERSONAL"])

        // Speed: 2,000 messages written, then a mailbox and a search read.
        store.ingest((0..<2000).map { fetched("bulk\($0)", labels: ["INBOX"], subject: "Weekly digest \($0)", body: String(repeating: "lorem ipsum ", count: 80), minutesAgo: Double($0)) })
        let t0 = Date()
        let inbox = store.messages(in: .inbox, account: nil)
        let t1 = Date()
        let hits = store.search("digest", account: nil)
        let t2 = Date()
        XCTAssertEqual(inbox.count, 600)
        XCTAssertFalse(hits.isEmpty)
        print("MEASURED inbox(600 of 2000) = \(Int(t1.timeIntervalSince(t0) * 1000)) ms, search = \(Int(t2.timeIntervalSince(t1) * 1000)) ms")
        XCTAssertLessThan(t1.timeIntervalSince(t0), 0.25)
        XCTAssertLessThan(t2.timeIntervalSince(t1), 0.25)
    }

    func testLocalIDsStayWhenAMessageIsFetchedAgain() throws {
        let store = Store(path: temporaryPath())
        let first = store.ingest([fetched("g1", labels: ["INBOX", "UNREAD"], subject: "Hello", body: "one")])[0]
        XCTAssertNotEqual(first.id, "g1", "the local ID is Postline's own")
        XCTAssertEqual(store.localID(account: "me@x.com", remoteID: "g1"), first.id)
        XCTAssertEqual(store.remoteID(for: first.id), "g1")

        let again = store.ingest([fetched("g1", labels: ["INBOX"], subject: "Hello again", body: "two")])[0]
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(store.message(first.id)?.subject, "Hello again")
        XCTAssertEqual(store.search("again", account: nil).map(\.id), [first.id], "the search entry is replaced, not duplicated")
        XCTAssertTrue(store.search("one", account: nil).isEmpty)

        store.delete(ids: [first.id])
        XCTAssertNil(store.message(first.id))
        XCTAssertNil(store.localID(account: "me@x.com", remoteID: "g1"))
        XCTAssertTrue(store.search("again", account: nil).isEmpty)
    }

    func testPrimaryTabByGmailIDs() {
        let store = Store(path: temporaryPath())
        let saved = store.ingest([
            fetched("p", labels: ["INBOX", "CATEGORY_UPDATES"], subject: "Kept in Primary", body: ""),
            fetched("o", labels: ["INBOX", "CATEGORY_UPDATES"], subject: "Not Primary", body: "")
        ])
        XCTAssertEqual(store.messages(in: .inbox, account: nil).count, 2, "until Gmail answers, Updates count as Primary")
        store.markPrimary(account: "me@x.com", primary: ["p"], since: .distantPast)
        XCTAssertEqual(store.messages(in: .inbox, account: nil).map(\.id), [saved[0].id])
        XCTAssertEqual(store.messages(in: .other, account: nil).map(\.id), [saved[1].id])
    }

    func testEmptyPrimaryAnswerFallsBackToCategoryLabels() {
        let store = Store(path: temporaryPath())
        let saved = store.ingest([
            fetched("p", labels: ["INBOX", "CATEGORY_PERSONAL"], subject: "From a person", body: ""),
            fetched("o", labels: ["INBOX", "CATEGORY_PROMOTIONS"], subject: "Sale", body: "")
        ])
        store.markPrimary(account: "me@x.com", primary: ["o"], since: .distantPast)
        XCTAssertEqual(store.messages(in: .inbox, account: nil).map(\.id), [saved[1].id])
        // Gmail finds no Primary mail at all: its answer is set aside.
        store.markPrimary(account: "me@x.com", primary: [], since: .distantPast)
        XCTAssertEqual(store.messages(in: .inbox, account: nil).map(\.id), [saved[0].id])
        XCTAssertEqual(store.messages(in: .other, account: nil).map(\.id), [saved[1].id])
    }

    func testMigratesVersion1Database() throws {
        let path = temporaryPath()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let v1 = """
        CREATE TABLE accounts(email TEXT PRIMARY KEY, name TEXT, picture TEXT, history_id TEXT,
            imported_since REAL, send_as TEXT, position INTEGER DEFAULT 0);
        CREATE TABLE messages(id TEXT PRIMARY KEY, account TEXT NOT NULL, thread_id TEXT NOT NULL,
            date REAL NOT NULL, from_name TEXT, from_email TEXT, to_list TEXT, cc_list TEXT,
            reply_to TEXT, subject TEXT, snippet TEXT, body_text TEXT, body_html TEXT,
            labels TEXT NOT NULL, attachments TEXT, category TEXT NOT NULL,
            verified INTEGER NOT NULL DEFAULT 0, message_id_header TEXT, refs TEXT,
            list_unsubscribe TEXT, primary_tab INTEGER);
        CREATE INDEX messages_date ON messages(date DESC);
        CREATE INDEX messages_thread ON messages(account, thread_id);
        CREATE VIRTUAL TABLE messages_fts USING fts5(id UNINDEXED, subject, sender, body);
        CREATE TABLE codes(message_id TEXT PRIMARY KEY, code TEXT, sender TEXT, account TEXT, date REAL);
        INSERT INTO accounts(email, name, history_id) VALUES('me@x.com', 'Me', '99');
        INSERT INTO messages VALUES('m1', 'me@x.com', 't1', 1700000000, 'Rico', 'rico@figma.com', 'me@x.com', '',
            NULL, 'Quarterly report', 'snip', 'The report is attached', '<p>Report</p>',
            ' CATEGORY_UPDATES INBOX STARRED UNREAD ', '[]', 'people', 1, '<m1@x>', NULL, NULL, 1);
        INSERT INTO messages VALUES('m2', 'me@x.com', 't2', 1700000100, 'Me', 'me@x.com', 'ana@x.com', '',
            NULL, 'Sent note', 'snip', 'Hi Ana', NULL, ' SENT ', '[]', 'people', 0, NULL, NULL, NULL, NULL);
        INSERT INTO messages VALUES('m3', 'me@x.com', 't3', 1700000200, 'Bo', 'bo@x.com', 'me@x.com', '',
            NULL, 'Old thing', 'snip', 'archived body', NULL, ' Label_7 ', '[]', 'people', 0, NULL, NULL, NULL, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, v1, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = Store(path: path)
        XCTAssertEqual(store.accounts().first?.historyID, "99")
        let m1 = try XCTUnwrap(store.message("m1"), "a migrated message keeps its ID")
        XCTAssertEqual(m1.state, MailState(roles: [.inbox], isUnread: true, isFlagged: true, tags: ["CATEGORY_UPDATES"]))
        XCTAssertEqual(m1.bodyText, "The report is attached")
        XCTAssertEqual(m1.bodyHTML, "<p>Report</p>")
        XCTAssertEqual(store.remoteID(for: "m1"), "m1")
        XCTAssertEqual(store.messages(in: .inbox, account: nil).map(\.id), ["m1"], "Gmail's Primary answer is kept")
        XCTAssertEqual(store.messages(in: .sent, account: nil).map(\.id), ["m2"])
        XCTAssertEqual(store.messages(in: .archive, account: nil).map(\.id), ["m3"], "sent mail to others is not archived")
        XCTAssertEqual(store.message("m3")?.state.tags, ["Label_7"])
        XCTAssertEqual(store.search("report", account: nil).map(\.id), ["m1"])
        XCTAssertEqual(store.search("archived", account: nil).map(\.id), ["m3"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: (path as NSString).deletingPathExtension + "-v1-backup.sqlite"))

        // Opening it again changes nothing.
        let reopened = Store(path: path)
        XCTAssertEqual(reopened.messages(in: .inbox, account: nil).map(\.id), ["m1"])
    }
}

final class GmailMappingTests: XCTestCase {
    func testLabelsBecomeRolesFlagsAndTags() {
        let s = GmailMapping.state(labels: ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "Label_3"], to: [], account: "me@x.com")
        XCTAssertEqual(s, MailState(roles: [.inbox], isUnread: true, isFlagged: true, tags: ["IMPORTANT", "Label_3"]))
        XCTAssertEqual(GmailMapping.labels(for: s), ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "Label_3"])
    }

    func testArchiveIsTheAbsenceOfInbox() {
        XCTAssertEqual(GmailMapping.state(labels: [], to: [], account: "me@x.com").roles, [.archive])
        XCTAssertEqual(GmailMapping.state(labels: ["TRASH"], to: [], account: "me@x.com").roles, [.trash])
        XCTAssertEqual(GmailMapping.state(labels: ["SENT"], to: ["ana@x.com"], account: "me@x.com").roles, [.sent])
        XCTAssertEqual(GmailMapping.state(labels: ["SENT"], to: ["Me <ME@x.com>"], account: "me@x.com").roles, [.sent, .archive],
                       "mail sent to yourself and archived stays findable")
        XCTAssertFalse(GmailMapping.labels(for: MailState(roles: [.archive])).contains("ARCHIVE"))
    }

    func testNormalisingDropsArchiveFromSentMail() {
        let archivedSent = MailState(roles: [.sent, .archive])
        XCTAssertEqual(GmailMapping.normalised(archivedSent, to: ["ana@x.com"], account: "me@x.com").roles, [.sent])
    }
}

final class OutgoingTests: XCTestCase {
    func testMIMEForReplyFromAlias() throws {
        let original = Message(id: "m", account: "me@gmail.com", threadID: "t", date: Date(), fromName: "Rico", fromEmail: "rico@figma.com",
                               to: ["Harshit <hello@example.com>"], cc: ["Ana <ana@figma.com>"], replyTo: nil, subject: "Feedback",
                               snippet: "", bodyText: "Line one\nLine two", bodyHTML: nil, state: MailState(roles: [.inbox]), attachments: [],
                               category: .people, verified: true, messageIDHeader: "<abc@figma.com>", references: "<root@figma.com>", listUnsubscribe: nil)
        let account = Account(email: "me@gmail.com", name: "Harshit", pictureURL: nil, historyID: nil,
                              sendAs: [SendAs(email: "me@gmail.com", name: "Harshit", isDefault: false),
                                       SendAs(email: "hello@example.com", name: "Harshit Maurya", isDefault: true)])
        let draft = Draft.reply(to: original, all: true, account: account)
        XCTAssertEqual(draft.from.email, "hello@example.com", "replies go out from the address the mail was sent to")
        XCTAssertEqual(draft.to, "rico@figma.com")
        XCTAssertEqual(draft.cc, "Ana <ana@figma.com>")
        XCTAssertEqual(draft.subject, "Re: Feedback")
        XCTAssertEqual(draft.references, "<root@figma.com> <abc@figma.com>")

        let mime = String(decoding: try draft.mime(), as: UTF8.self)
        XCTAssertTrue(mime.contains("From: Harshit Maurya <hello@example.com>"))
        XCTAssertTrue(mime.contains("In-Reply-To: <abc@figma.com>"))
        XCTAssertTrue(mime.contains("Content-Type: text/plain; charset=UTF-8"))
        XCTAssertEqual(Draft.encodeWord("Café"), "=?UTF-8?B?Q2Fmw6k=?=")
    }

    func testRootDomain() {
        XCTAssertEqual(Avatars.rootDomain(of: "a@mail.notion.so"), "notion.so")
        XCTAssertEqual(Avatars.rootDomain(of: "alerts@txn.bank.co.in"), "bank.co.in")
        XCTAssertEqual(Avatars.rootDomain(of: "x@gmail.com"), "gmail.com")
    }
}

@MainActor
final class WritingTests: XCTestCase {
    typealias C = SmartEditor.Coordinator

    func testOnlyFinishedSentencesBeforeTheCursorAreChecked() {
        let text = "i has send the file. they was happy with it\nanother line here"
        // Cursor at the very end: the first sentence and the first line are finished; the last line is being typed.
        let ranges = C.finishedSentences(in: text, caret: (text as NSString).length)
        let found = ranges.map { (text as NSString).substring(with: $0).trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(found, ["i has send the file.", "they was happy with it"])
        // Cursor inside the first sentence: nothing is touched.
        XCTAssertTrue(C.finishedSentences(in: text, caret: 5).isEmpty)
    }

    func testQuotedReplyIsNeverEdited() {
        let text = "sounds good see you there.\n\nOn Nov 12, 2026 at 4:18 PM, Rico <rico@figma.com> wrote:\n> are we still on for friday."
        let end = C.writableEnd(of: text)
        XCTAssertEqual((text as NSString).substring(to: end), "sounds good see you there.\n")
        let found = C.finishedSentences(in: text, caret: (text as NSString).length).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(found, ["sounds good see you there."])
    }

    func testModelOutputCleanup() {
        XCTAssertEqual(Writer.clean("1. Sounds good, see you then!"), "Sounds good, see you then!")
        XCTAssertEqual(Writer.clean("- \"Can we move it to Saturday?\""), "Can we move it to Saturday?")
        XCTAssertEqual(Writer.stripThinking("<think>hmm</think>\nYes, works for me."), "Yes, works for me.")
        XCTAssertEqual(Writer.newestPart(of: "Perfect, see you then\n\nOn Thu, Sam wrote:\n> booked a table"), "Perfect, see you then")
    }

    func testNoInventedNumbers() {
        // Seen live: "i will be there by" → " 9:00 AM sharp." with no time anywhere.
        XCTAssertTrue(Writer.inventsNumbers(" 9:00 AM sharp.", source: "I booked a table for 8. i will be there by"))
        XCTAssertFalse(Writer.inventsNumbers(" 8 then.", source: "I booked a table for 8."))
        XCTAssertFalse(Writer.inventsNumbers("Sounds good, see you then!", source: "Dinner on Friday?"))
    }
}

/// The menu bar icon's two five-minute windows (owner, 2026-11-14).
final class MenuIconClockTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testMailShowsForFiveMinutesThenGoes() {
        var c = MenuIconClock()
        XCTAssertFalse(c.visible)
        c.mail(at: t0)
        c.expire(at: t0 + 299)
        XCTAssertTrue(c.visible)
        XCTAssertFalse(c.showsCode)
        c.expire(at: t0 + 300)
        XCTAssertFalse(c.visible)
    }

    func testCodeShowsForFiveMinutesOrUntilCopied() {
        var c = MenuIconClock()
        c.code(at: t0)
        XCTAssertEqual(c.nextChange, t0 + 300)
        c.codeDone()
        XCTAssertFalse(c.visible)
        c.code(at: t0)
        c.expire(at: t0 + 300)
        XCTAssertFalse(c.visible)
    }

    func testEachWindowRunsOnItsOwn() {
        var c = MenuIconClock()
        c.mail(at: t0)
        c.code(at: t0 + 120)
        // Copying the code leaves the mail window running.
        c.codeDone()
        XCTAssertTrue(c.visible)
        XCTAssertEqual(c.nextChange, t0 + 300)
        // Newer mail restarts the mail window from that moment.
        c.mail(at: t0 + 240)
        c.expire(at: t0 + 400)
        XCTAssertTrue(c.visible)
        c.expire(at: t0 + 540)
        XCTAssertFalse(c.visible)
    }

    func testHideClearsBoth() {
        var c = MenuIconClock()
        c.mail(at: t0); c.code(at: t0)
        c.clear()
        XCTAssertFalse(c.visible)
        XCTAssertNil(c.nextChange)
    }
}

final class RemoteContentTests: XCTestCase {
    func testDetectsRemoteImagesStylesAndFonts() {
        for html in [
            #"<img src="https://t.example.com/open.gif" width="1" height="1">"#,
            #"<img src='//cdn.example.com/logo.png'>"#,
            #"<img srcset="https://example.com/a.png 2x">"#,
            #"<td background="http://example.com/bg.jpg">"#,
            #"<div style="background-image: url('https://example.com/bg.png')">"#,
            #"<link rel="stylesheet" href="https://example.com/mail.css">"#,
            #"<style>@import url("https://fonts.example.com/f.css");</style>"#
        ] {
            XCTAssertTrue(HTMLView.referencesRemoteContent(html), html)
        }
    }

    func testIgnoresLinksAndEmbeddedImages() {
        for html in [
            #"<a href="https://example.com/unsubscribe">Unsubscribe</a>"#,
            #"<img src="cid:logo@example.com">"#,
            #"<img src="data:image/png;base64,iVBORw0KGgo=">"#,
            "<p>See https://example.com for details</p>"
        ] {
            XCTAssertFalse(HTMLView.referencesRemoteContent(html), html)
        }
    }

    func testBlockedPolicyAllowsNoNetworkSources() {
        let policy = HTMLView.contentPolicy(allowsRemoteContent: false)
        XCTAssertTrue(policy.hasPrefix("default-src 'none'"))
        XCTAssertFalse(policy.contains("*"))
        XCTAssertFalse(policy.contains("http"))
        XCTAssertTrue(HTMLView.wrap("<p>hi</p>").contains(policy))
    }

    func testAllowedPolicyStillBlocksScriptsAndFrames() {
        let policy = HTMLView.contentPolicy(allowsRemoteContent: true)
        XCTAssertTrue(policy.hasPrefix("default-src 'none'"))
        XCTAssertFalse(policy.contains("script-src"))
        XCTAssertFalse(policy.contains("frame-src"))
    }

    func testOnlyWebAndMailLinksOpenExternally() {
        XCTAssertTrue(HTMLView.opensExternally(URL(string: "https://example.com")!))
        XCTAssertTrue(HTMLView.opensExternally(URL(string: "mailto:someone@example.com")!))
        XCTAssertFalse(HTMLView.opensExternally(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(HTMLView.opensExternally(URL(string: "javascript:alert(1)")!))
    }
}

final class TrackingImageFilterTests: XCTestCase {
    func testRemovesPixelsByShape() {
        for tag in [
            #"<img src="https://e.example.com/o/abc123" width="1" height="1">"#,
            #"<img width=1 height=1 src=https://e.example.com/x>"#,
            #"<img src="https://e.example.com/x" width="0" height="0" border="0">"#,
            #"<img src="https://e.example.com/x" width="1">"#,
            #"<img src="https://e.example.com/x" style="width:1px;height:1px">"#,
            #"<img src="https://e.example.com/x" style="display: none">"#,
            #"<img src="https://e.example.com/x" style="visibility:hidden">"#,
            #"<img src="https://e.example.com/x" style="opacity:0;">"#,
            #"<img src="//e.example.com/x" style="max-height:0px;overflow:hidden">"#
        ] {
            XCTAssertTrue(TrackingImageFilter.isTracker(tag), tag)
        }
    }

    func testRemovesKnownTrackingAddresses() {
        for tag in [
            #"<img src="https://example.us1.list-manage.com/track/open.php?u=1&id=2&e=3">"#,
            #"<img src="https://u123.ct.sendgrid.net/wf/open?upn=abc" alt="">"#,
            #"<img src="https://mailtrack.io/trace/mail/abc.png">"#,
            #"<img src="https://news.example.com/pixel.gif?id=9">"#
        ] {
            XCTAssertTrue(TrackingImageFilter.isTracker(tag), tag)
        }
    }

    func testKeepsRealImagesSpacersAndEmbeddedImages() {
        for tag in [
            #"<img src="https://cdn.example.com/hero.jpg" width="600" height="300">"#,
            #"<img src="https://cdn.example.com/logo.png">"#,
            #"<img src="https://cdn.example.com/spacer.gif" width="1" height="20">"#,
            #"<img src="https://cdn.example.com/a.png" style="max-width:100%;height:auto">"#,
            #"<img src="cid:logo@example.com" width="1" height="1">"#,
            #"<img src="data:image/gif;base64,R0lGOD" width="1" height="1">"#
        ] {
            XCTAssertFalse(TrackingImageFilter.isTracker(tag), tag)
        }
    }

    func testStripRemovesOnlyTrackers() {
        let html = #"<p>Hi</p><img src="https://cdn.example.com/hero.jpg" width="600"><img src="https://t.example.com/o.gif" width="1" height="1"><p>Bye</p>"#
        let result = TrackingImageFilter.strip(html)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.html, #"<p>Hi</p><img src="https://cdn.example.com/hero.jpg" width="600"><p>Bye</p>"#)
    }
}
