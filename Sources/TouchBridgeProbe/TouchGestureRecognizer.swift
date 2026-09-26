import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Pipeline Layer 5: TouchGestureRecognizer & Tap/Pan Arbitrator (P3-02 Section 1, 2, 3 & P3-03R Phase B)

public protocol TouchGestureRecognizerDelegate: AnyObject {
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didResolveTapWithSession session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didStartPanWithSession session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanWithSession session: InteractionSession, targetValue: Double)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanDeltaWithSession session: InteractionSession, deltaPixels: CGVector)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didCompletePanWithSession session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEnterMomentumWithSession session: InteractionSession, initialVelocity: CGVector)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didInterruptMomentumWithSession session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didMarkUnsupportedPan session: InteractionSession)
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didCancelSession session: InteractionSession, reason: String)
}

public extension TouchGestureRecognizerDelegate {
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanDeltaWithSession session: InteractionSession, deltaPixels: CGVector) {}
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEnterMomentumWithSession session: InteractionSession, initialVelocity: CGVector) {}
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didInterruptMomentumWithSession session: InteractionSession) {}
}

public final class TouchGestureRecognizer {
    public weak var delegate: TouchGestureRecognizerDelegate?
    
    private let mapper: CoordinateMapper
    public private(set) var activeSession: InteractionSession? = nil
    public var testContextOverride: AXInteractionContext? = nil
    public var experimentalOneFingerPanEnabled = GestureArbitrationConfig.experimentalOneFingerPanEnabled
    private var awaitingAllContactsLift = false
    
    // Per-contact tracking for multi-touch (P3-03R Phase B)
    public struct TrackedContactInfo {
        public let contactID: Int
        public var initialPoint: GlobalDisplayPoint
        public var currentPoint: GlobalDisplayPoint
        public var initialLocal: DisplayLocalPoint
        public var currentLocal: DisplayLocalPoint
        public var initialTime: Date
        public var currentTime: Date
    }
    
    public private(set) var activeContacts: [Int: TrackedContactInfo] = [:]
    
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
        activeContacts.removeAll()
        awaitingAllContactsLift = false
        TouchBridgeLogger.debug(.gesture, "TouchGestureRecognizer reset: active contact sessions and trackers cleared.")
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
        let now = Date()
        
        switch sample.phase {
        case .down:
            if awaitingAllContactsLift {
                activeContacts[sample.contactID] = TrackedContactInfo(
                    contactID: sample.contactID,
                    initialPoint: global,
                    currentPoint: global,
                    initialLocal: local,
                    currentLocal: local,
                    initialTime: now,
                    currentTime: now
                )
                return
            }

            // If in kinetic momentum, ANY new touch immediately cancels existing momentum (P3-03R Phase C)
            if let current = activeSession, current.state == .momentum {
                TouchBridgeLogger.info(.gesture, "New touch down during momentum -> Momentum interrupted immediately.")
                delegate?.gestureRecognizer(self, didInterruptMomentumWithSession: current)
                current.markMomentumEnded()
                self.activeSession = nil
                self.activeContacts.removeAll()
            }
            
            // Record contact
            let info = TrackedContactInfo(
                contactID: sample.contactID,
                initialPoint: global,
                currentPoint: global,
                initialLocal: local,
                currentLocal: local,
                initialTime: now,
                currentTime: now
            )
            activeContacts[sample.contactID] = info

            // A two-finger gesture owns its whole contact group. Do not create a new
            // session for another down until every contact from that group has lifted.
            if awaitingAllContactsLift { return }
            
            if activeSession == nil {
                // Primary Contact Down (C1)
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
                session.experimentalOneFingerPanEnabled = experimentalOneFingerPanEnabled
                self.activeSession = session
                ArbitrationTestWindowController.shared.updateLiveTelemetry(
                    state: session.state,
                    movement: 0.0,
                    duration: 0.0,
                    context: context
                )
            } else if let session = activeSession, activeContacts.count == 2 {
                // Secondary Contact Down (C2) -> Transition intentionally to TWO-FINGER DIRECT_PAN (P3-03R Phase B)
                session.secondaryContactID = sample.contactID
                let alreadyPanning = session.state == .directPan
                let points = activeContacts.values.map { $0.currentPoint.cgGlobal }
                let centroid = CGPoint(
                    x: (points[0].x + points[1].x) / 2.0,
                    y: (points[0].y + points[1].y) / 2.0
                )
                session.promoteToTwoFingerPan(centroid: centroid, now: now)
                if !alreadyPanning {
                    delegate?.gestureRecognizer(self, didStartPanWithSession: session)
                }
            } else {
                TouchBridgeLogger.debug(.gesture, "Additional contact tracked (Total: \(activeContacts.count), ID=\(sample.contactID)).")
            }
            
        case .move:
            guard let session = activeSession else { return }
            
            // Update contact point in dictionary
            activeContacts[sample.contactID]?.currentPoint = global
            activeContacts[sample.contactID]?.currentLocal = local
            activeContacts[sample.contactID]?.currentTime = now
            
            let moveLocal: DisplayLocalPoint
            let moveGlobal: GlobalDisplayPoint
            
            if activeContacts.count >= 2 {
                // Multi-touch: track centroid displacement
                let sorted = activeContacts.values.sorted(by: { $0.contactID < $1.contactID })
                let cX = (sorted[0].currentPoint.cgGlobal.x + sorted[1].currentPoint.cgGlobal.x) / 2.0
                let cY = (sorted[0].currentPoint.cgGlobal.y + sorted[1].currentPoint.cgGlobal.y) / 2.0
                let lX = (sorted[0].currentLocal.cgPoint.x + sorted[1].currentLocal.cgPoint.x) / 2.0
                let lY = (sorted[0].currentLocal.cgPoint.y + sorted[1].currentLocal.cgPoint.y) / 2.0
                moveGlobal = GlobalDisplayPoint(cgGlobal: CGPoint(x: cX, y: cY))
                moveLocal = DisplayLocalPoint(cgPoint: CGPoint(x: lX, y: lY))
            } else {
                // Single-touch: track primary contact
                guard sample.contactID == session.contactID else { return }
                moveLocal = local
                moveGlobal = global
            }
            
            let action = session.handleMove(local: moveLocal, global: moveGlobal, now: now)
            ArbitrationTestWindowController.shared.updateLiveTelemetry(
                state: session.state,
                movement: session.maxMovementPt,
                duration: now.timeIntervalSince(session.startTimeDate),
                context: session.context
            )
            
            switch action {
            case .transitionedToPan:
                delegate?.gestureRecognizer(self, didStartPanWithSession: session)
                let targetValue = session.calculateTargetScrollValue(currentY: moveGlobal.cgGlobal.y)
                let frameDy = moveGlobal.cgGlobal.y - session.startGlobalPoint.cgGlobal.y
                delegate?.gestureRecognizer(self, didUpdatePanDeltaWithSession: session, deltaPixels: CGVector(dx: 0, dy: frameDy))
                
                if session.shouldDispatchAXWrite(now: now, targetValue: targetValue, currentY: moveGlobal.cgGlobal.y) {
                    delegate?.gestureRecognizer(self, didUpdatePanWithSession: session, targetValue: targetValue)
                } else {
                    session.recordCoalescedSkip(fingerY: moveGlobal.cgGlobal.y, targetValue: targetValue)
                }
                
            case .transitionedToUnsupportedPan:
                delegate?.gestureRecognizer(self, didMarkUnsupportedPan: session)

            case .cancelledMovement:
                break
                
            case .panValueUpdated(let targetValue, let deltaPixels):
                delegate?.gestureRecognizer(self, didUpdatePanDeltaWithSession: session, deltaPixels: deltaPixels)
                
                if session.shouldDispatchAXWrite(now: now, targetValue: targetValue, currentY: moveGlobal.cgGlobal.y) {
                    delegate?.gestureRecognizer(self, didUpdatePanWithSession: session, targetValue: targetValue)
                } else {
                    session.recordCoalescedSkip(fingerY: moveGlobal.cgGlobal.y, targetValue: targetValue)
                }
                
            case .none:
                break
            }
            
        case .up:
            activeContacts.removeValue(forKey: sample.contactID)
            
            guard let session = activeSession else {
                if activeContacts.isEmpty { awaitingAllContactsLift = false }
                return
            }
            
            if activeContacts.count > 0 {
                if session.contactCount >= 2 {
                    // Losing either finger terminates scrolling. The remaining contact is
                    // quarantined until lift and cannot continue scrolling or become a tap.
                    if session.state == .directPan {
                        delegate?.gestureRecognizer(self, didCompletePanWithSession: session)
                        let velocity = session.filteredVelocity
                        if hypot(velocity.dx, velocity.dy) >= GestureArbitrationConfig.minFlickVelocityPtPerSec {
                            session.markMomentumStarted()
                            delegate?.gestureRecognizer(self, didEnterMomentumWithSession: session, initialVelocity: velocity)
                        } else {
                            session.markIdle()
                            activeSession = nil
                        }
                    } else if session.state == .unsupportedPan {
                        delegate?.gestureRecognizer(self, didCancelSession: session, reason: "UNSUPPORTED_PAN_RELEASE")
                        session.markIdle()
                        activeSession = nil
                    } else {
                        session.markIdle()
                        activeSession = nil
                    }
                    awaitingAllContactsLift = true
                    TouchBridgeLogger.debug(.gesture, "Two-finger gesture terminated when one contact lifted; waiting for all contacts to lift.")
                    return
                }
                TouchBridgeLogger.debug(.gesture, "Contact lifted (Remaining: \(activeContacts.count)). Continuing session.")
                return
            }

            awaitingAllContactsLift = false
            
            // All contacts lifted: evaluate termination or transition to momentum
            let duration = max(0.0, now.timeIntervalSince(session.startTimeDate))
            ArbitrationTestWindowController.shared.updateLiveTelemetry(
                state: session.state,
                movement: session.maxMovementPt,
                duration: duration,
                context: session.context
            )
            
            switch session.state {
            case .possibleTap:
                self.activeSession = nil
                
                if duration < GestureArbitrationConfig.minTapDurationSec {
                    session.cancel(reason: "CONTACT_TOO_BRIEF")
                    TouchBridgeLogger.debug(.gesture, "Tap rejected: duration too brief (\(String(format: "%.3f", duration))s < \(GestureArbitrationConfig.minTapDurationSec)s)")
                    delegate?.gestureRecognizer(self, didCancelSession: session, reason: "CONTACT_TOO_BRIEF")
                } else if session.maxMovementPt > GestureArbitrationConfig.panThresholdPt {
                    session.cancel(reason: "MOVEMENT_TOLERANCE_EXCEEDED")
                    TouchBridgeLogger.debug(.gesture, "Tap rejected: movement exceeded (\(String(format: "%.1f", session.maxMovementPt))pt)")
                    delegate?.gestureRecognizer(self, didCancelSession: session, reason: "MOVEMENT_TOLERANCE_EXCEEDED")
                } else {
                    // Qualified deterministic TAP! (Stationary finger down > 850ms qualifies cleanly, P3-03R Phase B)
                    session.markTapExecuted()
                    TouchBridgeLogger.info(
                        .gesture,
                        "Qualified Tap: [Dur: \(String(format: "%.3f", duration))s, Mov: \(String(format: "%.1f", session.maxMovementPt))pt <= \(GestureArbitrationConfig.panThresholdPt)pt]"
                    )
                    delegate?.gestureRecognizer(self, didResolveTapWithSession: session)
                }
                
            case .directPan:
                // Check release flick velocity for Kinetic Momentum (P3-03R Phase C)
                let releaseVelocity = session.filteredVelocity
                let speed = hypot(releaseVelocity.dx, releaseVelocity.dy)
                
                if speed >= GestureArbitrationConfig.minFlickVelocityPtPerSec {
                    // Enter kinetic momentum state
                    session.markMomentumStarted()
                    TouchBridgeLogger.info(
                        .gesture,
                        "Pan released with flick velocity: \(String(format: "%.1f", speed)) pt/s -> Entering KINETIC MOMENTUM"
                    )
                    delegate?.gestureRecognizer(self, didEnterMomentumWithSession: session, initialVelocity: releaseVelocity)
                } else {
                    // Clean stop
                    delegate?.gestureRecognizer(self, didCompletePanWithSession: session)
                    self.activeSession = nil
                }
                
            case .unsupportedPan:
                TouchBridgeLogger.info(.gesture, "Unsupported pan released: Interaction completed with zero action.")
                delegate?.gestureRecognizer(self, didCancelSession: session, reason: "UNSUPPORTED_PAN_RELEASE")
                self.activeSession = nil
                
            case .momentum:
                // Keep the released gesture active so the next fresh contact can
                // synchronously interrupt its momentum.
                break

            case .cancelled(let reason):
                if reason == "MOVEMENT_TOLERANCE_EXCEEDED" || reason == "CONTACT_TOO_BRIEF" {
                    delegate?.gestureRecognizer(self, didCancelSession: session, reason: reason)
                }
                self.activeSession = nil

            case .idle, .tapExecuted:
                self.activeSession = nil
            }
        }
    }
}
