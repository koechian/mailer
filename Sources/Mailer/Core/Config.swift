import Foundation

/// Everything Mailer needs to talk to Google, in one place.
///
/// Sign-in is the same flow Cued uses (OAuth 2 with PKCE through
/// `ASWebAuthenticationSession`), so there is no client secret anywhere: an
/// **iOS**-type OAuth client is the right type for a Mac app signing in this
/// way, and PKCE stands in for the secret. A client ID is not a secret — it is
/// printed in every sign-in URL. It still isn't kept in the repository, so a
/// build from source signs in through *your* Google project rather than
/// someone else's (an unverified project allows 100 users in total).
enum Config {

    /// Postline's, the app Mailer is forked from. It stays, with the Keychain
    /// service below: the Google client is registered for this ID, and
    /// existing sign-ins are kept under it.
    static let bundleID = "com.oiharshit.postline"

    /// The Google OAuth client ID (Google Cloud → your project → Clients →
    /// type **iOS**, Bundle ID `com.oiharshit.postline`; README → Google
    /// setup). A build from `build.sh` carries it, from `GoogleClientID.txt`
    /// or `MAILER_GOOGLE_CLIENT_ID`, and it is then kept on this Mac. Builds
    /// published on GitHub carry none, so that nobody who downloads one signs
    /// in through someone else's Google project: they use the one kept on
    /// this Mac, or ask for one during onboarding.
    static var googleClientID: String {
        builtClientID ?? UserDefaults.standard.string(forKey: clientIDKey) ?? "REPLACE_ME"
    }

    static var isConfigured: Bool { isValidClientID(googleClientID) }

    static func isValidClientID(_ id: String) -> Bool {
        id.hasSuffix(".apps.googleusercontent.com") && !id.contains(where: \.isWhitespace) && id.count > 30
    }

    private static let clientIDKey = "googleClientID"

    private static let builtClientID = (Bundle.main.object(forInfoDictionaryKey: "MailerGoogleClientID") as? String)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .flatMap { isValidClientID($0) ? $0 : nil }

    /// Keeps the client ID this build carries on this Mac, so the published
    /// updates that replace it, which carry none, still sign in.
    static func rememberBuiltClientID() {
        guard let builtClientID else { return }
        UserDefaults.standard.set(builtClientID, forKey: clientIDKey)
    }

    /// Saves a client ID pasted during onboarding. False if it isn't one.
    @discardableResult
    static func saveClientID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidClientID(trimmed) else { return false }
        UserDefaults.standard.set(trimmed, forKey: clientIDKey)
        return true
    }

    /// `https://mail.google.com/` is the one scope that covers both the Gmail
    /// API and IMAP. Mailer needs IMAP only for IDLE — Gmail pinging the app
    /// the instant a message lands — and the narrower `gmail.modify` does not
    /// open IMAP. Both are "restricted" scopes, so the consent screen is the
    /// same either way.
    static let mailScope = "https://mail.google.com/"

    static let scopes = [
        mailScope,
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        // Real photos for the people who write to you: your contacts, and the
        // "other contacts" Gmail saves for everyone you have emailed.
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/contacts.other.readonly"
    ]

    /// Google authenticates an iOS client's redirect by requiring the custom
    /// scheme to be the reversed client ID.
    static var redirectScheme: String {
        "com.googleusercontent.apps." + googleClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
    static let gmailBase = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    static let peopleBase = URL(string: "https://people.googleapis.com/v1/")!

    static let keychainService = "com.oiharshit.postline.oauth"
}

struct MailerError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
