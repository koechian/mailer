import AppKit

/// Minimizing hides the window instead of sending it to the Dock.
///
/// Postline has no Dock icon (LSUIElement), but macOS still parks a
/// minimized window in the Dock as a thumbnail beside the Trash — which read
/// as "Postline is in my Dock" (owner, 2026-11-14). So the yellow button puts
/// the window away the way closing does; opening Postline again from
/// Applications, Spotlight or the menu bar icon brings it back.
@MainActor
final class MinimizeHides: NSObject {
    static let shared = MinimizeHides()

    func install() {
        let center = NotificationCenter.default
        // The yellow button: retarget it on every window as it becomes key.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      let button = window.standardWindowButton(.miniaturizeButton),
                      button.target !== MinimizeHides.shared else { return }
                button.target = MinimizeHides.shared
                button.action = #selector(MinimizeHides.putAway(_:))
            }
        }
        // Anything that still minimizes (⌘M, double-clicking the title bar):
        // bring it straight back out of the Dock and put it away instead.
        // Coming out of the Dock is animated, and hiding before it ends was
        // undone by it (measured), so the hide waits for it to finish.
        center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                MinimizeHides.shared.leaving.insert(ObjectIdentifier(window))
                window.deminiaturize(nil)
            }
        }
        center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      MinimizeHides.shared.leaving.remove(ObjectIdentifier(window)) != nil else { return }
                window.orderOut(nil)
            }
        }
    }

    /// Windows on their way out of the Dock, to be put away once out.
    private var leaving: Set<ObjectIdentifier> = []

    @objc func putAway(_ sender: NSButton) {
        sender.window?.orderOut(nil)
    }
}
