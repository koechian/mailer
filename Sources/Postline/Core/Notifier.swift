import AppKit
import OTPCore
import UserNotifications

/// New-mail notifications, and the one-time-code notification with its
/// **Copy code** button. Clicking any notification opens that email.
///
/// Codes come from OpenOTP's detector, which proposes and never acts: the
/// code is shown with its sender, copied only when asked (or when "Copy codes
/// automatically" is on), and never typed anywhere.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Notifier()

    /// Opens a message: (account, message id).
    var open: ((String, String) -> Void)?
    /// A code was found, for the menu bar list.
    var foundCode: ((FoundCode) -> Void)?
    /// A code was copied (from the notification or the menu).
    var copied: (() -> Void)?
    /// New Primary mail from someone else, for the menu bar icon.
    var newMail: (([Message]) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private static let codeCategory = "postline.code"
    private static let mailCategory = "postline.mail"
    private static let copyAction = "postline.copy"

    func setUp() {
        center.delegate = self
        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy code", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.codeCategory, actions: [copy], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.mailCategory, actions: [], intentIdentifiers: [])
        ])
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: New mail

    func handle(_ messages: [Message], accounts: [Account]) {
        // "Sent by me" is judged per receiving account: mail from
        // your second account's alias landing in your first account is new
        // mail there and notifies. Merging every
        // account's addresses into one "me" silenced exactly that (2026-11-12).
        let ownAddresses = Dictionary(uniqueKeysWithValues: accounts.map { a in
            (a.email, Set([a.email] + a.sendAs.map(\.email)))
        })
        let prefs = Preferences.shared
        var primary: [Message] = []
        defer { if !primary.isEmpty { newMail?(primary) } }
        for m in messages.sorted(by: { $0.date < $1.date })
        where !(ownAddresses[m.account]?.contains(m.fromEmail) ?? false) {
            if let code = CodeFinder.find(subject: m.subject, text: m.bodyText, html: m.bodyHTML) {
                let found = FoundCode(code: code.code, sender: m.senderLabel, messageID: m.id, account: m.account, date: m.date)
                Store.shared.saveCode(found)
                foundCode?(found)
                if prefs.autoCopyCodes { copy(code.code, byYou: false) }
                postCode(found, confident: code.confident, message: m)
                continue
            }
            // Promotions and Social stay quiet, as they do in Gmail's Primary.
            if m.labels.contains("CATEGORY_PROMOTIONS") || m.labels.contains("CATEGORY_SOCIAL") || m.labels.contains("CATEGORY_FORUMS") {
                continue
            }
            // Shown in the menu bar icon whatever the notification setting:
            // that's how new mail is seen with no Dock icon (owner, 2026-11-14).
            if m.isInInbox { primary.append(m) }
            switch prefs.notify {
            case .none: continue
            case .people where m.category != .people: continue
            default: postMail(m)
            }
        }
    }

    private func postCode(_ found: FoundCode, confident: Bool, message m: Message) {
        let content = UNMutableNotificationContent()
        content.title = found.code
        // The sender is always shown with the code; a low-confidence guess
        // says so (OpenOTP's contract — every input is attacker-controlled).
        content.subtitle = confident ? "Code from \(found.sender)" : "Possible code from \(found.sender)"
        content.body = Preferences.shared.autoCopyCodes ? "Copied. \(m.subject)" : m.subject
        content.categoryIdentifier = Self.codeCategory
        content.userInfo = ["account": m.account, "id": m.id, "code": found.code]
        content.sound = .default
        content.threadIdentifier = "codes"
        center.add(UNNotificationRequest(identifier: "code-\(m.id)", content: content, trigger: nil))
    }

    /// A sample code notification, so the whole path — permission, banner,
    /// Copy code, click to open — can be checked without waiting for mail.
    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "482913"
        content.subtitle = "Code from Postline (test)"
        content.body = "Press Copy code, or click to open Postline."
        content.categoryIdentifier = Self.codeCategory
        content.userInfo = ["account": "", "id": "", "code": "482913"]
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "test-\(UUID())", content: content, trigger: nil))
        // The same path a real code takes, so the menu bar code icon shows too.
        foundCode?(FoundCode(code: "482913", sender: "Postline (test)", messageID: "test", account: "", date: Date()))
    }

    private func postMail(_ m: Message) {
        let content = UNMutableNotificationContent()
        content.title = m.senderLabel
        content.subtitle = m.subject
        content.body = m.snippet
        content.categoryIdentifier = Self.mailCategory
        content.userInfo = ["account": m.account, "id": m.id]
        content.sound = .default
        content.threadIdentifier = m.threadID
        center.add(UNNotificationRequest(identifier: "mail-\(m.id)", content: content, trigger: nil))
    }

    /// `byYou` is false for the automatic copy, which must not count as
    /// "done with it" — the menu bar code icon stays until you copy it.
    func copy(_ code: String, byYou: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        if byYou { copied?() }
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Show codes even while Postline is in front — that's when you need them.
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let account = info["account"] as? String ?? ""
        let id = info["id"] as? String ?? ""
        let code = info["code"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Self.copyAction, let code {
                self.copy(code)
            } else if action == UNNotificationDefaultActionIdentifier {
                self.open?(account, id)
            }
        }
    }
}
