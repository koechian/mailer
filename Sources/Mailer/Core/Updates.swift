import Foundation
import Sparkle

/// Mailer's updates, through Sparkle.
///
/// Every merge to `main` is built and signed on GitHub and published as a
/// release; the release's `appcast.xml` names the newest build, and GitHub
/// always serves the latest release's copy at the same address (`SUFeedURL`
/// in Info.plist). Mailer checks it every hour. A newer build is downloaded
/// in the background, checked against the EdDSA key in Info.plist
/// (`SUPublicEDKey`) and against Mailer's own code signature, and installed
/// when Mailer quits. Meanwhile the header says an update is ready, with a
/// button to restart into it now (owner, 2026-11-27: "install quietly on quit,
/// and let me know in the app").
///
/// The version is `<base>.<commits on main>` (build.sh), so a build of the
/// same commit is never offered as an update to itself.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    /// A downloaded update waiting for Mailer to quit.
    struct Ready {
        let version: String
        let installNow: () -> Void
    }

    private var controller: SPUStandardUpdaterController?

    /// Starts the hourly checks. Not in demo mode: a demo is a separate
    /// copy, not one to update.
    func start() {
        guard ProcessInfo.processInfo.environment["MAILER_DEMO"] != "1", controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var isRunning: Bool { controller != nil }

    /// Mailer → Check for Updates…: Sparkle's own window says what it found.
    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// "1.2.140 (140)", for Settings.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: SPUUpdaterDelegate

    /// The update is downloaded and will be installed when Mailer quits.
    /// True: Mailer shows its own notice instead of Sparkle's window.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            AppModel.shared.updateReady = Ready(version: version, installNow: immediateInstallationBlock)
            Log.write("update: \(version) downloaded, installs on quit")
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { Log.write("update: stopped — \(message)") }
    }
}
