import Foundation

/// A connected Gmail account.
struct Account: Identifiable, Equatable, Hashable, Sendable {
    var email: String
    var name: String?
    var pictureURL: URL?
    /// Gmail's history cursor: everything after it is news. Nil until the
    /// account's first sync has pinned a starting point.
    var historyID: String?
    /// Where the optional import of older mail has reached, if one ran.
    var importedSince: Date?
    /// Addresses this account can send as (Gmail "Send mail as"), primary first.
    var sendAs: [SendAs] = []
    var id: String { email }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return email.split(separator: "@").first.map(String.init) ?? email
    }
}

struct SendAs: Codable, Equatable, Hashable, Sendable {
    var email: String
    var name: String
    var isDefault: Bool
}

/// The Spark-style buckets the Inbox is folded into. People stay one row per
/// conversation; everything else collapses into a single row per bucket.
enum MailCategory: String, Codable, Sendable, CaseIterable {
    case people, notifications, newsletters, invitations

    var title: String {
        switch self {
        case .people: "People"
        case .notifications: "Notifications"
        case .newsletters: "Newsletters"
        case .invitations: "Invitations"
        }
    }
}

struct Attachment: Codable, Equatable, Hashable, Sendable {
    var filename: String
    var mimeType: String
    var size: Int
    var attachmentID: String?
    var partID: String
}

struct Message: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var account: String
    var threadID: String
    var date: Date
    var fromName: String
    var fromEmail: String
    var to: [String]
    var cc: [String]
    var replyTo: String?
    var subject: String
    var snippet: String
    var bodyText: String
    var bodyHTML: String?
    var labels: Set<String>
    var attachments: [Attachment]
    var category: MailCategory
    /// The sender's domain passed DMARC: Gmail checked the mail really came
    /// from where it says. Drawn as the blue tick beside the name.
    var verified: Bool
    var messageIDHeader: String?
    var references: String?
    var listUnsubscribe: String?

    var isUnread: Bool { labels.contains("UNREAD") }
    var isStarred: Bool { labels.contains("STARRED") }
    var isInInbox: Bool { labels.contains("INBOX") }
    var senderLabel: String { fromName.isEmpty ? fromEmail : fromName }
}

/// The places mail can be looked at. Labels are Gmail system labels.
enum Mailbox: String, CaseIterable, Identifiable, Sendable {
    case inbox, other, pinned, sent, drafts, archive, trash, spam
    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .other: "Other"
        case .pinned: "Pinned"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .archive: "Archive"
        case .trash: "Trash"
        case .spam: "Spam"
        }
    }

    var icon: Icon {
        switch self {
        case .inbox: .inbox
        case .other: .newsletter
        case .pinned: .pin
        case .sent: .sent
        case .drafts: .drafts
        case .archive: .archive
        case .trash: .trash
        case .spam: .spam
        }
    }

    private static let primary = """
    (primary_tab = 1 OR (primary_tab IS NULL AND labels NOT LIKE '% CATEGORY_PROMOTIONS %' \
    AND labels NOT LIKE '% CATEGORY_SOCIAL %' AND labels NOT LIKE '% CATEGORY_FORUMS %'))
    """

    /// SQL that picks this mailbox's messages out of `messages`.
    var predicate: String {
        switch self {
        // Inbox is exactly Gmail's Primary tab. Which mail that is, Gmail
        // decides (its own `category:primary` search — it keeps most
        // Updates in Primary, not by label alone); `primary_tab` holds its
        // answer. Until it has answered for a new message, Promotions,
        // Social and Forums are left out by label (owner, 2026-11-13).
        case .inbox: "labels LIKE '% INBOX %' AND \(Mailbox.primary)"
        // Everything else Gmail files in its Inbox: Promotions, Social,
        // the Updates it keeps out of Primary.
        case .other: "labels LIKE '% INBOX %' AND NOT \(Mailbox.primary)"
        case .pinned: "labels LIKE '% STARRED %' AND labels NOT LIKE '% TRASH %'"
        case .sent: "labels LIKE '% SENT %' AND labels NOT LIKE '% TRASH %'"
        case .drafts: "labels LIKE '% DRAFT %'"
        // Archived = out of the Inbox. Sent mail is left out (it was never in
        // the Inbox) — except mail you sent to your own address, which
        // arrives in the Inbox too; without this, archiving one hid it from
        // every list and it could not be unarchived (2026-11-12).
        case .archive: "labels NOT LIKE '% INBOX %' AND labels NOT LIKE '% TRASH %' AND labels NOT LIKE '% SPAM %' AND labels NOT LIKE '% DRAFT %' AND (labels NOT LIKE '% SENT %' OR to_list LIKE '%' || account || '%')"
        case .trash: "labels LIKE '% TRASH %'"
        case .spam: "labels LIKE '% SPAM %'"
        }
    }
}

/// A recent one-time code, for the menu bar.
struct FoundCode: Identifiable, Equatable, Sendable {
    var code: String
    var sender: String
    var messageID: String
    var account: String
    var date: Date
    var id: String { messageID }
}
