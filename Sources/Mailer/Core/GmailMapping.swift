import Foundation

/// Gmail's labels and Mailer's neutral `MailState`, both ways.
///
/// Gmail keeps everything as labels: Inbox, Sent, Unread and Starred are
/// labels just like a user's own. Mailer keeps roles and flags as columns
/// and every other label as a tag, so the same mailboxes work for providers
/// that have folders instead.
enum GmailMapping {

    private static let roleLabels: [(label: String, role: MailboxRole)] = [
        ("INBOX", .inbox), ("SENT", .sent), ("DRAFT", .drafts), ("TRASH", .trash), ("SPAM", .spam)
    ]
    private static let unread = "UNREAD"
    private static let starred = "STARRED"

    /// The state a message with these labels is in. `to` and `account`
    /// decide whether sent mail counts as archived (see `isArchived`).
    static func state(labels: Set<String>, to: [String], account: String) -> MailState {
        var roles = Set(roleLabels.filter { labels.contains($0.label) }.map(\.role))
        if isArchived(roles: roles, to: to, account: account) { roles.insert(.archive) }
        let claimed = Set(roleLabels.map(\.label) + [unread, starred])
        return MailState(roles: roles, isUnread: labels.contains(unread), isFlagged: labels.contains(starred),
                         tags: labels.subtracting(claimed))
    }

    /// The labels Gmail holds for a state. Archive is not a label in Gmail:
    /// it is the absence of Inbox.
    static func labels(for state: MailState) -> Set<String> {
        var labels = state.tags
        for (label, role) in roleLabels where state.roles.contains(role) { labels.insert(label) }
        if state.isUnread { labels.insert(unread) }
        if state.isFlagged { labels.insert(starred) }
        return labels
    }

    /// The state as Gmail will report it after the change reaches it, so the
    /// screen shows what the next sync would (archived sent mail, for
    /// instance, is not in the Archive mailbox).
    static func normalised(_ state: MailState, to: [String], account: String) -> MailState {
        self.state(labels: labels(for: state), to: to, account: account)
    }

    /// Archived means out of the Inbox and not in Trash, Spam or Drafts. Sent
    /// mail is left out (it was never in the Inbox), except mail you sent to
    /// your own address, which arrives in the Inbox too; without this,
    /// archiving one hid it from every list and it could not be unarchived
    /// (2026-11-12).
    private static func isArchived(roles: Set<MailboxRole>, to: [String], account: String) -> Bool {
        guard roles.isDisjoint(with: [.inbox, .trash, .spam, .drafts]) else { return false }
        guard roles.contains(.sent) else { return true }
        let me = account.lowercased()
        return to.contains { $0.lowercased().contains(me) }
    }

    // MARK: Changes to Gmail

    /// Sends the difference between two states of one message to Gmail.
    /// Moving into or out of Trash goes through Gmail's trash and untrash
    /// calls; whatever else changed (the Inbox label coming back with an
    /// untrash, say) follows as one label edit.
    static func push(from old: MailState, to new: MailState, remoteID: String, account: String) async throws {
        let api = GmailAPI(email: account)
        let wasTrashed = old.roles.contains(.trash), isTrashed = new.roles.contains(.trash)
        if !wasTrashed && isTrashed { try await api.trash(remoteID) }
        if wasTrashed && !isTrashed { try await api.untrash(remoteID) }
        let before = labels(for: old), after = labels(for: new)
        let add = after.subtracting(before).subtracting(["TRASH"])
        let remove = before.subtracting(after).subtracting(["TRASH"])
        guard !add.isEmpty || !remove.isEmpty else { return }
        try await api.modify(remoteID, add: Array(add), remove: Array(remove))
    }
}
