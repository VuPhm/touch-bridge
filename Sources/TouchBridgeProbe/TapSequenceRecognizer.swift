import Foundation
import CoreGraphics
import Cocoa

/// Tracks whether a completed tap can pair with subsequent taps (double-tap, triple-tap).
/// Each completed tap is delivered immediately; this type never delays or replays click 1.
final class TapSequenceRecognizer {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)

    static let spatialTolerancePt: CGFloat = 24.0

    var onFirstTap: ((InteractionSession) -> Void)?
    var onPairedSecondTap: ((InteractionSession) -> Void)?
    var onTripleTap: ((InteractionSession) -> Void)?
    var enableTripleTap: Bool = false

    private struct PairingCandidate {
        let point: CGPoint
        let completedAt: Date
        let count: Int
        let generation: UInt64
    }

    private var doubleTapInterval: TimeInterval
    private var scheduler: Scheduler
    private var cancelTimeout: (() -> Void)?
    private var pairingCandidate: PairingCandidate?
    public private(set) var currentSequenceCount: Int = 0
    private var generation: UInt64 = 0

    init(doubleTapInterval: TimeInterval = NSEvent.doubleClickInterval, scheduler: Scheduler? = nil) {
        self.doubleTapInterval = max(0.01, doubleTapInterval)
        self.scheduler = scheduler ?? { delay, action in
            let item = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }
    }

    var hasPairingCandidate: Bool { pairingCandidate != nil }
    var isSecondTapCandidate: Bool { currentSequenceCount == 2 }
    var isThirdTapCandidate: Bool { currentSequenceCount == 3 }

    func configureForTesting(doubleTapInterval: TimeInterval, scheduler: @escaping Scheduler) {
        reset()
        self.doubleTapInterval = max(0.01, doubleTapInterval)
        self.scheduler = scheduler
    }

    /// Called when a new primary contact begins. The previous click has already
    /// completed; a mismatch simply starts a fresh independent tap sequence.
    @discardableResult
    func beginCandidate(at point: CGPoint, now: Date) -> Bool {
        guard let previous = pairingCandidate else {
            currentSequenceCount = 1
            return false
        }

        let elapsed = now.timeIntervalSince(previous.completedAt)
        let distance = hypot(point.x - previous.point.x, point.y - previous.point.y)
        guard elapsed >= 0, elapsed <= doubleTapInterval, distance <= Self.spatialTolerancePt else {
            clearPairingCandidate()
            currentSequenceCount = 1
            return false
        }

        cancelTimeout?()
        cancelTimeout = nil
        currentSequenceCount = previous.count + 1
        return true
    }

    func completeCandidate(_ session: InteractionSession, at point: CGPoint, now: Date) {
        let count = currentSequenceCount
        currentSequenceCount = 0

        if count == 2 {
            // Completed 2nd tap! Pair with click 2.
            // Only store pairing candidate for 3rd tap if triple tap is explicitly enabled and handled.
            if enableTripleTap && onTripleTap != nil {
                storePairingCandidate(at: point, count: 2, now: now)
            } else {
                clearPairingCandidate()
            }
            onPairedSecondTap?(session)
            return
        }

        if count == 3 {
            // Completed 3rd tap! Sequence completes (triple tap)
            clearPairingCandidate()
            onTripleTap?(session)
            return
        }

        // Default: completed 1st tap! Eligible for 2nd tap within doubleTapInterval
        storePairingCandidate(at: point, count: 1, now: now)
        onFirstTap?(session)
    }

    /// Any non-tap transition invalidates only future pairing. The completed
    /// first click has already been sent and is never replayed or withdrawn.
    func cancelCandidate() {
        currentSequenceCount = 0
        clearPairingCandidate()
    }

    func reset() {
        currentSequenceCount = 0
        clearPairingCandidate()
        generation &+= 1
    }

    private func storePairingCandidate(at point: CGPoint, count: Int, now: Date) {
        cancelTimeout?()
        generation &+= 1
        let token = generation
        pairingCandidate = PairingCandidate(point: point, completedAt: now, count: count, generation: token)
        // Timeout only expires pairing eligibility; it cannot emit another click.
        cancelTimeout = scheduler(doubleTapInterval) { [weak self] in
            guard let self,
                  self.pairingCandidate?.generation == token else { return }
            self.pairingCandidate = nil
            self.cancelTimeout = nil
            self.currentSequenceCount = 0
            self.generation &+= 1
        }
    }

    private func clearPairingCandidate() {
        cancelTimeout?()
        cancelTimeout = nil
        pairingCandidate = nil
        generation &+= 1
    }
}
