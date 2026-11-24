import XCTest
import OTPCore
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
        ], labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], html: "<p>Hi</p>", attachment: true), account: "me@x.com")
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
        let promo = MessageParser.parse(try raw(headers: [("From", "Shop <deals@shop.com>"), ("Subject", "Sale")], labels: ["INBOX", "CATEGORY_PROMOTIONS"]), account: "a")
        XCTAssertEqual(promo.category, .newsletters)
        let update = MessageParser.parse(try raw(headers: [("From", "GitHub <noreply@github.com>"), ("Subject", "Build passed")], labels: ["INBOX", "CATEGORY_UPDATES"]), account: "a")
        XCTAssertEqual(update.category, .notifications)
        let list = MessageParser.parse(try raw(headers: [("From", "Substack <read@substack.com>"), ("Subject", "Weekly"), ("List-Unsubscribe", "<https://x>")], labels: ["INBOX"]), account: "a")
        XCTAssertEqual(list.category, .newsletters)
        let invite = MessageParser.parse(try raw(headers: [("From", "Cal <a@cal.com>"), ("Subject", "Invitation: Review @ Thu")], labels: ["INBOX"]), account: "a")
        XCTAssertEqual(invite.category, .invitations)
        let person = MessageParser.parse(try raw(headers: [("From", "Sam <sam@example.com>"), ("Subject", "Dinner?")], labels: ["INBOX"]), account: "a")
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
                                            html: "<style>p{}</style><p>Your code&nbsp;is</p><b>123</b>"), account: "a")
        XCTAssertEqual(m.bodyText, "Your code is\n 123")
    }
}

final class StoreTests: XCTestCase {
    private func message(_ id: String, labels: Set<String>, subject: String, body: String, minutesAgo: Double = 1, thread: String? = nil) -> Message {
        Message(id: id, account: "me@x.com", threadID: thread ?? id, date: Date().addingTimeInterval(-minutesAgo * 60),
                fromName: "Rico", fromEmail: "rico@figma.com", to: [], cc: [], replyTo: nil, subject: subject,
                snippet: body, bodyText: body, bodyHTML: nil, labels: labels, attachments: [], category: .people,
                verified: true, messageIDHeader: nil, references: nil, listUnsubscribe: nil)
    }

    func testMailboxesSearchAndLabels() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("postline-test-\(UUID()).sqlite").path
        let store = Store(path: path)
        store.save(Account(email: "me@x.com", name: "Me", pictureURL: nil, historyID: "42", sendAs: [SendAs(email: "hello@me.com", name: "Me", isDefault: true)]))
        XCTAssertEqual(store.accounts().first?.sendAs.first?.email, "hello@me.com")

        store.upsert([
            message("a", labels: ["INBOX", "UNREAD"], subject: "Invoice for October", body: "Please find the invoice attached"),
            message("b", labels: ["SENT"], subject: "Re: Invoice", body: "Thanks!", minutesAgo: 2, thread: "a"),
            message("c", labels: ["TRASH"], subject: "Old invoice", body: "gone")
        ])
        XCTAssertEqual(store.messages(in: .inbox, account: nil).map(\.id), ["a"])
        XCTAssertEqual(store.messages(in: .sent, account: nil).map(\.id), ["b"])
        XCTAssertEqual(store.messages(in: .trash, account: nil).map(\.id), ["c"])
        XCTAssertEqual(store.count(in: .inbox, account: nil, unreadOnly: true), 1)
        XCTAssertEqual(store.thread("a", account: "me@x.com").map(\.id), ["b", "a"])

        // Prefix search, and Trash stays out of results.
        XCTAssertEqual(Set(store.search("invo", account: nil).map(\.id)), ["a", "b"])
        XCTAssertEqual(store.search("figma", account: nil).count, 2, "sender address is searchable")

        // Archive: the label goes, the mail moves.
        store.setLabels("a", ["UNREAD"])
        XCTAssertTrue(store.messages(in: .inbox, account: nil).isEmpty)
        XCTAssertEqual(store.messages(in: .archive, account: nil).map(\.id), ["a"])

        // Speed: 2,000 messages written, then a mailbox and a search read.
        store.upsert((0..<2000).map { message("bulk\($0)", labels: ["INBOX"], subject: "Weekly digest \($0)", body: String(repeating: "lorem ipsum ", count: 80), minutesAgo: Double($0)) })
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
}

final class OutgoingTests: XCTestCase {
    func testMIMEForReplyFromAlias() throws {
        let original = Message(id: "m", account: "me@gmail.com", threadID: "t", date: Date(), fromName: "Rico", fromEmail: "rico@figma.com",
                               to: ["Harshit <hello@example.com>"], cc: ["Ana <ana@figma.com>"], replyTo: nil, subject: "Feedback",
                               snippet: "", bodyText: "Line one\nLine two", bodyHTML: nil, labels: ["INBOX"], attachments: [],
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
