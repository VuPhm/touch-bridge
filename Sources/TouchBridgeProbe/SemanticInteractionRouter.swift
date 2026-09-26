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
            delegate?.semanticRouter(self, didUpdateFeedback: "Tap Suppressed (Touch Disabled)", invariantPassed: true)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        
        guard AXPermissionManager.shared.isTrusted() else {
            TouchBridgeLogger.warning(.semantic, "Tap rejected: Accessibility permission UNAVAILABLE.")
            session.tapActionResult = "Rejected (Accessibility Permission Missing)"
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
            // Hit-test found no AX element -> Engage CoreGraphics Primary Click fallback
            TouchBridgeLogger.info(.semantic, "Hit-test found no AX element at tap position. Engaging CG Primary Click fallback.")
            executeCoreGraphicsPrimaryClick(point: session.startGlobalPoint.cgGlobal, session: session)
            return
        }
        
        let elem = context.hitElement
        let hitNode = context.hitNode
        
        // 1. CAPABILITY GATE: Settable Focus (Dedicated text inputs or focusable non-button containers)
        let isTextRole = (hitNode.role == "AXTextField" || hitNode.role == "AXTextArea" || hitNode.role == "AXSearchField")
        let hasPress = hitNode.supportedActions.contains(kAXPressAction as String)
        
        if hitNode.attributeNames.contains(kAXFocusedAttribute as String) && hitNode.isFocusSettable && (isTextRole || !hasPress) {
            let cursorBefore = SafetyInvariants.currentCursorPosition()
            let focusRec = SemanticFocusController.shared.attemptFocus(element: elem)
            let cursorAfter = SafetyInvariants.currentCursorPosition()
            
            session.cursorBefore = cursorBefore
            session.cursorAfter = cursorAfter
            session.tapActionResult = "AXFocused set to true [\(hitNode.role)] (\(focusRec.classification))"
            
            let (satisfied, _) = SafetyInvariants.assertPointerIsolation(
                cursorBefore: cursorBefore,
                cursorAfter: cursorAfter,
                context: "Capability: Focus [\(hitNode.role)]"
            )
            
            TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_FOCUS_SUCCESS] -> [\(context.applicationName) \(hitNode.role)]: \(focusRec.classification)")
            delegate?.semanticRouter(
                self,
                didUpdateFeedback: "Focused [\(hitNode.role)]: \(focusRec.classification)",
                invariantPassed: satisfied
            )
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        
        // 2. CAPABILITY GATE: Settable Selection (Table rows, list items)
        if hitNode.attributeNames.contains(kAXSelectedAttribute as String) && hitNode.isSelectedSettable {
            let cursorBefore = SafetyInvariants.currentCursorPosition()
            let selErr = AXUIElementSetAttributeValue(elem, kAXSelectedAttribute as CFString, true as CFTypeRef)
            let cursorAfter = SafetyInvariants.currentCursorPosition()
            
            session.cursorBefore = cursorBefore
            session.cursorAfter = cursorAfter
            session.tapActionResult = "AXSelected set to true on \(hitNode.role)"
            
            let (satisfied, _) = SafetyInvariants.assertPointerIsolation(
                cursorBefore: cursorBefore,
                cursorAfter: cursorAfter,
                context: "Capability: Selection [\(hitNode.role)]"
            )
            
            if selErr == .success {
                TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_SELECTION_SUCCESS] -> [\(context.applicationName) \(hitNode.role)]: AXSelected set to true.")
                delegate?.semanticRouter(self, didUpdateFeedback: "Selected [\(hitNode.role)]", invariantPassed: satisfied)
                delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
                return
            }
        }
        
        // 3. CAPABILITY GATE: Semantic Press (Buttons, actionable controls)
        if hitNode.supportedActions.contains(kAXPressAction as String) {
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
            let record = AXSemanticEngine.shared.performSemanticTap(
                tap: tapEvent,
                preResolvedElement: elem,
                preResolvedSnapshot: snap,
                testCase: activeTestCaseName
            )
            let cursorAfter = SafetyInvariants.currentCursorPosition()
            
            session.cursorBefore = cursorBefore
            session.cursorAfter = cursorAfter
            session.tapActionResult = record.visibleResult
            
            SafetyInvariants.assertPointerIsolation(
                cursorBefore: CGPoint(x: record.cursor.beforeX, y: record.cursor.beforeY),
                cursorAfter: CGPoint(x: record.cursor.afterX, y: record.cursor.afterY),
                context: "Capability: AXPress [\(context.applicationName) \(hitNode.role)]"
            )
            
            TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_PRESS_SUCCESS] -> [\(context.applicationName) \(hitNode.role)]: \(record.visibleResult)")
            delegate?.semanticRouter(self, didExecuteRecord: record)
            delegate?.semanticRouter(self, didUpdateFeedback: record.visibleResult, invariantPassed: record.cursor.invariantSatisfied)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        
        // 4. CAPABILITY GATE: Alternative Action (ShowMenu / Pick)
        if hitNode.supportedActions.contains(kAXShowMenuAction as String) {
            let cursorBefore = SafetyInvariants.currentCursorPosition()
            let actErr = AXUIElementPerformAction(elem, kAXShowMenuAction as CFString)
            let cursorAfter = SafetyInvariants.currentCursorPosition()
            session.cursorBefore = cursorBefore
            session.cursorAfter = cursorAfter
            session.tapActionResult = "kAXShowMenuAction dispatched to \(hitNode.role) (result=\(actErr.rawValue))"
            let (satisfied, _) = SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Capability: ShowMenu")
            TouchBridgeLogger.info(.semantic, "Capability Authorized [TAP_MENU_SUCCESS] -> [\(context.applicationName) \(hitNode.role)]: result=\(actErr.rawValue)")
            delegate?.semanticRouter(self, didUpdateFeedback: "ShowMenu [\(hitNode.role)]", invariantPassed: satisfied)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        
        if hitNode.supportedActions.contains("AXPick") {
            let cursorBefore = SafetyInvariants.currentCursorPosition()
            let actErr = AXUIElementPerformAction(elem, "AXPick" as CFString)
            let cursorAfter = SafetyInvariants.currentCursorPosition()
            session.cursorBefore = cursorBefore
            session.cursorAfter = cursorAfter
            session.tapActionResult = "AXPick dispatched to \(hitNode.role) (result=\(actErr.rawValue))"
            let (satisfied, _) = SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Capability: AXPick")
            TouchBridgeLogger.info(.semantic, "Capability Authorized [AXPick] -> [\(context.applicationName) \(hitNode.role)]: result=\(actErr.rawValue)")
            delegate?.semanticRouter(self, didUpdateFeedback: "Picked [\(hitNode.role)]", invariantPassed: satisfied)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        
        // 5. CAPABILITY FALLBACK: CoreGraphics Primary Click (P3-03R Phase B)
        // Public CoreGraphics primary-click fallback where AX cannot provide reliable activation (e.g. Safari web links, custom buttons).
        TouchBridgeLogger.info(
            .semantic,
            "Element [\(hitNode.role)] exposes no actionable semantic action. Engaging CoreGraphics Primary Click fallback."
        )
        executeCoreGraphicsPrimaryClick(point: session.startGlobalPoint.cgGlobal, session: session)
    }
    
    func executeCoreGraphicsPrimaryClick(point: CGPoint, session: InteractionSession) {
        let cursorBefore = SafetyInvariants.currentCursorPosition()
        
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            TouchBridgeLogger.error(.semantic, "Failed to synthesize CGEvent left click at (\(point.x), \(point.y))")
            session.tapActionResult = "Failed to create CGEvent left click"
            session.pointerIsolationSatisfied = false
            delegate?.semanticRouter(self, didUpdateFeedback: "CG click event creation failed", invariantPassed: false)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }
        
        down.post(tap: .cghidEventTap)
        usleep(10_000) // 10ms click hold duration
        up.post(tap: .cghidEventTap)
        
        let cursorAfter = SafetyInvariants.currentCursorPosition()
        let (isolationSatisfied, cursorDelta) = SafetyInvariants.assertPointerIsolation(
            cursorBefore: cursorBefore,
            cursorAfter: cursorAfter,
            context: "CoreGraphics Primary Click"
        )
        session.cursorBefore = cursorBefore
        session.cursorAfter = cursorAfter
        session.pointerIsolationSatisfied = isolationSatisfied
        let role = session.context?.hitNode.role ?? "None"
        session.tapActionResult = "CGPrimaryClick Fallback at (\(String(format: "%.1f, %.1f", point.x, point.y))) [\(role)]"
        
        TouchBridgeLogger.info(
            .semantic,
            "Capability Authorized [TAP_CG_FALLBACK] -> Dispatched CG Primary Left Click at (\(String(format: "%.1f, %.1f", point.x, point.y))) [Target: \(role)]"
        )
        TouchBridgeLogger.info(.semantic, "CG primary click pointer-isolation evidence: \(isolationSatisfied ? "PASS" : "FAIL") (cursor delta \(String(format: "%.3f", cursorDelta)) pt).")
        delegate?.semanticRouter(self, didUpdateFeedback: "Tap -> CG Click (\(String(format: "%.0f, %.0f", point.x, point.y)))", invariantPassed: isolationSatisfied)
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
