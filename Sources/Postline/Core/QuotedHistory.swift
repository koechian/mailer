import Foundation

/// The new part of a message's text, without the earlier messages it quotes,
/// its signature and its boilerplate.
///
/// Works on text (a plain-text email, or MailMarkdown's output, where reply
/// headers written as text survive): the first reply header ("On … wrote:",
/// Outlook's "From: … Sent: … Subject:" block, "Original Message") and
/// everything after it go, as do `>` quoted lines, a signature after `-- `,
/// "Sent from my iPhone" lines and confidentiality notices.
///
/// A forward is the exception. From its "Forwarded message" line on,
/// everything is kept, earlier replies included: that conversation is not
/// elsewhere in the thread.
enum QuotedHistory {

    static func trim(_ text: String, keepSignature: Bool = false) -> String {
        let lines = text.components(separatedBy: "\n")
        let forward = lines.firstIndex(where: isForwardMarker) ?? lines.count
        var own = Array(lines[..<forward])
        let kept = Array(lines[forward...]).map { isForwardMarker($0) ? "**Forwarded message**" : $0 }

        if let cut = own.indices.first(where: { isReplyHeader(own, at: $0) }) { own = Array(own[..<cut]) }
        own = own.filter { !isQuoted($0) && !isDeviceLine($0) }
        if !keepSignature, let dashes = own.firstIndex(where: isSignatureDelimiter) { own = Array(own[..<dashes]) }

        let joined = (own + kept).joined(separator: "\n")
        return MailMarkdown.tidy(withoutNotices(joined))
    }

    // MARK: Lines

    /// The line without Markdown emphasis, quote marks and outer spaces.
    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: #"[*_]{1,2}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func isForwardMarker(_ line: String) -> Bool {
        let p = plain(line).lowercased()
        return p.contains("forwarded message") && (p.hasPrefix("-") || p.hasPrefix("begin forwarded"))
            || p == "forwarded message"
    }

    private static let wroteLine = try! NSRegularExpression(
        pattern: #"^(on|am|le|el|il|op) .{4,240}(wrote|schrieb|a écrit|escribió|ha scritto|schreef)\s*:?$"#,
        options: [.caseInsensitive])

    static func isReplyHeader(_ lines: [String], at i: Int) -> Bool {
        let line = plain(lines[i])
        if matches(wroteLine, line) { return true }
        // "On Tue, 12 Nov 2026 at 09:14, Ben Otieno <ben@" + "x.com> wrote:"
        if line.lowercased().hasPrefix("on "), i + 1 < lines.count,
           matches(wroteLine, line + " " + plain(lines[i + 1])) { return true }
        if line.range(of: #"^-{2,}\s*original message\s*-{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if line.range(of: #"^_{10,}$"#, options: .regularExpression) != nil {
            return i + 1 < lines.count && isHeaderBlock(lines, at: i + 1)
        }
        return isHeaderBlock(lines, at: i)
    }

    /// Outlook's block: "From:" followed within a few lines by "Sent:" or
    /// "Date:", and by "To:" or "Subject:".
    static func isHeaderBlock(_ lines: [String], at i: Int) -> Bool {
        guard plain(lines[i]).lowercased().hasPrefix("from:") else { return false }
        let following = lines[(i + 1)..<min(lines.count, i + 6)].map { plain($0).lowercased() }
        let dated = following.contains { $0.hasPrefix("sent:") || $0.hasPrefix("date:") }
        let addressed = following.contains { $0.hasPrefix("to:") || $0.hasPrefix("subject:") }
        return dated && addressed
    }

    static func isQuoted(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    static func isSignatureDelimiter(_ line: String) -> Bool {
        line == "-- " || line.trimmingCharacters(in: .whitespaces) == "--"
    }

    private static let deviceLine = try! NSRegularExpression(
        pattern: #"^(sent from my .{1,40}|sent from (mail|outlook) for .{1,30}|get outlook for .{1,30}|sent via .{1,40})$"#,
        options: [.caseInsensitive])

    static func isDeviceLine(_ line: String) -> Bool {
        matches(deviceLine, plain(line))
    }

    // MARK: Paragraphs

    /// Confidentiality notices and "think before you print" lines.
    static func isNotice(_ paragraph: String) -> Bool {
        let p = paragraph.lowercased()
        let confidential = p.contains("confidential") || p.contains("privileged")
        let addressee = p.contains("intended recipient") || p.contains("intended solely")
            || p.contains("received this email in error") || p.contains("received this message in error")
        return (confidential && addressee) || p.contains("before printing this e")
    }

    private static func withoutNotices(_ text: String) -> String {
        text.components(separatedBy: "\n\n").filter { !isNotice($0) }.joined(separator: "\n\n")
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
