import Foundation

/// A plain log file at ~/Library/Logs/Postline.log, readable with Console or
/// `tail`. NSLog alone was not enough: on this Mac the unified log is not
/// readable from a terminal, and the live connection's failures were invisible
/// (2026-11-12). Kept under 1 MB by starting over when it grows past that.
///
/// With diagnostics on, every line also goes to GlitchTip (Telemetry), and
/// `error` raises an issue there. A failure caused by the Mac being offline
/// is only a warning: it fixes itself and would otherwise raise an issue on
/// every sync.
enum Log {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Postline.log")
    private static let queue = DispatchQueue(label: "mailer.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Something that happened.
    static func write(_ message: String) {
        append(message)
        Telemetry.log(message, level: .info)
    }

    /// Something went wrong that Mailer recovers from by itself.
    static func warning(_ message: String) {
        append("WARNING " + message)
        Telemetry.log(message, level: .warning)
    }

    /// Something failed. `message` says what Mailer was doing; the error's
    /// description is added to the line.
    static func error(_ message: String, _ error: Error? = nil) {
        let line = error.map { "\(message) — \($0.localizedDescription)" } ?? message
        if let error, isConnectivityFailure(error) {
            warning(line)
            return
        }
        append("ERROR " + line)
        Telemetry.log(line, level: .error)
        Telemetry.capture(message, error: error)
    }

    /// The Mac is offline or the connection dropped: not Mailer's fault.
    static func isConnectivityFailure(_ error: Error) -> Bool {
        let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                           .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                           .internationalRoamingOff, .dataNotAllowed]
        return (error as? URLError).map { offline.contains($0.code) } ?? false
    }

    private static func append(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        NSLog("Mailer: %@", message)
        queue.async {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
