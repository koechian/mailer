import Foundation

/// A message being written. Built into RFC 822 and sent through the Gmail API
/// from whichever "Send mail as" address was picked, so mail sent as
/// an alias like hello@yourdomain.com goes out exactly as it does from Gmail on the web.
struct Draft: Equatable, Identifiable {
    var id = UUID()
    var account: String
    var from: SendAs
    var to: String = ""
    var cc: String = ""
    var subject: String = ""
    var body: String = ""
    var threadID: String?
    var inReplyTo: String?
    var references: String?
    var attachments: [URL] = []

    var recipients: [String] { Self.split(to) + Self.split(cc) }
    var isSendable: Bool { !Self.split(to).isEmpty }

    static func split(_ field: String) -> [String] {
        field.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Replies

    static func reply(to m: Message, all: Bool, account: Account) -> Draft {
        let me = Set(account.sendAs.map(\.email) + [account.email])
        // Reply from the address the mail was sent to, when it is one of ours.
        let from = account.sendAs.first { a in (m.to + m.cc).contains { $0.lowercased().contains(a.email) } }
            ?? account.sendAs.first ?? SendAs(email: account.email, name: account.name ?? "", isDefault: true)
        var to = [m.replyTo ?? m.fromEmail]
        if m.isSent { to = m.to }
        var cc: [String] = []
        if all {
            cc = (m.to + m.cc).filter { addr in !me.contains { addr.lowercased().contains($0) } && !to.contains(addr) }
        }
        let subject = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: \(m.subject)"
        return Draft(account: account.email, from: from, to: to.joined(separator: ", "), cc: cc.joined(separator: ", "),
                     subject: subject, body: "\n\n" + quote(m), threadID: m.threadID,
                     inReplyTo: m.messageIDHeader,
                     references: [m.references, m.messageIDHeader].compactMap { $0 }.joined(separator: " "))
    }

    static func forward(_ m: Message, account: Account) -> Draft {
        let from = account.sendAs.first ?? SendAs(email: account.email, name: account.name ?? "", isDefault: true)
        let header = """
        ---------- Forwarded message ---------
        From: \(m.fromName) <\(m.fromEmail)>
        Date: \(m.date.formatted(date: .abbreviated, time: .shortened))
        Subject: \(m.subject)
        To: \(m.to.joined(separator: ", "))
        """
        let subject = m.subject.lowercased().hasPrefix("fwd:") ? m.subject : "Fwd: \(m.subject)"
        return Draft(account: account.email, from: from, subject: subject, body: "\n\n\(header)\n\n\(m.bodyText)")
    }

    private static func quote(_ m: Message) -> String {
        let when = m.date.formatted(date: .abbreviated, time: .shortened)
        let quoted = m.bodyText.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return "On \(when), \(m.senderLabel) <\(m.fromEmail)> wrote:\n\(quoted)"
    }

    // MARK: RFC 822

    func mime(date: Date = Date()) throws -> Data {
        let boundary = "postline-" + UUID().uuidString
        var lines: [String] = []
        let fromHeader = from.name.isEmpty ? from.email : "\(Self.encodeWord(from.name)) <\(from.email)>"
        lines.append("From: \(fromHeader)")
        lines.append("To: \(Self.split(to).joined(separator: ", "))")
        if !Self.split(cc).isEmpty { lines.append("Cc: \(Self.split(cc).joined(separator: ", "))") }
        lines.append("Subject: \(Self.encodeWord(subject))")
        lines.append("Date: \(Self.rfc2822(date))")
        lines.append("MIME-Version: 1.0")
        if let inReplyTo { lines.append("In-Reply-To: \(inReplyTo)") }
        if let references, !references.isEmpty { lines.append("References: \(references)") }

        let text = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let textPart = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])

        if attachments.isEmpty {
            lines.append(textPart)
            return Data(lines.joined(separator: "\r\n").utf8)
        }

        lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        lines.append("")
        lines.append("--\(boundary)")
        lines.append(textPart)
        for url in attachments {
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            lines.append("--\(boundary)")
            lines.append("Content-Type: application/octet-stream; name=\"\(name)\"")
            lines.append("Content-Disposition: attachment; filename=\"\(name)\"")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
        }
        lines.append("--\(boundary)--")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// RFC 2047 for anything outside plain ASCII.
    static func encodeWord(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { !$0.isASCII }) else { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    static func rfc2822(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }
}
