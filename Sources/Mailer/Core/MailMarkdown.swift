import Foundation

/// An email's HTML as plain Markdown, holding only what the reader showed.
///
/// Built for handing a thread to an AI model, so three kinds of content are
/// left out:
///
/// * **Hidden text.** Anything styled out of sight (`display:none`, zero
///   size, zero opacity, `hidden`). It never appears on screen, so a sender
///   could use it to give instructions to a model that the reader never saw.
/// * **Quoted history.** Gmail's, Apple Mail's, Outlook's and Thunderbird's
///   quote containers: in a thread export each message appears once anyway.
///   Forwarded mail is kept, since its content is nowhere else.
/// * **Signatures**, unless asked for.
///
/// Headings become bold lines (the export's own headings hold the
/// structure), layout tables become paragraphs, and tables with header
/// cells become Markdown tables. Reply headers written as plain text (an
/// Outlook "From: … Sent: …" block) are left to `QuotedHistory`.
enum MailMarkdown {

    static func convert(_ html: String, keepSignature: Bool = false) -> String {
        guard let document = try? XMLDocument(data: Data(html.utf8), options: [.documentTidyHTML]),
              let root = document.rootElement() else { return MessageParser.htmlToText(html) }
        let body = root.elements(forName: "body").first ?? root
        var renderer = Renderer(keepSignature: keepSignature)
        let text = renderer.children(of: body)
        return tidy(text)
    }

    /// Runs of blank lines become one; spaces around line breaks go.
    static func tidy(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n[ \t]+(?![-*>\d ])"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: What to leave out

    private static let skipped: Set<String> = ["head", "script", "style", "title", "meta", "link", "noscript",
                                               "template", "iframe", "object", "embed", "select", "button", "svg"]

    /// Styles that hide an element and everything in it.
    private static let hiddenStyle = try! NSRegularExpression(pattern: #"""
    (?ix)
      display\s*:\s*none
    | visibility\s*:\s*hidden
    | opacity\s*:\s*0*\.?0+\s*(?:;|!|$)
    | mso-hide\s*:\s*all
    """#)

    /// A zero font size hides only the text that inherits it: templates set
    /// it on whole layout tables to close the gaps between columns, and set
    /// a real size again inside (2026-11-27: 70 of 546 real emails came out
    /// empty when it hid everything). A zero height hides only with the
    /// overflow cut off.
    private static let zeroFontSize = try! NSRegularExpression(
        pattern: #"font-size\s*:\s*0(?:\.0+)?(?:px|pt|em|rem|%)?\s*(?:;|!|$)"#, options: [.caseInsensitive])
    private static let fontSize = try! NSRegularExpression(pattern: #"font-size\s*:"#, options: [.caseInsensitive])
    private static let collapsedHeight = try! NSRegularExpression(
        pattern: #"max-height\s*:\s*0(?:px)?\s*(?:;|!|$)"#, options: [.caseInsensitive])

    static func isHidden(_ element: XMLElement) -> Bool {
        if element.attribute(forName: "hidden") != nil { return true }
        guard let style = element.attribute(forName: "style")?.stringValue else { return false }
        if matches(hiddenStyle, style) { return true }
        return matches(collapsedHeight, style) && style.range(of: #"overflow\s*:\s*hidden"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The font size the element sets for the text in it: true for zero,
    /// false for any other size, nil when it sets none.
    static func setsZeroFontSize(_ element: XMLElement) -> Bool? {
        guard let style = element.attribute(forName: "style")?.stringValue, matches(fontSize, style) else { return nil }
        return matches(zeroFontSize, style)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Containers of earlier messages, by the class or id each mail program
    /// gives them.
    private static let historyClasses: Set<String> = ["gmail_quote", "gmail_extra", "yahoo_quoted", "moz-cite-prefix",
                                                      "OutlookMessageHeader"]
    /// Where Outlook on the web starts the earlier messages: this element and
    /// everything after it is history.
    private static let historyStartIDs: Set<String> = ["divRplyFwdMsg", "appendonsend"]
    private static let signatureClasses: Set<String> = ["gmail_signature", "moz-signature"]
    private static let signatureIDs: Set<String> = ["Signature", "signature"]

    private static func classes(_ element: XMLElement) -> Set<String> {
        Set((element.attribute(forName: "class")?.stringValue ?? "").split(separator: " ").map(String.init))
    }

    private static func id(_ element: XMLElement) -> String {
        element.attribute(forName: "id")?.stringValue ?? ""
    }

    /// A forward starts with its "Forwarded message" line; a reply's history
    /// starts "On … wrote:", even when a forward sits further down in it.
    static func isForwarded(_ element: XMLElement) -> Bool {
        let opening = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
        return opening.range(of: "Forwarded message", options: .caseInsensitive) != nil
    }

    // MARK: Rendering

    private struct Renderer {
        let keepSignature: Bool
        /// Set once the earlier messages begin; nothing after is kept.
        var historyStarted = false
        var listDepth = 0
        /// Inside an element whose font size is zero, until one sets it again.
        var zeroFont = false

        mutating func children(of element: XMLElement) -> String {
            var out = ""
            for child in element.children ?? [] {
                if historyStarted { break }
                out += node(child)
            }
            return out
        }

        mutating func node(_ node: XMLNode) -> String {
            switch node.kind {
            case .text: return zeroFont ? "" : MailMarkdown.collapse(node.stringValue ?? "")
            case .element: return element(node as! XMLElement)
            default: return ""
            }
        }

        mutating func element(_ e: XMLElement) -> String {
            let name = (e.name ?? "").lowercased()
            if MailMarkdown.skipped.contains(name) || MailMarkdown.isHidden(e) { return "" }
            if MailMarkdown.historyStartIDs.contains(MailMarkdown.id(e)) { historyStarted = true; return "" }
            if isHistory(e) { return MailMarkdown.isForwarded(e) ? forwarded(e) : "" }
            if !keepSignature, isSignature(e) { return "" }
            let outerZeroFont = zeroFont
            defer { zeroFont = outerZeroFont }
            if let zero = MailMarkdown.setsZeroFontSize(e) { zeroFont = zero }
            return render(e, name: name)
        }

        func isHistory(_ e: XMLElement) -> Bool {
            if !MailMarkdown.classes(e).isDisjoint(with: MailMarkdown.historyClasses) { return true }
            return e.name?.lowercased() == "blockquote" && e.attribute(forName: "type")?.stringValue == "cite"
        }

        func isSignature(_ e: XMLElement) -> Bool {
            !MailMarkdown.classes(e).isDisjoint(with: MailMarkdown.signatureClasses)
                || MailMarkdown.signatureIDs.contains(MailMarkdown.id(e))
        }

        /// Kept whole, its own "Forwarded message" line included, which
        /// QuotedHistory knows to keep the header block after.
        mutating func forwarded(_ e: XMLElement) -> String {
            "\n\n" + children(of: e) + "\n\n"
        }

        mutating func render(_ e: XMLElement, name: String) -> String {
            if let mark = MailMarkdown.inlineMarks[name] { return wrap(children(of: e), in: mark) }
            if let text = inline(e, name: name) ?? section(e, name: name) { return text }
            let inner = children(of: e)
            return MailMarkdown.blockElements.contains(name) ? "\n\n" + inner + "\n\n" : inner
        }

        /// Line breaks, links, images and preformatted text.
        mutating func inline(_ e: XMLElement, name: String) -> String? {
            switch name {
            case "br": "\n"
            case "a": link(e)
            case "img": image(e)
            case "pre": "\n\n```\n" + (e.stringValue ?? "").trimmingCharacters(in: .newlines) + "\n```\n\n"
            default: nil
            }
        }

        /// Headings, lists, quotations, tables and rules.
        mutating func section(_ e: XMLElement, name: String) -> String? {
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6": "\n\n" + wrap(children(of: e), in: "**") + "\n\n"
            case "ul", "ol": list(e, ordered: name == "ol")
            case "blockquote": quote(e)
            case "table": table(e)
            case "hr": "\n\n"
            default: nil
            }
        }

        func wrap(_ text: String, in mark: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return text }
            // Keep the spaces outside the marks, where Markdown needs them.
            let leading = text.hasPrefix(" ") ? " " : "", trailing = text.hasSuffix(" ") ? " " : ""
            return leading + mark + trimmed + mark + trailing
        }

        mutating func link(_ e: XMLElement) -> String {
            let text = children(of: e)
            let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let href = e.attribute(forName: "href")?.stringValue,
                  let url = URL(string: href.trimmingCharacters(in: .whitespaces)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return text }
            let clean = MailMarkdown.withoutTracking(url)
            if label.isEmpty { return "" }
            if label == clean || label == href { return "<\(clean)>" }
            return "[\(label)](\(clean))"
        }

        func image(_ e: XMLElement) -> String {
            let alt = (e.attribute(forName: "alt")?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            return MailMarkdown.isMeaningfulAlt(alt) ? "[image: \(alt)]" : ""
        }

        mutating func list(_ e: XMLElement, ordered: Bool) -> String {
            listDepth += 1
            defer { listDepth -= 1 }
            let indent = String(repeating: "  ", count: listDepth - 1)
            var out = "\n"
            var number = 1
            for item in e.elements(forName: "li") where !MailMarkdown.isHidden(item) {
                let text = MailMarkdown.tidy(element(item)).replacingOccurrences(of: "\n", with: "\n\(indent)  ")
                out += "\(indent)\(ordered ? "\(number)." : "-") \(text)\n"
                number += 1
            }
            return out + "\n"
        }

        mutating func quote(_ e: XMLElement) -> String {
            let text = MailMarkdown.tidy(children(of: e))
            guard !text.isEmpty else { return "" }
            return "\n\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        }

        /// A table with header cells is data: a Markdown table. Anything else
        /// is layout, and its cells are paragraphs.
        mutating func table(_ e: XMLElement) -> String {
            let rows = MailMarkdown.tableRows(of: e)
            let isData = rows.contains { row in row.contains { $0.name?.lowercased() == "th" } }
            guard isData else {
                return rows.map { row in row.map { "\n\n" + element($0) + "\n\n" }.joined() }.joined()
            }
            var lines: [String] = []
            for (index, row) in rows.enumerated() {
                let cells = row.map { MailMarkdown.tidy(element($0)).replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|") }
                lines.append("| " + cells.joined(separator: " | ") + " |")
                if index == 0 { lines.append("|" + String(repeating: " --- |", count: cells.count)) }
            }
            return "\n\n" + lines.joined(separator: "\n") + "\n\n"
        }
    }

    private static let inlineMarks = ["b": "**", "strong": "**", "i": "*", "em": "*", "code": "`"]
    private static let blockElements: Set<String> = ["p", "div", "section", "article", "header", "footer", "main",
                                                     "center", "tr", "td", "th", "dl", "dt", "dd", "figure", "address"]

    /// Rows of a table, its own only (not those of tables inside it).
    static func tableRows(of table: XMLElement) -> [[XMLElement]] {
        var rows: [[XMLElement]] = []
        for child in table.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name?.lowercased() {
            case "tr": rows.append(child.elements(forName: "td") + child.elements(forName: "th"))
            case "thead", "tbody", "tfoot": rows += tableRows(of: child)
            default: break
            }
        }
        return rows.map { $0.sorted { $0.index < $1.index } }
    }

    /// HTML whitespace: any run of it is one space.
    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Alt text worth keeping: not empty, not a file name, not just "image".
    static func isMeaningfulAlt(_ alt: String) -> Bool {
        guard alt.count > 1 else { return false }
        let lower = alt.lowercased()
        if ["image", "img", "photo", "picture", "logo", "spacer"].contains(lower) { return false }
        return lower.range(of: #"\.(png|jpe?g|gif|webp|bmp)$"#, options: .regularExpression) == nil
    }

    /// The link without the query items mail tools add to follow clicks.
    static func withoutTracking(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems else {
            return url.absoluteString
        }
        let kept = items.filter { !isTrackingParameter($0.name) }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url?.absoluteString ?? url.absoluteString
    }

    private static func isTrackingParameter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_") || ["mc_cid", "mc_eid", "fbclid", "gclid", "_hsenc", "_hsmi", "mkt_tok"].contains(lower)
    }
}
