import Foundation

/// When the menu bar icon is up. Postline normally has no menu bar icon; it
/// appears for five minutes when new Primary mail arrives, and for five
/// minutes when a sign-in code arrives (owner, 2026-11-14). The two windows
/// run independently and the icon stays while either is open, so copying a
/// code doesn't take away the mail that came with it, and a burst of mail
/// restarts only the mail window.
struct MenuIconClock: Equatable {
    var length: TimeInterval = 300
    private(set) var codeUntil: Date?
    private(set) var mailUntil: Date?

    mutating func code(at now: Date) { codeUntil = now.addingTimeInterval(length) }
    mutating func mail(at now: Date) { mailUntil = now.addingTimeInterval(length) }
    /// The code was copied: its job is done, the mail window keeps running.
    mutating func codeDone() { codeUntil = nil }
    mutating func clear() { codeUntil = nil; mailUntil = nil }

    /// Drops whichever window has run out.
    mutating func expire(at now: Date) {
        if let c = codeUntil, c <= now { codeUntil = nil }
        if let m = mailUntil, m <= now { mailUntil = nil }
    }

    var visible: Bool { codeUntil != nil || mailUntil != nil }
    var showsCode: Bool { codeUntil != nil }
    var showsMail: Bool { mailUntil != nil }
    /// When to look again.
    var nextChange: Date? { [codeUntil, mailUntil].compactMap { $0 }.min() }
}
