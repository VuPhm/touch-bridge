import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

// MARK: - Pipeline Layer 6: Capability-Driven SemanticInteractionRouter & Pan Executor (P3-02)

public protocol SemanticInteractionRouterDelegate: AnyObject {
    func semanticRouter(_ router: SemanticInteractionRouter, didExecuteRecord record: SemanticEvidenceRecord)
    func semanticRouter(_ router: SemanticInteractionRouter, didUpdateFeedback feedback: String, invariantPassed: Bool)
    func semanticRouter(_ router: SemanticInteractionRouter, didCompleteSession session: InteractionSession, evidenceBlock: String)
}

public extension SemanticInteractionRouterDelegate {
    func semanticRouter(_ router: SemanticInteractionRouter, didCompleteSession session: InteractionSession, evidenceBlock: String) {}
}

public final class SemanticInteractionRouter: TouchGestureRecognizerDelegate {
    public weak var delegate: SemanticInteractionRouterDelegate?
    
    /// Explicit user intent gate. If false, ZERO semantic interaction may occur.
    public var userIntent: UserIntent = .disabled
    public var probeOnly: Bool = false
    public var activeTestCaseName: String = "TouchBridge Semantic Tap"
    public var preferContinuousCGScroll: Bool = true
    
    // Kinetic momentum state (P3-03R Phase C)
    private var momentumTimer: Timer? = nil
    private var activeMomentumSession: InteractionSession? = nil
    private var currentMomentumVelocity: CGVector = .zero
    private var fingerDownSmoothingTimer: Timer? = nil
    private var fingerDownSmoothingTail: FingerDownSmoothingTail? = nil
    private var lastDirectPanVelocityY: Double = 0
    private var loggedDirectScrollFields = false
    private var loggedMomentumFields = false
    
    public init() {}
    
    deinit {
        haltMomentum()
        haltFingerDownSmoothing()
    }
    
    // MARK: - TouchGestureRecognizerDelegate
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didResolveTapWithSession session: InteractionSession) {
        // Absolute User Intent Gate (P3-01.1 Requirement 1 & P3-02 Section 5)
        guard userIntent == .enabled else {
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
        
        guard AXPermissionManager.shared.isTrusted() else {
            TouchBridgeLogger.warning(.semantic, "Tap rejected: Accessibility permission UNAVAILABLE.")
            session.tapActionResult = "Rejected (Accessibility Permission Missing)"
            TouchBridgeLogger.info(.semantic, "TAP ROUTE: ACCESSIBILITY_UNAVAILABLE -> REJECTED")
            delegate?.semanticRouter(self, didUpdateFeedback: "Accessibility Permission Missing", invariantPassed: true)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        
        if probeOnly {
            probeElement(at: session.startGlobalPoint.cgGlobal)
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
        if preferContinuousCGScroll || session.context?.scrollBarElement == nil {
            session.panActionResult = "DIRECT_PAN -> CG_SCROLL_WHEEL (public continuous pixel events)"
        } else {
            session.panActionResult = "DIRECT_PAN -> AX_SCROLL_VALUE"
        }
        TouchBridgeLogger.info(
            .semantic,
            "Direct Pan STARTED on [\(appName)] (Contacts: \(session.contactCount))"
        )
        
        if preferContinuousCGScroll || session.context?.scrollBarElement == nil {
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
        
        if preferContinuousCGScroll || session.context?.scrollBarElement == nil {
            postScrollWheelEvent(location: session.latestGlobalPoint.cgGlobal, deltaY: deltaPixels.dy, phase: 2, momentumPhase: 0)
        }
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanWithSession session: InteractionSession, targetValue: Double) {
        guard userIntent == .enabled else { return }
        guard !preferContinuousCGScroll, let bar = session.context?.scrollBarElement else { return }
        
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
        
        if preferContinuousCGScroll || session.context?.scrollBarElement == nil {
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
                self.activeMomentumSession = nil
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
        
        if reason == "UNSUPPORTED_PAN_RELEASE" {
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
        }
    }
    
    // MARK: - Capability-Authorized Tap Execution (P3-02 & P3-03R Phase B)
    
    private func executeCapabilityAuthorizedTap(session: InteractionSession) {
        if session.state != .tapExecuted {
            session.recordDelayedTapViolation()
            TouchBridgeLogger.error(.semantic, "CRITICAL ARBITRATION VIOLATION: Tap executed when session state was \(session.state)!")
        }

        guard let context = session.context else {
            TouchBridgeLogger.info(.semantic, "Hit-test found no AX element at tap position. Engaging CG Primary Click fallback.")
            executeCoreGraphicsPrimaryClick(point: session.startGlobalPoint.cgGlobal, session: session, route: ["AX_HIT_TEST_NONE"])
            return
        }

        let elem = context.hitElement
        let hitNode = context.hitNode
        let backends = TapRoutingPolicy.backends(
            role: hitNode.role,
            supportedActions: Set(hitNode.supportedActions),
            settableAttributes: Set(hitNode.settableAttributes)
        )
        var route: [String] = []

        for backend in backends {
            switch backend {
            case .focus:
                route.append("AX_FOCUS")
                let cursorBefore = SafetyInvariants.currentCursorPosition()
                let focusRec = SemanticFocusController.shared.attemptFocus(element: elem)
                let cursorAfter = SafetyInvariants.currentCursorPosition()
                let (satisfied, _) = SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Capability: Focus [\(hitNode.role)]")
                guard TapRoutingPolicy.succeeded(.focusReadback(isFocused: focusRec.isFocusedAfter)) else {
                    route[route.count - 1] = "AX_FOCUS_REJECTED"
                    TouchBridgeLogger.warning(.semantic, "AX focus attempt rejected for [\(hitNode.role)]: readback=UNFOCUSED [NO], classification=\(focusRec.classification). Continuing tap routing.")
                    continue
                }
                session.cursorBefore = cursorBefore
                session.cursorAfter = cursorAfter
                session.tapActionResult = "AXFocused read back true [\(hitNode.role)] (\(focusRec.classification))"
                TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_FOCUS_SUCCESS] -> [\(context.applicationName) \(hitNode.role)]: readback=FOCUSED [YES]")
                delegate?.semanticRouter(self, didUpdateFeedback: "Focused [\(hitNode.role)]: \(focusRec.classification)", invariantPassed: satisfied)
                completeTapRoute(route, role: hitNode.role, result: "SUCCESS", session: session)
                return

            case .selection:
                route.append("AX_SELECTION")
                let cursorBefore = SafetyInvariants.currentCursorPosition()
                let setError = AXUIElementSetAttributeValue(elem, kAXSelectedAttribute as CFString, true as CFTypeRef)
                var selectedRef: AnyObject?
                let readError = AXUIElementCopyAttributeValue(elem, kAXSelectedAttribute as CFString, &selectedRef)
                let isSelected = readError == .success && (selectedRef as? Bool == true)
                let cursorAfter = SafetyInvariants.currentCursorPosition()
                let (satisfied, _) = SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Capability: Selection [\(hitNode.role)]")
                guard TapRoutingPolicy.succeeded(.selection(setSucceeded: setError == .success, isSelected: isSelected)) else {
                    route[route.count - 1] = "AX_SELECTION_REJECTED"
                    TouchBridgeLogger.warning(.semantic, "AX selection rejected for [\(hitNode.role)]: set=\(setError.rawValue), readback=\(isSelected ? "SELECTED" : "NOT_SELECTED") (error \(readError.rawValue)). Continuing tap routing.")
                    continue
                }
                session.cursorBefore = cursorBefore
                session.cursorAfter = cursorAfter
                session.tapActionResult = "AXSelected read back true on \(hitNode.role)"
                TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_SELECTION_SUCCESS] -> [\(context.applicationName) \(hitNode.role)]: setter and readback succeeded.")
                delegate?.semanticRouter(self, didUpdateFeedback: "Selected [\(hitNode.role)]", invariantPassed: satisfied)
                completeTapRoute(route, role: hitNode.role, result: "SUCCESS", session: session)
                return

            case .press:
                route.append("AX_PRESS")
                let duration = max(0.0, Date().timeIntervalSince(session.startTimeDate))
                let tapEvent = PhysicalTapEvent(
                    rawDownPoint: session.startRawPoint,
                    rawUpPoint: session.startRawPoint,
                    downSensorPoint: session.startSensorPoint,
                    calibratedLocalCG: session.startLocalPoint.cgPoint,
                    calibratedGlobalCG: session.startGlobalPoint.cgGlobal,
                    durationSec: duration,
                    movementPt: session.maxMovementPt,
                    timestampMach: session.startTimeMach,
                    timestampDate: session.startTimeDate
                )
                let cursorBefore = SafetyInvariants.currentCursorPosition()
                let snap = hitNode.toSnapshot(pid: context.pid, appName: context.applicationName)
                let record = AXSemanticEngine.shared.performSemanticTap(tap: tapEvent, preResolvedElement: elem, preResolvedSnapshot: snap, testCase: activeTestCaseName)
                let cursorAfter = SafetyInvariants.currentCursorPosition()
                session.cursorBefore = cursorBefore
                session.cursorAfter = cursorAfter
                session.tapActionResult = record.visibleResult
                SafetyInvariants.assertPointerIsolation(
                    cursorBefore: CGPoint(x: record.cursor.beforeX, y: record.cursor.beforeY),
                    cursorAfter: CGPoint(x: record.cursor.afterX, y: record.cursor.afterY),
                    context: "Capability: AXPress [\(context.applicationName) \(hitNode.role)]"
                )
                delegate?.semanticRouter(self, didExecuteRecord: record)
                let pressSucceeded = record.classification == .semanticPressSuccess &&
                    record.semanticAction.executed &&
                    record.semanticAction.axErrorCode == AXError.success.rawValue
                guard TapRoutingPolicy.succeeded(.axActionSucceeded(pressSucceeded)) else {
                    route[route.count - 1] = "AX_PRESS_REJECTED"
                    TouchBridgeLogger.warning(.semantic, "AXPress failed for [\(hitNode.role)]: \(record.visibleResult). Continuing tap routing.")
                    continue
                }
                TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_PRESS_SUCCESS] -> [\(context.applicationName) \(hitNode.role)]: \(record.visibleResult)")
                delegate?.semanticRouter(self, didUpdateFeedback: record.visibleResult, invariantPassed: record.cursor.invariantSatisfied)
                completeTapRoute(route, role: hitNode.role, result: "SUCCESS", session: session)
                return

            case .showMenu, .pick:
                let actionName = backend == .showMenu ? (kAXShowMenuAction as String) : "AXPick"
                let label = backend == .showMenu ? "AX_SHOW_MENU" : "AX_PICK"
                route.append(label)
                let cursorBefore = SafetyInvariants.currentCursorPosition()
                let actionError = AXUIElementPerformAction(elem, actionName as CFString)
                let cursorAfter = SafetyInvariants.currentCursorPosition()
                let (satisfied, _) = SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Capability: \(actionName)")
                guard TapRoutingPolicy.succeeded(.axActionSucceeded(actionError == .success)) else {
                    route[route.count - 1] = "\(label)_REJECTED"
                    TouchBridgeLogger.warning(.semantic, "\(actionName) failed for [\(hitNode.role)]: AX error \(actionError.rawValue). Continuing tap routing.")
                    continue
                }
                session.cursorBefore = cursorBefore
                session.cursorAfter = cursorAfter
                session.tapActionResult = "\(actionName) succeeded on \(hitNode.role)"
                TouchBridgeLogger.info(.semantic, "Capability Authorized [\(actionName)] -> [\(context.applicationName) \(hitNode.role)]: AX call succeeded.")
                delegate?.semanticRouter(self, didUpdateFeedback: "\(actionName) [\(hitNode.role)]", invariantPassed: satisfied)
                completeTapRoute(route, role: hitNode.role, result: "SUCCESS", session: session)
                return

            case .coreGraphicsPrimaryClick:
                executeCoreGraphicsPrimaryClick(point: session.startGlobalPoint.cgGlobal, session: session, route: route)
                return
            }
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

    func executeCoreGraphicsPrimaryClick(point: CGPoint, session: InteractionSession, route initialRoute: [String] = []) {
        let cursorBefore = SafetyInvariants.currentCursorPosition()

        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            TouchBridgeLogger.error(.semantic, "Failed to synthesize CGEvent left click at (\(point.x), \(point.y))")
            session.tapActionResult = "Failed to create CGEvent left click"
            session.pointerIsolationSatisfied = false
            delegate?.semanticRouter(self, didUpdateFeedback: "CG click event creation failed", invariantPassed: false)
            TouchBridgeLogger.info(.semantic, "TAP ROUTE: \((initialRoute + ["CG_PRIMARY_CLICK", "FAILED"]).joined(separator: " -> "))")
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }

        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)

        let cursorAfter = SafetyInvariants.currentCursorPosition()
        let (isolationSatisfied, cursorDelta) = SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "CoreGraphics Primary Click")
        session.cursorBefore = cursorBefore
        session.cursorAfter = cursorAfter
        session.pointerIsolationSatisfied = isolationSatisfied
        let role = session.context?.hitNode.role ?? "None"
        session.tapActionResult = "CGPrimaryClick Fallback at (\(String(format: "%.1f, %.1f", point.x, point.y))) [\(role)]"

        TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_CG_FALLBACK] -> Dispatched CG Primary Left Click at (\(String(format: "%.1f, %.1f", point.x, point.y))) [Target: \(role)]")
        TouchBridgeLogger.info(.semantic, "CG primary click pointer-isolation evidence: \(isolationSatisfied ? "PASS" : "FAIL") (cursor delta \(String(format: "%.3f", cursorDelta)) pt).")
        let routeText = (initialRoute + ["CG_PRIMARY_CLICK", "SUCCESS"]).joined(separator: " -> ")
        TouchBridgeLogger.info(.semantic, "TAP ROUTE: \(contextRole(session)) -> \(routeText) | POINTER_ISOLATION=\(isolationSatisfied ? "PASS" : "FAIL") (delta \(String(format: "%.3f", cursorDelta)) pt)")
        delegate?.semanticRouter(self, didUpdateFeedback: "Tap -> CG Click (\(String(format: "%.0f, %.0f", point.x, point.y)))", invariantPassed: isolationSatisfied)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }

    private func contextRole(_ session: InteractionSession) -> String {
        diagnosticRole(session.context?.hitNode.role ?? "None")
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
            if self.preferContinuousCGScroll {
                self.postScrollWheelEvent(location: session.latestGlobalPoint.cgGlobal, deltaY: delta, phase: 2, momentumPhase: 0)
            }
        }
    }

    private func haltFingerDownSmoothing() {
        fingerDownSmoothingTimer?.invalidate()
        fingerDownSmoothingTimer = nil
        fingerDownSmoothingTail = nil
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
