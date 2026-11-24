import Foundation

/// The Gmail REST API, for one account. Thin: requests in, decoded JSON out.
/// Retries once on 401 (a just-expired token) and backs off on 429/5xx.
struct GmailAPI: Sendable {
    let email: String

    // MARK: Wire types

    struct Profile: Decodable { let emailAddress: String; let historyId: String; let messagesTotal: Int? }
    struct Ref: Decodable { let id: String; let threadId: String }
    struct ListPage: Decodable { let messages: [Ref]?; let nextPageToken: String?; let resultSizeEstimate: Int? }

    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let size: Int?; let data: String?; let attachmentId: String? }
    struct Part: Decodable {
        let partId: String?
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?
    }
    struct RawMessage: Decodable {
        let id: String
        let threadId: String
        let labelIds: [String]?
        let snippet: String?
        let historyId: String?
        let internalDate: String?
        let payload: Part?
    }
    struct Thread: Decodable { let id: String; let messages: [RawMessage]? }

    struct History: Decodable {
        struct Added: Decodable { let message: Ref }
        struct LabelChange: Decodable { let message: RawMessage; let labelIds: [String]? }
        let id: String
        let messagesAdded: [Added]?
        let messagesDeleted: [Added]?
        let labelsAdded: [LabelChange]?
        let labelsRemoved: [LabelChange]?
    }
    struct HistoryPage: Decodable { let history: [History]?; let nextPageToken: String?; let historyId: String? }

    struct SendAsList: Decodable {
        struct Item: Decodable { let sendAsEmail: String; let displayName: String?; let isDefault: Bool?; let isPrimary: Bool?; let verificationStatus: String? }
        let sendAs: [Item]?
    }

    // MARK: Calls

    func profile() async throws -> Profile { try await get("profile") }

    func list(query: String?, pageToken: String?, max: Int = 500) async throws -> ListPage {
        var items = [URLQueryItem(name: "maxResults", value: "\(max)")]
        if let query { items.append(.init(name: "q", value: query)) }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        return try await get("messages", items)
    }

    func message(_ id: String) async throws -> RawMessage {
        try await get("messages/\(id)", [.init(name: "format", value: "full")])
    }

    /// Headers needed for the arrival time, without the body.
    func arrival(_ id: String) async throws -> RawMessage {
        try await get("messages/\(id)", [.init(name: "format", value: "metadata"),
                                         .init(name: "metadataHeaders", value: "Received"),
                                         .init(name: "metadataHeaders", value: "Date")])
    }

    /// A message's current labels only (format=minimal), for repairs.
    func labels(_ id: String) async throws -> [String] {
        let m: RawMessage = try await get("messages/\(id)", [.init(name: "format", value: "minimal")])
        return m.labelIds ?? []
    }

    func thread(_ id: String) async throws -> Thread {
        try await get("threads/\(id)", [.init(name: "format", value: "full")])
    }

    /// Everything that changed since `startHistoryID`. Throws `.historyGone`
    /// when Gmail has forgotten that point (about a week offline).
    func history(since startHistoryID: String, pageToken: String?) async throws -> HistoryPage {
        var items: [URLQueryItem] = [.init(name: "startHistoryId", value: startHistoryID), .init(name: "maxResults", value: "500")]
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        return try await get("history", items)
    }

    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        struct A: Decodable { let data: String }
        let a: A = try await get("messages/\(messageID)/attachments/\(attachmentID)")
        return Data(base64URL: a.data) ?? Data()
    }

    func sendAs() async throws -> [SendAs] {
        let list: SendAsList = try await get("settings/sendAs")
        return (list.sendAs ?? [])
            .filter { $0.verificationStatus == nil || $0.verificationStatus == "accepted" || $0.isPrimary == true }
            .map { SendAs(email: $0.sendAsEmail.lowercased(), name: $0.displayName ?? "", isDefault: $0.isDefault == true) }
            .sorted { $0.isDefault && !$1.isDefault }
    }

    func modify(_ id: String, add: [String], remove: [String]) async throws {
        struct M: Encodable { let addLabelIds: [String]; let removeLabelIds: [String] }
        _ = try await send("POST", "messages/\(id)/modify", body: M(addLabelIds: add, removeLabelIds: remove)) as Ignored
    }

    func trash(_ id: String) async throws { _ = try await send("POST", "messages/\(id)/trash", body: Optional<Int>.none) as Ignored }
    func untrash(_ id: String) async throws { _ = try await send("POST", "messages/\(id)/untrash", body: Optional<Int>.none) as Ignored }

    func sendRaw(_ mime: Data, threadID: String?) async throws -> Ref {
        struct S: Encodable { let raw: String; let threadId: String? }
        return try await send("POST", "messages/send", body: S(raw: mime.base64URLEncoded, threadId: threadID))
    }

    // MARK: Plumbing

    private struct Ignored: Decodable {}

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = []) async throws -> T {
        var c = URLComponents(url: Config.gmailBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { c.queryItems = items }
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 30
        return try await perform(request)
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?) async throws -> T {
        var request = URLRequest(url: Config.gmailBase.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ base: URLRequest, attempt: Int = 0) async throws -> T {
        var request = base
        let token = try await GoogleAuth.shared.accessToken(for: email)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            if T.self == Ignored.self { return Ignored() as! T }
            return try JSONDecoder().decode(T.self, from: data)
        case 401 where attempt == 0:
            await GoogleAuth.shared.invalidate(email)
            return try await perform(base, attempt: 1)
        case 404 where base.url?.path.hasSuffix("/history") == true:
            throw GmailError.historyGone
        case 404:
            throw GmailError.notFound
        case 403 where String(data: data, encoding: .utf8).map { $0.contains("Quota exceeded") || $0.contains("ateLimitExceeded") } == true:
            // Gmail's per-user budget for this project. Retrying straight
            // away only spends more of it; the sync engine pauses instead.
            throw GmailError.rateLimited
        case 429 where attempt < 4, 500..<600 where attempt < 4:
            try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 0.5 * 1_000_000_000))
            return try await perform(base, attempt: attempt + 1)
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PostlineError("Gmail returned \(status) for \(base.url?.lastPathComponent ?? ""): \(text.prefix(200))")
        }
    }
}

enum GmailError: Error, LocalizedError {
    case historyGone, notFound, rateLimited
    var errorDescription: String? {
        switch self {
        case .historyGone: "Gmail no longer has that change history."
        case .notFound: "That message is gone from Gmail."
        case .rateLimited: "Gmail asked Postline to slow down for a minute."
        }
    }
}
