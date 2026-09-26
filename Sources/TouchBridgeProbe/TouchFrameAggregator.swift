import Foundation
import Darwin

public enum TouchPhase: String, Codable {
    case down = "DOWN"
    case move = "MOVE"
    case up   = "UP"
}

public struct TouchSample: CustomStringConvertible {
    public let phase: TouchPhase
    public let rawX: Int
    public let rawY: Int
    public let normX: Double
    public let normY: Double
    public let timestamp: UInt64
    public let elapsedSeconds: Double
    public let slot: Int
    public let contactID: Int
    
    public init(
        phase: TouchPhase,
        rawX: Int = 2048,
        rawY: Int = 2048,
        normX: Double = 0.5,
        normY: Double = 0.5,
        timestamp: UInt64 = mach_absolute_time(),
        elapsedSeconds: Double = 0.0,
        slot: Int = 0,
        contactID: Int = 0
    ) {
        self.phase = phase
        self.rawX = rawX
        self.rawY = rawY
        self.normX = normX
        self.normY = normY
        self.timestamp = timestamp
        self.elapsedSeconds = elapsedSeconds
        self.slot = slot
        self.contactID = contactID
    }
    
    public var rawPoint: RawHIDPoint {
        RawHIDPoint(x: rawX, y: rawY)
    }
    
    public var normalizedSensorPoint: NormalizedSensorPoint {
        NormalizedSensorPoint(u: normX, v: normY)
    }
    
    public var description: String {
        String(format: "TouchSample [%-4@] +%6.3fs Raw: (%4d, %4d) Norm: (%.4f, %.4f) Slot: %d ID: %d",
               phase.rawValue, elapsedSeconds, rawX, rawY, normX, normY, slot, contactID)
    }
}

public final class TouchFrameAggregator {
    // Current stable contact state (Slot #0)
    private var isContactDown: Bool = false
    private var lastRawX: Int = 0
    private var lastRawY: Int = 0
    private var hasObservedCoordinates: Bool = false
    private var activeContactID: Int = 0
    
    // In-flight report accumulation (grouped by hardware timestamp)
    private var pendingTimestamp: UInt64 = 0
    private var pendingTipSwitch: Bool? = nil
    private var pendingRawX: Int? = nil
    private var pendingRawY: Int? = nil
    private var pendingContactID: Int? = nil
    private var isFlushScheduled: Bool = false
    
    // Device bounds for normalization
    private let logMinX: Int
    private let logMaxX: Int
    private let logMinY: Int
    private let logMaxY: Int
    
    // Timing
    private let startMachTime: UInt64
    private var timebaseInfo = mach_timebase_info()
    
    // Callback
    private let onSample: (TouchSample) -> Void
    public var onSampleForwarder: ((TouchSample) -> Void)? = nil
    
    public init(
        logMinX: Int = 0, logMaxX: Int = 4096,
        logMinY: Int = 0, logMaxY: Int = 4096,
        onSample: @escaping (TouchSample) -> Void
    ) {
        self.logMinX = logMinX
        self.logMaxX = logMaxX
        self.logMinY = logMinY
        self.logMaxY = logMaxY
        self.onSample = onSample
        self.startMachTime = mach_absolute_time()
        mach_timebase_info(&self.timebaseInfo)
    }
    
    public func reset() {
        isContactDown = false
        hasObservedCoordinates = false
        pendingTipSwitch = nil
        pendingRawX = nil
        pendingRawY = nil
        pendingContactID = nil
        pendingTimestamp = 0
        isFlushScheduled = false
    }
    
    private func emitSample(_ sample: TouchSample) {
        if let forwarder = onSampleForwarder {
            forwarder(sample)
        } else {
            onSample(sample)
        }
    }
    
    private func elapsedSeconds(for machTime: UInt64) -> Double {
        let elapsed = (machTime >= startMachTime) ? (machTime - startMachTime) : 0
        let nanos = elapsed * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func normalize(rawX: Int, rawY: Int) -> (normX: Double, normY: Double) {
        let spanX = Double(max(1, logMaxX - logMinX))
        let spanY = Double(max(1, logMaxY - logMinY))
        let nx = Double(rawX - logMinX) / spanX
        let ny = Double(rawY - logMinY) / spanY
        return (max(0.0, min(1.0, nx)), max(0.0, min(1.0, ny)))
    }
    
    /// Feeds an incoming raw element update from IOHIDValueCallback.
    /// Elements with identical machTime belong to the same hardware report packet.
    public func handleElement(usagePage: UInt32, usage: UInt32, value: Int, machTime: UInt64) {
        // If a new report timestamp arrives while a previous report is still pending, flush immediately.
        if pendingTimestamp != 0 && machTime != pendingTimestamp {
            flushPendingFrame()
        }
        
        pendingTimestamp = machTime
        
        if usagePage == 0x0D { // Digitizer
            switch usage {
            case 0x42: // Tip Switch (Touch Down / Up)
                pendingTipSwitch = (value != 0)
            case 0x51: // Contact Identifier
                pendingContactID = value
            default:
                break
            }
        } else if usagePage == 0x01 { // Generic Desktop
            switch usage {
            case 0x30: // Absolute X
                pendingRawX = value
            case 0x31: // Absolute Y
                pendingRawY = value
            default:
                break
            }
        }
        
        // Coalesce element arrivals across the current runloop cycle
        if !isFlushScheduled {
            isFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingFrame()
            }
        }
    }
    
    /// Flushes the pending accumulated elements for the current report timestamp.
    public func flushPendingFrame() {
        isFlushScheduled = false
        guard pendingTimestamp != 0 else { return }
        
        let reportTime = pendingTimestamp
        let elapsed = elapsedSeconds(for: reportTime)
        
        if let newX = pendingRawX {
            lastRawX = newX
            hasObservedCoordinates = true
        }
        if let newY = pendingRawY {
            lastRawY = newY
            hasObservedCoordinates = true
        }
        if let cID = pendingContactID {
            activeContactID = cID
        }
        
        let (normX, normY) = normalize(rawX: lastRawX, rawY: lastRawY)
        
        // Process Tip Switch state changes
        if let tipDown = pendingTipSwitch {
            if tipDown && !isContactDown {
                // TOUCH DOWN: Only emit when coordinates have arrived for this contact
                isContactDown = true
                if hasObservedCoordinates {
                    let sample = TouchSample(
                        phase: .down,
                        rawX: lastRawX,
                        rawY: lastRawY,
                        normX: normX,
                        normY: normY,
                        timestamp: reportTime,
                        elapsedSeconds: elapsed,
                        slot: 0,
                        contactID: activeContactID
                    )
                    emitSample(sample)
                }
            } else if !tipDown && isContactDown {
                // TOUCH UP
                isContactDown = false
                let sample = TouchSample(
                    phase: .up,
                    rawX: lastRawX,
                    rawY: lastRawY,
                    normX: normX,
                    normY: normY,
                    timestamp: reportTime,
                    elapsedSeconds: elapsed,
                    slot: 0,
                    contactID: activeContactID
                )
                emitSample(sample)
                // Inter-gesture clean start (P3-03 Section 8):
                // Clear coordinate cache so subsequent contacts never inherit stale coordinates.
                hasObservedCoordinates = false
                lastRawX = 0
                lastRawY = 0
            } else if tipDown && isContactDown {
                // Continued touch with potential move
                if pendingRawX != nil || pendingRawY != nil {
                    let sample = TouchSample(
                        phase: .move,
                        rawX: lastRawX,
                        rawY: lastRawY,
                        normX: normX,
                        normY: normY,
                        timestamp: reportTime,
                        elapsedSeconds: elapsed,
                        slot: 0,
                        contactID: activeContactID
                    )
                    emitSample(sample)
                }
            }
        } else {
            // No tip switch change in this report, but X/Y updated while down
            if isContactDown && (pendingRawX != nil || pendingRawY != nil) {
                let sample = TouchSample(
                    phase: .move,
                    rawX: lastRawX,
                    rawY: lastRawY,
                    normX: normX,
                    normY: normY,
                    timestamp: reportTime,
                    elapsedSeconds: elapsed,
                    slot: 0,
                    contactID: activeContactID
                )
                emitSample(sample)
            }
        }
        
        // Clear pending report fields
        pendingTipSwitch = nil
        pendingRawX = nil
        pendingRawY = nil
        pendingContactID = nil
        pendingTimestamp = 0
    }
}
