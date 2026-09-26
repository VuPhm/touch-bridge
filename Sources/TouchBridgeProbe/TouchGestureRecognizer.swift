import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Pipeline Layer 5: TouchGestureRecognizer & Tap/Pan Arbitrator (P3-02 Section 1, 2, 3)

public protocol TouchGestureRecognizerDelegate: AnyObject {
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didResolveTapWithSession session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didStartPanWithSession session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanWithSession session: InteractionSession, targetValue: Double)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didCompletePanWithSession session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didMarkUnsupportedPan session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didCancelSession session: InteractionSession, reason: String)
}

public final class TouchGestureRecognizer {
    public weak var delegate: TouchGestureRecognizerDelegate?
    
    private let mapper: CoordinateMapper
    public private(set) var activeSession: InteractionSession? = nil
    public var testContextOverride: AXInteractionContext? = nil
    
    public init(mapper: CoordinateMapper) {
        self.mapper = mapper
    }
    
    public func updateBinding() {
        // Calibration/display binding updated from runtime
    }
    
    public func reset() {
        if let s = activeSession {
            s.cancel(reason: "HOT_PLUG_RESET")
            activeSession = nil
        }
        TouchBridgeLogger.debug(.gesture, "TouchGestureRecognizer reset: active contact session cleared.")
    }
    
    public func processSample(_ sample: TouchSample) {
        guard let (local, global) = mapper.map(sample: sample) else { return }
        processSampleWithPoints(sample: sample, local: local, global: global)
    }
    
    public func processMappedPoint(
        phase: TouchPhase,
        local: DisplayLocalPoint,
        global: GlobalDisplayPoint,
        timestamp: UInt64 = mach_absolute_time(),
        contactID: Int = 0
    ) {
        let sample = TouchSample(
            phase: phase,
            rawX: 2048,
            rawY: 2048,
            normX: 0.5,
            normY: 0.5,
            timestamp: timestamp,
            contactID: contactID
        )
        processSampleWithPoints(sample: sample, local: local, global: global)
    }
    
    public func processSampleWithPoints(sample: TouchSample, local: DisplayLocalPoint, global: GlobalDisplayPoint) {
        switch sample.phase {
        case .down:
            // Single-touch invariant (P3-02 Section 18 & P3-03 Section 3):
            // If already tracking an active contact, ignore secondary contacts safely.
            if activeSession != nil {
                TouchBridgeLogger.debug(.gesture, "Secondary contact ignored (Strict single-touch enforced, ID=\(sample.contactID)).")
                return
            }
            
            // Early Capability Discovery (P3-02 Section 4 & 9):
            // Discover actionable child element & scrollable ancestor ONCE at touch-down.
            var context: AXInteractionContext? = testContextOverride
            if context == nil && AXPermissionManager.shared.isTrusted() {
                let (elemOpt, _, err) = AXSemanticEngine.shared.probeElementAt(globalCG: global.cgGlobal)
                if err == .success, let elem = elemOpt {
                    context = AXCapabilityInspector.shared.discoverContext(element: elem)
                    TouchBridgeLogger.debug(
                        .gesture,
                        "Early Capability Discovery: App='\(context?.applicationName ?? "")', Child='\(context?.hitNode.role ?? "")', ScrollArea='\(context?.scrollCapability.hasScrollArea == true ? "YES" : "NO")', Mech='\(context?.scrollCapability.mechanism ?? "NONE")'"
                    )
                }
            }
            
            let session = InteractionSession(
                startSample: sample,
                localPoint: local,
                globalPoint: global,
                context: context
            )
            self.activeSession = session
            ArbitrationTestWindowController.shared.updateLiveTelemetry(
                state: session.state,
                movement: 0.0,
                duration: 0.0,
                context: context
            )
            
        case .move:
            // Guard active session and enforce contact ID isolation
            guard let session = activeSession, sample.contactID == session.contactID else { return }
            
            let action = session.handleMove(local: local, global: global)
            ArbitrationTestWindowController.shared.updateLiveTelemetry(
                state: session.state,
                movement: session.maxMovementPt,
                duration: Date().timeIntervalSince(session.startTimeDate),
                context: session.context
            )
            switch action {
            case .transitionedToPan:
                delegate?.gestureRecognizer(self, didStartPanWithSession: session)
                // P3-03: Immediately evaluate initial pan update to reduce perceived latency
                let targetValue = session.calculateTargetScrollValue(currentY: global.cgGlobal.y)
                let now = Date()
                if session.shouldDispatchAXWrite(now: now, targetValue: targetValue, currentY: global.cgGlobal.y) {
                    delegate?.gestureRecognizer(self, didUpdatePanWithSession: session, targetValue: targetValue)
                } else {
                    session.recordCoalescedSkip(fingerY: global.cgGlobal.y, targetValue: targetValue)
                }
                
            case .transitionedToUnsupportedPan:
                delegate?.gestureRecognizer(self, didMarkUnsupportedPan: session)
                
            case .panValueUpdated(let targetValue):
                let now = Date()
                if session.shouldDispatchAXWrite(now: now, targetValue: targetValue, currentY: global.cgGlobal.y) {
                    delegate?.gestureRecognizer(self, didUpdatePanWithSession: session, targetValue: targetValue)
                } else {
                    session.recordCoalescedSkip(fingerY: global.cgGlobal.y, targetValue: targetValue)
                }
                
            case .none:
                break
            }
            
        case .up:
            // Guard active session and enforce contact ID isolation
            guard let session = activeSession, sample.contactID == session.contactID else { return }
            self.activeSession = nil
            
            let duration = max(0.0, Date().timeIntervalSince(session.startTimeDate))
            ArbitrationTestWindowController.shared.updateLiveTelemetry(
                state: session.state,
                movement: session.maxMovementPt,
                duration: duration,
                context: session.context
            )
            
            switch session.state {
            case .possibleTap:
                if duration < GestureArbitrationConfig.minTapDurationSec {
                    session.cancel(reason: "CONTACT_TOO_BRIEF")
                    TouchBridgeLogger.debug(.gesture, "Tap rejected: duration too brief (\(String(format: "%.3f", duration))s < \(GestureArbitrationConfig.minTapDurationSec)s)")
                    delegate?.gestureRecognizer(self, didCancelSession: session, reason: "CONTACT_TOO_BRIEF")
                } else if duration > GestureArbitrationConfig.maxTapDurationSec {
                    session.cancel(reason: "HOLD_DURATION_EXCEEDED")
                    TouchBridgeLogger.debug(.gesture, "Tap rejected: hold duration exceeded (\(String(format: "%.3f", duration))s > \(GestureArbitrationConfig.maxTapDurationSec)s)")
                    delegate?.gestureRecognizer(self, didCancelSession: session, reason: "HOLD_DURATION_EXCEEDED")
                } else if session.maxMovementPt > GestureArbitrationConfig.panThresholdPt {
                    session.cancel(reason: "MOVEMENT_TOLERANCE_EXCEEDED")
                    TouchBridgeLogger.debug(.gesture, "Tap rejected: movement exceeded (\(String(format: "%.1f", session.maxMovementPt))pt)")
                    delegate?.gestureRecognizer(self, didCancelSession: session, reason: "MOVEMENT_TOLERANCE_EXCEEDED")
                } else {
                    // Qualified deterministic TAP!
                    session.markTapExecuted()
                    TouchBridgeLogger.debug(
                        .gesture,
                        "Qualified Tap: [Dur: \(String(format: "%.3f", duration))s, Mov: \(String(format: "%.1f", session.maxMovementPt))pt <= \(GestureArbitrationConfig.panThresholdPt)pt]"
                    )
                    delegate?.gestureRecognizer(self, didResolveTapWithSession: session)
                }
                
            case .semanticPan:
                // Complete continuous pan (P3-02 Section 6)
                delegate?.gestureRecognizer(self, didCompletePanWithSession: session)
                
            case .unsupportedPan:
                // Unsupported surface release: DO NOTHING. NEVER convert to tap (P3-02 Section 8).
                TouchBridgeLogger.info(.gesture, "Unsupported pan released: Interaction completed with zero action.")
                delegate?.gestureRecognizer(self, didCancelSession: session, reason: "UNSUPPORTED_PAN_RELEASE")
                
            case .cancelled, .idle, .tapExecuted:
                break
            }
        }
    }
}
