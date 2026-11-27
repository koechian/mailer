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

/// Where a message sits, in words every provider can map onto: Gmail's
/// system labels, IMAP's special-use folders, Microsoft's well-known folders.
/// A message can hold several (Gmail mail you sent to yourself is in both
/// Inbox and Sent).
enum MailboxRole: String, CaseIterable, Codable, Sendable {
    case inbox, sent, drafts, trash, spam, archive

    /// The `messages` column that records the role.
    var column: String { "in_\(rawValue)" }
}

/// A message's state apart from its content: its roles, the two flags every
/// provider has, and tags. Tags hold everything else a provider says about
/// the message (Gmail's categories and user labels, an IMAP folder's name)
/// and, later, Postline's own sorting.
struct MailState: Equatable, Hashable, Sendable {
    var roles: Set<MailboxRole> = []
    var isUnread = false
    /// Gmail's star, IMAP's \Flagged; drawn as Pinned.
    var isFlagged = false
    var tags: Set<String> = []
}

struct Message: Identifiable, Equatable, Hashable, Sendable {
    /// Postline's own ID for the message. It never changes, even when the
    /// provider's ID does (an IMAP message moved to another folder gets a new
    /// UID); the store maps it to the provider's IDs.
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
    /// Bodies are loaded for a single message or a conversation, not for
    /// lists: in a mailbox listing or search result these are empty.
    var bodyText: String
    var bodyHTML: String?
    var state: MailState
    var attachments: [Attachment]
    var category: MailCategory
    /// The sender's domain passed DMARC: Gmail checked the mail really came
    /// from where it says. Drawn as the blue tick beside the name.
    var verified: Bool
    var messageIDHeader: String?
    var references: String?
    var listUnsubscribe: String?

    var isUnread: Bool { state.isUnread }
    var isFlagged: Bool { state.isFlagged }
    var isInInbox: Bool { state.roles.contains(.inbox) }
    var isSent: Bool { state.roles.contains(.sent) }
    var senderLabel: String { fromName.isEmpty ? fromEmail : fromName }
}

/// A message as a provider delivered it, before the store has given it a
/// local ID: `message.id` is ignored and `remoteID` is the provider's own.
struct FetchedMessage: Sendable {
    var remoteID: String
    var message: Message
}

/// The places mail can be looked at, as SQL over the neutral columns.
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

    /// Tags that keep a message out of the Inbox (Primary) until the
    /// provider has said otherwise: Gmail's Promotions, Social and Forums.
    static let otherTags = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"]

    private static let primary = """
    (primary_tab = 1 OR (primary_tab IS NULL AND NOT EXISTS (SELECT 1 FROM message_tags t \
    WHERE t.message_id = messages.id AND t.tag IN (\(otherTags.map { "'\($0)'" }.joined(separator: ","))))))
    """

    /// SQL that picks this mailbox's messages out of `messages`.
    var predicate: String {
        switch self {
        // Inbox is exactly Gmail's Primary tab. Which mail that is, Gmail
        // decides (its own `category:primary` search — it keeps most
        // Updates in Primary, not by label alone); `primary_tab` holds its
        // answer. Until it has answered for a new message, Promotions,
        // Social and Forums are left out by tag (owner, 2026-11-13).
        // Providers with no Primary tab leave `primary_tab` NULL and no
        // such tags, so their whole Inbox is here.
        case .inbox: "in_inbox = 1 AND \(Mailbox.primary)"
        // Everything else Gmail files in its Inbox: Promotions, Social,
        // the Updates it keeps out of Primary.
        case .other: "in_inbox = 1 AND NOT \(Mailbox.primary)"
        case .pinned: "is_flagged = 1 AND in_trash = 0"
        case .sent: "in_sent = 1 AND in_trash = 0"
        case .drafts: "in_drafts = 1"
        case .archive: "in_archive = 1"
        case .trash: "in_trash = 1"
        case .spam: "in_spam = 1"
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
