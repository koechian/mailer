import AppKit
import CryptoKit
import Observation

/// Real faces and logos for the people and companies that write to you.
///
/// In order of preference:
/// 1. **Your own accounts** — the Google profile picture.
/// 2. **People you know** — the photo Google Contacts holds for that address,
///    from your contacts or the "other contacts" Gmail saves for everyone you
///    have emailed. Google's generated letter tiles are skipped.
/// 3. **Companies** — the logo of the sender's domain (github.com, deel.com…),
///    only when the person turned company logos on in Settings: the lookup
///    goes through Google's favicon service, which sees the domain.
///    Free-mail domains like gmail.com are skipped: their logo would put the
///    same "G" beside every friend.
/// 4. **Everyone else** — initials on a colour picked from the address, so a
///    person always gets the same colour.
///
/// Results, including "nothing found", are cached on disk for a week, so each
/// address is looked up once.
@MainActor
@Observable
final class Avatars {
    static let shared = Avatars()

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var misses: [String: Date] = [:]
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private var warmedUp: Set<String> = []

    nonisolated static let freeMail: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com", "icloud.com",
        "me.com", "mac.com", "proton.me", "protonmail.com", "aol.com", "gmx.com", "zoho.com", "yandex.com",
        "rediffmail.com", "msn.com", "hey.com", "fastmail.com", "pm.me"
    ]

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Postline/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = UserDefaults.standard.dictionary(forKey: "avatar.misses") as? [String: Double] {
            misses = data.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    /// The image for an address, or nil while it loads or when there is none
    /// (the view then draws initials). Asking starts the lookup.
    func image(for email: String, account: String?, picture: URL? = nil) -> NSImage? {
        let key = email.lowercased()
        if let img = images[key] { return img }
        load(key, account: account, picture: picture)
        return nil
    }

    /// True when the address's avatar is its company's logo rather than a
    /// face; the view insets logos on a white disc.
    func isLogo(_ email: String) -> Bool { logos.contains(email.lowercased()) }
    @ObservationIgnored private var logos: Set<String> = []

    private func load(_ key: String, account: String?, picture: URL?) {
        guard !key.isEmpty, !inFlight.contains(key) else { return }
        let photoFile = dir.appendingPathComponent(Self.hash(key) + ".png")
        let logoFile = dir.appendingPathComponent(Self.hash(key) + "-logo.png")
        if let img = NSImage(contentsOf: photoFile) { images[key] = img; return }
        if let img = NSImage(contentsOf: logoFile) { logos.insert(key); images[key] = img; return }
        if let miss = misses[key], miss.timeIntervalSinceNow > -7 * 86400, picture == nil { return }
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            var data: Data?
            var isLogo = false
            if let picture { data = await Self.download(picture) }
            if data == nil, let account, ProcessInfo.processInfo.environment["POSTLINE_DEMO"] != "1" {
                data = await contactPhoto(key, account: account)
            }
            if data == nil, Preferences.shared.companyLogos {
                data = await Self.domainLogo(for: key)
                isLogo = data != nil
            }
            if let data, let img = NSImage(data: data) {
                try? data.write(to: isLogo ? logoFile : photoFile)
                if isLogo { logos.insert(key) }
                images[key] = img
            } else {
                misses[key] = Date()
                UserDefaults.standard.set(misses.mapValues(\.timeIntervalSince1970), forKey: "avatar.misses")
            }
        }
    }

    /// Forgets every "nothing found", so addresses are looked up again (after
    /// company logos are turned on).
    func forgetMisses() {
        misses = [:]
        UserDefaults.standard.removeObject(forKey: "avatar.misses")
    }

    // MARK: Google Contacts

    private func contactPhoto(_ email: String, account: String) async -> Data? {
        // Google asks for one empty search to warm its index before the
        // first real one returns results.
        if !warmedUp.contains(account) {
            warmedUp.insert(account)
            _ = await search("people:searchContacts", query: "", account: account)
            _ = await search("otherContacts:search", query: "", account: account)
        }
        for endpoint in ["people:searchContacts", "otherContacts:search"] {
            if let url = await search(endpoint, query: email, account: account) {
                return await Self.download(url)
            }
        }
        return nil
    }

    private func search(_ endpoint: String, query: String, account: String) async -> URL? {
        struct Result: Decodable {
            struct Item: Decodable { let person: Person }
            struct Person: Decodable { let photos: [Photo]?; let emailAddresses: [Address]? }
            struct Photo: Decodable { let url: String; let `default`: Bool? }
            struct Address: Decodable { let value: String }
            let results: [Item]?
        }
        guard let token = try? await GoogleAuth.shared.accessToken(for: account) else { return nil }
        var c = URLComponents(url: Config.peopleBase.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "query", value: query), .init(name: "readMask", value: "photos,emailAddresses"), .init(name: "pageSize", value: "5")]
        var request = URLRequest(url: c.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(Result.self, from: data) else { return nil }
        for item in result.results ?? [] where (item.person.emailAddresses ?? []).contains(where: { $0.value.lowercased() == query }) {
            if let photo = item.person.photos?.first(where: { $0.default != true }) {
                return URL(string: photo.url.replacingOccurrences(of: "=s100", with: "=s200"))
            }
        }
        return nil
    }

    // MARK: Company logos

    /// The registrable domain: `mail.notion.so` → `notion.so`,
    /// `alerts.bank.co.in` → `bank.co.in`.
    nonisolated static func rootDomain(of email: String) -> String? {
        guard let host = email.split(separator: "@").last.map(String.init)?.lowercased(), host.contains(".") else { return nil }
        let parts = host.split(separator: ".").map(String.init)
        let twoPartSuffixes: Set<String> = ["co.uk", "co.in", "com.au", "co.jp", "com.br", "co.nz", "org.uk", "ac.in", "gov.in", "net.in"]
        if parts.count >= 3, twoPartSuffixes.contains(parts.suffix(2).joined(separator: ".")) {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    private static func domainLogo(for email: String) async -> Data? {
        guard let domain = rootDomain(of: email), !freeMail.contains(domain) else { return nil }
        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128"),
              let data = await download(url), let img = NSImage(data: data),
              // Google answers unknown domains with a 16-px globe; a real logo
              // comes back at least 32 across.
              (img.representations.first?.pixelsWide ?? Int(img.size.width)) >= 32 else { return nil }
        return data
    }

    private static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
