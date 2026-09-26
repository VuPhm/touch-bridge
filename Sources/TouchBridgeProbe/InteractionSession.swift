import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

// MARK: - P3-02 Interaction Session & Gesture Arbitration Taxonomy

/// Deterministic states of a physical single-touch contact session.
public enum GestureState: Equatable, CustomStringConvertible {
    case idle
    case possibleTap        // Movement is below panThreshold; eligible for tap on release
    case semanticPan        // Movement crossed panThreshold; actively driving continuous semantic scroll
    case unsupportedPan     // Movement crossed panThreshold, but surface has no semantic scroll backend
    case tapExecuted        // Released while in possibleTap -> Tap successfully dispatched
    case cancelled(reason: String) // Cancelled (hold timeout, micro-glitch, hot-plug disconnect)
    
    public var description: String {
        switch self {
        case .idle: return "IDLE"
        case .possibleTap: return "POSSIBLE_TAP"
        case .semanticPan: return "SEMANTIC_PAN"
        case .unsupportedPan: return "UNSUPPORTED_PAN"
        case .tapExecuted: return "TAP_EXECUTED"
        case .cancelled(let reason): return "CANCELLED(\(reason))"
        }
    }
}

/// Explicit Interaction Result Taxonomy (P3-02 Section 12).
public enum InteractionResultType: String, Codable {
    case tapPressSuccess      = "TAP_PRESS_SUCCESS"
    case tapFocusSuccess      = "TAP_FOCUS_SUCCESS"
    case tapSelectionSuccess  = "TAP_SELECTION_SUCCESS"
    case tapMenuSuccess       = "TAP_MENU_SUCCESS"
    
    case panStarted           = "PAN_STARTED"
    case panUpdated           = "PAN_UPDATED"
    case panCompleted         = "PAN_COMPLETED"
    
    case panUnsupported       = "PAN_UNSUPPORTED"
    case gestureCancelled     = "GESTURE_CANCELLED"
    case semanticUnsupported  = "SEMANTIC_UNSUPPORTED"
    case axFailure            = "AX_FAILURE"
}

/// Centralized, tunable arbitration thresholds (P3-02 Section 16 & P3-03 Section 2).
public struct GestureArbitrationConfig {
    /// Baseline movement tolerance threshold in points.
    /// Below this: candidate for TAP.
    /// Exceeding this: permanently cancels TAP and transitions to PAN (or UNSUPPORTED_PAN).
    public static var panThresholdPt: Double = 18.0
    
    /// Minimum contact duration to filter out electrical glitches or micro-bounces.
    public static var minTapDurationSec: Double = 0.015
    
    /// Maximum contact duration for a momentary tap. Holds exceeding this are cancelled.
    public static var maxTapDurationSec: Double = 0.85
    
    /// Rate-limiting interval for continuous AX scroll writes (~60 Hz) to avoid AX IPC queuing.
    public static var scrollCoalesceIntervalSec: Double = 0.016
    
    /// Deadband for continuous pan updates to eliminate stationary finger tremor from issuing redundant AX writes.
    public static var panUpdateDeadbandPt: Double = 2.0
    
    /// Minimum scroll value delta to prevent floating-point noise updates.
    public static var minScrollValueDelta: Double = 0.0008
}

/// Actions emitted during gesture transition evaluation.
public enum GestureTransitionAction {
    case none
    case transitionedToPan(initialValue: Double)
    case transitionedToUnsupportedPan
    case panValueUpdated(targetValue: Double)
}

/// Represents one explicit physical contact session (P3-02 Section 2).
public final class InteractionSession {
    public let id: String
    public let contactID: Int
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
        
        switch state {
        case .possibleTap:
            if dist > GestureArbitrationConfig.panThresholdPt {
                self.timeToPanSec = now.timeIntervalSince(startTimeDate)
                self.movementAtPanTransitionPt = dist
                
                // Permanently cancel TAP (P3-02 Section 3)
                if hasValidContinuousScrollBackend() {
                    state = .semanticPan
                    transitionDescription = "possibleTap -> semanticPan"
                    panActionResult = "Continuous semantic scroll active"
                    trace?.recordPanStart(fingerY: global.cgGlobal.y)
                    TouchBridgeLogger.debug(
                        .gesture,
                        "Arbitration: Movement (%.1f pt) > Threshold (%.1f pt) -> Transition to SEMANTIC_PAN on [\(context?.applicationName ?? "App")]"
                    )
                    return .transitionedToPan(initialValue: initialScrollValue)
                } else {
                    state = .unsupportedPan
                    transitionDescription = "possibleTap -> unsupportedPan"
                    panActionResult = "Unsupported pan suppressed (no continuous semantic scroll backend)"
                    TouchBridgeLogger.debug(
                        .gesture,
                        "Arbitration: Movement (%.1f pt) > Threshold (%.1f pt) on unsupported surface -> Transition to UNSUPPORTED_PAN"
                    )
                    return .transitionedToUnsupportedPan
                }
            }
            return .none
            
        case .semanticPan:
            let targetValue = calculateTargetScrollValue(currentY: global.cgGlobal.y)
            return .panValueUpdated(targetValue: targetValue)
            
        case .unsupportedPan, .idle, .tapExecuted, .cancelled:
            return .none
        }
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
    
    public func hasValidContinuousScrollBackend() -> Bool {
        guard let ctx = context else { return false }
        return ctx.scrollCapability.mechanism == "DIRECT_VALUE" && ctx.scrollBarElement != nil
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
