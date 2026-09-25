import Foundation
import CoreGraphics

public struct TapConstants {
    /// Maximum displacement from initial touch-down in points before gesture is cancelled as a drag/motion.
    public static let maxMovementTolerancePt: Double = 18.0
    
    /// Maximum duration between touch-down and touch-up for a momentary tap.
    /// Touches held longer than this are considered holds and cancelled.
    public static let maxTapDurationSec: Double = 0.85
    
    /// Minimum duration to filter out electrical glitches or micro-bounces.
    public static let minTapDurationSec: Double = 0.015
}

public struct PhysicalTapEvent: CustomStringConvertible {
    public let rawDownPoint: RawHIDPoint
    public let rawUpPoint: RawHIDPoint
    public let downSensorPoint: NormalizedSensorPoint
    public let calibratedLocalCG: CGPoint
    public let calibratedGlobalCG: CGPoint
    public let durationSec: Double
    public let movementPt: Double
    public let timestampMach: UInt64
    public let timestampDate: Date
    
    public var description: String {
        return String(
            format: "Tap @ Global [%.1f, %.1f] (Raw: %d,%d | Dur: %.3fs | Mov: %.1f pt)",
            calibratedGlobalCG.x, calibratedGlobalCG.y,
            rawDownPoint.x, rawDownPoint.y,
            durationSec, movementPt
        )
    }
}

public enum TapCancellationReason: String {
    case movementExceeded = "MOVEMENT_TOLERANCE_EXCEEDED"
    case holdTimeout = "HOLD_DURATION_EXCEEDED"
    case glitchTooShort = "CONTACT_TOO_BRIEF"
    case multitouchDiscarded = "MULTITOUCH_IGNORED"
}

public final class SingleTapRecognizer {
    private var isTracking: Bool = false
    private var isCancelled: Bool = false
    private var cancellationReason: TapCancellationReason? = nil
    
    private var downSample: TouchSample? = nil
    private var downLocalPoint: DisplayLocalPoint? = nil
    private var downGlobalPoint: GlobalDisplayPoint? = nil
    private var maxObservedDisplacement: Double = 0.0
    
    private var display: DisplayMetadata
    private var profile: CalibrationProfile
    
    private let onTap: (PhysicalTapEvent) -> Void
    private let onCancelled: ((TapCancellationReason, Double, Double) -> Void)?
    
    public init(
        display: DisplayMetadata,
        profile: CalibrationProfile,
        onTap: @escaping (PhysicalTapEvent) -> Void,
        onCancelled: ((TapCancellationReason, Double, Double) -> Void)? = nil
    ) {
        self.display = display
        self.profile = profile
        self.onTap = onTap
        self.onCancelled = onCancelled
    }
    
    public func updateContext(display: DisplayMetadata, profile: CalibrationProfile) {
        self.display = display
        self.profile = profile
    }
    
    public func processSample(_ sample: TouchSample) {
        let localPt = profile.mapToDisplayLocal(sensor: sample.normalizedSensorPoint)
        let globalPt = localPt.toGlobal(display: display)
        
        switch sample.phase {
        case .down:
            // Single finger tap: start tracking on first down contact
            isTracking = true
            isCancelled = false
            cancellationReason = nil
            maxObservedDisplacement = 0.0
            downSample = sample
            downLocalPoint = localPt
            downGlobalPoint = globalPt
            
        case .move:
            guard isTracking, let downLocal = downLocalPoint else { return }
            
            let dx = localPt.cgPoint.x - downLocal.cgPoint.x
            let dy = localPt.cgPoint.y - downLocal.cgPoint.y
            let dist = sqrt(Double(dx * dx + dy * dy))
            if dist > maxObservedDisplacement {
                maxObservedDisplacement = dist
            }
            
            // Movement safety gate: movement cancels semantic press
            if dist > TapConstants.maxMovementTolerancePt && !isCancelled {
                isCancelled = true
                cancellationReason = .movementExceeded
            }
            
        case .up:
            guard isTracking,
                  let downS = downSample,
                  let downLocal = downLocalPoint,
                  let downGlobal = downGlobalPoint else {
                reset()
                return
            }
            
            let duration = max(0.0, sample.elapsedSeconds - downS.elapsedSeconds)
            
            // Check final up position displacement
            let dx = localPt.cgPoint.x - downLocal.cgPoint.x
            let dy = localPt.cgPoint.y - downLocal.cgPoint.y
            let finalDist = sqrt(Double(dx * dx + dy * dy))
            let maxDist = max(maxObservedDisplacement, finalDist)
            
            if isCancelled {
                let reason = cancellationReason ?? .movementExceeded
                onCancelled?(reason, maxDist, duration)
                reset()
                return
            }
            
            if maxDist > TapConstants.maxMovementTolerancePt {
                onCancelled?(.movementExceeded, maxDist, duration)
                reset()
                return
            }
            
            if duration > TapConstants.maxTapDurationSec {
                onCancelled?(.holdTimeout, maxDist, duration)
                reset()
                return
            }
            
            if duration < TapConstants.minTapDurationSec {
                onCancelled?(.glitchTooShort, maxDist, duration)
                reset()
                return
            }
            
            // Qualified deterministic single-finger tap!
            let event = PhysicalTapEvent(
                rawDownPoint: downS.rawPoint,
                rawUpPoint: sample.rawPoint,
                downSensorPoint: downS.normalizedSensorPoint,
                calibratedLocalCG: downLocal.cgPoint,
                calibratedGlobalCG: downGlobal.cgGlobal,
                durationSec: duration,
                movementPt: maxDist,
                timestampMach: sample.timestamp,
                timestampDate: Date()
            )
            
            reset()
            onTap(event)
        }
    }
    
    private func reset() {
        isTracking = false
        isCancelled = false
        cancellationReason = nil
        downSample = nil
        downLocalPoint = nil
        downGlobalPoint = nil
        maxObservedDisplacement = 0.0
    }
}
