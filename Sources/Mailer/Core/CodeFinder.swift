import Foundation
import OTPCore

/// Finds the one-time code in a message.
///
/// OpenOTP's detector goes first: it reads an email's HTML structure (a code
/// set big and alone on its line) and is very precise. Measured on
/// 2026-11-12, though, it returns nothing for plain-text mail ("Your login code
/// is 731904."), so a second, deliberately narrow rule covers that: a code
/// word within a few words of a 4–8 digit number (or two halves like
/// 731-904), with order numbers, prices, phone numbers and years ruled out.
enum CodeFinder {

    struct Found: Equatable { let code: String; let confident: Bool }

    static func find(subject: String, text: String, html: String?) -> Found? {
        if let html, let r = OTPv2.detect(subject: subject, body: html, isHTML: true) {
            return Found(code: r.value, confident: r.confidence >= DetectedCode.unverifiedThreshold)
        }
        if let r = OTPv2.detect(subject: subject, body: text, isHTML: false) {
            return Found(code: r.value, confident: r.confidence >= DetectedCode.unverifiedThreshold)
        }
        return plainText(subject: subject, text: text.isEmpty ? (html.map(MessageParser.htmlToText) ?? "") : text)
    }

    private static let keywords = #"(?:code|otp|one[- ]time|passcode|password|pin|verification|verify|security|login|sign[- ]?in|2fa|token)"#
    private static let negatives = #"(?:order|invoice|total|amount|tracking|receipt|ticket|booking|reference|ref\.?|account|a/c|phone|mobile|call|flight|pnr|room|item|qty|₹|\$|rs\.?|inr|usd)"#

    static func plainText(subject: String, text: String) -> Found? {
        let haystack = (subject + "\n" + String(text.prefix(4000)))
        let lower = haystack.lowercased()
        guard lower.range(of: keywords, options: .regularExpression) != nil else { return nil }

        // 4–8 digits, or two 3–4 digit halves joined by a hyphen or space.
        // A sentence may end right after the code ("is 731904."); a decimal
        // or thousands separator may not ("12.50", "1,299").
        let pattern = #"(?<![\w\-/.,:#₹$])(\d{3,4}[- ]\d{3,4}|\d{4,8})(?![\w\-/%]|[.,]\d)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = haystack as NSString
        var best: (code: String, distance: Int)?
        for match in re.matches(in: haystack, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range(at: 1))
            let digits = raw.filter(\.isNumber)
            guard (4...8).contains(digits.count) else { continue }
            // A year on its own is not a code.
            if digits.count == 4, let year = Int(digits), (1950...2100).contains(year) { continue }
            let before = lower.substring(around: match.range, in: ns, before: 40)
            let after = lower.substring(around: match.range, in: ns, after: 30)
            if before.range(of: negatives, options: .regularExpression) != nil { continue }
            let near = before + " " + after
            guard near.range(of: keywords, options: .regularExpression) != nil else { continue }
            // Prefer the candidate closest after its keyword.
            let distance = before.distanceToLastMatch(of: keywords)
            if best == nil || distance < best!.distance { best = (digits.count == raw.count ? raw : digits, distance) }
        }
        return best.map { Found(code: $0.code, confident: false) }
    }
}

private extension String {
    func substring(around range: NSRange, in ns: NSString, before: Int) -> String {
        let start = max(0, range.location - before)
        return (self as NSString).substring(with: NSRange(location: start, length: range.location - start))
    }
    func substring(around range: NSRange, in ns: NSString, after: Int) -> String {
        let start = range.location + range.length
        let length = min(after, ns.length - start)
        return length > 0 ? (self as NSString).substring(with: NSRange(location: start, length: length)) : ""
    }
    /// Characters between the end of the last keyword and the end of the string.
    func distanceToLastMatch(of pattern: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let last = re.matches(in: self, range: NSRange(location: 0, length: (self as NSString).length)).last else { return 9999 }
        return (self as NSString).length - (last.range.location + last.range.length)
    }
}
