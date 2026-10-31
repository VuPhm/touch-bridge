import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Pipeline Layer 5: TouchGestureRecognizer & Tap/Pan/Drag Arbitrator (P3-02, P3-03R & Direct-Touch Suite)

typealias ReleaseMomentumDecisionScheduler = (@escaping () -> Void) -> Void
typealias LongPressTimerScheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)

public protocol TouchGestureRecognizerDelegate: AnyObject {
    func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEmit intent: InteractionIntent)
}

public final class TouchGestureRecognizer {
    public weak var delegate: TouchGestureRecognizerDelegate?
    
    private let mapper: CoordinateMapper
    public private(set) var activeSession: InteractionSession? = nil
    public var testContextOverride: AXInteractionContext? = nil
    public var experimentalOneFingerPanEnabled = GestureArbitrationConfig.experimentalOneFingerPanEnabled
    public var directTouchModeEnabled: Bool = false
    /// In unit tests where `directTouchModeEnabled` is enabled without live screen windows, set false to skip live CGWindow/AX hit-testing when `testContextOverride == nil`.
    public var allowLiveHitDiscoveryInDirectMode: Bool = true

    private var awaitingAllContactsLift = false
    private var firstContactLiftAt: Date?
    private var releaseMomentumDecisionScheduler: ReleaseMomentumDecisionScheduler = { decision in decision() }
    private var longPressScheduler: LongPressTimerScheduler = { interval, action in
        let timer = Timer(timeInterval: interval, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
    private var cancelLongPressTimer: (() -> Void)? = nil
    private let tapSequenceRecognizer = TapSequenceRecognizer()

    // Two-finger pinch & rotate tracking state
    private var initialTwoFingerSpan: Double = 0
    private var lastTwoFingerSpan: Double = 0
    private var initialTwoFingerAngleRad: Double = 0
    private var lastTwoFingerAngleRad: Double = 0
    private var isMagnifyGestureActive = false
    private var isRotateGestureActive = false
    
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
        tapSequenceRecognizer.onFirstTap = { [weak self] session in self?.emit(.tap(session)) }
        tapSequenceRecognizer.onPairedSecondTap = { [weak self] session in self?.emit(.pairedSecondTap(session)) }
    }
    
    public func updateBinding() {
        // Calibration/display binding updated from runtime
    }

    func setReleaseMomentumDecisionSchedulerForTesting(_ scheduler: @escaping ReleaseMomentumDecisionScheduler) {
        releaseMomentumDecisionScheduler = scheduler
    }

    func setLongPressSchedulerForTesting(_ scheduler: @escaping LongPressTimerScheduler) {
        cancelPendingLongPressTimer()
        longPressScheduler = scheduler
    }

    func setTapSequenceSchedulerForTesting(
        doubleTapInterval: TimeInterval,
        scheduler: @escaping TapSequenceRecognizer.Scheduler
    ) {
        tapSequenceRecognizer.configureForTesting(doubleTapInterval: doubleTapInterval, scheduler: scheduler)
    }

    var hasTapPairingCandidateForTesting: Bool { tapSequenceRecognizer.hasPairingCandidate }

    private func cancelPendingLongPressTimer() {
        cancelLongPressTimer?()
        cancelLongPressTimer = nil
    }

    private func resetTwoFingerPinchRotateIfNeeded(for session: InteractionSession?) {
        if isMagnifyGestureActive, let s = session {
            emit(.magnifyUpdated(s, phase: 4, magnification: 0.0))
        }
        if isRotateGestureActive, let s = session {
            emit(.rotateUpdated(s, phase: 4, rotationDegrees: 0.0))
        }
        isMagnifyGestureActive = false
        isRotateGestureActive = false
        initialTwoFingerSpan = 0
        lastTwoFingerSpan = 0
        initialTwoFingerAngleRad = 0
        lastTwoFingerAngleRad = 0
    }
    
    public func reset() {
        tapSequenceRecognizer.reset()
        cancelPendingLongPressTimer()
        if let s = activeSession {
            resetTwoFingerPinchRotateIfNeeded(for: s)
            let wasDragging = (s.state == .directDrag)
            s.cancel(reason: "HOT_PLUG_RESET")
            if wasDragging {
                emit(.cancelled(s, reason: "HOT_PLUG_RESET"))
            }
            activeSession = nil
        }
        activeContacts.removeAll()
        awaitingAllContactsLift = false
        firstContactLiftAt = nil
        TouchBridgeLogger.debug(.gesture, "TouchGestureRecognizer reset: active contact sessions and trackers cleared.")
    }

    public func interruptPendingTapSequence() {
        tapSequenceRecognizer.reset()
        cancelPendingLongPressTimer()
    }
    
    public func processSample(_ sample: TouchSample) {
        guard let (local, global) = mapper.map(sample: sample) else { return }
        processSampleWithPoints(sample: sample, local: local, global: global)
    }
    
    public func processMappedPoint(
        phase: TouchPhase,
        local: DisplayLocalPoint,
        global: GlobalDisplayPoint,
        timestamp: UInt64 = 0,
        contactID: Int = 0,
        now: Date = Date()
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
        processSampleWithPoints(sample: sample, local: local, global: global, now: now)
    }

    private func discoverLiveContextIfNeeded(at globalPoint: CGPoint) -> AXInteractionContext? {
        if let override = testContextOverride { return override }
        guard directTouchModeEnabled, allowLiveHitDiscoveryInDirectMode else { return nil }

        let winHit = AXCapabilityInspector.shared.resolveTopmostWindow(at: globalPoint)
        
        // Fast-path: Direct WindowServer controls (Title bar drag or window edge/corner resize) skip deep AX IPC
        if let winHit, winHit.zone != .contentArea {
            let sysElem = AXUIElementCreateSystemWide()
            let cap = AXScrollCapability(
                hasScrollArea: false, scrollAreaRole: nil, verticalScrollBarAvailable: false,
                isVerticalValueSettable: false, verticalValue: nil, verticalMin: nil, verticalMax: nil,
                verticalActions: [], scrollAreaActions: [], mechanism: "UNSUPPORTED"
            )
            let node = AXNodeCapability(
                role: "AXWindow", subrole: nil, title: winHit.windowTitle, descriptionText: nil,
                value: nil, minValue: nil, maxValue: nil, valueIncrement: nil, isEnabled: true,
                isFocused: true, isSelected: false, position: [Double(winHit.bounds.origin.x), Double(winHit.bounds.origin.y)],
                size: [Double(winHit.bounds.size.width), Double(winHit.bounds.size.height)], parentRole: "AXApplication",
                supportedActions: [], attributeNames: [], parameterizedAttributeNames: [], settableAttributes: []
            )
            return AXInteractionContext(
                pid: winHit.ownerPID, applicationName: winHit.ownerName, hitElement: sysElem,
                hitNode: node, ancestorChain: [], scrollAreaElement: nil, scrollBarElement: nil,
                scrollCapability: cap, scrollAreaHeight: Double(max(100.0, winHit.bounds.height)), windowHitInfo: winHit
            )
        }

        if AXPermissionManager.shared.isTrusted() {
            let (elem, _, err) = AXSemanticEngine.shared.probeElementAt(globalCG: globalPoint)
            if err == .success, let elem {
                var ctx = AXCapabilityInspector.shared.discoverContext(element: elem, maxAncestors: 4)
                ctx.windowHitInfo = winHit
                return ctx
            }
        }

        if let winHit {
            let sysElem = AXUIElementCreateSystemWide()
            let cap = AXScrollCapability(
                hasScrollArea: false,
                scrollAreaRole: nil,
                verticalScrollBarAvailable: false,
                isVerticalValueSettable: false,
                verticalValue: nil,
                verticalMin: nil,
                verticalMax: nil,
                verticalActions: [],
                scrollAreaActions: [],
                mechanism: "UNSUPPORTED"
            )
            let node = AXNodeCapability(
                role: "AXWindow",
                subrole: nil,
                title: winHit.windowTitle,
                descriptionText: nil,
                value: nil,
                minValue: nil,
                maxValue: nil,
                valueIncrement: nil,
                isEnabled: true,
                isFocused: true,
                isSelected: false,
                position: [Double(winHit.bounds.origin.x), Double(winHit.bounds.origin.y)],
                size: [Double(winHit.bounds.size.width), Double(winHit.bounds.size.height)],
                parentRole: "AXApplication",
                supportedActions: [],
                attributeNames: [],
                parameterizedAttributeNames: [],
                settableAttributes: []
            )
            return AXInteractionContext(
                pid: winHit.ownerPID,
                applicationName: winHit.ownerName,
                hitElement: sysElem,
                hitNode: node,
                ancestorChain: [],
                scrollAreaElement: nil,
                scrollBarElement: nil,
                scrollCapability: cap,
                scrollAreaHeight: Double(max(100.0, winHit.bounds.height)),
                windowHitInfo: winHit
            )
        }
        return nil
    }
    
    public func processSampleWithPoints(sample: TouchSample, local: DisplayLocalPoint, global: GlobalDisplayPoint, now: Date = Date()) {
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

            // Natural momentum completion is reported asynchronously by the
            // router. Retire any settled session before starting a fresh contact.
            if activeContacts.isEmpty, activeSession?.state == .idle {
                activeSession = nil
            }

            var didInterruptActiveMomentum = false
            // If in kinetic momentum, ANY new touch immediately cancels existing momentum (P3-03R Phase C)
            if let current = activeSession, current.state == .releasePending || current.state == .momentum {
                let wasCoastingMomentum = (current.state == .momentum)
                let interruptedState = current.state.description
                TouchBridgeLogger.info(.gesture, "P3-06R2 retouch: interrupting prior \(interruptedState) release lease before new contact.")
                emit(.momentumInterrupted(current))
                current.markMomentumEnded()
                self.activeSession = nil
                self.activeContacts.removeAll()
                firstContactLiftAt = nil
                didInterruptActiveMomentum = wasCoastingMomentum
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
                if !(directTouchModeEnabled && didInterruptActiveMomentum) {
                    tapSequenceRecognizer.beginCandidate(at: global.cgGlobal, now: now)
                } else {
                    tapSequenceRecognizer.cancelCandidate()
                }
                // Primary Contact Down (C1)
                let context = discoverLiveContextIfNeeded(at: global.cgGlobal)
                
                let session = InteractionSession(
                    startSample: sample,
                    localPoint: local,
                    globalPoint: global,
                    context: context,
                    now: now
                )
                session.experimentalOneFingerPanEnabled = experimentalOneFingerPanEnabled
                session.directTouchModeEnabled = directTouchModeEnabled
                session.interruptedActiveMomentum = didInterruptActiveMomentum
                self.activeSession = session
                firstContactLiftAt = nil

                if directTouchModeEnabled && !didInterruptActiveMomentum {
                    cancelPendingLongPressTimer()
                    cancelLongPressTimer = longPressScheduler(GestureArbitrationConfig.longPressContextMenuDurationSec) { [weak self, weak session] in
                        guard let self,
                              let session,
                              self.activeSession === session,
                              self.activeContacts.count == 1,
                              session.state == .possibleTap,
                              session.maxMovementPt <= GestureArbitrationConfig.longPressSlopPt else {
                            return
                        }
                        self.cancelLongPressTimer = nil
                        self.tapSequenceRecognizer.cancelCandidate()
                        session.commitLongPressContextMenu()
                        TouchBridgeLogger.info(.gesture, "Stationary long-press qualified -> emitting CONTEXT_MENU at (\(Int(session.startGlobalPoint.cgGlobal.x)), \(Int(session.startGlobalPoint.cgGlobal.y)))")
                        self.emit(.contextMenu(session))
                    }
                }

                ArbitrationTestWindowController.shared.updateLiveTelemetry(
                    state: session.state,
                    movement: 0.0,
                    duration: 0.0,
                    context: context
                )
            } else if let session = activeSession, activeContacts.count == 2 {
                tapSequenceRecognizer.cancelCandidate()
                cancelPendingLongPressTimer()
                if session.state == .directDrag {
                    emit(.dragEnded(session, endPoint: session.latestGlobalPoint.cgGlobal))
                }
                // Secondary Contact Down (C2) -> Transition intentionally to TWO-FINGER DIRECT_PAN (P3-03R Phase B)
                session.secondaryContactID = sample.contactID
                let alreadyPanning = session.state == .directPan
                let sorted = activeContacts.values.sorted(by: { $0.contactID < $1.contactID })
                let p0 = sorted[0].currentPoint.cgGlobal
                let p1 = sorted[1].currentPoint.cgGlobal
                let centroid = CGPoint(
                    x: (p0.x + p1.x) / 2.0,
                    y: (p0.y + p1.y) / 2.0
                )
                let span = hypot(p1.x - p0.x, p1.y - p0.y)
                let angle = atan2(p1.y - p0.y, p1.x - p0.x)
                initialTwoFingerSpan = span
                lastTwoFingerSpan = span
                initialTwoFingerAngleRad = angle
                lastTwoFingerAngleRad = angle
                isMagnifyGestureActive = false
                isRotateGestureActive = false

                session.promoteToTwoFingerPan(centroid: centroid, now: now, timestampMach: sample.timestamp)
                if !alreadyPanning, session.state == .directPan {
                    emit(.directPanStarted(session))
                }
            } else {
                TouchBridgeLogger.debug(.gesture, "Additional contact tracked (Total: \(activeContacts.count), ID=\(sample.contactID)).")
            }
            
        case .move:
            if awaitingAllContactsLift { return }
            guard let session = activeSession else { return }
            
            // Update contact point in dictionary
            activeContacts[sample.contactID]?.currentPoint = global
            activeContacts[sample.contactID]?.currentLocal = local
            activeContacts[sample.contactID]?.currentTime = now
            
            let moveLocal: DisplayLocalPoint
            let moveGlobal: GlobalDisplayPoint
            
            if activeContacts.count >= 2 {
                // Multi-touch: track centroid displacement + pinch/rotate geometry
                let sorted = activeContacts.values.sorted(by: { $0.contactID < $1.contactID })
                let p0 = sorted[0].currentPoint.cgGlobal
                let p1 = sorted[1].currentPoint.cgGlobal
                let cX = (p0.x + p1.x) / 2.0
                let cY = (p0.y + p1.y) / 2.0
                let lX = (sorted[0].currentLocal.cgPoint.x + sorted[1].currentLocal.cgPoint.x) / 2.0
                let lY = (sorted[0].currentLocal.cgPoint.y + sorted[1].currentLocal.cgPoint.y) / 2.0
                moveGlobal = GlobalDisplayPoint(cgGlobal: CGPoint(x: cX, y: cY))
                moveLocal = DisplayLocalPoint(cgPoint: CGPoint(x: lX, y: lY))

                if directTouchModeEnabled && initialTwoFingerSpan > 20.0 {
                    let currentSpan = hypot(p1.x - p0.x, p1.y - p0.y)
                    let currentAngle = atan2(p1.y - p0.y, p1.x - p0.x)
                    let totalSpanDelta = abs(currentSpan - initialTwoFingerSpan)
                    let stepSpanDelta = currentSpan - lastTwoFingerSpan

                    var totalAngleDelta = currentAngle - initialTwoFingerAngleRad
                    while totalAngleDelta > .pi { totalAngleDelta -= 2.0 * .pi }
                    while totalAngleDelta < -.pi { totalAngleDelta += 2.0 * .pi }
                    let totalAngleDeg = totalAngleDelta * 180.0 / .pi

                    var stepAngleDelta = currentAngle - lastTwoFingerAngleRad
                    while stepAngleDelta > .pi { stepAngleDelta -= 2.0 * .pi }
                    while stepAngleDelta < -.pi { stepAngleDelta += 2.0 * .pi }
                    let stepAngleDeg = stepAngleDelta * 180.0 / .pi

                    if !isMagnifyGestureActive && totalSpanDelta >= GestureArbitrationConfig.pinchActivationSpanDeltaPt {
                        isMagnifyGestureActive = true
                        emit(.magnifyUpdated(session, phase: 1, magnification: 0.0))
                    }
                    if isMagnifyGestureActive && abs(stepSpanDelta) >= 0.5 {
                        let mag = stepSpanDelta / max(120.0, lastTwoFingerSpan)
                        emit(.magnifyUpdated(session, phase: 2, magnification: mag))
                        lastTwoFingerSpan = currentSpan
                    }

                    if !isRotateGestureActive && initialTwoFingerSpan >= 60.0 && abs(totalAngleDeg) >= GestureArbitrationConfig.rotateActivationAngleDeg {
                        isRotateGestureActive = true
                        emit(.rotateUpdated(session, phase: 1, rotationDegrees: 0.0))
                    }
                    if isRotateGestureActive && abs(stepAngleDeg) >= 0.25 {
                        emit(.rotateUpdated(session, phase: 2, rotationDegrees: stepAngleDeg))
                        lastTwoFingerAngleRad = currentAngle
                    }
                }
            } else {
                // Single-touch: track primary contact
                guard sample.contactID == session.contactID else { return }
                moveLocal = local
                moveGlobal = global
            }
            
            let action = session.handleMove(local: moveLocal, global: moveGlobal, now: now, timestampMach: sample.timestamp)
            if session.maxMovementPt > GestureArbitrationConfig.longPressSlopPt {
                cancelPendingLongPressTimer()
            }
            ArbitrationTestWindowController.shared.updateLiveTelemetry(
                state: session.state,
                movement: session.maxMovementPt,
                duration: now.timeIntervalSince(session.startTimeDate),
                context: session.context
            )
            
            switch action {
            case .transitionedToPan:
                tapSequenceRecognizer.cancelCandidate()
                cancelPendingLongPressTimer()
                emit(.directPanStarted(session))
                let targetValue = session.calculateTargetScrollValue(currentY: moveGlobal.cgGlobal.y)
                let frameDx = moveGlobal.cgGlobal.x - session.startGlobalPoint.cgGlobal.x
                let frameDy = moveGlobal.cgGlobal.y - session.startGlobalPoint.cgGlobal.y
                emit(.directPanUpdated(session, deltaPixels: CGVector(dx: frameDx, dy: frameDy)))
                
                if session.shouldDispatchAXWrite(now: now, targetValue: targetValue, currentY: moveGlobal.cgGlobal.y) {
                    emit(.directPanAXValueUpdated(session, targetValue: targetValue))
                } else {
                    session.recordCoalescedSkip(fingerY: moveGlobal.cgGlobal.y, targetValue: targetValue)
                }

            case .transitionedToDrag(let deltaPixels):
                tapSequenceRecognizer.cancelCandidate()
                cancelPendingLongPressTimer()
                emit(.dragStarted(session))
                emit(.dragUpdated(session, currentPoint: moveGlobal.cgGlobal, deltaPixels: deltaPixels))

            case .dragUpdated(let currentPoint, let deltaPixels):
                emit(.dragUpdated(session, currentPoint: currentPoint, deltaPixels: deltaPixels))
                
            case .transitionedToUnsupportedPan:
                tapSequenceRecognizer.cancelCandidate()
                cancelPendingLongPressTimer()
                emit(.unsupportedPan(session))

            case .cancelledMovement:
                tapSequenceRecognizer.cancelCandidate()
                cancelPendingLongPressTimer()
                break
                
            case .panValueUpdated(let targetValue, let deltaPixels):
                if !isMagnifyGestureActive && !isRotateGestureActive {
                    emit(.directPanUpdated(session, deltaPixels: deltaPixels))
                    
                    if session.shouldDispatchAXWrite(now: now, targetValue: targetValue, currentY: moveGlobal.cgGlobal.y) {
                        emit(.directPanAXValueUpdated(session, targetValue: targetValue))
                    } else {
                        session.recordCoalescedSkip(fingerY: moveGlobal.cgGlobal.y, targetValue: targetValue)
                    }
                }
                
            case .none:
                break
            }
            
        case .up:
            activeContacts.removeValue(forKey: sample.contactID)
            cancelPendingLongPressTimer()
            
            guard let session = activeSession else {
                if activeContacts.isEmpty { awaitingAllContactsLift = false }
                return
            }
            
            if activeContacts.count > 0 {
                if session.contactCount >= 2 {
                    tapSequenceRecognizer.cancelCandidate()
                    resetTwoFingerPinchRotateIfNeeded(for: session)
                    // Losing either finger terminates scrolling. The remaining contact is
                    // quarantined until lift and cannot continue scrolling or become a tap.
                    // Keep the backend/session open until the last contact lifts so release
                    // momentum starts at the actual end of the two-finger gesture.
                    if session.state == .unsupportedPan {
                        emit(.cancelled(session, reason: "UNSUPPORTED_PAN_RELEASE"))
                        session.markIdle()
                        activeSession = nil
                    } else if session.state != .directPan {
                        session.markIdle()
                        activeSession = nil
                    }
                    awaitingAllContactsLift = true
                    firstContactLiftAt = now
                    TouchBridgeLogger.info(
                        .gesture,
                        "P3-06R2 first_contact_lift: session=\(session.id) remaining=\(activeContacts.count) at=\(String(format: "%.3f", now.timeIntervalSince1970)) state=\(session.state.description)"
                    )
                    TouchBridgeLogger.debug(.gesture, "Two-finger gesture terminated when one contact lifted; waiting for all contacts to lift.")
                    return
                }
                TouchBridgeLogger.debug(.gesture, "Contact lifted (Remaining: \(activeContacts.count)). Continuing session.")
                return
            }

            awaitingAllContactsLift = false
            resetTwoFingerPinchRotateIfNeeded(for: session)
            
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
                
                if session.directTouchModeEnabled && session.interruptedActiveMomentum {
                    tapSequenceRecognizer.cancelCandidate()
                    session.cancel(reason: "MOMENTUM_STOP_ABSORBED")
                    TouchBridgeLogger.info(.gesture, "Touch during momentum absorbed as stop-scroll without firing click.")
                } else if duration < GestureArbitrationConfig.minTapDurationSec {
                    tapSequenceRecognizer.cancelCandidate()
                    session.cancel(reason: "CONTACT_TOO_BRIEF")
                    TouchBridgeLogger.debug(.gesture, "Tap rejected: duration too brief (\(String(format: "%.3f", duration))s < \(GestureArbitrationConfig.minTapDurationSec)s)")
                    emit(.cancelled(session, reason: "CONTACT_TOO_BRIEF"))
                } else if session.maxMovementPt > GestureArbitrationConfig.panThresholdPt {
                    tapSequenceRecognizer.cancelCandidate()
                    session.cancel(reason: "MOVEMENT_TOLERANCE_EXCEEDED")
                    TouchBridgeLogger.debug(.gesture, "Tap rejected: movement exceeded (\(String(format: "%.1f", session.maxMovementPt))pt)")
                    emit(.cancelledOneFingerMovement(session, reason: "MOVEMENT_TOLERANCE_EXCEEDED"))
                } else {
                    // Qualified deterministic TAP!
                    session.markTapExecuted()
                    TouchBridgeLogger.info(
                        .gesture,
                        "Qualified Tap: [Dur: \(String(format: "%.3f", duration))s, Mov: \(String(format: "%.1f", session.maxMovementPt))pt <= \(GestureArbitrationConfig.panThresholdPt)pt]"
                    )
                    tapSequenceRecognizer.completeCandidate(session, at: session.startGlobalPoint.cgGlobal, now: now)
                }

            case .directDrag:
                self.activeSession = nil
                session.markIdle()
                emit(.dragEnded(session, endPoint: global.cgGlobal))
                firstContactLiftAt = nil

            case .longPressCommitted:
                self.activeSession = nil
                session.markIdle()
                firstContactLiftAt = nil
                
            case .directPan:
                let releaseAt = now
                let firstLiftText = firstContactLiftAt.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "none"
                let latestMovementSample = session.latestMovementVelocitySnapshot(asOf: releaseAt)
                let releaseSample = session.movementVelocitySnapshot(asOf: releaseAt)
                session.markReleasePending(at: releaseAt)
                TouchBridgeLogger.info(
                    .gesture,
                    "P3-06R2 final_contact_lift: session=\(session.id) firstLiftAt=\(firstLiftText) finalLiftAt=\(String(format: "%.3f", releaseAt.timeIntervalSince1970)) lastMoveAt=\(latestMovementSample.map { String(format: "%.3f", $0.sampledAt.timeIntervalSince1970) } ?? "none") sampleAgeMs=\(latestMovementSample.map { String(format: "%.1f", $0.ageSec * 1000) } ?? "n/a") retainedVelocity=\(latestMovementSample.map { String(format: "%.1f,%.1f", $0.velocity.dx, $0.velocity.dy) } ?? "none") velocityUsable=\(releaseSample != nil)"
                )
                emit(.directPanEnded(session))

                // Production resolves synchronously. If event delivery is ever queued,
                // the router's release lease keeps the selected backend alive briefly.
                releaseMomentumDecisionScheduler { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.resolvePendingReleaseMomentum(session, releaseAt: releaseAt, sample: releaseSample)
                }
                firstContactLiftAt = nil
                
            case .unsupportedPan:
                tapSequenceRecognizer.cancelCandidate()
                TouchBridgeLogger.info(.gesture, "Unsupported pan released: Interaction completed with zero action.")
                emit(.cancelled(session, reason: "UNSUPPORTED_PAN_RELEASE"))
                self.activeSession = nil
                
            case .momentum:
                // Keep the released gesture active so the next fresh contact can
                // synchronously interrupt its momentum.
                break

            case .releasePending:
                // An extra/stale up after the final release cannot end the bounded lease.
                break

            case .cancelled(let reason):
                tapSequenceRecognizer.cancelCandidate()
                if reason == "MOVEMENT_TOLERANCE_EXCEEDED" || reason == "CONTACT_TOO_BRIEF" {
                    emit(.cancelledOneFingerMovement(session, reason: reason))
                }
                self.activeSession = nil

            case .idle, .tapExecuted:
                self.activeSession = nil
            }
        }
    }

    func momentumDidEnd(_ session: InteractionSession) {
        releaseLifecycleDidEnd(session)
    }

    func releaseLifecycleDidEnd(_ session: InteractionSession) {
        guard activeSession === session else { return }
        if activeContacts.isEmpty {
            activeSession = nil
        }
    }

    private func resolvePendingReleaseMomentum(_ session: InteractionSession, releaseAt: Date, sample: MovementVelocitySnapshot?) {
        guard activeSession === session,
              session.releaseDecisionIsOpen(at: Date()) else {
            TouchBridgeLogger.debug(.gesture, "P3-06R2 delayed release decision ignored: session ended or settle lease expired.")
            return
        }

        guard let sample else {
            let hasSample = session.lastMovementVelocitySampleAt != nil
            let reason = hasSample ? "stale_or_invalid_sample" : "no_movement_sample"
            TouchBridgeLogger.info(.gesture, "P3-06R2 release decision: momentum_not_scheduled reason=\(reason) threshold=\(GestureArbitrationConfig.minFlickVelocityPtPerSec)pt/s; holding backend through \(GestureArbitrationConfig.releaseSettleWindowSec)s settle window.")
            return
        }

        let qualifies = GestureArbitrationConfig.qualifiesForReleaseMomentum(sample.velocity)
        TouchBridgeLogger.info(
            .gesture,
            "P3-06R2 release decision: sampleAt=\(String(format: "%.3f", sample.sampledAt.timeIntervalSince1970)) ageMs=\(String(format: "%.1f", sample.ageSec * 1000)) velocity=\(String(format: "%.1f,%.1f", sample.velocity.dx, sample.velocity.dy)) speed=\(String(format: "%.1f", sample.speed)) threshold=\(GestureArbitrationConfig.minFlickVelocityPtPerSec) qualifies=\(qualifies) releaseAgeMs=\(String(format: "%.1f", Date().timeIntervalSince(releaseAt) * 1000))"
        )
        guard qualifies else {
            TouchBridgeLogger.info(.gesture, "P3-06R2 release decision: momentum_not_scheduled reason=below_threshold; compatibility transaction remains leased until settle expiry.")
            return
        }

        session.markMomentumStarted()
        TouchBridgeLogger.info(.gesture, "P3-06R2 momentum_start emitted from releasePending session=\(session.id).")
        emit(.momentumStarted(session, initialVelocity: sample.velocity))
    }

    private func emit(_ intent: InteractionIntent) {
        delegate?.gestureRecognizer(self, didEmit: intent)
    }
}
