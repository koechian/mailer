import Foundation

/// A plain log file at ~/Library/Logs/Postline.log, readable with Console or
/// `tail`. NSLog alone was not enough: on this Mac the unified log is not
/// readable from a terminal, and the live connection's failures were invisible
/// (2026-11-12). Kept under 1 MB by starting over when it grows past that.
enum Log {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Postline.log")
    private static let queue = DispatchQueue(label: "mailer.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
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
