import Foundation
import Sentry

/// Errors, crashes, hangs, timings and log lines, sent to GlitchTip (a
/// server that speaks Sentry's protocol) through the Sentry SDK, and only
/// while diagnostics are turned on in Settings. They are off by default.
///
/// The address (DSN) is not in the repository: `build.sh` writes it into
/// Info.plist from `MAILER_GLITCHTIP_DSN` or `GlitchTipDSN.txt`, and it is
/// then kept on this Mac, like the Google client ID, because the published
/// updates that replace the build carry none. A Mac that has never run a
/// build with one has no Settings switch and sends nothing.
///
/// What goes out: the error or crash with its stack, the log lines leading
/// up to it, `Log` lines, `Performance` timings as transactions and spans,
/// and main-thread hangs. Log lines and error messages can name an account
/// or an attachment. What does not: network requests are neither traced nor
/// kept as breadcrumbs (Gmail URLs carry message IDs and search words), and
/// the SDK's default user data (IP address, user name) is off.
enum Telemetry {

    /// The GlitchTip project's DSN: this build's, else the one kept on this
    /// Mac; nil when there is neither.
    static var dsn: String? { builtDSN ?? UserDefaults.standard.string(forKey: dsnKey) }

    private static let dsnKey = "glitchTipDSN"

    private static let builtDSN = (Bundle.main.object(forInfoDictionaryKey: "MailerGlitchTipDSN") as? String)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .flatMap { $0.isEmpty ? nil : $0 }

    /// Keeps the DSN this build carries on this Mac.
    static func rememberBuiltDSN() {
        guard let builtDSN else { return }
        UserDefaults.standard.set(builtDSN, forKey: dsnKey)
    }

    static var isAvailable: Bool { dsn != nil }

    /// Where reports go, for Settings.
    static var host: String? { dsn.flatMap { URL(string: $0)?.host } }

    /// Starts or stops reporting to match the setting.
    static func apply(enabled: Bool) {
        if enabled, let dsn {
            guard !SentrySDK.isEnabled else { return }
            SentrySDK.start { configure($0, dsn: dsn) }
        } else if SentrySDK.isEnabled {
            SentrySDK.close()
        }
    }

    /// The SDK's settings. GlitchTip has no sessions, so session tracking
    /// is off; timings come from `Performance`, so the SDK's own automatic
    /// tracing (network, file, UI) is off.
    static func configure(_ options: Options, dsn: String) {
        options.dsn = dsn
        options.releaseName = release
        options.environment = "production"
        options.sendDefaultPii = false
        options.enableAutoSessionTracking = false
        options.enableAutoPerformanceTracing = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableFileIOTracing = false
        options.enableCrashHandler = true
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = 2
        options.enableLogs = true
        options.tracesSampler = { context in
            NSNumber(value: sampleRate(operation: context.transactionContext.operation))
        }
    }

    /// Mail sync runs about 1,150 times an hour with two accounts (measured
    /// 2026-11-27, nearly all of them finding nothing new), so one in twenty
    /// is kept. Everything else is kept whole.
    static func sampleRate(operation: String) -> Double {
        operation.hasPrefix("sync.") ? 0.05 : 1
    }

    /// `mailer@1.1+<commit>`, matching the build to its source.
    static var release: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["MailerGitCommit"] as? String ?? info["CFBundleVersion"] as? String ?? "0"
        return "mailer@\(version)+\(build)"
    }

    // MARK: Reporting

    enum Level { case info, warning, error }

    /// A `Log` line: kept as a breadcrumb for the next error, and sent as a
    /// log entry.
    static func log(_ message: String, level: Level) {
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: level.breadcrumbLevel, category: "log")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        switch level {
        case .info: SentrySDK.logger.info(message)
        case .warning: SentrySDK.logger.warn(message)
        case .error: SentrySDK.logger.error(message)
        }
    }

    /// An error worth looking into, as an issue in GlitchTip. `message` says
    /// what Mailer was doing.
    static func capture(_ message: String, error: Error?) {
        guard SentrySDK.isEnabled else { return }
        guard let error else {
            SentrySDK.capture(message: message) { $0.setLevel(.error) }
            return
        }
        SentrySDK.capture(error: error) { scope in
            scope.setContext(value: ["action": message, "description": error.localizedDescription], key: "mailer")
        }
    }
}

private extension Telemetry.Level {
    var breadcrumbLevel: SentryLevel {
        switch self {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }
}
