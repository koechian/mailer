import AppKit
import SwiftUI

/// The compose editor: a real NSTextView (so macOS's own spelling
/// autocorrect, grammar underlines, smart quotes and Writing Tools all work)
/// with two writing aids from `Writer`:
///
/// * **Ghost text** — when you pause at the end of a line, the next few words
///   appear faintly after the cursor. Tab or → accepts them; any other key
///   (or a click) clears them. They are never part of the draft until taken.
/// * **Grammar fixes** — when you pause, each sentence you've *finished*
///   (it ends in . ! ? or a line break) is proofread and corrected in place
///   with a brief soft highlight; ⌘Z undoes a fix. The sentence under the
///   cursor and the quoted mail below are never touched, so nothing moves
///   while you type.
struct SmartEditor: NSViewRepresentable {
    @Binding var text: String
    /// The email being replied to, for better suggestions.
    var replyingTo: String?
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = GhostTextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 14)
        view.textColor = NSColor(Theme.ink)
        view.insertionPointColor = NSColor(Theme.accent)
        view.textContainerInset = NSSize(width: 15, height: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = Self.typing
        // macOS's own help, all on: spelling fixed as you type, grammar
        // underlined, smart quotes and dashes.
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isGrammarCheckingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.smartInsertDeleteEnabled = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        // Start right after what's already written (a chosen quick reply),
        // above the quoted email — ready to keep typing.
        let ns = text as NSString
        let written = ns.substring(to: Coordinator.writableEnd(of: text))
        let caret = (written.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) as NSString).length
        view.setSelectedRange(NSRange(location: caret, length: 0))
        scroll.documentView = view
        context.coordinator.textView = view

        view.wantsFocusOnWindow = focusOnAppear
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.textView, view.plainText != text else { return }
        view.clearGhost()
        view.string = text
    }

    static var typing: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(Theme.ink), .paragraphStyle: p]
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SmartEditor
        weak var textView: GhostTextView?
        private var ghostTask: Task<Void, Never>?
        private var grammarTask: Task<Void, Never>?
        /// Sentences already proofread (as they read now), never sent twice.
        private var checked: Set<String> = []
        private var applyingFix = false

        init(_ parent: SmartEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            parent.text = view.plainText
            guard !applyingFix else { return }
            schedule()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Moving the cursor away from a suggestion drops it.
            guard let view = textView, let ghost = view.ghostRange else { return }
            if view.selectedRange() != NSRange(location: ghost.location, length: 0) { view.clearGhost() }
        }

        private func schedule() {
            ghostTask?.cancel()
            grammarTask?.cancel()
            let prefs = Preferences.shared
            if prefs.ghostText {
                ghostTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.suggest()
                }
            }
            if prefs.fixGrammar {
                grammarTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.proofreadFinished()
                }
            }
        }

        // MARK: Ghost text

        private func suggest() async {
            guard let view = textView, view.ghostRange == nil, view.window?.firstResponder === view else { return }
            let caret = view.selectedRange()
            guard caret.length == 0 else { return }
            let ns = view.string as NSString
            // Only at the end of a line, and only in what you're writing (not the quote).
            let atLineEnd = caret.location == ns.length || ns.character(at: caret.location) == 10
            let written = ns.substring(to: caret.location)
            guard atLineEnd, written.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3,
                  !written.hasSuffix("\n"), caret.location <= Self.writableEnd(of: view.string) else { return }
            let before = view.string
            guard let words = await Writer.shared.continuation(of: written, replyingTo: parent.replyingTo),
                  !Task.isCancelled, view.string == before, view.selectedRange() == caret else { return }
            view.showGhost(words, at: caret.location)
        }

        // MARK: Grammar

        /// Where the text you're writing ends: the quoted reply or forwarded
        /// message below it is someone else's words and is left alone.
        static func writableEnd(of text: String) -> Int {
            let ns = text as NSString
            var end = ns.length
            for marker in [#"\nOn [^\n]{3,200} wrote:"#, "\n---------- Forwarded message"] {
                let r = ns.range(of: marker, options: .regularExpression)
                if r.location != NSNotFound { end = min(end, r.location) }
            }
            return end
        }

        /// Finished sentences before the cursor that haven't been checked.
        static func finishedSentences(in text: String, caret: Int) -> [NSRange] {
            let ns = text as NSString
            let limit = min(caret, writableEnd(of: text))
            guard limit > 0 else { return [] }
            let pattern = #"[^\n.!?]*[^\s\n.!?][^\n.!?]*(?:[.!?]+(?=\s)|(?=\n))"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: text, range: NSRange(location: 0, length: limit)).map(\.range).filter { r in
                let s = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                // A finished sentence ends before the cursor and has some words in it.
                return NSMaxRange(r) < caret && s.split(separator: " ").count >= 2
            }
        }

        private func proofreadFinished() async {
            guard let view = textView else { return }
            for range in Self.finishedSentences(in: view.plainText, caret: view.selectedRange().location) {
                guard !Task.isCancelled else { return }
                let ns = view.plainText as NSString
                guard NSMaxRange(range) <= ns.length else { continue }
                let raw = ns.substring(with: range)
                let lead = raw.prefix { $0 == " " }
                let sentence = String(raw.dropFirst(lead.count))
                guard !sentence.isEmpty, !checked.contains(sentence) else { continue }
                checked.insert(sentence)
                guard let fixed = await Writer.shared.proofread(sentence), !Task.isCancelled else { continue }
                checked.insert(fixed)
                // Only if that text is still exactly there and the cursor is past it.
                let target = NSRange(location: range.location + lead.utf16.count, length: (sentence as NSString).length)
                let now = view.plainText as NSString
                guard NSMaxRange(target) <= now.length, now.substring(with: target) == sentence,
                      view.selectedRange().location > NSMaxRange(target) || view.window?.firstResponder !== view else { continue }
                apply(fixed, to: target, in: view)
            }
        }

        private func apply(_ fixed: String, to range: NSRange, in view: GhostTextView) {
            view.clearGhost()
            let caret = view.selectedRange()
            applyingFix = true
            defer { applyingFix = false }
            // Through shouldChange/didChange so the fix is one ⌘Z.
            guard view.shouldChangeText(in: range, replacementString: fixed) else { return }
            view.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: fixed, attributes: SmartEditor.typing))
            view.didChangeText()
            view.undoManager?.setActionName("Grammar Fix")
            let delta = (fixed as NSString).length - range.length
            view.setSelectedRange(NSRange(location: caret.location + (caret.location >= NSMaxRange(range) ? delta : 0), length: 0))
            // A soft green wash over what changed, fading away.
            let changed = NSRange(location: range.location, length: (fixed as NSString).length)
            view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor(Theme.green).withAlphaComponent(0.16), forCharacterRange: changed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak view] in
                guard let lm = view?.layoutManager, let len = view?.string.utf16.count else { return }
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: len))
            }
            Log.write("writer: fixed grammar")
            // The fix cleared any ghost text; ask again for the line being typed.
            if Preferences.shared.ghostText {
                ghostTask?.cancel()
                ghostTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.suggest()
                }
            }
        }
    }
}

/// An NSTextView that can show a faint suggestion after the cursor without
/// it ever being part of the text you wrote.
final class GhostTextView: NSTextView {
    weak var coordinator: SmartEditor.Coordinator?
    /// Take keyboard focus as soon as this view is in a window. An async
    /// makeFirstResponder from makeNSView ran before the window existed and
    /// silently did nothing, leaving focus on the Send button.
    var wantsFocusOnWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocusOnWindow, let window else { return }
        wantsFocusOnWindow = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }
    private(set) var ghostRange: NSRange?
    static let ghostKey = NSAttributedString.Key("postline.ghost")

    /// The draft without any suggestion in it.
    var plainText: String {
        guard let g = ghostRange, NSMaxRange(g) <= (string as NSString).length else { return string }
        return (string as NSString).replacingCharacters(in: g, with: "")
    }

    func showGhost(_ words: String, at location: Int) {
        clearGhost()
        var attrs = SmartEditor.typing
        attrs[.foregroundColor] = NSColor(Theme.muted2)
        attrs[Self.ghostKey] = true
        // Straight into storage: not an edit, not in Undo, not in the draft.
        textStorage?.insert(NSAttributedString(string: words, attributes: attrs), at: location)
        ghostRange = NSRange(location: location, length: (words as NSString).length)
        setSelectedRange(NSRange(location: location, length: 0))
        typingAttributes = SmartEditor.typing
    }

    func clearGhost() {
        guard let g = ghostRange else { return }
        ghostRange = nil
        if NSMaxRange(g) <= (string as NSString).length { textStorage?.deleteCharacters(in: g) }
        typingAttributes = SmartEditor.typing
    }

    /// Takes the suggestion as real text (one Undo step).
    private func acceptGhost() {
        guard let g = ghostRange else { return }
        let words = (string as NSString).substring(with: g)
        clearGhost()
        insertText(words, replacementRange: NSRange(location: g.location, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        if ghostRange != nil {
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if plain && (event.keyCode == 48 || event.keyCode == 124) {   // Tab or →
                acceptGhost()
                return
            }
            clearGhost()
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        clearGhost()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        clearGhost()
        return super.resignFirstResponder()
    }
}
