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
    // Multi-slot contact state tracking (supports up to 6 fingers on USB2IIC_CTP_CONTROL)
    public struct ContactSlot {
        public let slotIndex: Int
        public var isContactDown: Bool = false
        public var lastRawX: Int = 0
        public var lastRawY: Int = 0
        public var hasObservedCoordinates: Bool = false
        public var activeContactID: Int = 0
        
        // Pending elements for the current report packet
        public var pendingTipSwitch: Bool? = nil
        public var pendingRawX: Int? = nil
        public var pendingRawY: Int? = nil
        public var pendingContactID: Int? = nil
        
        public init(slotIndex: Int) {
            self.slotIndex = slotIndex
            self.activeContactID = slotIndex
        }
        
        public mutating func reset() {
            isContactDown = false
            lastRawX = 0
            lastRawY = 0
            hasObservedCoordinates = false
            pendingTipSwitch = nil
            pendingRawX = nil
            pendingRawY = nil
            pendingContactID = nil
        }
    }
    
    private var slots: [ContactSlot] = (0..<6).map { ContactSlot(slotIndex: $0) }
    
    // In-flight report timestamp grouping
    private var pendingTimestamp: UInt64 = 0
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
        for i in 0..<slots.count {
            slots[i].reset()
        }
        pendingTimestamp = 0
        isFlushScheduled = false
    }
    
    // Backwards-compatible accessors for single-contact introspection
    public var isContactDown: Bool {
        slots.contains(where: { $0.isContactDown })
    }
    
    public var activeContactCount: Int {
        slots.filter { $0.isContactDown }.count
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
    
    /// Maps an IOHIDElement cookie to its corresponding finger slot (0..5).
    /// Defaults to slot 0 if cookie is 0 (e.g. synthetic test harnesses).
    public static func slotForCookie(_ cookie: UInt32) -> Int {
        if cookie >= 0x0010 && cookie <= 0x0015 {
            return Int(cookie - 0x0010)
        } else if cookie >= 0x0016 && cookie <= 0x002D {
            return Int((cookie - 0x0016) / 4)
        }
        return 0
    }
    
    /// Feeds an incoming raw element update from IOHIDValueCallback.
    /// Elements with identical machTime belong to the same hardware report packet.
    public func handleElement(usagePage: UInt32, usage: UInt32, value: Int, machTime: UInt64, cookie: UInt32 = 0) {
        // If a new report timestamp arrives while a previous report is still pending, flush immediately.
        if pendingTimestamp != 0 && machTime != pendingTimestamp {
            flushPendingFrame()
        }
        
        pendingTimestamp = machTime
        let slotIdx = max(0, min(slots.count - 1, TouchFrameAggregator.slotForCookie(cookie)))
        
        if usagePage == 0x0D { // Digitizer
            switch usage {
            case 0x42: // Tip Switch (Touch Down / Up)
                slots[slotIdx].pendingTipSwitch = (value != 0)
            case 0x51: // Contact Identifier
                slots[slotIdx].pendingContactID = value
            default:
                break
            }
        } else if usagePage == 0x01 { // Generic Desktop
            switch usage {
            case 0x30: // Absolute X
                slots[slotIdx].pendingRawX = value
            case 0x31: // Absolute Y
                slots[slotIdx].pendingRawY = value
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
    
    /// Flushes the pending accumulated elements across all finger slots for the current report timestamp.
    public func flushPendingFrame() {
        isFlushScheduled = false
        guard pendingTimestamp != 0 else { return }
        
        let reportTime = pendingTimestamp
        let elapsed = elapsedSeconds(for: reportTime)
        
        for i in 0..<slots.count {
            if let newX = slots[i].pendingRawX {
                slots[i].lastRawX = newX
                slots[i].hasObservedCoordinates = true
            }
            if let newY = slots[i].pendingRawY {
                slots[i].lastRawY = newY
                slots[i].hasObservedCoordinates = true
            }
            if let cID = slots[i].pendingContactID {
                slots[i].activeContactID = cID
            }
            
            let (normX, normY) = normalize(rawX: slots[i].lastRawX, rawY: slots[i].lastRawY)
            
            // Process Tip Switch state changes for this slot
            if let tipDown = slots[i].pendingTipSwitch {
                if tipDown && !slots[i].isContactDown {
                    // TOUCH DOWN: Only emit when coordinates have arrived for this contact
                    slots[i].isContactDown = true
                    if slots[i].hasObservedCoordinates {
                        let sample = TouchSample(
                            phase: .down,
                            rawX: slots[i].lastRawX,
                            rawY: slots[i].lastRawY,
                            normX: normX,
                            normY: normY,
                            timestamp: reportTime,
                            elapsedSeconds: elapsed,
                            slot: i,
                            contactID: slots[i].activeContactID
                        )
                        emitSample(sample)
                    }
                } else if !tipDown && slots[i].isContactDown {
                    // TOUCH UP
                    slots[i].isContactDown = false
                    let sample = TouchSample(
                        phase: .up,
                        rawX: slots[i].lastRawX,
                        rawY: slots[i].lastRawY,
                        normX: normX,
                        normY: normY,
                        timestamp: reportTime,
                        elapsedSeconds: elapsed,
                        slot: i,
                        contactID: slots[i].activeContactID
                    )
                    emitSample(sample)
                    // Clean coordinate reset per-slot on touch-up
                    slots[i].hasObservedCoordinates = false
                    slots[i].lastRawX = 0
                    slots[i].lastRawY = 0
                } else if tipDown && slots[i].isContactDown {
                    // Continued touch with potential move
                    if slots[i].pendingRawX != nil || slots[i].pendingRawY != nil {
                        let sample = TouchSample(
                            phase: .move,
                            rawX: slots[i].lastRawX,
                            rawY: slots[i].lastRawY,
                            normX: normX,
                            normY: normY,
                            timestamp: reportTime,
                            elapsedSeconds: elapsed,
                            slot: i,
                            contactID: slots[i].activeContactID
                        )
                        emitSample(sample)
                    }
                }
            } else if slots[i].isContactDown {
                // Continued touch position update without tip-switch change
                if slots[i].pendingRawX != nil || slots[i].pendingRawY != nil {
                    let sample = TouchSample(
                        phase: .move,
                        rawX: slots[i].lastRawX,
                        rawY: slots[i].lastRawY,
                        normX: normX,
                        normY: normY,
                        timestamp: reportTime,
                        elapsedSeconds: elapsed,
                        slot: i,
                        contactID: slots[i].activeContactID
                    )
                    emitSample(sample)
                }
            }
            
            // Clear slot pending elements
            slots[i].pendingTipSwitch = nil
            slots[i].pendingRawX = nil
            slots[i].pendingRawY = nil
            slots[i].pendingContactID = nil
        }
        
        pendingTimestamp = 0
    }
}
