import SwiftUI
import AppKit

@main
struct PostlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @State private var prefs = Preferences.shared

    var body: some Scene {
        Window("Postline", id: "main") {
            Group {
                if !model.isDemo && (!prefs.onboarded || model.accounts.isEmpty) {
                    OnboardingView(model: model)
                } else {
                    MainView(model: model)
                }
            }
            .frame(minWidth: 1080, minHeight: 640)
            .background(WindowOpener(model: model))
            .onAppear {
                KeyShortcuts.install(model)
                RowSwipe.shared.install()
                RowSwipe.shared.onCommit = { message, edge in
                    if edge == .leading { model.swipeArchive(message) } else { model.swipeTrash(message) }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Email") { model.compose() }.keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { NotificationCenter.default.post(name: .postlineFocusSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Message") {
                Button("Reply") { model.reply() }.keyboardShortcut("r", modifiers: .command)
                Button("Reply All") { model.reply(all: true) }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Forward") { model.forward() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Archive") { model.archive() }.keyboardShortcut("e", modifiers: .command)
                Button("Move to Trash") { model.trash() }.keyboardShortcut(.delete, modifiers: .command)
                Button("Mark as Read/Unread") { model.toggleUnread() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Pin") { model.togglePin() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export for AI…") { model.exportingThread = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.thread.isEmpty)
            }
        }

        Settings {
            SettingsView(model: model)
        }

        // Not there normally — Postline has no Dock icon and no menu bar icon
        // (owner, 2026-11-14). It appears for five minutes when new Primary
        // mail arrives (an envelope) or a sign-in code does (a key, until the
        // code is copied), then leaves by itself.
        MenuBarExtra(isInserted: Binding(get: { model.menuIconVisible }, set: { inserted in
            // SwiftUI reports "not inserted" while setting the icon up; acting
            // on that when nothing is showing re-rendered forever (measured:
            // main thread pinned, 2026-11-14). Only a real removal counts.
            if !inserted && model.menuIconVisible { model.hideMenuIcon() }
        })) {
            MenuBarView(model: model)
        } label: {
            Image(nsImage: menuBarIcon(model.menuIcon.showsCode ? .key : .mail))
        }
    }

    private func menuBarIcon(_ icon: Icon) -> NSImage {
        let img = icon.image.copy() as! NSImage
        img.size = NSSize(width: 16, height: 16)
        img.isTemplate = true
        return img
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.appearance = Preferences.shared.appearance.nsAppearance
            AppModel.shared.start()
            MinimizeHides.shared.install()
            // Started by "Open at login": run in the background, no window.
            let event = NSAppleEventManager.shared().currentAppleEvent
            if event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
                DispatchQueue.main.async {
                    NSApp.windows.filter { $0.identifier?.rawValue.contains("main") == true }.forEach { $0.orderOut(nil) }
                }
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Closing the window keeps Postline running in the background, so mail
    /// and codes still arrive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening Postline again from Applications or Spotlight while it runs
    /// in the background brings its window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showMainWindow() }
        return false
    }

}

/// Hands the window-opening action to the model, so a notification click or
/// a reopen from Applications can bring the window back after it was closed.
private struct WindowOpener: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Spark's single-key shortcuts, active whenever you aren't typing:
/// J/K move, E archives, # trashes, R/A/F reply, reply all, forward,
/// C composes, S pins, U toggles read, / searches, Esc closes a bucket.
@MainActor
enum KeyShortcuts {
    private static var monitor: Any?

    static func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Leave every key alone while a text field or editor has focus.
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            // ⌘Z undoes the last archive, trash or send while its toast is up.
            // The standard Edit → Undo menu item owns ⌘Z and took it before the
            // toast's own button could (found testing on real mail, 2026-11-12).
            if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               event.charactersIgnoringModifiers == "z", let undo = model.toast?.undo {
                undo()
                model.toast = nil
                return nil
            }
            // ⌘A selects every conversation in the list.
            if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               event.charactersIgnoringModifiers == "a" {
                model.selectAll()
                return nil
            }
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            // While writing, letters are letters. On 2026-11-12 a compose box
            // that hadn't taken focus turned a typed sentence into archive,
            // pin and forward commands on real mail; never again.
            if model.composing != nil { return event }
            // In select mode the keys act on the selection.
            if model.selecting {
                switch (event.charactersIgnoringModifiers, event.keyCode) {
                case ("e", _): model.batchArchive()
                case ("#", _), (_, 51), (_, 117): model.batchTrash()   // # · Delete · Forward Delete
                case (_, 53): model.selecting = false                  // Esc
                default: return event
                }
                return nil
            }
            guard NSApp.keyWindow?.identifier?.rawValue.contains("main") == true || NSApp.keyWindow?.title == "Postline" else { return event }
            switch event.charactersIgnoringModifiers {
            case "j": model.move(1)
            case "k": model.move(-1)
            case "e": model.archive()
            case "#": model.trash()
            case "r": model.reply()
            case "a": model.reply(all: true)
            case "f": model.forward()
            case "c": model.compose()
            case "s": model.togglePin()
            case "u": model.toggleUnread()
            case "/": NotificationCenter.default.post(name: .postlineFocusSearch, object: nil)
            default:
                switch event.keyCode {
                case 125: model.move(1)          // ↓
                case 126: model.move(-1)         // ↑
                case 53:                          // Esc
                    if model.composing != nil { return event }
                    if !model.searchText.isEmpty { model.searchText = "" }
                    else { return event }
                default: return event
                }
            }
            return nil
        }
    }
}
