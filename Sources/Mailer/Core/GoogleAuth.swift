import AppKit
import AuthenticationServices
import CryptoKit

struct GoogleProfile: Equatable, Sendable {
    var email: String
    var name: String?
    var pictureURL: URL?
}

/// OAuth 2 with PKCE for any number of Google accounts — Cued's `GoogleAuth`,
/// keyed by address. Each account keeps one refresh token in the Keychain;
/// access tokens live in memory only and refresh themselves an hour at a time.
@MainActor
final class GoogleAuth {

    static let shared = GoogleAuth()

    private struct Session { var accessToken: String; var expiresAt: Date }
    private var sessions: [String: Session] = [:]
    /// One refresh in flight per account: a burst of sync calls after wake
    /// would otherwise each post their own refresh grant.
    private var refreshing: [String: Task<Void, Error>] = [:]

    private let presenter = AuthPresenter()
    private var webSession: ASWebAuthenticationSession?

    private static func tokenKey(_ email: String) -> String { "refresh:\(email.lowercased())" }

    // MARK: Public

    /// `hint` puts that address first on Google's account chooser, for
    /// signing an existing account in again.
    func signIn(hint: String? = nil) async throws -> GoogleProfile {
        guard Config.isConfigured else { throw MailerError.notConfigured }
        let verifier = Self.makeCodeVerifier()
        let code = try await authorize(challenge: Self.challenge(for: verifier), hint: hint)
        let token = try await postToken([
            "client_id": Config.googleClientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": Config.redirectURI
        ])
        guard let refresh = token.refreshToken else {
            throw MailerError("Google did not return a refresh token. Remove Mailer at myaccount.google.com/permissions and sign in again.")
        }
        let profile = try await fetchProfile(accessToken: token.accessToken)
        let email = profile.email.lowercased()
        guard (token.scope ?? "").contains(Config.mailScope) else {
            throw MailerError("Mailer needs permission to read and send your mail. Sign in again and tick every box on Google's screen.")
        }
        Keychain.set(refresh, for: Self.tokenKey(email))
        sessions[email] = Session(accessToken: token.accessToken,
                                  expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
        return profile
    }

    func hasToken(for email: String) -> Bool { Keychain.get(Self.tokenKey(email)) != nil }

    func signOut(_ email: String) async {
        let email = email.lowercased()
        if let token = Keychain.get(Self.tokenKey(email)) {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(token)".utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
        Keychain.delete(Self.tokenKey(email))
        sessions[email] = nil
    }

    /// A valid access token, refreshed when it has less than a minute left.
    func accessToken(for email: String) async throws -> String {
        let email = email.lowercased()
        if let s = sessions[email], s.expiresAt.timeIntervalSinceNow > 60 { return s.accessToken }
        if let task = refreshing[email] {
            try await task.value
        } else {
            guard let refresh = Keychain.get(Self.tokenKey(email)) else {
                throw MailerError("\(email) is signed out. Sign in again from Settings.")
            }
            let task = Task<Void, Error> { try await self.refresh(email: email, token: refresh) }
            refreshing[email] = task
            defer { refreshing[email] = nil }
            try await task.value
        }
        guard let s = sessions[email] else { throw MailerError("Could not refresh the Google session for \(email).") }
        return s.accessToken
    }

    func invalidate(_ email: String) { sessions[email.lowercased()] = nil }

    // MARK: Token endpoint

    private func refresh(email: String, token: String) async throws {
        do {
            let t = try await postToken([
                "client_id": Config.googleClientID,
                "refresh_token": token,
                "grant_type": "refresh_token"
            ])
            sessions[email] = Session(accessToken: t.accessToken,
                                      expiresAt: Date().addingTimeInterval(TimeInterval(t.expiresIn)))
        } catch let error as MailerError where Self.isSignedOut(error) {
            // Revoked, or a Testing-mode project's 7-day expiry, or a token
            // another Google project issued (the fork's first launch with
            // its own project: every few seconds, both accounts, 2026-11-27).
            // Drop it so the account shows "Sign in again" instead of
            // retrying forever.
            Keychain.delete(Self.tokenKey(email))
            throw MailerError("Google signed \(email) out. Sign in again from Settings.")
        }
    }

    /// Google's answers that mean the saved sign-in will never work again.
    private static func isSignedOut(_ error: MailerError) -> Bool {
        error.message.contains("invalid_grant") || error.message.contains("unauthorized_client")
    }

    private func postToken(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.key)=\($0.value.formURLEncoded)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
            throw MailerError(detail?.readable ?? "Google returned \(status).")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchProfile(accessToken: String) async throws -> GoogleProfile {
        var request = URLRequest(url: Config.userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        struct UserInfo: Decodable { let email: String?; let name: String?; let picture: String? }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(UserInfo.self, from: data),
              let email = info.email, !email.isEmpty else {
            throw MailerError("Google didn't return your profile.")
        }
        // Ask for a picture that stays sharp in a Retina avatar.
        let picture = info.picture.map { $0.replacingOccurrences(of: "=s96-c", with: "=s256-c") }
        return GoogleProfile(email: email.lowercased(), name: info.name, pictureURL: picture.flatMap(URL.init(string:)))
    }

    // MARK: Authorization

    private func authorize(challenge: String, hint: String?) async throws -> String {
        var c = URLComponents(url: Config.authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: Config.googleClientID),
            .init(name: "redirect_uri", value: Config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // Both are needed for Google to hand back a refresh token.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "include_granted_scopes", value: "true")
        ]
        if let hint { c.queryItems?.append(.init(name: "login_hint", value: hint)) }
        let url = c.url!
        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Config.redirectScheme) { callback, error in
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(throwing: MailerError(error.localizedDescription))
                    }
                    return
                }
                let items = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                if let denied = items.first(where: { $0.name == "error" })?.value {
                    cont.resume(throwing: MailerError("Google sign-in failed: \(denied)")); return
                }
                guard let code = items.first(where: { $0.name == "code" })?.value else {
                    cont.resume(throwing: MailerError("Google returned no authorization code.")); return
                }
                cont.resume(returning: code)
            }
            session.presentationContextProvider = presenter
            // Reuse the browser's Google cookies: an account you're already
            // signed in to is one click.
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() { cont.resume(throwing: MailerError("Could not open the sign-in window.")) }
        }
    }

    // MARK: PKCE

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?
    enum CodingKeys: String, CodingKey { case error, errorDescription = "error_description" }
    var readable: String { [error, errorDescription].compactMap { $0 }.joined(separator: ": ") }
}

private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var fallback: NSWindow?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) { return window }
        if let fallback { return fallback }
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 1, height: 1), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.orderFrontRegardless()
        fallback = w
        return w
    }
}

extension MailerError {
    static let notConfigured = MailerError("Google sign-in isn't set up yet. Add the OAuth client ID to Config.swift and rebuild — README.md has the steps.")
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}

extension String {
    var formURLEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
