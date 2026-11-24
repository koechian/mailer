import Foundation

/// Turns Gmail's `format=full` JSON into a `Message`: headers, the best text
/// and HTML bodies, attachments, the Spark-style category and the DMARC tick.
enum MessageParser {

    static func parse(_ raw: GmailAPI.RawMessage, account: String) -> Message {
        let payload = raw.payload
        let headers = Dictionary((payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) },
                                 uniquingKeysWith: { first, _ in first })
        var text: String?
        var html: String?
        var attachments: [Attachment] = []
        if let payload { walk(payload, text: &text, html: &html, attachments: &attachments) }

        let (fromName, fromEmail) = splitAddress(headers["from"] ?? "")
        let date = arrivalDate(internalDate: raw.internalDate, headers: headers)
        let labels = Set(raw.labelIds ?? [])
        let bodyText = text ?? html.map(htmlToText) ?? ""
        let subject = headers["subject"].map(decodeEncodedWords) ?? ""

        let category = classify(labels: labels, headers: headers, subject: subject,
                                hasCalendar: attachments.contains { $0.mimeType.hasPrefix("text/calendar") || $0.filename.hasSuffix(".ics") })

        return Message(
            id: raw.id, account: account, threadID: raw.threadId, date: date,
            fromName: decodeEncodedWords(fromName), fromEmail: fromEmail.lowercased(),
            to: addressList(headers["to"]), cc: addressList(headers["cc"]),
            replyTo: headers["reply-to"].map { splitAddress($0).1 },
            subject: subject, snippet: decodeEntities(raw.snippet ?? ""),
            bodyText: bodyText, bodyHTML: html, labels: labels, attachments: attachments,
            category: category, verified: dmarcPassed(headers["authentication-results"], from: fromEmail),
            messageIDHeader: headers["message-id"], references: headers["references"],
            listUnsubscribe: headers["list-unsubscribe"])
    }

    // MARK: Parts

    private static func walk(_ part: GmailAPI.Part, text: inout String?, html: inout String?, attachments: inout [Attachment]) {
        let mime = (part.mimeType ?? "").lowercased()
        if let filename = part.filename, !filename.isEmpty {
            attachments.append(Attachment(filename: filename, mimeType: mime, size: part.body?.size ?? 0,
                                          attachmentID: part.body?.attachmentId, partID: part.partId ?? ""))
        } else if mime == "text/plain", text == nil, let data = part.body?.data {
            text = Data(base64URL: data).map { decodeBody($0, part: part) }
        } else if mime == "text/html", html == nil, let data = part.body?.data {
            html = Data(base64URL: data).map { decodeBody($0, part: part) }
        } else if mime == "text/calendar" {
            attachments.append(Attachment(filename: "invite.ics", mimeType: mime, size: part.body?.size ?? 0,
                                          attachmentID: part.body?.attachmentId, partID: part.partId ?? ""))
        }
        for child in part.parts ?? [] { walk(child, text: &text, html: &html, attachments: &attachments) }
    }

    /// Gmail has already undone the transfer encoding; what's left is the
    /// charset, which is almost always UTF-8 and occasionally Latin-1.
    private static func decodeBody(_ data: Data, part: GmailAPI.Part) -> String {
        let contentType = part.headers?.first { $0.name.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if contentType.contains("iso-8859-1") || contentType.contains("windows-1252") {
            return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }

    // MARK: Category

    /// Spark's Smart Inbox, from what Gmail already knows: its own category
    /// labels, mailing-list headers and calendar parts. Mail from a person
    /// stays a conversation; everything automated is folded into a bucket.
    static func classify(labels: Set<String>, headers: [String: String], subject: String, hasCalendar: Bool) -> MailCategory {
        let lowSubject = subject.lowercased()
        if hasCalendar || lowSubject.hasPrefix("invitation:") || lowSubject.hasPrefix("updated invitation")
            || lowSubject.hasPrefix("accepted:") || lowSubject.hasPrefix("declined:") {
            return .invitations
        }
        if labels.contains("SENT") { return .people }
        if labels.contains("CATEGORY_PROMOTIONS") { return .newsletters }
        if headers["list-unsubscribe"] != nil || headers["list-id"] != nil {
            return labels.contains("CATEGORY_UPDATES") ? .notifications : .newsletters
        }
        if labels.contains("CATEGORY_UPDATES") || labels.contains("CATEGORY_FORUMS") || labels.contains("CATEGORY_SOCIAL") {
            return .notifications
        }
        let from = (headers["from"] ?? "").lowercased()
        if from.contains("noreply") || from.contains("no-reply") || from.contains("notifications@")
            || from.contains("donotreply") || headers["auto-submitted"].map({ $0 != "no" }) == true {
            return .notifications
        }
        return .people
    }

    /// The blue tick: Gmail's own check found the From domain passing DMARC.
    static func dmarcPassed(_ results: String?, from: String) -> Bool {
        guard let r = results?.lowercased() else { return false }
        return r.contains("dmarc=pass")
    }

    // MARK: Addresses

    /// `"Rico O." <rico@x.com>` → ("Rico O.", "rico@x.com").
    static func splitAddress(_ raw: String) -> (String, String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return (name.replacingOccurrences(of: "\\\"", with: "\""), String(s[s.index(after: lt)..<gt]))
        }
        return ("", s)
    }

    static func addressList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        // Split on commas that are not inside quotes.
        var out: [String] = []
        var current = ""
        var quoted = false
        for ch in raw {
            if ch == "\"" { quoted.toggle() }
            if ch == ",", !quoted { out.append(current); current = "" } else { current.append(ch) }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map(decodeEncodedWords)
    }

    // MARK: Text helpers

    /// RFC 2047 `=?UTF-8?B?…?=` and `=?UTF-8?Q?…?=` in headers.
    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = s
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
        for m in matches {
            guard let whole = Range(m.range, in: s), let enc = Range(m.range(at: 2), in: s), let text = Range(m.range(at: 3), in: s) else { continue }
            let payload = String(s[text])
            var data: Data?
            if s[enc].lowercased() == "b" {
                data = Data(base64Encoded: payload) ?? Data(base64URL: payload)
            } else {
                var bytes: [UInt8] = []
                var i = payload.startIndex
                while i < payload.endIndex {
                    let c = payload[i]
                    if c == "_" { bytes.append(0x20) }
                    else if c == "=", let end = payload.index(i, offsetBy: 3, limitedBy: payload.endIndex),
                            let v = UInt8(payload[payload.index(after: i)..<end], radix: 16) {
                        bytes.append(v); i = payload.index(i, offsetBy: 2)
                    } else { bytes.append(contentsOf: Array(String(c).utf8)) }
                    i = payload.index(after: i)
                }
                data = Data(bytes)
            }
            if let data, let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                result.replaceSubrange(whole, with: decoded)
            }
        }
        // Adjacent encoded words are joined without the whitespace between them.
        return result
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// Readable text from HTML, for search and for mail that has no plain part.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for (pattern, replacement) in [
            (#"(?is)<(script|style|head)[^>]*>.*?</\1>"#, " "),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(p|div|tr|h[1-6]|li)>"#, "\n"),
            (#"<[^>]+>"#, " "),
            (#"[ \t]+"#, " "),
            (#"\n\s*\n\s*\n+"#, "\n\n")
        ] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return decodeEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When the mail reached this mailbox. Gmail's internalDate is that time
    /// for normal mail, but for mail Gmail *fetches* from another account
    /// ("Check mail from other accounts", e.g. a work address pulled in
    /// over POP) it is the time the mail was written, hours earlier: a 9:19 PM
    /// alert sat under 3:54 PM (2026-11-12). The newest Received: line is
    /// the real arrival, so the later of the two wins.
    static func arrivalDate(internalDate: String?, headers: [String: String]) -> Date {
        let stamped = internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? headers["date"].flatMap(parseRFC2822)
        let received = headers["received"].flatMap { line -> Date? in
            guard let semi = line.lastIndex(of: ";") else { return nil }
            return parseRFC2822(line[line.index(after: semi)...].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        switch (stamped, received) {
        case let (s?, r?): return max(s, r)
        case let (s?, nil): return s
        case let (nil, r?): return r
        default: return Date()
        }
    }

    static func parseRFC2822(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            f.dateFormat = format
            if let d = f.date(from: s.components(separatedBy: " (").first ?? s) { return d }
        }
        return nil
    }
}
