import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

// MARK: - P3-02 Interaction Session & Gesture Arbitration Taxonomy

/// Deterministic states of a physical single-touch / multi-touch contact session (P3-03R Phase B).
public enum GestureState: Equatable, CustomStringConvertible {
    case idle
    case possibleTap        // Movement is below panThreshold; eligible for tap on release
    case directPan          // Active continuous direct-touch pan (1 or 2 fingers)
    case momentum           // Kinetic coasting after flick release
    case unsupportedPan     // Movement crossed panThreshold, but surface has no scroll backend
    case tapExecuted        // Released while in possibleTap -> Tap successfully dispatched
    case cancelled(reason: String) // Cancelled (micro-glitch, hot-plug disconnect)
    
    // Backwards-compatible alias for P3-02 tests and loggers
    public static var semanticPan: GestureState { .directPan }
    
    public var description: String {
        switch self {
        case .idle: return "IDLE"
        case .possibleTap: return "POSSIBLE_TAP"
        case .directPan: return "DIRECT_PAN"
        case .momentum: return "MOMENTUM"
        case .unsupportedPan: return "UNSUPPORTED_PAN"
        case .tapExecuted: return "TAP_EXECUTED"
        case .cancelled(let reason): return "CANCELLED(\(reason))"
        }
    }
}

/// Explicit Interaction Result Taxonomy (P3-02 Section 12 & P3-03R).
public enum InteractionResultType: String, Codable {
    case tapPressSuccess      = "TAP_PRESS_SUCCESS"
    case tapFocusSuccess      = "TAP_FOCUS_SUCCESS"
    case tapSelectionSuccess  = "TAP_SELECTION_SUCCESS"
    case tapMenuSuccess       = "TAP_MENU_SUCCESS"
    case tapCGClickSuccess    = "TAP_CG_CLICK_SUCCESS"
    
    case panStarted           = "PAN_STARTED"
    case panUpdated           = "PAN_UPDATED"
    case panCompleted         = "PAN_COMPLETED"
    case momentumStarted      = "MOMENTUM_STARTED"
    case momentumEnded        = "MOMENTUM_ENDED"
    
    case panUnsupported       = "PAN_UNSUPPORTED"
    case gestureCancelled     = "GESTURE_CANCELLED"
    case semanticUnsupported  = "SEMANTIC_UNSUPPORTED"
    case axFailure            = "AX_FAILURE"
}

/// Centralized, tunable arbitration thresholds (P3-02 Section 16 & P3-03R).
public struct GestureArbitrationConfig {
    /// Baseline movement tolerance threshold in points (touch slop).
    /// Below this: candidate for TAP.
    /// Exceeding this: permanently cancels TAP and transitions to DIRECT_PAN.
    public static var panThresholdPt: Double = 18.0
    
    /// Minimum contact duration to filter out electrical glitches or micro-bounces (15 ms).
    public static var minTapDurationSec: Double = 0.015
    
    /// Rate-limiting interval for continuous AX scroll writes (~60 Hz).
    public static var scrollCoalesceIntervalSec: Double = 0.016
    
    /// Deadband for continuous pan updates to eliminate stationary finger tremor from issuing redundant writes.
    public static var panUpdateDeadbandPt: Double = 2.0
    
    /// Minimum scroll value delta to prevent floating-point noise updates.
    public static var minScrollValueDelta: Double = 0.0008
    
    /// Kinetic momentum parameters (P3-03R Phase C)
    public static var minFlickVelocityPtPerSec: Double = 60.0
    public static var momentumDecayFactor: Double = 0.94
    public static var minMomentumVelocityPtPerSec: Double = 10.0
}

/// Actions emitted during gesture transition evaluation.
public enum GestureTransitionAction {
    case none
    case transitionedToPan(initialValue: Double)
    case transitionedToUnsupportedPan
    case panValueUpdated(targetValue: Double, deltaPixels: CGVector)
}

/// Represents one explicit physical contact session (P3-02 Section 2 & P3-03R).
public final class InteractionSession {
    public let id: String
    public let contactID: Int
    public var contactCount: Int = 1
    public var secondaryContactID: Int? = nil
    public var allowCGScrollFallback: Bool = true
    
    public let startTimeMach: UInt64
    public let startTimeDate: Date
    public let startRawPoint: RawHIDPoint
    public let startSensorPoint: NormalizedSensorPoint
    public let startLocalPoint: DisplayLocalPoint
    public let startGlobalPoint: GlobalDisplayPoint
    
    public private(set) var latestGlobalPoint: GlobalDisplayPoint
    public private(set) var latestLocalPoint: DisplayLocalPoint
    public private(set) var maxMovementPt: Double = 0.0
    public private(set) var currentMovementPt: Double = 0.0
    public private(set) var state: GestureState = .possibleTap
    
    // Velocity tracking (P3-03R Phase B & C)
    public private(set) var instantaneousVelocity: CGVector = .zero
    public private(set) var filteredVelocity: CGVector = .zero
    private var lastSampleTimeDate: Date
    private var lastSamplePoint: CGPoint
    
    // Cached Early Capability Context (P3-02 Section 4 & 9)
    public let context: AXInteractionContext?
    
    // Continuous Pan Metrics (P3-02 Section 7)
    public let initialScrollValue: Double
    public let minScrollValue: Double
    public let maxScrollValue: Double
    public let visibleHeight: Double
    public private(set) var lastDispatchedScrollValue: Double
    public private(set) var lastDispatchedGlobalY: Double
    public private(set) var lastScrollDispatchTime: Date
    public private(set) var isStationaryHold: Bool = false
    public private(set) var panUpdatesCount: Int = 0
    
    // Detailed Physical Evidence Telemetry (P3-02)
    public var testTag: String = "Test"
    public var touchTargetDescription: String = ""
    public var trace: ScrollSessionTrace? = nil
    public private(set) var timeToPanSec: Double? = nil
    public private(set) var movementAtPanTransitionPt: Double? = nil
    public private(set) var delayedTapEmitted: Bool = false
    public var cursorBefore: CGPoint = .zero
    public var cursorAfter: CGPoint = .zero
    public var tapActionResult: String = "None"
    public var panActionResult: String = "None"
    public var transitionDescription: String = "possibleTap"

    public init(
        startSample: TouchSample,
        localPoint: DisplayLocalPoint,
        globalPoint: GlobalDisplayPoint,
        context: AXInteractionContext?
    ) {
        self.id = "SES-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
        self.contactID = startSample.contactID
        self.startTimeMach = startSample.timestamp
        self.startTimeDate = Date()
        self.lastSampleTimeDate = self.startTimeDate
        self.lastSamplePoint = globalPoint.cgGlobal
        self.instantaneousVelocity = .zero
        self.filteredVelocity = .zero
        self.startRawPoint = startSample.rawPoint
        self.startSensorPoint = startSample.normalizedSensorPoint
        self.startLocalPoint = localPoint
        self.startGlobalPoint = globalPoint
        self.latestGlobalPoint = globalPoint
        self.latestLocalPoint = localPoint
        self.context = context
        
        let cap = context?.scrollCapability
        let initialVal = cap?.verticalValue ?? 0.0
        self.initialScrollValue = initialVal
        self.minScrollValue = cap?.verticalMin ?? 0.0
        self.maxScrollValue = cap?.verticalMax ?? 1.0
        self.visibleHeight = max(100.0, context?.scrollAreaHeight ?? 400.0)
        self.lastDispatchedScrollValue = initialVal
        self.lastDispatchedGlobalY = globalPoint.cgGlobal.y
        self.lastScrollDispatchTime = Date()
        self.state = .possibleTap
        
        let cur = SafetyInvariants.currentCursorPosition()
        self.cursorBefore = cur
        self.cursorAfter = cur
        
        if let ctx = context {
            let role = ctx.hitNode.role
            let title = ctx.hitNode.title ?? ctx.hitNode.descriptionText ?? ""
            self.touchTargetDescription = title.isEmpty ? role : "\(role): \"\(title)\""
        } else {
            self.touchTargetDescription = "Blank surface"
        }
        
        let scrollbarDesc: String
        if let bar = context?.scrollBarElement {
            scrollbarDesc = "AXScrollBar (\(bar))"
        } else {
            scrollbarDesc = "None"
        }
        
        let tr = ScrollTransactionTracer.shared.startSession(
            sessionID: self.id,
            applicationName: context?.applicationName ?? "UnknownApp",
            targetIdentity: self.touchTargetDescription,
            scrollbarIdentity: scrollbarDesc,
            initialAXValue: initialVal,
            startGlobalY: globalPoint.cgGlobal.y
        )
        tr.recordDown(fingerY: globalPoint.cgGlobal.y)
        self.trace = tr
    }
    
    /// Evaluates movement against arbitration thresholds.
    public func handleMove(
        local: DisplayLocalPoint,
        global: GlobalDisplayPoint,
        now: Date = Date()
    ) -> GestureTransitionAction {
        self.latestLocalPoint = local
        self.latestGlobalPoint = global
        
        let dx = global.cgGlobal.x - startGlobalPoint.cgGlobal.x
        let dy = global.cgGlobal.y - startGlobalPoint.cgGlobal.y
        let dist = sqrt(Double(dx * dx + dy * dy))
        self.currentMovementPt = dist
        if dist > maxMovementPt {
            maxMovementPt = dist
        }
        
        // Calculate instantaneous and filtered velocity (P3-03R Phase B & C)
        let dt = max(0.001, now.timeIntervalSince(lastSampleTimeDate))
        let frameDx = global.cgGlobal.x - lastSamplePoint.x
        let frameDy = global.cgGlobal.y - lastSamplePoint.y
        let vx = frameDx / dt
        let vy = frameDy / dt
        self.instantaneousVelocity = CGVector(dx: vx, dy: vy)
        
        let alpha = 0.35
        self.filteredVelocity = CGVector(
            dx: alpha * vx + (1.0 - alpha) * filteredVelocity.dx,
            dy: alpha * vy + (1.0 - alpha) * filteredVelocity.dy
        )
        self.lastSampleTimeDate = now
        self.lastSamplePoint = global.cgGlobal
        
        switch state {
        case .possibleTap:
            if dist > GestureArbitrationConfig.panThresholdPt {
                self.timeToPanSec = now.timeIntervalSince(startTimeDate)
                self.movementAtPanTransitionPt = dist
                
                // Permanently cancel TAP (P3-02 Section 3 & P3-03R)
                if hasValidContinuousScrollBackend() {
                    state = .directPan
                    transitionDescription = "possibleTap -> directPan"
                    panActionResult = "Continuous direct-touch pan active"
                    trace?.recordPanStart(fingerY: global.cgGlobal.y)
                    TouchBridgeLogger.debug(
                        .gesture,
                        "Arbitration: Movement (%.1f pt) > Threshold (%.1f pt) -> Transition to DIRECT_PAN on [\(context?.applicationName ?? "App")]"
                    )
                    return .transitionedToPan(initialValue: initialScrollValue)
                } else {
                    state = .unsupportedPan
                    transitionDescription = "possibleTap -> unsupportedPan"
                    panActionResult = "Unsupported pan suppressed (no continuous scroll backend)"
                    TouchBridgeLogger.debug(
                        .gesture,
                        "Arbitration: Movement (%.1f pt) > Threshold (%.1f pt) on unsupported surface -> Transition to UNSUPPORTED_PAN"
                    )
                    return .transitionedToUnsupportedPan
                }
            }
            return .none
            
        case .directPan:
            let targetValue = calculateTargetScrollValue(currentY: global.cgGlobal.y)
            let deltaPixels = CGVector(dx: frameDx, dy: frameDy)
            return .panValueUpdated(targetValue: targetValue, deltaPixels: deltaPixels)
            
        case .unsupportedPan, .idle, .tapExecuted, .cancelled, .momentum:
            return .none
        }
    }
    
    /// Immediate promotion to two-finger pan when a secondary contact arrives (P3-03R Phase B).
    public func promoteToTwoFingerPan(centroid: CGPoint, now: Date = Date()) {
        guard state == .possibleTap else { return }
        self.contactCount = 2
        self.timeToPanSec = now.timeIntervalSince(startTimeDate)
        self.movementAtPanTransitionPt = currentMovementPt
        if hasValidContinuousScrollBackend() {
            state = .directPan
            transitionDescription = "possibleTap -> directPan (two-finger)"
            panActionResult = "Two-finger direct-touch pan active"
            trace?.recordPanStart(fingerY: centroid.y)
            TouchBridgeLogger.info(
                .gesture,
                "Arbitration: Secondary contact detected -> Immediate Transition to TWO-FINGER DIRECT_PAN"
            )
        } else {
            state = .unsupportedPan
            transitionDescription = "possibleTap -> unsupportedPan (two-finger)"
            panActionResult = "Unsupported two-finger pan suppressed"
        }
    }
    
    public func markMomentumStarted() {
        state = .momentum
        transitionDescription = "directPan -> momentum"
        panActionResult = "Kinetic momentum coasting"
    }
    
    public func markMomentumEnded() {
        state = .idle
        transitionDescription = "momentum -> idle"
        panActionResult = "Kinetic momentum ended"
    }
    
    /// Natural 1:1 direct touch scroll calculation relative to initial touch-down (P3-02 Section 7).
    /// Derives movement from initial state to prevent numerical integration drift.
    public func calculateTargetScrollValue(currentY: Double) -> Double {
        let fingerDeltaY = currentY - startGlobalPoint.cgGlobal.y
        let valueSpan = maxScrollValue - minScrollValue
        // Dragging finger UP (fingerDeltaY < 0) reveals content lower down (increases scrollbar value)
        let proportionalDelta = (-fingerDeltaY / visibleHeight) * valueSpan
        let rawNewVal = initialScrollValue + proportionalDelta
        return max(minScrollValue, min(maxScrollValue, rawNewVal))
    }
    
    public func hasValidContinuousScrollBackend() -> Bool {
        if let ctx = context {
            if ctx.scrollCapability.hasScrollArea && ctx.scrollBarElement != nil && ctx.scrollCapability.isVerticalValueSettable {
                return true
            }
            if ctx.scrollCapability.hasScrollArea && allowCGScrollFallback {
                return true
            }
        }
        return false
    }
    
    /// Checks whether an AX write should occur (throttled to ~60Hz, with deadband filtering to prevent stationary jitter).
    public func shouldDispatchAXWrite(now: Date, targetValue: Double, currentY: Double? = nil) -> Bool {
        guard state == .semanticPan else { return false }
        let timeSinceLast = now.timeIntervalSince(lastScrollDispatchTime)
        guard timeSinceLast >= GestureArbitrationConfig.scrollCoalesceIntervalSec else {
            return false
        }
        
        let valueDelta = abs(targetValue - lastDispatchedScrollValue)
        guard valueDelta >= GestureArbitrationConfig.minScrollValueDelta else {
            return false
        }
        
        if let y = currentY {
            let displacementSinceLast = abs(y - lastDispatchedGlobalY)
            if displacementSinceLast < GestureArbitrationConfig.panUpdateDeadbandPt {
                self.isStationaryHold = true
                return false
            }
        }
        
        self.isStationaryHold = false
        return true
    }
    
    public func recordAXWriteDispatched(now: Date, value: Double, currentY: Double? = nil) {
        self.lastScrollDispatchTime = now
        self.lastDispatchedScrollValue = value
        if let y = currentY {
            self.lastDispatchedGlobalY = y
        } else {
            self.lastDispatchedGlobalY = latestGlobalPoint.cgGlobal.y
        }
        self.isStationaryHold = false
        self.panUpdatesCount += 1
    }
    
    public func recordCoalescedSkip(fingerY: Double, targetValue: Double) {
        trace?.recordCoalescedSkip(fingerY: fingerY, targetValue: targetValue)
    }
    
    
    public func cancel(reason: String) {
        state = .cancelled(reason: reason)
        transitionDescription = "\(transitionDescription) -> cancelled(\(reason))"
    }
    
    public func markTapExecuted() {
        state = .tapExecuted
        transitionDescription = "possibleTap -> tapExecuted"
    }
    
    public func recordDelayedTapViolation() {
        delayedTapEmitted = true
    }
    
    public func markIdle() {
        state = .idle
    }
    
    /// Generates structured physical evidence block conforming strictly to P3-02 format.
    public func formattedEvidenceBlock(testNameOverride: String? = nil) -> String {
        let name = testNameOverride ?? self.testTag
        let target = touchTargetDescription.isEmpty ? (context?.hitNode.role ?? "Unknown") : touchTargetDescription
        let global = String(format: "(%.1f, %.1f)", startGlobalPoint.cgGlobal.x, startGlobalPoint.cgGlobal.y)
        
        let hitRole = context?.hitNode.role ?? "None"
        let hitTitle = context?.hitNode.title ?? context?.hitNode.descriptionText ?? ""
        let hitElemStr = hitTitle.isEmpty ? hitRole : "\(hitRole): \"\(hitTitle)\""
        
        let actionableCap: String
        if let node = context?.hitNode {
            if node.supportedActions.contains(kAXPressAction as String) {
                actionableCap = "AXPress"
            } else if node.attributeNames.contains(kAXSelectedAttribute as String) && node.isSelectedSettable {
                actionableCap = "AXSelected"
            } else if node.attributeNames.contains(kAXFocusedAttribute as String) && node.isFocusSettable {
                actionableCap = "AXFocused"
            } else {
                actionableCap = "None"
            }
        } else {
            actionableCap = "None"
        }
        
        let scrollCapStr: String
        if let ctx = context, ctx.scrollCapability.hasScrollArea {
            let mech = ctx.scrollCapability.mechanism
            scrollCapStr = "AXScrollArea -> AXScrollBar.AXValue (\(mech))"
        } else {
            scrollCapStr = "None"
        }
        
        let maxMovStr = String(format: "%.1f pt", maxMovementPt)
        let threshStr = String(format: "%.1f pt", GestureArbitrationConfig.panThresholdPt)
        
        let timeToPanStr: String
        if let t = timeToPanSec, let m = movementAtPanTransitionPt {
            timeToPanStr = String(format: "%.0f ms (movement at transition: %.1f pt)", t * 1000.0, m)
        } else {
            timeToPanStr = "N/A (stationary tap)"
        }
        
        let curDelta = hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y)
        
        return """
        Test: \(name)
        Touch target: \(target)

        Down:
          global point: \(global)
          hit element: \(hitElemStr)
          actionable capability: \(actionableCap)
          scroll ancestor capability: \(scrollCapStr)

        Gesture:
          max movement: \(maxMovStr)
          threshold: \(threshStr)
          transition: \(transitionDescription.isEmpty ? state.description : transitionDescription)
          time-to-pan if applicable: \(timeToPanStr)

        Semantic result:
          tap action: \(tapActionResult)
          pan action: \(panActionResult)
          initial scroll value: \(String(format: "%.3f", initialScrollValue))
          final scroll value: \(String(format: "%.3f", lastDispatchedScrollValue))

        Release:
          delayed tap emitted: \(delayedTapEmitted ? "YES" : "NO")

        Cursor:
          before: (\(String(format: "%.1f", cursorBefore.x)), \(String(format: "%.1f", cursorBefore.y)))
          after: (\(String(format: "%.1f", cursorAfter.x)), \(String(format: "%.1f", cursorAfter.y)))
          delta: \(String(format: "%.2f", curDelta)) pt
        """
    }
}
