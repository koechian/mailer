import AppKit
import Observation
import ServiceManagement

/// The handful of settings Postline has. Stored in UserDefaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    enum Notify: String, CaseIterable, Identifiable {
        case all, people, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All new mail"
            case .people: "Only people"
            case .none: "Only codes"
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            NSApp.appearance = appearance.nsAppearance
        }
    }

    var notify: Notify {
        didSet { UserDefaults.standard.set(notify.rawValue, forKey: "notify") }
    }
    /// Off by default: a code is copied when you press Copy code.
    var autoCopyCodes: Bool {
        didSet { UserDefaults.standard.set(autoCopyCodes, forKey: "autoCopyCodes") }
    }
    /// Writing help, all on this Mac (Writer.swift).
    var suggestReplies: Bool { didSet { UserDefaults.standard.set(suggestReplies, forKey: "suggestReplies") } }
    var ghostText: Bool { didSet { UserDefaults.standard.set(ghostText, forKey: "ghostText") } }
    var fixGrammar: Bool { didSet { UserDefaults.standard.set(fixGrammar, forKey: "fixGrammar") } }

    var onboarded: Bool {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }
    var openAtLogin: Bool {
        didSet {
            if openAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    private init() {
        let d = UserDefaults.standard
        // Light by default, like the reference screens; System and Dark in Settings.
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .light
        notify = Notify(rawValue: d.string(forKey: "notify") ?? "") ?? .all
        autoCopyCodes = d.bool(forKey: "autoCopyCodes")
        onboarded = d.bool(forKey: "onboarded")
        suggestReplies = d.object(forKey: "suggestReplies") as? Bool ?? true
        ghostText = d.object(forKey: "ghostText") as? Bool ?? true
        fixGrammar = d.object(forKey: "fixGrammar") as? Bool ?? true
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
