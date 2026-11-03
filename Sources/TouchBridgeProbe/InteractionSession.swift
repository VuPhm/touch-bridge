import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

// MARK: - P3-02 Interaction Session & Gesture Arbitration Taxonomy

/// Deterministic states of a physical single-touch / multi-touch contact session (P3-03R Phase B).
public enum GestureState: Equatable, CustomStringConvertible {
    case idle
    case possibleTap        // One-finger tap candidate while movement remains within touch slop
    case directPan          // Active continuous two-finger pan (or direct-touch one-finger scroll)
    case directDrag         // Active one-finger pointer drag (slider/titlebar/edge or hold-then-drag)
    case wordSelectionDrag  // Double-tap-hold-drag word-by-word selection (clickState: 2)
    case longPressCommitted // Stationary hold committed to context menu (suppresses tap on release)
    case releasePending     // Final lift seen; bounded momentum decision lease remains open
    case momentum           // Kinetic coasting after flick release
    case unsupportedPan     // Two-finger pan has no scroll backend
    case tapExecuted        // Released while in possibleTap -> Tap successfully dispatched
    case cancelled(reason: String) // Cancelled (micro-glitch, hot-plug disconnect)
    
    // Backwards-compatible alias for P3-02 tests and loggers
    public static var semanticPan: GestureState { .directPan }
    
    public var description: String {
        switch self {
        case .idle: return "IDLE"
        case .possibleTap: return "POSSIBLE_TAP"
        case .directPan: return "DIRECT_PAN"
        case .directDrag: return "DIRECT_DRAG"
        case .wordSelectionDrag: return "WORD_SELECTION_DRAG"
        case .longPressCommitted: return "LONG_PRESS_COMMITTED"
        case .releasePending: return "RELEASE_PENDING"
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
    case contextMenuSuccess   = "CONTEXT_MENU_SUCCESS"
    case dragStarted          = "DRAG_STARTED"
    case dragCompleted        = "DRAG_COMPLETED"
    
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
    /// In product mode, exceeding this cancels TAP. Two-finger contact independently starts scrolling.
    public static var panThresholdPt: Double = 18.0

    /// Diagnostic escape hatch for the retired one-finger pan behavior. Product defaults to false.
    public static var experimentalOneFingerPanEnabled: Bool = false

    /// Movement slop for immediate 1-finger drag on direct-manipulation controls (sliders, scrollbars, titlebars, window edges).
    public static var directDragControlSlopPt: Double = 8.0

    /// Movement slop for hold-then-drag and stationary long-press context menu.
    public static var longPressSlopPt: Double = 12.0

    /// Minimum dwell duration within `longPressSlopPt` before movement transitions into 1-finger precision drag (file drag / text selection).
    public static var holdForDragDurationSec: TimeInterval = 0.240

    /// Minimum stationary hold duration within `longPressSlopPt` to trigger context menu (right-click).
    public static var longPressContextMenuDurationSec: TimeInterval = 0.480

    /// Minimum 2-finger span delta in points to trigger native pinch-to-zoom (`magnify`).
    public static var pinchActivationSpanDeltaPt: Double = 24.0

    /// Minimum 2-finger rotation angle delta in degrees to trigger native `rotate`.
    public static var rotateActivationAngleDeg: Double = 10.0
    
    /// Minimum contact duration to filter out electrical glitches or micro-bounces (15 ms).
    public static var minTapDurationSec: Double = 0.015
    
    /// Rate-limiting interval for continuous AX scroll writes (~60 Hz).
    public static var scrollCoalesceIntervalSec: Double = 0.016
    
    /// Deadband for continuous pan updates to eliminate stationary finger tremor from issuing redundant writes.
    public static var panUpdateDeadbandPt: Double = 2.0
    
    /// Minimum scroll value delta to prevent floating-point noise updates.
    public static var minScrollValueDelta: Double = 0.0008
    
    // MARK: - Release Momentum Parameters (P3-06R Corrected)

    /// Minimum release speed required to trigger a release glide.
    /// Below this threshold, scrolling terminates cleanly with 0 coasting.
    public static var minFlickVelocityPtPerSec: Double = 80.0

    /// Upper clamp on starting release speed for AX semantic scrolling.
    /// Clamping prevents high-speed flings from overshooting uncontrollably.
    public static var maxReleaseVelocityPtPerSec: Double = 1100.0

    /// Monotonic velocity decay rate per frame (~60 Hz).
    /// 0.915 yields a smooth, perceptible deceleration curve over ~250-440 ms.
    public static var momentumDecayFactor: Double = 0.915

    /// Early cut-off speed threshold. Below this, momentum terminates naturally
    /// to avoid an imperceptible crawling tail.
    public static var minMomentumVelocityPtPerSec: Double = 50.0

    /// Hard cap on maximum momentum duration for AX scrolling (in seconds).
    public static var maxMomentumDurationSec: Double = 0.440

    /// Hard cap on maximum accumulated coast distance for AX scrolling (in points).
    public static var maxMomentumDistancePt: Double = 350.0

    // MARK: - Compatibility Backend (Transient Pointer) Momentum Constraints

    /// Upper clamp on starting release speed for compatibility fallback scrolling.
    public static var compatibilityMaxReleaseVelocityPtPerSec: Double = 550.0

    /// Monotonic decay rate for compatibility fallback scrolling.
    /// A modestly longer tail keeps medium releases perceptible without increasing launch speed.
    public static var compatibilityMomentumDecayFactor: Double = 0.90

    /// Early cut-off speed threshold for compatibility fallback scrolling.
    public static var compatibilityMinMomentumVelocityPtPerSec: Double = 35.0

    /// Hard cap on maximum momentum duration for compatibility fallback scrolling (in seconds).
    /// Keeps a medium release perceptible while bounding the pointer transaction to a short coast.
    public static var compatibilityMaxMomentumDurationSec: Double = 0.320

    /// Hard cap on maximum accumulated coast distance for compatibility fallback scrolling (in points).
    public static var compatibilityMaxMomentumDistancePt: Double = 100.0

    /// A movement-derived sample must be this recent at final lift to qualify for release momentum.
    public static let releaseVelocityMaximumAgeSec: TimeInterval = 0.120

    /// Keep the selected backend alive briefly while a delayed release decision is delivered.
    public static let releaseSettleWindowSec: TimeInterval = 0.120

    /// Absolute safety bound for the pointer transaction after final release.
    public static let releaseTransactionCeilingSec: TimeInterval = 0.440

    public static func qualifiesForReleaseMomentum(_ velocity: CGVector) -> Bool {
        hypot(velocity.dx, velocity.dy) >= minFlickVelocityPtPerSec
    }

    /// Finger-down smoothing is intentionally separate from release momentum.
    public static let fingerDownSmoothingFrameIntervalSec: Double = 1.0 / 60.0
    public static let fingerDownSmoothingMaxDurationSec: Double = 0.080
    public static let fingerDownSmoothingDecayFactor: Double = 0.45
    public static let fingerDownSmoothingMaxDistancePt: Double = 4.0
}

public struct MovementVelocitySnapshot {
    public let velocity: CGVector
    public let sampledAt: Date
    public let ageSec: TimeInterval

    public var speed: Double { hypot(velocity.dx, velocity.dy) }
}

public struct FingerDownSmoothingTail {
    private var velocityY: Double
    private var elapsed: Double = 0
    private var distance: Double = 0

    public init(velocityY: Double) { self.velocityY = velocityY }

    public mutating func nextDeltaY() -> Double? {
        let dt = GestureArbitrationConfig.fingerDownSmoothingFrameIntervalSec
        guard elapsed < GestureArbitrationConfig.fingerDownSmoothingMaxDurationSec,
              distance < GestureArbitrationConfig.fingerDownSmoothingMaxDistancePt else { return nil }
        let remaining = GestureArbitrationConfig.fingerDownSmoothingMaxDistancePt - distance
        let delta = min(abs(velocityY) * dt, remaining) * (velocityY < 0 ? -1 : 1)
        guard abs(delta) > 0.001 else { return nil }
        distance += abs(delta)
        elapsed += dt
        velocityY *= GestureArbitrationConfig.fingerDownSmoothingDecayFactor
        return delta
    }
}

/// Actions emitted during gesture transition evaluation.
public enum GestureTransitionAction {
    case none
    case transitionedToPan(initialValue: Double)
    case transitionedToDrag(deltaPixels: CGVector)
    case transitionedToWordSelectionDrag
    case transitionedToUnsupportedPan
    case cancelledMovement
    case panValueUpdated(targetValue: Double, deltaPixels: CGVector)
    case dragUpdated(currentPoint: CGPoint, deltaPixels: CGVector)
    case wordSelectionDragUpdated(currentPoint: CGPoint)
}

/// Represents one explicit physical contact session (P3-02 Section 2 & P3-03R).
public final class InteractionSession {
    public let id: String
    public private(set) var contactID: Int
    public var contactCount: Int = 1
    public var secondaryContactID: Int? = nil
    public var allowCGScrollFallback: Bool = true
    public var experimentalOneFingerPanEnabled = GestureArbitrationConfig.experimentalOneFingerPanEnabled
    public var directTouchModeEnabled: Bool = false
    public var interruptedActiveMomentum: Bool = false
    public private(set) var dwelledWithinLongPressSlop: Bool = false
    private var exceededLongPressSlopBeforeDwell: Bool = false
    public var isWordSelectionCandidate: Bool = false
    
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
    public var diagnosticBackend: String {
        if state == .directPan || state == .releasePending || state == .momentum { return "CG_SCROLL_WHEEL" }
        if state == .directDrag { return "CG_POINTER_DRAG" }
        if state == .wordSelectionDrag { return "WORD_SELECTION_DRAG" }
        if state == .longPressCommitted { return "CONTEXT_MENU" }
        return "TAP_INTENT_READY"
    }
    
    // Velocity tracking (P3-03R Phase B & C + Monotonic Hardware Timestamp)
    public private(set) var instantaneousVelocity: CGVector = .zero
    public private(set) var filteredVelocity: CGVector = .zero
    private var lastMovementDerivedVelocity: CGVector = .zero
    public private(set) var lastMovementVelocitySampleAt: Date?
    public private(set) var lastMovementVelocitySampleMach: UInt64?
    public private(set) var releasePendingAt: Date?
    public private(set) var releaseSettleDeadline: Date?
    public var scrollStabilizer = AdaptiveScrollStabilizer()
    public private(set) var stationaryDwellDurationSec: Double = 0.0
    private var lastSampleTimeDate: Date
    private var lastSampleTimeMach: UInt64
    private var lastSamplePoint: CGPoint
    
    // Cached Early Capability Context (P3-02 Section 4 & 9)
    public var context: AXInteractionContext?
    public var scrollDeliveryBackend: ScrollDeliveryBackend? = nil

    public func applyAXEnrichment(_ context: AXInteractionContext) {
        self.context = context
        let title = context.hitNode.title ?? context.hitNode.descriptionText ?? ""
        self.touchTargetDescription = title.isEmpty ? context.hitNode.role : "\(context.hitNode.role): \"\(title)\""
    }
    
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
    public var pointerIsolationSatisfied: Bool? = nil
    public var cursorActionClassification: String? = nil
    public var tapActionResult: String = "None"
    public var interactionIntent: String = "NONE"
    public var deliveryPolicy: String = "NOT_SELECTED"
    public var deliveryBackend: String = "NOT_SELECTED"
    public var axEnrichmentStatus: String = "NOT_REQUIRED"
    public var panActionResult: String = "None"
    public var transitionDescription: String = "possibleTap"

    public init(
        startSample: TouchSample,
        localPoint: DisplayLocalPoint,
        globalPoint: GlobalDisplayPoint,
        context: AXInteractionContext?,
        now: Date = Date()
    ) {
        self.id = "SES-\(Int(now.timeIntervalSince1970))-\(Int.random(in: 100...999))"
        self.contactID = startSample.contactID
        self.startTimeMach = startSample.timestamp
        self.startTimeDate = now
        self.lastSampleTimeDate = now
        self.lastSampleTimeMach = startSample.timestamp
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
        self.lastScrollDispatchTime = now
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
        now: Date = Date(),
        timestampMach: UInt64 = 0
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
        
        // Calculate instantaneous and filtered velocity using monotonic hardware timestamp when available (>= 1ms)
        let wallDt = now.timeIntervalSince(lastSampleTimeDate)
        let machDt: Double
        if timestampMach > 0 && lastSampleTimeMach > 0 && timestampMach > lastSampleTimeMach {
            machDt = TouchSample.machTimeToSeconds(timestampMach - lastSampleTimeMach)
        } else {
            machDt = 0.0
        }
        let dt = (machDt >= 0.001 && machDt < 1.0) ? machDt : max(0.001, wallDt)
        let frameDx = global.cgGlobal.x - lastSamplePoint.x
        let frameDy = global.cgGlobal.y - lastSamplePoint.y
        let vx = frameDx / dt
        let vy = frameDy / dt
        self.instantaneousVelocity = CGVector(dx: vx, dy: vy)
        
        let alpha = 0.45
        self.filteredVelocity = CGVector(
            dx: alpha * vx + (1.0 - alpha) * filteredVelocity.dx,
            dy: alpha * vy + (1.0 - alpha) * filteredVelocity.dy
        )
        self.lastSampleTimeDate = now
        if timestampMach > 0 {
            self.lastSampleTimeMach = timestampMach
        }
        self.lastSamplePoint = global.cgGlobal
        let frameDist = hypot(frameDx, frameDy)
        if frameDist > 0.01 {
            if frameDist >= 1.0 || hypot(vx, vy) >= 60.0 {
                self.lastMovementDerivedVelocity = self.filteredVelocity
                self.lastMovementVelocitySampleAt = now
                if timestampMach > 0 {
                    self.lastMovementVelocitySampleMach = timestampMach
                }
                self.stationaryDwellDurationSec = 0.0
            } else {
                self.stationaryDwellDurationSec += dt
            }
        } else {
            self.stationaryDwellDurationSec += dt
        }

        // Track dwell-before-move for hold-then-drag disambiguation
        let machTotalElapsed = (timestampMach > startTimeMach && startTimeMach > 0) ? TouchSample.machTimeToSeconds(timestampMach - startTimeMach) : 0.0
        let totalElapsedSec = max(now.timeIntervalSince(startTimeDate), machTotalElapsed)
        if maxMovementPt <= GestureArbitrationConfig.longPressSlopPt {
            if totalElapsedSec >= GestureArbitrationConfig.holdForDragDurationSec && !exceededLongPressSlopBeforeDwell {
                dwelledWithinLongPressSlop = true
            }
        } else {
            if totalElapsedSec < GestureArbitrationConfig.holdForDragDurationSec {
                exceededLongPressSlopBeforeDwell = true
            } else if !exceededLongPressSlopBeforeDwell {
                dwelledWithinLongPressSlop = true
            }
        }
        
        switch state {
        case .possibleTap:
            // 0. Word Selection Drag Candidate (Tap 2 down, held and moved > 4.0 pt)
            if isWordSelectionCandidate && dist > 4.0 {
                self.timeToPanSec = totalElapsedSec
                self.movementAtPanTransitionPt = dist
                state = .wordSelectionDrag
                transitionDescription = "possibleTap -> wordSelectionDrag"
                panActionResult = "Word selection drag active (clickState: 2)"
                return .transitionedToWordSelectionDrag
            }

            // 1. Direct-Drag Control (Slider, Scrollbar, Splitter, Window Title Bar, Window Resize Edge)
            if directTouchModeEnabled,
               context?.isDirectDragControl == true,
               dist > GestureArbitrationConfig.directDragControlSlopPt {
                self.timeToPanSec = totalElapsedSec
                self.movementAtPanTransitionPt = dist
                state = .directDrag
                transitionDescription = "possibleTap -> directDrag (direct control)"
                panActionResult = "One-finger direct control drag active"
                return .transitionedToDrag(deltaPixels: CGVector(dx: dx, dy: dy))
            }

            // 2. Hold-Then-Drag (~0.24s dwell within slop, then move -> precision drag for files, text selection, custom UI)
            if directTouchModeEnabled,
               dwelledWithinLongPressSlop,
               dist > GestureArbitrationConfig.longPressSlopPt {
                self.timeToPanSec = totalElapsedSec
                self.movementAtPanTransitionPt = dist
                state = .directDrag
                transitionDescription = "possibleTap -> directDrag (hold-then-drag)"
                panActionResult = "One-finger precision hold-then-drag active"
                return .transitionedToDrag(deltaPixels: CGVector(dx: dx, dy: dy))
            }

            if dist > GestureArbitrationConfig.panThresholdPt {
                self.timeToPanSec = totalElapsedSec
                self.movementAtPanTransitionPt = dist

                guard experimentalOneFingerPanEnabled || directTouchModeEnabled else {
                    state = .cancelled(reason: "MOVEMENT_TOLERANCE_EXCEEDED")
                    transitionDescription = "possibleTap -> cancelled(movement tolerance exceeded)"
                    panActionResult = "One-finger movement cancelled; scrolling requires two contacts"
                    return .cancelledMovement
                }
                
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
            let rawDelta = CGVector(dx: frameDx, dy: frameDy)
            let deltaPixels = scrollStabilizer.filterDelta(rawDelta: rawDelta, currentVelocity: filteredVelocity)
            return .panValueUpdated(targetValue: targetValue, deltaPixels: deltaPixels)

        case .directDrag:
            let deltaPixels = CGVector(dx: frameDx, dy: frameDy)
            return .dragUpdated(currentPoint: global.cgGlobal, deltaPixels: deltaPixels)
            
        case .wordSelectionDrag:
            return .wordSelectionDragUpdated(currentPoint: global.cgGlobal)
            
        case .longPressCommitted, .unsupportedPan, .idle, .tapExecuted, .cancelled, .releasePending, .momentum:
            return .none
        }
    }

    public func commitLongPressContextMenu() {
        guard state == .possibleTap else { return }
        state = .longPressCommitted
        transitionDescription = "possibleTap -> longPressCommitted"
        tapActionResult = "Context menu triggered (stationary long-press)"
    }
    
    /// Immediate promotion to two-finger pan when a secondary contact arrives.
    public func promoteToTwoFingerPan(centroid: CGPoint, now: Date = Date(), timestampMach: UInt64 = 0) {
        guard state == .possibleTap || state == .cancelled(reason: "MOVEMENT_TOLERANCE_EXCEEDED") else { return }
        self.contactCount = 2
        self.timeToPanSec = now.timeIntervalSince(startTimeDate)
        self.movementAtPanTransitionPt = currentMovementPt
        rebaseMotion(point: centroid, now: now, timestampMach: timestampMach)
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

    private func rebaseMotion(point: CGPoint, now: Date, timestampMach: UInt64 = 0) {
        let rebased = GlobalDisplayPoint(cgGlobal: point)
        latestGlobalPoint = rebased
        instantaneousVelocity = .zero
        filteredVelocity = .zero
        lastMovementDerivedVelocity = .zero
        lastMovementVelocitySampleAt = nil
        lastMovementVelocitySampleMach = nil
        scrollStabilizer.reset()
        stationaryDwellDurationSec = 0.0
        lastSamplePoint = point
        lastSampleTimeDate = now
        if timestampMach > 0 {
            lastSampleTimeMach = timestampMach
        }
    }

    public func movementVelocitySnapshot(
        asOf time: Date,
        maximumAge: TimeInterval = GestureArbitrationConfig.releaseVelocityMaximumAgeSec
    ) -> MovementVelocitySnapshot? {
        guard let latest = latestMovementVelocitySnapshot(asOf: time), latest.ageSec <= maximumAge else { return nil }
        return latest
    }

    public func latestMovementVelocitySnapshot(asOf time: Date) -> MovementVelocitySnapshot? {
        // Suppress accidental momentum flick if finger dwelled stationary for >= 85ms before release
        if stationaryDwellDurationSec >= 0.085 {
            return nil
        }
        guard let sampledAt = lastMovementVelocitySampleAt else { return nil }
        let age = time.timeIntervalSince(sampledAt)
        let velocity = lastMovementDerivedVelocity
        guard age >= 0,
              velocity.dx.isFinite,
              velocity.dy.isFinite,
              hypot(velocity.dx, velocity.dy) > 0 else { return nil }
        return MovementVelocitySnapshot(velocity: velocity, sampledAt: sampledAt, ageSec: age)
    }

    public func markReleasePending(at time: Date, settleWindow: TimeInterval = GestureArbitrationConfig.releaseSettleWindowSec) {
        state = .releasePending
        releasePendingAt = time
        releaseSettleDeadline = time.addingTimeInterval(settleWindow)
        transitionDescription = "directPan -> releasePending"
        panActionResult = "Release settle lease pending momentum decision"
    }

    public func releaseDecisionIsOpen(at time: Date) -> Bool {
        guard state == .releasePending, let deadline = releaseSettleDeadline else { return false }
        return time <= deadline
    }
    
    public func markMomentumStarted() {
        state = .momentum
        transitionDescription = releasePendingAt == nil ? "directPan -> momentum" : "releasePending -> momentum"
        panActionResult = "Kinetic momentum coasting"
    }
    
    public func markMomentumEnded() {
        let priorState = state
        state = .idle
        releasePendingAt = nil
        releaseSettleDeadline = nil
        transitionDescription = priorState == .releasePending ? "releasePending -> idle" : "momentum -> idle"
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
        // AX semantic scrolling and CG compatibility scrolling are independent capabilities.
        if allowCGScrollFallback { return true }
        if let ctx = context {
            if ctx.scrollCapability.hasScrollArea && ctx.scrollBarElement != nil && ctx.scrollCapability.isVerticalValueSettable {
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

        Intent: \(interactionIntent)
        Policy: \(deliveryPolicy)
        Delivery: \(deliveryBackend)
        AX enrichment: \(axEnrichmentStatus)
        Final delivery result: \(tapActionResult)

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
          cursor action classification: \(cursorActionClassification ?? "NOT APPLICABLE")
        """
    }
}
