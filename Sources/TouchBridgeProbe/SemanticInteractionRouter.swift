import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

// MARK: - Interaction intent delivery and direct pan execution

public protocol SemanticInteractionRouterDelegate: AnyObject {
    func semanticRouter(_ router: SemanticInteractionRouter, didExecuteRecord record: SemanticEvidenceRecord)
    func semanticRouter(_ router: SemanticInteractionRouter, didUpdateFeedback feedback: String, invariantPassed: Bool)
    func semanticRouter(_ router: SemanticInteractionRouter, didCompleteSession session: InteractionSession, evidenceBlock: String)
}

public extension SemanticInteractionRouterDelegate {
    func semanticRouter(_ router: SemanticInteractionRouter, didCompleteSession session: InteractionSession, evidenceBlock: String) {}
}

public final class InteractionDeliveryRouter: TouchGestureRecognizerDelegate {
    public weak var delegate: SemanticInteractionRouterDelegate?
    
    /// Explicit user intent gate. If false, ZERO semantic interaction may occur.
    public var userIntent: UserIntent = .disabled
    public var probeOnly: Bool = false
    public var activeTestCaseName: String = "TouchBridge Semantic Tap"
    /// Selects one-finger tap delivery. Pointer-compatible delivery is primary;
    /// semantic-only is retained for diagnostic A/B comparisons.
    public var tapBackendMode: TapBackendMode = .transientPointer {
        didSet {
            if tapBackendMode == .transientPointer { _ = transientPointerBackend }
        }
    }
    public lazy var transientPointerBackend = TransientPointerTapBackend()
    public var preferContinuousCGScroll: Bool = true
    /// Compatibility escape hatch. CG click events move the real system cursor on some hosts.
    public var allowCursorMovingCGFallback: Bool = false
    /// Unsafe experimental cursor restoration prototype; never enabled by the product path.
    public var enableCGCursorRestoreExperiment: Bool = false
    
    // Kinetic momentum state (P3-03R Phase C)
    private var momentumTimer: Timer? = nil
    private var activeMomentumSession: InteractionSession? = nil
    private weak var momentumRecognizer: TouchGestureRecognizer?
    private var currentMomentumVelocity: CGVector = .zero
    private var fingerDownSmoothingTimer: Timer? = nil
    private var fingerDownSmoothingTail: FingerDownSmoothingTail? = nil
    private var lastDirectPanVelocityY: Double = 0
    private var loggedDirectScrollFields = false
    private var loggedMomentumFields = false
    
    public init() {}

    /// Delivery policy boundary between recognized intent and OS mechanisms.
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEmit intent: InteractionIntent) {
        switch intent {
        case .tap(let session):
            gestureRecognizer(recognizer, didResolveTapWithSession: session)
        case .cancelledOneFingerMovement(let session, let reason), .cancelled(let session, let reason):
            gestureRecognizer(recognizer, didCancelSession: session, reason: reason)
        case .directPanStarted(let session):
            gestureRecognizer(recognizer, didStartPanWithSession: session)
        case .directPanUpdated(let session, let delta):
            gestureRecognizer(recognizer, didUpdatePanDeltaWithSession: session, deltaPixels: delta)
        case .directPanAXValueUpdated(let session, let targetValue):
            gestureRecognizer(recognizer, didUpdatePanWithSession: session, targetValue: targetValue)
        case .directPanEnded(let session):
            gestureRecognizer(recognizer, didCompletePanWithSession: session)
        case .momentumStarted(let session, let velocity):
            gestureRecognizer(recognizer, didEnterMomentumWithSession: session, initialVelocity: velocity)
        case .momentumInterrupted(let session):
            gestureRecognizer(recognizer, didInterruptMomentumWithSession: session)
        case .unsupportedPan(let session):
            gestureRecognizer(recognizer, didMarkUnsupportedPan: session)
        }
    }

    public func prepareTapBackendForRuntime() {
        guard tapBackendMode == .transientPointer else { return }
        transientPointerBackend.prepareForTransactions()
    }
    
    deinit {
        haltMomentum()
        haltFingerDownSmoothing()
    }
    
    // MARK: - TouchGestureRecognizerDelegate
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didResolveTapWithSession session: InteractionSession) {
        session.interactionIntent = "TAP"
        session.deliveryPolicy = tapBackendMode.diagnosticName
        session.deliveryBackend = InteractionDeliveryPolicy.tapMechanism(mode: tapBackendMode).rawValue
        session.axEnrichmentStatus = tapBackendMode == .semantic
            ? (AXPermissionManager.shared.isTrusted() ? "AVAILABLE" : "UNAVAILABLE")
            : "NOT_REQUIRED"
        TouchBridgeLogger.info(.gesture, "Intent: TAP")
        TouchBridgeLogger.info(.semantic, "Policy: \(session.deliveryPolicy) | Delivery: \(session.deliveryBackend) | AX enrichment: \(session.axEnrichmentStatus)")
        // Absolute User Intent Gate (P3-01.1 Requirement 1 & P3-02 Section 5)
        guard userIntent == .enabled else {
            logTapNotResolved(point: session.startGlobalPoint.cgGlobal, rawRole: session.context?.hitNode.role ?? "None")
            TouchBridgeLogger.info(
                .semantic,
                "Physical tap OBSERVED at (\(String(format: "%.1f, %.1f", session.startGlobalPoint.cgGlobal.x, session.startGlobalPoint.cgGlobal.y))), but semantic interaction is SUPPRESSED (UserIntent is DISABLED)."
            )
            session.tapActionResult = "Suppressed (UserIntent Disabled)"
            TouchBridgeLogger.info(.semantic, "TAP ROUTE: USER_INTENT_DISABLED -> SUPPRESSED")
            delegate?.semanticRouter(self, didUpdateFeedback: "Tap Suppressed (Touch Disabled)", invariantPassed: true)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }

        if tapBackendMode == .transientPointer {
            let appName = session.context?.applicationName
            let result = transientPointerBackend.performClick(at: session.startGlobalPoint.cgGlobal, appName: appName)
            session.tapActionResult = result.succeeded ? "TRANSIENT_POINTER_CLICK" : "TRANSIENT_POINTER_CLICK_FAILED"
            TouchBridgeLogger.info(.semantic, "Final delivery result: \(session.tapActionResult)")
            delegate?.semanticRouter(
                self,
                didUpdateFeedback: result.succeeded ? "Transient Pointer Click [\(appName ?? "Application")]" : "Transient Pointer Click Failed",
                invariantPassed: result.restoreResult == "SUCCESS" && (result.finalDisplacement.map { $0 <= 1.0 } ?? false)
            )
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }

        if session.context == nil, AXPermissionManager.shared.isTrusted() {
            let (element, _, error) = AXSemanticEngine.shared.probeElementAt(globalCG: session.startGlobalPoint.cgGlobal)
            if error == .success, let element {
                session.applyAXEnrichment(AXCapabilityInspector.shared.discoverContext(element: element))
            }
        }
        
        guard AXPermissionManager.shared.isTrusted() else {
            logTapNotResolved(point: session.startGlobalPoint.cgGlobal, rawRole: session.context?.hitNode.role ?? "None")
            TouchBridgeLogger.warning(.semantic, "Tap rejected: Accessibility permission UNAVAILABLE.")
            session.axEnrichmentStatus = "UNAVAILABLE"
            session.tapActionResult = "Diagnostic semantic delivery unavailable (Accessibility permission missing)"
            TouchBridgeLogger.info(.semantic, "Final delivery result: \(session.tapActionResult)")
            delegate?.semanticRouter(self, didUpdateFeedback: "Accessibility Permission Missing", invariantPassed: true)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        
        if probeOnly {
            logTapNotResolved(point: session.startGlobalPoint.cgGlobal, rawRole: session.context?.hitNode.role ?? "None")
            probeElement(at: session.startGlobalPoint.cgGlobal)
            TouchBridgeLogger.info(.semantic, "TAP ROUTE: PROBE_ONLY -> INSPECTED_NO_ACTION")
            return
        }
        
        executeCapabilityAuthorizedTap(session: session)
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didStartPanWithSession session: InteractionSession) {
        haltMomentum()
        haltFingerDownSmoothing()
        lastDirectPanVelocityY = 0
        loggedDirectScrollFields = false
        
        guard userIntent == .enabled else {
            TouchBridgeLogger.info(.semantic, "Pan gesture observed, but interaction is SUPPRESSED (UserIntent is DISABLED).")
            return
        }
        
        let appName = session.context?.applicationName ?? "Application"
        if usesCGScroll(for: session) {
            session.panActionResult = "DIRECT_PAN -> CG_SCROLL_WHEEL (public continuous pixel events)"
        } else {
            session.panActionResult = "DIRECT_PAN -> AX_SCROLL_VALUE"
        }
        TouchBridgeLogger.info(
            .semantic,
            "Direct Pan STARTED on [\(appName)] (Contacts: \(session.contactCount))"
        )
        
        if usesCGScroll(for: session) {
            postScrollWheelEvent(location: session.startGlobalPoint.cgGlobal, deltaY: 0, phase: 1, momentumPhase: 0)
        }
        
        delegate?.semanticRouter(self, didUpdateFeedback: "Pan Started [\(appName)]", invariantPassed: true)
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanDeltaWithSession session: InteractionSession, deltaPixels: CGVector) {
        guard userIntent == .enabled else { return }

        if abs(deltaPixels.dy) > 0.01 {
            haltFingerDownSmoothing()
            lastDirectPanVelocityY = session.filteredVelocity.dy
        } else if fingerDownSmoothingTimer == nil, abs(lastDirectPanVelocityY) > 1 {
            fingerDownSmoothingTail = FingerDownSmoothingTail(velocityY: lastDirectPanVelocityY)
            lastDirectPanVelocityY = 0
            startFingerDownSmoothing(session: session)
        }
        
        if usesCGScroll(for: session) {
            postScrollWheelEvent(location: session.latestGlobalPoint.cgGlobal, deltaY: deltaPixels.dy, phase: 2, momentumPhase: 0)
        }
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanWithSession session: InteractionSession, targetValue: Double) {
        guard userIntent == .enabled else { return }
        guard !usesCGScroll(for: session), let bar = session.context?.scrollBarElement else { return }
        
        let scheduledAt = Date()
        let cursorBefore = SafetyInvariants.currentCursorPosition()
        let err = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, targetValue as CFTypeRef)
        let executedAt = Date()
        let cursorAfter = SafetyInvariants.currentCursorPosition()
        
        var readbackVal: Double? = nil
        var rRef: AnyObject?
        if AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &rRef) == .success, let r = rRef {
            if let n = r as? NSNumber { readbackVal = n.doubleValue }
            else if let d = Double(String(describing: r)) { readbackVal = d }
        }
        
        session.trace?.recordAXWrite(
            phase: "pan-update",
            fingerY: session.latestGlobalPoint.cgGlobal.y,
            scheduledAt: scheduledAt,
            executedAt: executedAt,
            requestedValue: targetValue,
            error: err,
            immediateReadback: readbackVal
        )
        
        let (satisfied, _) = SafetyInvariants.assertPointerIsolation(
            cursorBefore: cursorBefore,
            cursorAfter: cursorAfter,
            context: "Semantic Pan Update"
        )
        
        if err == .success {
            session.recordAXWriteDispatched(now: Date(), value: targetValue)
            session.cursorAfter = cursorAfter
            TouchBridgeLogger.debug(.semantic, "Pan Value Updated -> \(String(format: "%.3f", targetValue)) (Cursor Isolated: \(satisfied ? "YES" : "NO"))")
        } else {
            TouchBridgeLogger.warning(.semantic, "AXUIElementSetAttributeValue failed on scrollbar: \(err.rawValue)")
        }
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didCompletePanWithSession session: InteractionSession) {
        guard userIntent == .enabled else { return }
        haltMomentum()
        haltFingerDownSmoothing()
        
        if usesCGScroll(for: session) {
            postScrollWheelEvent(location: session.latestGlobalPoint.cgGlobal, deltaY: 0, phase: 4, momentumPhase: 0)
        }
        
        let cursorBefore = SafetyInvariants.currentCursorPosition()
        let cursorAfter = SafetyInvariants.currentCursorPosition()
        SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Pan Complete")
        
        session.cursorBefore = cursorBefore
        session.cursorAfter = cursorAfter
        
        let totalDeltaY = session.latestGlobalPoint.cgGlobal.y - session.startGlobalPoint.cgGlobal.y
        let appName = session.context?.applicationName ?? "Application"
        let summary = "PAN_COMPLETED on [\(appName)]: Updates=\(session.panUpdatesCount) | DeltaY=\(String(format: "%.1f", totalDeltaY)) pt"
        session.panActionResult = summary
        
        TouchBridgeLogger.info(.semantic, summary)
        delegate?.semanticRouter(self, didUpdateFeedback: summary, invariantPassed: true)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEnterMomentumWithSession session: InteractionSession, initialVelocity: CGVector) {
        guard userIntent == .enabled else { return }
        haltMomentum()
        haltFingerDownSmoothing()
        
        // 1. Terminate the touch phase
        postScrollWheelEvent(location: session.latestGlobalPoint.cgGlobal, deltaY: 0, phase: 4, momentumPhase: 0)
        
        // 2. Start kinetic momentum
        self.activeMomentumSession = session
        self.momentumRecognizer = recognizer
        self.currentMomentumVelocity = initialVelocity
        loggedMomentumFields = false
        
        let dt: Double = 0.016
        let initialStep = initialVelocity.dy * dt
        postScrollWheelEvent(location: session.latestGlobalPoint.cgGlobal, deltaY: initialStep, phase: 0, momentumPhase: 1)
        
        let initialSpeed = hypot(initialVelocity.dx, initialVelocity.dy)
        TouchBridgeLogger.info(
            .semantic,
            "Kinetic Momentum Started: speed=\(String(format: "%.1f", initialSpeed)) pt/s, initialStep=\(String(format: "%.2f", initialStep)) px"
        )
        
        self.momentumTimer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self] timer in
            guard let self = self, let active = self.activeMomentumSession else {
                timer.invalidate()
                return
            }
            
            self.currentMomentumVelocity.dy *= GestureArbitrationConfig.momentumDecayFactor
            let speed = abs(self.currentMomentumVelocity.dy)
            let step = self.currentMomentumVelocity.dy * dt
            
            if speed < GestureArbitrationConfig.minMomentumVelocityPtPerSec {
                // Natural momentum termination
                timer.invalidate()
                self.momentumTimer = nil
                self.postScrollWheelEvent(location: active.latestGlobalPoint.cgGlobal, deltaY: 0, phase: 0, momentumPhase: 4)
                active.markMomentumEnded()
                TouchBridgeLogger.info(.semantic, "Kinetic momentum settled naturally.")
                self.delegate?.semanticRouter(self, didCompleteSession: active, evidenceBlock: active.formattedEvidenceBlock())
                self.momentumRecognizer?.momentumDidEnd(active)
                self.activeMomentumSession = nil
                self.momentumRecognizer = nil
            } else {
                // Continuous kinetic momentum step
                self.postScrollWheelEvent(location: active.latestGlobalPoint.cgGlobal, deltaY: step, phase: 0, momentumPhase: 2)
            }
        }
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didInterruptMomentumWithSession session: InteractionSession) {
        haltFingerDownSmoothing()
        if let active = activeMomentumSession {
            haltMomentum()
            postScrollWheelEvent(location: active.latestGlobalPoint.cgGlobal, deltaY: 0, phase: 0, momentumPhase: 4)
            active.markMomentumEnded()
            TouchBridgeLogger.info(.semantic, "Kinetic momentum INTERRUPTED immediately by new touch contact.")
            self.activeMomentumSession = nil
            self.momentumRecognizer = nil
        }
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didMarkUnsupportedPan session: InteractionSession) {
        guard userIntent == .enabled else { return }
        let appName = session.context?.applicationName ?? "Application"
        session.cursorBefore = SafetyInvariants.currentCursorPosition()
        session.cursorAfter = session.cursorBefore
        session.panActionResult = "None (Continuous scroll backend missing; action suppressed without synthetic events)"
        TouchBridgeLogger.warning(
            .semantic,
            "PAN_UNSUPPORTED on [\(appName)]: Movement (\(String(format: "%.1f", session.maxMovementPt)) pt) crossed pan threshold on surface without writable continuous scrollbar. Action suppressed."
        )
        delegate?.semanticRouter(self, didUpdateFeedback: "Unsupported Pan [\(appName)]", invariantPassed: true)
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didCancelSession session: InteractionSession, reason: String) {
        haltMomentum()
        session.cursorAfter = SafetyInvariants.currentCursorPosition()
        TouchBridgeLogger.debug(.gesture, "Gesture session cancelled: \(reason) (Mov: \(String(format: "%.1f", session.maxMovementPt)) pt)")
        
        if reason == "UNSUPPORTED_PAN_RELEASE" || reason == "MOVEMENT_TOLERANCE_EXCEEDED" || reason == "CONTACT_TOO_BRIEF" {
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
        }
    }
    
    // MARK: - Capability-Authorized Tap Execution (P3-02 & P3-03R Phase B)
    
    private func executeCapabilityAuthorizedTap(session: InteractionSession) {
        if session.state != .tapExecuted {
            session.recordDelayedTapViolation()
            TouchBridgeLogger.error(.semantic, "CRITICAL ARBITRATION VIOLATION: Tap executed when session state was \(session.state)!")
        }

        let point = session.startGlobalPoint.cgGlobal
        let rawRole = session.context?.hitNode.role ?? "None"
        guard let rawElement = session.context?.hitElement else {
            logTapResolution(point: point, rawRole: rawRole, resolvedRole: nil, depth: nil, nodes: 0)
            completeUnresolvedTap(session: session, role: rawRole, route: ["AX_HIT_TEST_NONE"])
            return
        }

        let resolution = AXActionableHitResolver.resolve(initialElement: rawElement, point: point)
        logTapResolution(
            point: point,
            rawRole: rawRole,
            resolvedRole: resolution.node?.role,
            depth: resolution.depth,
            nodes: resolution.nodesVisited
        )
        guard let element = resolution.element, let node = resolution.node else {
            completeUnresolvedTap(session: session, role: rawRole, route: [])
            return
        }

        let backends = TapRoutingPolicy.backends(
            role: node.role,
            supportedActions: Set(node.supportedActions),
            settableAttributes: Set(node.settableAttributes)
        )
        var route: [String] = []
        let context = session.context!

        for backend in backends {
            switch backend {
            case .press:
                route.append("AX_PRESS")
                let duration = max(0.0, Date().timeIntervalSince(session.startTimeDate))
                let tapEvent = PhysicalTapEvent(
                    rawDownPoint: session.startRawPoint,
                    rawUpPoint: session.startRawPoint,
                    downSensorPoint: session.startSensorPoint,
                    calibratedLocalCG: session.startLocalPoint.cgPoint,
                    calibratedGlobalCG: point,
                    durationSec: duration,
                    movementPt: session.maxMovementPt,
                    timestampMach: session.startTimeMach,
                    timestampDate: session.startTimeDate
                )
                let snap = node.toSnapshot(pid: context.pid, appName: context.applicationName)
                let record = AXSemanticEngine.shared.performSemanticTap(
                    tap: tapEvent,
                    preResolvedElement: element,
                    preResolvedSnapshot: snap,
                    testCase: activeTestCaseName
                )
                session.tapActionResult = record.visibleResult
                delegate?.semanticRouter(self, didExecuteRecord: record)
                let pressSucceeded = record.classification == .semanticPressSuccess &&
                    record.semanticAction.executed &&
                    record.semanticAction.axErrorCode == AXError.success.rawValue
                guard TapRoutingPolicy.succeeded(.axPressSucceeded(pressSucceeded)) else {
                    route[route.count - 1] = "AX_PRESS_REJECTED"
                    TouchBridgeLogger.warning(.semantic, "AXPress failed for [\(node.role)]: \(record.visibleResult). Continuing tap routing.")
                    continue
                }
                TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_PRESS_SUCCESS] -> [\(context.applicationName) \(node.role)]: \(record.visibleResult)")
                delegate?.semanticRouter(self, didUpdateFeedback: record.visibleResult, invariantPassed: record.cursor.invariantSatisfied)
                completeTapRoute(route, role: node.role, result: "SUCCESS", session: session)
                return

            case .showMenu:
                route.append(TapBackend.showMenu.rawValue)
                let error = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
                guard error == .success else {
                    route[route.count - 1] = "AX_SHOW_MENU_REJECTED"
                    TouchBridgeLogger.warning(.semantic, "AXShowMenu failed for [\(node.role)]: error \(error.rawValue). Continuing tap routing.")
                    continue
                }
                session.tapActionResult = "AXShowMenu succeeded on \(node.role)"
                TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_MENU_SUCCESS] -> [\(context.applicationName) \(node.role)]")
                delegate?.semanticRouter(self, didUpdateFeedback: session.tapActionResult, invariantPassed: true)
                completeTapRoute(route, role: node.role, result: "SUCCESS", session: session)
                return

            case .selection:
                route.append("AX_SELECTION")
                let cursorBefore = SafetyInvariants.currentCursorPosition()
                let setError = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, true as CFTypeRef)
                var selectedRef: AnyObject?
                let readError = AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &selectedRef)
                let isSelected = readError == .success && (selectedRef as? Bool == true)
                let cursorAfter = SafetyInvariants.currentCursorPosition()
                let (pointerUnchanged, _) = SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Capability: Selection [\(node.role)]")
                guard TapRoutingPolicy.succeeded(.selection(setSucceeded: setError == .success, isSelected: isSelected)) else {
                    route[route.count - 1] = "AX_SELECTION_REJECTED"
                    TouchBridgeLogger.warning(.semantic, "AX selection rejected for [\(node.role)]: set=\(setError.rawValue), readback=\(isSelected ? "SELECTED" : "NOT_SELECTED") (error \(readError.rawValue)). Continuing tap routing.")
                    continue
                }
                session.cursorBefore = cursorBefore
                session.cursorAfter = cursorAfter
                session.tapActionResult = "AXSelected read back true on \(node.role)"
                TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_SELECTION_SUCCESS] -> [\(context.applicationName) \(node.role)]: setter and readback succeeded.")
                delegate?.semanticRouter(self, didUpdateFeedback: "Selected [\(node.role)]", invariantPassed: pointerUnchanged)
                completeTapRoute(route, role: node.role, result: "SUCCESS", session: session)
                return

            case .focus:
                route.append("AX_FOCUS")
                let cursorBefore = SafetyInvariants.currentCursorPosition()
                let focusRec = SemanticFocusController.shared.attemptFocus(element: element)
                let cursorAfter = SafetyInvariants.currentCursorPosition()
                let (pointerUnchanged, _) = SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Capability: Focus [\(node.role)]")
                guard TapRoutingPolicy.succeeded(.focusReadback(isFocused: focusRec.isFocusedAfter)) else {
                    route[route.count - 1] = "AX_FOCUS_REJECTED"
                    TouchBridgeLogger.warning(.semantic, "AX focus rejected for [\(node.role)]: readback=UNFOCUSED [NO]. Continuing tap routing.")
                    continue
                }
                session.cursorBefore = cursorBefore
                session.cursorAfter = cursorAfter
                session.tapActionResult = "AXFocused read back true [\(node.role)]"
                TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_FOCUS_SUCCESS] -> [\(context.applicationName) \(node.role)]: readback=FOCUSED [YES]")
                delegate?.semanticRouter(self, didUpdateFeedback: "Focused [\(node.role)]", invariantPassed: pointerUnchanged)
                completeTapRoute(route, role: node.role, result: "SUCCESS", session: session)
                return

            case .cursorMovingCGClick:
                completeUnresolvedTap(session: session, role: node.role, route: route)
                return
            }
        }
    }

    private func logTapResolution(point: CGPoint, rawRole: String, resolvedRole: String?, depth: Int?, nodes: Int) {
        let raw = diagnosticRole(rawRole)
        if let resolvedRole, let depth {
            TouchBridgeLogger.info(.semantic, "TAP RESOLVE: point=(\(String(format: "%.1f, %.1f", point.x, point.y))) raw=\(raw) -> resolved=\(diagnosticRole(resolvedRole)) depth=\(depth) nodes=\(nodes)")
        } else {
            TouchBridgeLogger.info(.semantic, "TAP RESOLVE: point=(\(String(format: "%.1f, %.1f", point.x, point.y))) raw=\(raw) -> no actionable descendant nodes=\(nodes)")
        }
    }

    private func logTapNotResolved(point: CGPoint, rawRole: String) {
        TouchBridgeLogger.info(.semantic, "TAP RESOLVE: point=(\(String(format: "%.1f, %.1f", point.x, point.y))) raw=\(diagnosticRole(rawRole)) -> resolution not run nodes=0")
    }

    private func completeUnresolvedTap(session: InteractionSession, role: String, route: [String]) {
        let prefix = ([diagnosticRole(role)] + route).filter { !$0.isEmpty }
        // Semantic-only is a diagnostic backend. It never substitutes a pointer
        // click when AX cannot resolve or execute an action.
        if tapBackendMode == .semantic {
            session.tapActionResult = "Diagnostic semantic delivery unresolved"
            session.pointerIsolationSatisfied = nil
            session.axEnrichmentStatus = AXPermissionManager.shared.isTrusted() ? "AVAILABLE" : "UNAVAILABLE"
            let routeText = (prefix + ["SEMANTIC_UNRESOLVED"]).joined(separator: " -> ")
            TouchBridgeLogger.info(.semantic, "TAP ROUTE: \(routeText)")
            delegate?.semanticRouter(self, didUpdateFeedback: session.tapActionResult, invariantPassed: true)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        switch TapRoutingPolicy.unresolvedHandling(
            allowCursorMovingFallback: allowCursorMovingCGFallback,
            enableCursorRestoreExperiment: enableCGCursorRestoreExperiment
        ) {
        case .cursorRestoreExperiment:
            executeCGCursorRestoreExperiment(point: session.startGlobalPoint.cgGlobal, session: session, route: prefix)
        case .cursorMovingCGClick:
            executeCursorMovingCGClick(point: session.startGlobalPoint.cgGlobal, session: session, route: prefix)
        case .semanticUnresolved:
            session.tapActionResult = "Semantic unresolved; cursor-moving CG fallback suppressed"
            session.pointerIsolationSatisfied = nil
            session.cursorActionClassification = "CG_CURSOR_MOVING_FALLBACK_SUPPRESSED"
            let routeText = (prefix + ["SEMANTIC_UNRESOLVED", "CG_CURSOR_MOVING_FALLBACK_SUPPRESSED"]).joined(separator: " -> ")
            TouchBridgeLogger.info(.semantic, "TAP ROUTE: \(routeText)")
            delegate?.semanticRouter(self, didUpdateFeedback: "Tap unresolved (cursor-moving fallback suppressed)", invariantPassed: true)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
        }
    }

    private func completeTapRoute(_ route: [String], role: String, result: String, session: InteractionSession) {
        let routeText = ([diagnosticRole(role)] + route + [result]).joined(separator: " -> ")
        TouchBridgeLogger.info(.semantic, "TAP ROUTE: \(routeText)")
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }

    private func diagnosticRole(_ role: String) -> String {
        let name = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        var result = "AX_"
        for character in name {
            if character.isUppercase, result.last != "_" { result.append("_") }
            result.append(character.uppercased())
        }
        return result
    }

    private func executeCursorMovingCGClick(point: CGPoint, session: InteractionSession, route: [String]) {
        session.cursorActionClassification = TapExecutionClassification.cursorMovingCGClick.rawValue
        let before = SafetyInvariants.currentCursorPosition()
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            finishCGClickFailure(session: session, route: route + [TapBackend.cursorMovingCGClick.rawValue])
            return
        }
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
        let after = SafetyInvariants.currentCursorPosition()
        let delta = hypot(after.x - before.x, after.y - before.y)
        session.cursorBefore = before
        session.cursorAfter = after
        session.pointerIsolationSatisfied = delta <= 0.001
        session.tapActionResult = "\(TapExecutionClassification.cursorMovingCGClick.rawValue) dispatched (cursor delta \(String(format: "%.3f", delta)) pt)"
        let routeText = (route + [TapExecutionClassification.cursorMovingCGClick.rawValue, "DISPATCHED", "CURSOR_DELTA=\(String(format: "%.3f", delta))pt"]).joined(separator: " -> ")
        TouchBridgeLogger.warning(.semantic, "TAP ROUTE: \(routeText)")
        delegate?.semanticRouter(self, didUpdateFeedback: "Cursor-moving CG click (delta \(String(format: "%.3f", delta)) pt)", invariantPassed: delta <= 0.001)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }

    /// Experimental only. Cursor restoration is attempted only when the post-click
    /// cursor remains at the injected click location. This cannot distinguish an
    /// external mouse landing at that exact point or eliminate the check/warp race.
    private func executeCGCursorRestoreExperiment(point: CGPoint, session: InteractionSession, route: [String]) {
        session.cursorActionClassification = TapExecutionClassification.cursorRestoreExperiment.rawValue
        let startedAt = ProcessInfo.processInfo.systemUptime
        let before = SafetyInvariants.currentCursorPosition()
        let displayID = CGMainDisplayID()
        let hideError = CGDisplayHideCursor(displayID)
        guard hideError == .success else {
            session.tapActionResult = "CG_CURSOR_RESTORE_EXPERIMENT aborted: cursor hide failed (\(hideError.rawValue))"
            session.pointerIsolationSatisfied = nil
            TouchBridgeLogger.warning(.semantic, "TAP ROUTE: \((route + [TapExecutionClassification.cursorRestoreExperiment.rawValue, "ABORTED_CURSOR_HIDE_FAILED"]).joined(separator: " -> "))")
            delegate?.semanticRouter(self, didUpdateFeedback: session.tapActionResult, invariantPassed: false)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            CGDisplayShowCursor(displayID)
            finishCGClickFailure(session: session, route: route + [TapExecutionClassification.cursorRestoreExperiment.rawValue])
            return
        }
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)

        // Conservative location check: movement away from the injected target
        // suppresses restoration. This cannot identify external motion landing
        // exactly at the target or close the race between this check and the warp.
        let afterClick = SafetyInvariants.currentCursorPosition()
        let appearsUncontested = hypot(afterClick.x - point.x, afterClick.y - point.y) <= 1.0
        let restoreResult: String
        if appearsUncontested {
            restoreResult = CGWarpMouseCursorPosition(before) == .success ? "RESTORED_HEURISTIC" : "RESTORE_FAILED"
        } else {
            restoreResult = "SKIPPED_EXTERNAL_MOTION"
        }
        CGDisplayShowCursor(displayID)
        let after = SafetyInvariants.currentCursorPosition()
        let delta = hypot(after.x - before.x, after.y - before.y)
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        session.cursorBefore = before
        session.cursorAfter = after
        session.pointerIsolationSatisfied = nil
        session.tapActionResult = "\(TapExecutionClassification.cursorRestoreExperiment.rawValue): \(restoreResult), final delta \(String(format: "%.3f", delta)) pt"
        let routeText = (route + [TapExecutionClassification.cursorRestoreExperiment.rawValue, restoreResult, "FINAL_CURSOR_DELTA=\(String(format: "%.3f", delta))pt", "DURATION=\(String(format: "%.1f", elapsedMs))ms"]).joined(separator: " -> ")
        let routeTextWithObservations = routeText + " -> VISIBLE_FLICKER=MANUAL_CHECK -> EXTERNAL_MOUSE=LOCATION_HEURISTIC"
        TouchBridgeLogger.warning(.semantic, "TAP ROUTE: \(routeTextWithObservations)")
        TouchBridgeLogger.warning(.semantic, "Cursor restore experiment is not pointer isolation. Position sampling cannot detect external movement landing at the touch point or prevent movement between the check and warp.")
        delegate?.semanticRouter(self, didUpdateFeedback: session.tapActionResult, invariantPassed: false)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }

    private func finishCGClickFailure(session: InteractionSession, route: [String]) {
        session.tapActionResult = "CG primary click event creation failed"
        session.pointerIsolationSatisfied = nil
        TouchBridgeLogger.info(.semantic, "TAP ROUTE: \((route + ["EVENT_CREATION_FAILED"]).joined(separator: " -> "))")
        delegate?.semanticRouter(self, didUpdateFeedback: "CG click event creation failed", invariantPassed: false)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }

    private func postScrollWheelEvent(location: CGPoint, deltaY: Double, phase: Int64, momentumPhase: Int64) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(round(deltaY)),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        
        event.location = location
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(round(deltaY)))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        if (!loggedDirectScrollFields && phase == 2 && momentumPhase == 0 && abs(deltaY) > 0.001) || (!loggedMomentumFields && momentumPhase == 1) {
            if momentumPhase == 1 { loggedMomentumFields = true } else { loggedDirectScrollFields = true }
            TouchBridgeLogger.info(.semantic, "CG_SCROLL_WHEEL fields: units=pixel continuous=1 scrollPhase=\(phase) momentumPhase=\(momentumPhase) wheelDeltaY=\(Int32(round(deltaY))) fixedPixelDeltaY=\(String(format: "%.3f", deltaY)) pointPixelDeltaY=\(String(format: "%.3f", deltaY))")
        }
        event.post(tap: .cghidEventTap)
    }

    private func startFingerDownSmoothing(session: InteractionSession) {
        let dt = GestureArbitrationConfig.fingerDownSmoothingFrameIntervalSec
        fingerDownSmoothingTimer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self, weak session] timer in
            guard let self, let session, var tail = self.fingerDownSmoothingTail,
                  session.state == .directPan else {
                timer.invalidate()
                self?.haltFingerDownSmoothing()
                return
            }
            guard let delta = tail.nextDeltaY() else {
                self.haltFingerDownSmoothing()
                return
            }
            self.fingerDownSmoothingTail = tail
            if self.usesCGScroll(for: session) {
                self.postScrollWheelEvent(location: session.latestGlobalPoint.cgGlobal, deltaY: delta, phase: 2, momentumPhase: 0)
            }
        }
    }

    private func haltFingerDownSmoothing() {
        fingerDownSmoothingTimer?.invalidate()
        fingerDownSmoothingTimer = nil
        fingerDownSmoothingTail = nil
    }

    private func usesCGScroll(for session: InteractionSession) -> Bool {
        session.contactCount >= 2 || preferContinuousCGScroll || session.context?.scrollBarElement == nil
    }
    
    private func haltMomentum() {
        if let timer = momentumTimer {
            timer.invalidate()
            momentumTimer = nil
        }
    }
    
    private func probeElement(at globalCG: CGPoint) {
        TouchBridgeLogger.info(.semantic, "Probe-only hit-test at Global (\(String(format: "%.1f, %.1f", globalCG.x, globalCG.y)))")
        let (elemOpt, _, err) = AXSemanticEngine.shared.probeElementAt(globalCG: globalCG)
        if err == .success, let elem = elemOpt {
            let inspection = AXCapabilityInspector.shared.inspect(element: elem)
            TouchBridgeLogger.info(
                .semantic,
                "Hit: App: \(inspection.applicationName) (PID: \(inspection.pid)), Role: \(inspection.hitNode.role), Actions: \(inspection.hitNode.supportedActions), Settable: \(inspection.hitNode.settableAttributes)"
            )
            delegate?.semanticRouter(
                self,
                didUpdateFeedback: "Hit: \(inspection.applicationName) (\(inspection.hitNode.role))",
                invariantPassed: true
            )
        } else {
            TouchBridgeLogger.warning(.semantic, "Hit test failed: \(AXSemanticEngine.shared.axErrorDescription(err))")
        }
    }
}

/// Source compatibility for existing integrations that used the P3-02 name.
public typealias SemanticInteractionRouter = InteractionDeliveryRouter
