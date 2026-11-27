import Foundation

/// Sample mail for `MAILER_DEMO=1`, so every screen can be seen and tested
/// before a Google account is connected. Lives in its own database
/// (demo.sqlite) and never touches real mail.
enum DemoData {

    static func seedIfEmpty(_ store: Store) {
        guard store.accounts().isEmpty else { return }
        let me = Account(email: "hello@mailer.test", name: "Alex", pictureURL: nil, historyID: "1",
                         sendAs: [SendAs(email: "hello@mailer.test", name: "Alex", isDefault: true)])
        let work = Account(email: "studio@mailer.test", name: "Studio", pictureURL: nil, historyID: "1",
                           sendAs: [SendAs(email: "studio@mailer.test", name: "Studio", isDefault: true)])
        store.save(me)
        store.save(work)

        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var n = 0
        func m(_ account: String = "hello@mailer.test", from: String, _ email: String, _ subject: String, _ body: String,
               at date: Date, labels: Set<String> = ["INBOX", "UNREAD"], category: MailCategory = .people,
               verified: Bool = true, thread: String? = nil, html: String? = nil, files: [Attachment] = [],
               to: [String] = ["Alex <hello@mailer.test>"]) -> FetchedMessage {
            n += 1
            let message = Message(id: "", account: account, threadID: thread ?? "t\(n)", date: date, fromName: from, fromEmail: email,
                           to: to, cc: [], replyTo: nil, subject: subject,
                           snippet: String(body.replacingOccurrences(of: "\n", with: " ").prefix(140)), bodyText: body,
                           bodyHTML: html, state: GmailMapping.state(labels: labels, to: to, account: account),
                           attachments: files, category: category, verified: verified,
                           messageIDHeader: "<demo\(n)@mailer.test>", references: thread == nil ? nil : "<demo1@mailer.test>",
                           listUnsubscribe: category == .newsletters ? "<https://example.com/unsubscribe>" : nil)
            return FetchedMessage(remoteID: "demo\(n)", message: message)
        }

        let messages: [FetchedMessage] = [
            m(from: "Rico Oktananda", "rico@figma.com", "We need your UX feedback!",
              "Hi Alex,\n\nWe're refining our product and need your insights on our user experience design. Please share any additional feedback you have — your perspective is crucial in helping us exceed user expectations.\n\nBest regards,\nRico",
              at: ago(9), files: [
                Attachment(filename: "design-review.pdf", mimeType: "application/pdf", size: 2_100_000, attachmentID: "a1", partID: "1"),
                Attachment(filename: "flows.fig", mimeType: "application/octet-stream", size: 1_500_000, attachmentID: "a2", partID: "2"),
                Attachment(filename: "metrics.xlsx", mimeType: "application/vnd.ms-excel", size: 234_000, attachmentID: "a3", partID: "3")]),
            m(from: "Alicia from Deel", "alicia@deel.com", "Your money is on the way!",
              "Your Deel withdrawal is all set, and your money is on its way to your bank account. It usually arrives within 1–2 business days.",
              at: ago(42), category: .notifications),
            m(from: "Google", "no-reply@accounts.google.com", "Your Google verification code",
              "Your verification code is 482913. Don't share it with anyone.", at: ago(3), category: .notifications,
              html: "<p>Use this code to finish signing in:</p><p style='font-size:28px;font-weight:600;letter-spacing:4px'>482913</p><p>The code expires in 10 minutes. Don't share it with anyone.</p>"),
            m(from: "Sam Lee", "sam.lee@example.com", "Dinner on Friday?",
              "Hey! Are we still on for Friday? I booked a table for 8.\n\nLet me know if that time works.", at: ago(95), verified: false),
            m(from: "Alex", "hello@mailer.test", "Re: Dinner on Friday?", "8 works. See you there!",
              at: ago(80), labels: ["SENT"], thread: "t4", to: ["Sam Lee <sam.lee@example.com>"]),
            m(from: "Sam Lee", "sam.lee@example.com", "Re: Dinner on Friday?", "Perfect, see you then 🙌",
              at: ago(60), verified: false, thread: "t4"),
            m(from: "Substack Read", "read@substack.com", "Research as a leisure activity",
              "Solstice strawberries, and things to do besides worry. This week's picks from writers you follow.",
              at: ago(130), labels: ["INBOX"], category: .newsletters,
              html: "<h2 style='font-family:Georgia,serif;font-weight:500'>Research as a leisure activity</h2><p style='color:#71717a'>Solstice strawberries, and things to do besides worry.</p><p>This week's picks from writers you follow — slow reading for a long weekend.</p><p><a href='https://substack.com'>Read in the app</a></p>"),
            m(from: "Medium Daily Digest", "noreply@medium.com", "How to hire your inner critic",
              "Brittany Amara in The Writing Cooperative — I spent 120 hours finding out.", at: ago(300),
              labels: ["INBOX"], category: .newsletters),
            m(from: "GitHub", "noreply@github.com", "[mailer] Build passed on main",
              "All checks have passed for your latest push to main.", at: ago(210), category: .notifications),
            m(from: "Cal.com", "no-reply@cal.com", "Invitation: Design review @ Thu 4pm",
              "You have been invited to Design review. Thursday 4:00 – 4:30 pm.", at: ago(250), category: .invitations),
            m(from: "Netflix", "info@netflix.com", "Your phone number has been verified",
              "Hi, we've added and verified your phone number ending in 50. It can now be used to help you sign in.",
              at: ago(1500), labels: ["INBOX"], category: .notifications),
            m(from: "Kiran Shah", "kiran@notion.so", "Brand guidelines — final",
              "Attached are the final brand guidelines. Let me know if anything needs a change before we hand off.",
              at: ago(1600), labels: ["INBOX", "STARRED"]),
            m(from: "Omar Haddad", "omar@contra.com", "Quick question about the landing page",
              "Do we keep the testimonial carousel, or move to a grid? I prefer the grid on mobile.",
              at: ago(2900), labels: ["INBOX"]),
            m("studio@mailer.test", from: "Jiho from Mobbin", "jiho@mobbin.com", "Your 6-month free trial",
              "This is a reminder that the offer to get a free 6 month trial of BFM+ with your Mobbin Pro account ends soon.",
              at: ago(4400), labels: ["INBOX"], category: .newsletters),
            m("studio@mailer.test", from: "Maya Chen", "maya@ycombinator.com", "Intro: Maya ↔ Alex",
              "Hi Alex, introducing you to Maya who is building a fintech app and needs a design partner.",
              at: ago(5000), labels: ["INBOX", "UNREAD"])
        ]
        store.ingest(messages)
        if let code = store.localID(account: "hello@mailer.test", remoteID: "demo3") {
            store.saveCode(FoundCode(code: "482913", sender: "Google", messageID: code, account: "hello@mailer.test", date: ago(3)))
        }
    }
}
