import Foundation
import CoreGraphics
import Cocoa

/// Tracks whether a completed tap can pair with the next tap. Each completed
/// tap is delivered immediately; this type never delays or replays click 1.
final class TapSequenceRecognizer {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)

    static let spatialTolerancePt: CGFloat = 24.0

    var onFirstTap: ((InteractionSession) -> Void)?
    var onPairedSecondTap: ((InteractionSession) -> Void)?

    private struct PairingCandidate {
        let point: CGPoint
        let completedAt: Date
        let generation: UInt64
    }

    private var doubleTapInterval: TimeInterval
    private var scheduler: Scheduler
    private var cancelTimeout: (() -> Void)?
    private var pairingCandidate: PairingCandidate?
    private var secondTapCandidate = false
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
            secondTapCandidate = false
            return false
        }

        let elapsed = now.timeIntervalSince(previous.completedAt)
        let distance = hypot(point.x - previous.point.x, point.y - previous.point.y)
        guard elapsed >= 0, elapsed <= doubleTapInterval, distance <= Self.spatialTolerancePt else {
            clearPairingCandidate()
            secondTapCandidate = false
            return false
        }

        cancelTimeout?()
        cancelTimeout = nil
        secondTapCandidate = true
        return true
    }

    func completeCandidate(_ session: InteractionSession, at point: CGPoint, now: Date) {
        if secondTapCandidate, pairingCandidate != nil {
            clearPairingCandidate()
            secondTapCandidate = false
            onPairedSecondTap?(session)
            return
        }

        secondTapCandidate = false
        storePairingCandidate(at: point, now: now)
        onFirstTap?(session)
    }

    /// Any non-tap transition invalidates only future pairing. The completed
    /// first click has already been sent and is never replayed or withdrawn.
    func cancelCandidate() {
        secondTapCandidate = false
        clearPairingCandidate()
    }

    func reset() {
        secondTapCandidate = false
        clearPairingCandidate()
        generation &+= 1
    }

    private func storePairingCandidate(at point: CGPoint, now: Date) {
        cancelTimeout?()
        generation &+= 1
        let token = generation
        pairingCandidate = PairingCandidate(point: point, completedAt: now, generation: token)
        // Timeout only expires pairing eligibility; it cannot emit another click.
        cancelTimeout = scheduler(doubleTapInterval) { [weak self] in
            guard let self,
                  self.pairingCandidate?.generation == token else { return }
            self.pairingCandidate = nil
            self.cancelTimeout = nil
            self.secondTapCandidate = false
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
