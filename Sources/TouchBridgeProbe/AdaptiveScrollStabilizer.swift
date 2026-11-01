import Foundation
import CoreGraphics

/// Pipeline Filter: Adaptive Anti-Shake Scroll Stabilizer
/// Damps sensor micro-tremor and hand jitter when holding stationary,
/// accumulates subpixel crawl for continuous smooth slow pans,
/// provides 1:1 zero-latency pass-through for intentional fast gestures,
/// and reverses direction instantaneously without lag.
public struct AdaptiveScrollStabilizer: Equatable {
    /// Deadband in points for micro-jitter suppression when stationary (default 1.2 pt)
    public var deadbandPt: Double
    
    /// Speed threshold below which deadband is fully active (default 25.0 pt/s)
    public var stationarySpeedThresholdPtPerSec: Double
    
    /// Speed threshold above which deadband collapses to 0 for 1:1 pass-through (default 40.0 pt/s)
    public var passThroughSpeedThresholdPtPerSec: Double
    
    // Subpixel accumulation for slow crawl
    public private(set) var accumulatedDx: Double = 0.0
    public private(set) var accumulatedDy: Double = 0.0
    private var lastSignX: Double = 0.0
    private var lastSignY: Double = 0.0

    public init(
        deadbandPt: Double = 1.2,
        stationarySpeedThresholdPtPerSec: Double = 25.0,
        passThroughSpeedThresholdPtPerSec: Double = 40.0
    ) {
        self.deadbandPt = deadbandPt
        self.stationarySpeedThresholdPtPerSec = stationarySpeedThresholdPtPerSec
        self.passThroughSpeedThresholdPtPerSec = passThroughSpeedThresholdPtPerSec
    }
    
    public mutating func reset() {
        accumulatedDx = 0.0
        accumulatedDy = 0.0
        lastSignX = 0.0
        lastSignY = 0.0
    }
    
    /// Filters raw frame delta. Returns the stabilized delta to emit.
    public mutating func filterDelta(
        rawDelta: CGVector,
        currentVelocity: CGVector
    ) -> CGVector {
        let speed = hypot(currentVelocity.dx, currentVelocity.dy)
        let dx = Double(rawDelta.dx)
        let dy = Double(rawDelta.dy)
        
        // 1. High-speed pass-through: If swiping intentionally (speed >= passThroughSpeedThresholdPtPerSec), 0 hysteresis, 1:1 direct pass-through
        if speed >= passThroughSpeedThresholdPtPerSec {
            accumulatedDx = 0.0
            accumulatedDy = 0.0
            lastSignX = dx >= 0 ? 1.0 : -1.0
            lastSignY = dy >= 0 ? 1.0 : -1.0
            return rawDelta
        }
        
        // 2. Direction reversal check: If current movement opposes previous direction, immediately flush opposite accumulator
        let curSignX = dx > 0.05 ? 1.0 : (dx < -0.05 ? -1.0 : 0.0)
        let curSignY = dy > 0.05 ? 1.0 : (dy < -0.05 ? -1.0 : 0.0)
        
        if curSignX != 0 && lastSignX != 0 && curSignX != lastSignX {
            accumulatedDx = 0.0
        }
        if curSignY != 0 && lastSignY != 0 && curSignY != lastSignY {
            accumulatedDy = 0.0
        }
        if curSignX != 0 { lastSignX = curSignX }
        if curSignY != 0 { lastSignY = curSignY }

        // 3. Accumulate subpixel motion
        accumulatedDx += dx
        accumulatedDy += dy
        
        // Adaptive deadband: linear blend from deadbandPt down to 0 between stationary and pass-through speed
        let span = max(0.1, passThroughSpeedThresholdPtPerSec - stationarySpeedThresholdPtPerSec)
        let blend = max(0.0, min(1.0, (speed - stationarySpeedThresholdPtPerSec) / span))
        let effectiveDeadband = deadbandPt * (1.0 - blend)
        
        var emittedDx: Double = 0.0
        var emittedDy: Double = 0.0
        
        if abs(accumulatedDx) >= effectiveDeadband {
            emittedDx = accumulatedDx
            accumulatedDx = 0.0
        }
        if abs(accumulatedDy) >= effectiveDeadband {
            emittedDy = accumulatedDy
            accumulatedDy = 0.0
        }
        
        return CGVector(dx: emittedDx, dy: emittedDy)
    }
}
