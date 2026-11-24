import AppKit
import Observation
import SwiftUI

/// Two-finger trackpad swipes on message rows, as in Mail and Spark:
/// swipe right to archive, swipe left to move to Trash.
///
/// macOS has no row-swipe gesture outside `List`, so this reads the
/// trackpad's horizontal scroll events directly:
///
/// * **Track** — while the fingers are down the row moves with them 1:1, no
///   animation. The axis is decided in the first 8 pt: mostly vertical goes
///   on scrolling the list untouched, mostly horizontal belongs to the row.
/// * **Release** — when the fingers lift, a spring finishes it, seeded with
///   the swipe's speed. It commits on distance OR a flick
///   (`offset + velocity × 0.18` past the threshold), otherwise it snaps
///   back fast and stiff.
/// * The coloured bed, its icon and the haptic tick are all read from the
///   one offset, so reversing mid-swipe stays in sync.
@MainActor
@Observable
final class RowSwipe {
    static let shared = RowSwipe()

    /// The row being swiped and how far, in points (+ right, − left).
    private(set) var key: String?
    private(set) var offset: CGFloat = 0
    /// A row the pointer is over, reported by the rows themselves.
    @ObservationIgnored var hovered: (key: String, message: Message, width: CGFloat)?
    @ObservationIgnored var onCommit: ((Message, Edge) -> Void)?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var owning = false
    @ObservationIgnored private var swallowMomentum = false
    @ObservationIgnored private var undecided = CGSize.zero
    @ObservationIgnored private var samples: [(t: TimeInterval, x: CGFloat)] = []
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var target: (message: Message, width: CGFloat)?
    @ObservationIgnored var enabled = true

    /// How far a swipe must go to count, as a share of the row.
    static let commitShare: CGFloat = 0.38

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Returns true when the event was used for a swipe (and must not scroll).
    private func handle(_ event: NSEvent) -> Bool {
        // Only real two-finger trackpad gestures; a mouse wheel never swipes.
        guard event.hasPreciseScrollingDeltas else { return false }

        // The trackpad keeps sending "momentum" after the fingers lift; after a
        // swipe we owned, swallow it so the list doesn't drift.
        if event.momentumPhase != [] { return swallowMomentum }

        switch event.phase {
        case .began:
            swallowMomentum = false
            guard enabled, let hovered else { owning = false; return false }
            owning = false
            undecided = .zero
            samples = []
            target = (hovered.message, hovered.width)
            key = nil
            return false
        case .changed:
            guard let target else { return false }
            if !owning {
                undecided.width += event.scrollingDeltaX
                undecided.height += event.scrollingDeltaY
                guard max(abs(undecided.width), abs(undecided.height)) >= 8 else { return false }
                guard abs(undecided.width) > abs(undecided.height) * 1.2 else { self.target = nil; return false }
                owning = true
                armed = false
                key = AppModel.key(target.message)
                setOffset(undecided.width, width: target.width)
                return true
            }
            setOffset(offset + event.scrollingDeltaX, width: target.width)
            return true
        case .ended, .cancelled:
            guard owning, let target else { self.target = nil; return false }
            release(target.message, width: target.width)
            owning = false
            swallowMomentum = true
            self.target = nil
            return true
        default:
            return owning
        }
    }

    /// Track phase: no animation; rubber-band past the row's width.
    private func setOffset(_ raw: CGFloat, width: CGFloat) {
        var t = Transaction()
        t.disablesAnimations = true
        let limit = width * 0.92
        let x = abs(raw) <= limit ? raw : (raw > 0 ? 1 : -1) * (limit + (abs(raw) - limit) * 0.2)
        withTransaction(t) { offset = x }
        samples.append((ProcessInfo.processInfo.systemUptime, x))
        samples = samples.filter { samples.last!.t - $0.t < 0.1 }
        // One light tick when crossing the threshold, either way.
        let past = abs(x) >= width * Self.commitShare
        if past != armed {
            armed = past
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Release phase: commit on distance or flick, else snap back.
    private func release(_ message: Message, width: CGFloat) {
        let velocity: CGFloat = {
            guard let first = samples.first, let last = samples.last, last.t > first.t else { return 0 }
            return (last.x - first.x) / CGFloat(last.t - first.t)
        }()
        let projected = offset + velocity * 0.18
        let threshold = width * Self.commitShare
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Commit only in the direction the row is already showing.
        if abs(projected) >= threshold && (projected > 0) == (offset > 0) {
            let edge: Edge = projected > 0 ? .leading : .trailing
            let end = (projected > 0 ? 1 : -1) * (width + 40)
            let remaining = end - offset
            let spring: Animation = reduce ? .easeOut(duration: 0.12)
                : .interpolatingSpring(mass: 1, stiffness: 320, damping: 34,
                                       initialVelocity: remaining == 0 ? 0 : Double(velocity / remaining))
            withAnimation(spring) { offset = end }
            // The row leaves first, then the mail moves.
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0.12 : 0.22)) { [weak self] in
                self?.onCommit?(message, edge)
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { self?.offset = 0; self?.key = nil }
            }
        } else {
            // Fast, stiff, well damped: the UI never argues.
            withAnimation(reduce ? .easeOut(duration: 0.1) : .spring(response: 0.24, dampingFraction: 0.9)) { offset = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.offset == 0 { self?.key = nil }
            }
        }
        armed = false
    }
}

/// The bed under a swiping row: green Archive on the left, red Trash on the
/// right, its icon growing in as the swipe nears the threshold.
struct SwipeBed: View {
    let offset: CGFloat
    let width: CGFloat

    var body: some View {
        let progress = min(1, abs(offset) / max(1, width * RowSwipe.commitShare))
        let right = offset > 0
        ZStack(alignment: right ? .leading : .trailing) {
            (right ? Theme.green : Theme.red)
                .opacity(0.25 + 0.75 * progress)
            HStack(spacing: 7) {
                IconView(right ? .archive : .trash, size: 18)
                Text(right ? "Archive" : "Trash").font(.calloutStrong)
            }
            .foregroundStyle(.white)
            .opacity(progress)
            .scaleEffect(0.85 + 0.15 * progress)
            .padding(.horizontal, 22)
        }
        .accessibilityHidden(true)
    }
}

/// Wraps a row so it can be swiped: reports its size and hover to
/// `RowSwipe`, draws the bed underneath, and slides by the tracked offset.
struct SwipeableRow<Content: View>: View {
    let message: Message
    let enabled: Bool
    @ViewBuilder let content: () -> Content
    @State private var width: CGFloat = 360
    private var swipe: RowSwipe { RowSwipe.shared }

    var body: some View {
        let key = AppModel.key(message)
        let offset = swipe.key == key ? swipe.offset : 0
        content()
            .offset(x: offset)
            .background {
                if offset != 0 { SwipeBed(offset: offset, width: width) }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onHover { inside in
                if inside, enabled {
                    swipe.hovered = (key, message, width)
                } else if swipe.hovered?.key == key {
                    swipe.hovered = nil
                }
            }
    }
}
