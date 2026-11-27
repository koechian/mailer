import Foundation

/// Finds the open-tracking images in an email's HTML and removes them before
/// the email is drawn, so the rest of its remote images can load.
///
/// A tracking image only works if it is fetched, so it has to be recognised
/// from the HTML alone, before anything loads. Two signals are used:
///
/// * **Shape.** A pixel is drawn tiny or not at all: both sides 2 px or less,
///   one side given as 1 px or less, or hidden by its style (`display:none`,
///   `visibility:hidden`, `opacity:0`, a zero maximum size).
/// * **Address.** The open-tracking endpoints of the common mailing and sales
///   tools, whatever size the image claims to be.
///
/// Spacer images (1 px wide and 20 px tall, say) are layout and stay.
/// A tracker that looks like an ordinary image is not caught; nothing short
/// of blocking every remote image would catch it.
enum TrackingImageFilter {

    struct Result: Equatable {
        var html: String
        var removed: Int
    }

    /// The HTML without its tracking images, and how many were removed.
    static func strip(_ html: String) -> Result {
        let range = NSRange(html.startIndex..., in: html)
        var output = html
        var removed = 0
        // Back to front, so earlier ranges stay valid while editing.
        for match in imageTag.matches(in: html, range: range).reversed() {
            guard let tagRange = Range(match.range, in: html), isTracker(String(html[tagRange])) else { continue }
            output.replaceSubrange(tagRange, with: "")
            removed += 1
        }
        return Result(html: output, removed: removed)
    }

    /// True when an `<img>` tag is an open-tracking image.
    static func isTracker(_ tag: String) -> Bool {
        guard let source = attribute("src", in: tag), isRemote(source) else { return false }
        let style = attribute("style", in: tag)?.lowercased() ?? ""
        if isHidden(style: style) || isTrackingAddress(source) { return true }
        return isPixelSized(width: dimension("width", tag: tag, style: style),
                            height: dimension("height", tag: tag, style: style))
    }

    // MARK: Signals

    private static func isRemote(_ source: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespaces).lowercased()
        return s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("//")
    }

    private static func isHidden(style: String) -> Bool {
        hiddenStyle.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)) != nil
    }

    private static func isTrackingAddress(_ source: String) -> Bool {
        trackingAddress.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
    }

    private static func isPixelSized(width: Double?, height: Double?) -> Bool {
        switch (width, height) {
        case let (w?, h?): w <= 2 && h <= 2
        case let (w?, nil): w <= 1
        case let (nil, h?): h <= 1
        case (nil, nil): false
        }
    }

    // MARK: Reading the tag

    /// The smaller of the attribute (`width="1"`) and the style
    /// (`width:1px`), when either is given in pixels.
    private static func dimension(_ name: String, tag: String, style: String) -> Double? {
        let fromAttribute = attribute(name, in: tag).flatMap(pixels)
        let fromStyle = styleValue(name, in: style).flatMap(pixels)
        return [fromAttribute, fromStyle].compactMap { $0 }.min()
    }

    /// "1", "1px", "0.5px" → a number; "100%", "auto" → nil.
    private static func pixels(_ value: String) -> Double? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        let number = v.hasSuffix("px") ? String(v.dropLast(2)) : v
        return Double(number.trimmingCharacters(in: .whitespaces))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\s"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        return firstCapture(pattern, in: tag)
    }

    private static func styleValue(_ name: String, in style: String) -> String? {
        firstCapture(#"(?:^|;)\s*"# + name + #"\s*:\s*([^;]+)"#, in: style)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for group in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: group), in: text) { return String(text[r]) }
        }
        return nil
    }

    // MARK: Patterns

    private static let imageTag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])

    private static let hiddenStyle = try! NSRegularExpression(pattern: #"""
    (?x)
      display\s*:\s*none
    | visibility\s*:\s*hidden
    | opacity\s*:\s*0*\.?0+\s*(?:;|!|$)
    | max-(?:width|height)\s*:\s*0(?:px)?\s*(?:;|!|$)
    """#)

    /// Open-tracking endpoints: Mailchimp, Mandrill, SendGrid, HubSpot,
    /// Mailtrack, Yesware, Streak, Superhuman, and the generic
    /// `open.gif` / `pixel.png` / `beacon` names.
    private static let trackingAddress = try! NSRegularExpression(pattern: #"""
    (?ix)
      list-manage\.com/track/open
    | mandrillapp\.com/track/open
    | /wf/open\?
    | /track/open
    | hubspotemail\.net/
    | track\.hubspot\.com/
    | mailtrack\.io/trace
    | \bt\.yesware\.com/
    | mailfoogae\.appspot\.com/
    | \br\.superhuman\.com/
    | /(?:open|opened|pixel|beacon|tracking)\.(?:gif|png|jpe?g|php|aspx?)(?:[?\x23]|$)
    """#)
}
