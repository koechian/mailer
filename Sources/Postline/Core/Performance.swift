import Foundation
import os

/// Timings of the operations that have to stay fast: opening an email,
/// listing a mailbox, searching, syncing.
///
/// Each measurement goes two ways:
///
/// * **Instruments.** An `os_signpost` interval in the Points of Interest
///   lane, beside the Time Profiler's samples, so a slow interval can be
///   opened up to see what the CPU was doing in it.
/// * **A local file**, `~/Library/Logs/Postline-performance.jsonl`, one JSON
///   object per line (`op`, `ms`, `at`, and optional `detail`).
///   `tools/performance_report.py` turns it into median, 90th, 99th
///   percentile and worst case per operation, so a change can be measured
///   against the same use before and after.
///
/// Nothing leaves the Mac. The file is started over when it passes 5 MB.
enum Performance {

    static let signposter = OSSignposter(subsystem: Config.bundleID, category: .pointsOfInterest)

    /// An operation that ends later, in a callback (a page finishing loading).
    struct Interval: Sendable {
        let name: StaticString
        let started: ContinuousClock.Instant
        let state: OSSignpostIntervalState

        /// Milliseconds since the interval began, without ending it.
        var elapsed: Double { Performance.milliseconds(ContinuousClock.now - started) }

        func end(_ detail: [String: String] = [:]) {
            Performance.signposter.endInterval(name, state)
            Performance.record(String(describing: name), ms: elapsed, detail: detail)
        }
    }

    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, started: .now, state: signposter.beginInterval(name))
    }

    /// Times a synchronous piece of work.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ detail: [String: String] = [:], _ work: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { interval.end(detail) }
        return try work()
    }

    /// Times an asynchronous piece of work.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ detail: [String: String] = [:], _ work: () async throws -> T) async rethrows -> T {
        let interval = begin(name)
        defer { interval.end(detail) }
        return try await work()
    }

    /// Records a duration measured some other way.
    static func record(_ op: String, ms: Double, detail: [String: String] = [:]) {
        var entry: [String: Any] = ["op": op, "ms": (ms * 100).rounded() / 100,
                                    "at": Date().timeIntervalSince1970.rounded()]
        if !detail.isEmpty { entry["detail"] = detail }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        queue.async { append(data + Data("\n".utf8)) }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    // MARK: The file

    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Postline-performance.jsonl")
    private static let queue = DispatchQueue(label: "postline.performance", qos: .utility)
    /// Test runs measure too, but their numbers are not the app's.
    private static let isTestRun = NSClassFromString("XCTestCase") != nil

    private static func append(_ line: Data) {
        guard !isTestRun else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 5_000_000 { try? FileManager.default.removeItem(at: url) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

/// Opening an email, from the click to the last message of the thread
/// drawn. Each message with HTML reports when its page is ready; the open is
/// recorded when the last one does.
@MainActor
enum ReaderTiming {
    private static var open: (interval: Performance.Interval, threadID: String, waiting: Int, messages: Int)?

    static func began(threadID: String, messages: Int, withHTML: Int) {
        let interval = Performance.begin("reader.open")
        open = (interval, threadID, withHTML, messages)
        if withHTML == 0 { finish() }
    }

    /// One message's page is ready (`domReady`: text laid out; otherwise the
    /// whole page, images included, has loaded).
    static func messageReady(threadID: String) {
        guard var current = open, current.threadID == threadID else { return }
        current.waiting -= 1
        open = current
        if current.waiting <= 0 { finish() }
    }

    private static func finish() {
        guard let current = open else { return }
        current.interval.end(["messages": "\(current.messages)"])
        open = nil
    }
}
