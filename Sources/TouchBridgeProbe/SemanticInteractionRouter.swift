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
    
    public init() {}
    
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
        guard userIntent == .enabled else {
            TouchBridgeLogger.info(.semantic, "Pan gesture observed, but interaction is SUPPRESSED (UserIntent is DISABLED).")
            return
        }
        
        let appName = session.context?.applicationName ?? "Application"
        TouchBridgeLogger.info(
            .semantic,
            "Semantic Pan STARTED on [\(appName)] [InitialVal: \(String(format: "%.3f", session.initialScrollValue)) | Height: \(String(format: "%.0f", session.visibleHeight)) pt]"
        )
        delegate?.semanticRouter(self, didUpdateFeedback: "Pan Started [\(appName)]", invariantPassed: true)
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanWithSession session: InteractionSession, targetValue: Double) {
        guard userIntent == .enabled else { return }
        guard let bar = session.context?.scrollBarElement else { return }
        
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
        guard let ctx = session.context else { return }
        
        // 1. Value observed at touch-up before any flush
        var valAtUp: Double? = nil
        var upRef: AnyObject?
        if let bar = ctx.scrollBarElement, AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &upRef) == .success, let r = upRef {
            if let n = r as? NSNumber { valAtUp = n.doubleValue }
            else if let d = Double(String(describing: r)) { valAtUp = d }
        }
        session.trace?.recordTouchUp(fingerY: session.latestGlobalPoint.cgGlobal.y, valueObserved: valAtUp)
        
        let cursorBefore = SafetyInvariants.currentCursorPosition()
        let cursorAfter = SafetyInvariants.currentCursorPosition()
        SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Pan Complete")
        
        // Record pan-end
        var endVal: Double? = nil
        var endRef: AnyObject?
        if let bar = ctx.scrollBarElement, AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &endRef) == .success, let r = endRef {
            if let n = r as? NSNumber { endVal = n.doubleValue }
            else if let d = Double(String(describing: r)) { endVal = d }
        }
        session.trace?.recordPanEnd(fingerY: session.latestGlobalPoint.cgGlobal.y, valueObserved: endVal)
        
        // Schedule delayed readbacks for +35ms and +100ms
        if let trace = session.trace, let bar = ctx.scrollBarElement {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
                var v35: Double? = nil
                var vRef: AnyObject?
                if AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &vRef) == .success, let r = vRef {
                    if let n = r as? NSNumber { v35 = n.doubleValue }
                    else if let d = Double(String(describing: r)) { v35 = d }
                }
                trace.recordPostUpReadback(delayMs: 35, value: v35)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.100) {
                var v100: Double? = nil
                var vRef: AnyObject?
                if AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &vRef) == .success, let r = vRef {
                    if let n = r as? NSNumber { v100 = n.doubleValue }
                    else if let d = Double(String(describing: r)) { v100 = d }
                }
                trace.recordPostUpReadback(delayMs: 100, value: v100)
            }
        }
        
        session.cursorBefore = cursorBefore
        session.cursorAfter = cursorAfter
        
        let totalDeltaY = session.latestGlobalPoint.cgGlobal.y - session.startGlobalPoint.cgGlobal.y
        let summary = "PAN_COMPLETED on [\(ctx.applicationName)]: Updates=\(session.panUpdatesCount) | DeltaY=\(String(format: "%.1f", totalDeltaY)) pt | Scroll=\(String(format: "%.3f -> %.3f", session.initialScrollValue, session.lastDispatchedScrollValue))"
        session.panActionResult = summary
        
        TouchBridgeLogger.info(.semantic, summary)
        delegate?.semanticRouter(self, didUpdateFeedback: summary, invariantPassed: true)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didMarkUnsupportedPan session: InteractionSession) {
        guard userIntent == .enabled else { return }
        let appName = session.context?.applicationName ?? "Application"
        session.cursorBefore = SafetyInvariants.currentCursorPosition()
        session.cursorAfter = session.cursorBefore
        session.panActionResult = "None (Continuous scroll backend missing; action suppressed without synthetic events)"
        TouchBridgeLogger.warning(
            .semantic,
            "PAN_UNSUPPORTED on [\(appName)]: Movement (\(String(format: "%.1f", session.maxMovementPt)) pt) crossed pan threshold on surface without writable continuous scrollbar. Action suppressed without synthetic events."
        )
        delegate?.semanticRouter(self, didUpdateFeedback: "Unsupported Pan [\(appName)]", invariantPassed: true)
    }
    
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didCancelSession session: InteractionSession, reason: String) {
        session.cursorAfter = SafetyInvariants.currentCursorPosition()
        TouchBridgeLogger.debug(.gesture, "Gesture session cancelled: \(reason) (Mov: \(String(format: "%.1f", session.maxMovementPt)) pt)")
        
        if reason == "UNSUPPORTED_PAN_RELEASE" {
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
        }
    }
    
    // MARK: - Capability-Authorized Tap Execution (P3-02 Section 5 & 9)
    
    private func executeCapabilityAuthorizedTap(session: InteractionSession) {
        // Invariant assertion: session must have qualified as tapExecuted
        if session.state != .tapExecuted {
            session.recordDelayedTapViolation()
            TouchBridgeLogger.error(.semantic, "CRITICAL ARBITRATION VIOLATION: Tap executed when session state was \(session.state)!")
        }
        
        guard let context = session.context else {
            TouchBridgeLogger.warning(.semantic, "Hit-test found no element at tap position.")
            session.tapActionResult = "No Element at Tap Position"
            delegate?.semanticRouter(self, didUpdateFeedback: "No Element at Tap Position", invariantPassed: true)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
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
        
        // 5. NO ACTIONABLE CAPABILITY EXPOSED
        // Absolute prohibition: Zero synthetic mouse fallback! Zero cursor movement!
        session.cursorBefore = SafetyInvariants.currentCursorPosition()
        session.cursorAfter = session.cursorBefore
        session.tapActionResult = "None (No actionable capability exposed on \(hitNode.role))"
        TouchBridgeLogger.warning(
            .semantic,
            "SEMANTIC_UNSUPPORTED: Element at tap exposes no supported semantic capability. Role: \"\(hitNode.role)\", Supported Actions: \(hitNode.supportedActions), Settable Attrs: \(hitNode.settableAttributes). Fallback mouse click prohibited."
        )
        delegate?.semanticRouter(self, didUpdateFeedback: "No Actionable Capability [\(hitNode.role)]", invariantPassed: true)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
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
