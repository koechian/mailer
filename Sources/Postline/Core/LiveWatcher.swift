import Foundation

/// Keeps one IMAP connection per account sitting in IDLE on the Inbox, so
/// Gmail tells Postline about new mail the instant it lands — usually within
/// a second or two. It never downloads anything over IMAP: each ping just
/// calls `onChange`, and the sync engine asks the Gmail API what changed.
///
/// Gmail drops an idle connection after about 29 minutes, so IDLE is renewed
/// every 9; a dropped connection is retried with a growing pause.
actor LiveWatcher {
    private let email: String
    private let onChange: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(email: String, onChange: @escaping @Sendable () async -> Void) {
        self.email = email
        self.onChange = onChange
    }

    func start() {
        guard task == nil else { return }
        task = Task { await self.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            let client = IMAPClient(email: email)
            do {
                Log.write("live \(email): connecting")
                try await client.connect()
                Log.write("live \(email): connected, signing in")
                let token = try await GoogleAuth.shared.accessToken(for: email)
                do {
                    try await client.authenticate(accessToken: token)
                } catch IMAPError.authFailed {
                    // A token that expired between refresh and use: get a new
                    // one and try once more before backing off.
                    await GoogleAuth.shared.invalidate(email)
                    try await client.authenticate(accessToken: try await GoogleAuth.shared.accessToken(for: email))
                }
                _ = try await client.selectInboxUIDNext()
                Log.write("live \(email): watching Inbox (IDLE)")
                backoff = 2
                // Catch anything that arrived while disconnected.
                await onChange()
                while !Task.isCancelled {
                    try await client.idle(maxSeconds: 9 * 60)
                    guard await client.idleSupported else { Log.write("live \(email): server refused IDLE"); break }
                    Log.write("live \(email): Inbox changed, syncing")
                    await onChange()
                }
            } catch {
                Log.write("live \(email): dropped — \(error.localizedDescription) [\(error)]")
            }
            await client.disconnect()
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 120)
        }
    }
}
