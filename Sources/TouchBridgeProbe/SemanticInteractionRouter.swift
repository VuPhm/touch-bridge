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

typealias MomentumTickScheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)
typealias ReleaseLeaseScheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)

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
    public var scrollCoordinator = HybridScrollDeliveryCoordinator.shared
    public private(set) var activeScrollBackend: ScrollDeliveryBackend? = nil
    public var preferContinuousCGScroll: Bool = false {
        didSet {
            scrollCoordinator.forceFallback = preferContinuousCGScroll
        }
    }

    /// Compatibility escape hatch. CG click events move the real system cursor on some hosts.
    public var allowCursorMovingCGFallback: Bool = false
    /// Unsafe experimental cursor restoration prototype; never enabled by the product path.
    public var enableCGCursorRestoreExperiment: Bool = false

    // Kinetic momentum state (P3-03R Phase C & P3-06 Tuning)
    private var cancelMomentumTimer: (() -> Void)? = nil
    private var momentumTickScheduler: MomentumTickScheduler = { interval, tick in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
    private var releaseLeaseScheduler: ReleaseLeaseScheduler = { interval, action in
        let timer = Timer(timeInterval: interval, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
    private var cancelReleaseSettle: (() -> Void)?
    private var cancelReleaseCeiling: (() -> Void)?
    private weak var releaseLeaseRecognizer: TouchGestureRecognizer?
    private var releaseLeaseSession: InteractionSession?
    private var releaseLeaseStartedAt: Date?
    private var activeMomentumSession: InteractionSession? = nil
    private weak var momentumRecognizer: TouchGestureRecognizer?
    private var currentMomentumVelocity: CGVector = .zero
    private var momentumElapsedSec: Double = 0
    private var momentumAccumulatedDistancePt: Double = 0
    private var momentumFrameCount: Int = 0
    private var momentumTimerTickCount: Int = 0
    private var fingerDownSmoothingTimer: Timer? = nil
    private var fingerDownSmoothingTail: FingerDownSmoothingTail? = nil
    private var lastDirectPanVelocityY: Double = 0
    private var lastDirectPanVelocity: CGVector = .zero
    private var lastDirectPanVelocityAt: Date?
    private var loggedDirectScrollFields = false
    private var loggedMomentumFields = false
    private var usesCustomMomentumSchedulerForTesting = false
    private var lastMomentumTickUptime: TimeInterval = 0
    public var showKeyboardPillOnTextTap: Bool = false

    public init() {}

    /// Cleanly aborts any active scroll, momentum, release lease, or held mouse drag.
    public func resetGestureState() {
        KeyboardPopoverController.shared.dismiss()
        haltMomentum()
        cancelReleaseLeaseTimers()
        haltFingerDownSmoothing()
        if let active = activeMomentumSession {
            activeScrollBackend?.cancel(session: active, reason: "ROUTER_RESET")
        }
        activeScrollBackend = nil
        activeMomentumSession = nil
        momentumRecognizer = nil
        releaseLeaseSession = nil
        releaseLeaseRecognizer = nil
        transientPointerBackend.cancelDrag()
    }

    // Deterministic runtime validation can advance momentum frames without wall-clock sleeps.
    func setMomentumTickSchedulerForTesting(_ scheduler: @escaping MomentumTickScheduler) {
        stopMomentumTimer()
        usesCustomMomentumSchedulerForTesting = true
        momentumTickScheduler = scheduler
    }

    func setReleaseLeaseSchedulerForTesting(_ scheduler: @escaping ReleaseLeaseScheduler) {
        cancelReleaseLeaseTimers()
        releaseLeaseScheduler = scheduler
    }

    /// Delivery policy boundary between recognized intent and OS mechanisms.
    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEmit intent: InteractionIntent) {
        switch intent {
        case .tap(let session):
            gestureRecognizer(recognizer, didResolveTapWithSession: session)
        case .pairedSecondTap(let session):
            gestureRecognizer(recognizer, didResolveDoubleTapWithSession: session)
        case .tripleTap(let session):
            gestureRecognizer(recognizer, didResolveTripleTapWithSession: session)
        case .contextMenu(let session):
            gestureRecognizer(recognizer, didResolveContextMenuWithSession: session)
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
        case .dragStarted(let session):
            gestureRecognizer(recognizer, didStartDragWithSession: session)
        case .dragUpdated(let session, let currentPoint, _):
            gestureRecognizer(recognizer, didUpdateDragWithSession: session, currentPoint: currentPoint)
        case .dragEnded(let session, let endPoint):
            gestureRecognizer(recognizer, didEndDragWithSession: session, endPoint: endPoint)
        case .wordSelectionDragStarted(let session):
            gestureRecognizer(recognizer, didStartWordSelectionDragWithSession: session)
        case .wordSelectionDragUpdated(let session, let currentPoint):
            gestureRecognizer(recognizer, didUpdateWordSelectionDragWithSession: session, currentPoint: currentPoint)
        case .wordSelectionDragEnded(let session, let endPoint):
            gestureRecognizer(recognizer, didEndWordSelectionDragWithSession: session, endPoint: endPoint)
        case .magnifyUpdated(let session, let phase, let magnification):
            gestureRecognizer(recognizer, didUpdateMagnifyWithSession: session, phase: phase, magnification: magnification)
        case .rotateUpdated(let session, let phase, let rotationDegrees):
            gestureRecognizer(recognizer, didUpdateRotateWithSession: session, phase: phase, rotationDegrees: rotationDegrees)
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
        resetGestureState()
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

    private func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didResolveDoubleTapWithSession session: InteractionSession) {
        session.interactionIntent = "PAIRED_SECOND_TAP"
        session.deliveryPolicy = tapBackendMode.diagnosticName
        session.deliveryBackend = InteractionDeliveryPolicy.tapMechanism(mode: tapBackendMode).rawValue
        session.axEnrichmentStatus = "NOT_REQUIRED"
        TouchBridgeLogger.info(.gesture, "Intent: PAIRED_SECOND_TAP")
        guard userIntent == .enabled else {
            session.tapActionResult = "Suppressed (UserIntent Disabled)"
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }

        if tapBackendMode == .transientPointer {
            let result = transientPointerBackend.performPairedClick(
                at: session.startGlobalPoint.cgGlobal,
                appName: session.context?.applicationName
            )
            session.tapActionResult = result.succeeded ? "TRANSIENT_POINTER_DOUBLE_CLICK" : "TRANSIENT_POINTER_DOUBLE_CLICK_FAILED"
            delegate?.semanticRouter(
                self,
                didUpdateFeedback: result.succeeded ? "Transient Pointer Double Click" : "Transient Pointer Double Click Failed",
                invariantPassed: result.restoreResult == "SUCCESS" && (result.finalDisplacement.map { $0 <= 1.0 } ?? false)
            )
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }

        // Semantic-only diagnostics cannot carry native CGEvent clickState.
        // Route the paired contact through the existing semantic tap mechanism.
        gestureRecognizer(recognizer, didResolveTapWithSession: session)
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didResolveContextMenuWithSession session: InteractionSession) {
        session.interactionIntent = "CONTEXT_MENU"
        session.deliveryPolicy = tapBackendMode.diagnosticName
        TouchBridgeLogger.info(.gesture, "Intent: CONTEXT_MENU")
        guard userIntent == .enabled else {
            session.tapActionResult = "Suppressed (UserIntent Disabled)"
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }

        if tapBackendMode == .transientPointer {
            let appName = session.context?.applicationName
            let result = transientPointerBackend.performRightClick(
                at: session.startGlobalPoint.cgGlobal,
                appName: appName
            )
            session.tapActionResult = result.succeeded ? "TRANSIENT_POINTER_RIGHT_CLICK" : "TRANSIENT_POINTER_RIGHT_CLICK_FAILED"
            delegate?.semanticRouter(
                self,
                didUpdateFeedback: result.succeeded ? "Context Menu [\(appName ?? "Application")]" : "Context Menu Failed",
                invariantPassed: result.restoreResult == "SUCCESS" && (result.finalDisplacement.map { $0 <= 1.0 } ?? false)
            )
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
            return
        }

        if let element = session.context?.hitElement {
            let err = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
            session.tapActionResult = err == .success ? "AX_SHOW_MENU_SUCCESS" : "AX_SHOW_MENU_FAILED(\(err.rawValue))"
            delegate?.semanticRouter(self, didUpdateFeedback: session.tapActionResult, invariantPassed: true)
            delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
        }
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didStartDragWithSession session: InteractionSession) {
        haltMomentum()
        haltFingerDownSmoothing()
        session.interactionIntent = "DIRECT_DRAG"
        guard userIntent == .enabled else { return }

        let startPt = session.startGlobalPoint.cgGlobal
        let currentPt = session.latestGlobalPoint.cgGlobal
        let started = transientPointerBackend.beginDrag(at: startPt)
        if started {
            transientPointerBackend.updateDrag(to: currentPt)
            let appName = session.context?.applicationName ?? "Application"
            session.panActionResult = "DIRECT_DRAG_STARTED on [\(appName)]"
            delegate?.semanticRouter(self, didUpdateFeedback: "Drag Started [\(appName)]", invariantPassed: true)
        }
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdateDragWithSession session: InteractionSession, currentPoint: CGPoint) {
        guard userIntent == .enabled else { return }
        transientPointerBackend.updateDrag(to: currentPoint)
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEndDragWithSession session: InteractionSession, endPoint: CGPoint) {
        guard userIntent == .enabled else {
            transientPointerBackend.cancelDrag()
            return
        }
        transientPointerBackend.endDrag(at: endPoint)
        let appName = session.context?.applicationName ?? "Application"
        session.panActionResult = "DIRECT_DRAG_COMPLETED on [\(appName)] at (\(Int(endPoint.x)),\(Int(endPoint.y)))"
        delegate?.semanticRouter(self, didUpdateFeedback: "Drag Completed [\(appName)]", invariantPassed: true)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didStartWordSelectionDragWithSession session: InteractionSession) {
        haltMomentum()
        haltFingerDownSmoothing()
        session.interactionIntent = "WORD_SELECTION_DRAG"
        guard userIntent == .enabled else { return }

        let startPt = session.startGlobalPoint.cgGlobal
        let currentPt = session.latestGlobalPoint.cgGlobal
        let started = transientPointerBackend.beginWordSelectionDrag(at: startPt)
        if started {
            transientPointerBackend.updateWordSelectionDrag(to: currentPt)
            let appName = session.context?.applicationName ?? "Application"
            session.panActionResult = "WORD_SELECTION_DRAG_STARTED on [\(appName)]"
            delegate?.semanticRouter(self, didUpdateFeedback: "Word Selection Drag [\(appName)]", invariantPassed: true)
        }
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdateWordSelectionDragWithSession session: InteractionSession, currentPoint: CGPoint) {
        guard userIntent == .enabled else { return }
        transientPointerBackend.updateWordSelectionDrag(to: currentPoint)
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEndWordSelectionDragWithSession session: InteractionSession, endPoint: CGPoint) {
        guard userIntent == .enabled else {
            transientPointerBackend.cancelDrag()
            return
        }
        transientPointerBackend.endWordSelectionDrag(at: endPoint)
        let appName = session.context?.applicationName ?? "Application"
        session.panActionResult = "WORD_SELECTION_DRAG_COMPLETED on [\(appName)]"
        delegate?.semanticRouter(self, didUpdateFeedback: "Word Selection Drag Completed [\(appName)]", invariantPassed: true)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didResolveTripleTapWithSession session: InteractionSession) {
        haltMomentum()
        haltFingerDownSmoothing()
        session.interactionIntent = "TRIPLE_TAP"
        guard userIntent == .enabled else { return }

        let target = session.startGlobalPoint.cgGlobal
        let appName = session.context?.applicationName

        let result = transientPointerBackend.performTripleClick(at: target, appName: appName)
        session.tapActionResult = result.succeeded ? "TRANSIENT_POINTER_TRIPLE_CLICK" : "TRANSIENT_POINTER_TRIPLE_CLICK_FAILED"

        delegate?.semanticRouter(
            self,
            didUpdateFeedback: result.succeeded ? "Paragraph Selected [\(appName ?? "Application")]" : "Triple Tap Failed",
            invariantPassed: result.restoreResult == "SUCCESS" && (result.finalDisplacement.map { $0 <= 1.0 } ?? false)
        )
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())

        // Check if editable text input
        var isEditable = false
        if let ctx = session.context {
            isEditable = ctx.isTextInputControl || ctx.hitNode.isValueSettable
        } else if AXPermissionManager.shared.isTrusted() {
            let (elem, _, err) = AXSemanticEngine.shared.probeElementAt(globalCG: target)
            if err == .success, let elem {
                let ctx = AXCapabilityInspector.shared.discoverContext(element: elem, maxAncestors: 4)
                isEditable = ctx.isTextInputControl || ctx.hitNode.isValueSettable
            }
        }

        if isEditable {
            KeyboardPopoverController.shared.present(near: target) {
                SystemVirtualKeyboardManager.shared.setVisible(true)
            }
        }
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdateMagnifyWithSession session: InteractionSession, phase: Int64, magnification: Double) {
        guard userIntent == .enabled else { return }
        let wid = session.context?.windowHitInfo?.windowID
        _ = transientPointerBackend.postMagnify(
            at: session.startGlobalPoint.cgGlobal,
            phase: phase,
            magnification: magnification,
            windowID: wid
        )
        session.panActionResult = "NATIVE_MAGNIFY (phase=\(phase), mag=\(String(format: "%.3f", magnification)))"
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdateRotateWithSession session: InteractionSession, phase: Int64, rotationDegrees: Double) {
        guard userIntent == .enabled else { return }
        let wid = session.context?.windowHitInfo?.windowID
        _ = transientPointerBackend.postRotate(
            at: session.startGlobalPoint.cgGlobal,
            phase: phase,
            rotationDegrees: rotationDegrees,
            windowID: wid
        )
        session.panActionResult = "NATIVE_ROTATE (phase=\(phase), deg=\(String(format: "%.2f", rotationDegrees)))"
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didStartPanWithSession session: InteractionSession) {
        haltMomentum()
        haltFingerDownSmoothing()
        lastDirectPanVelocityY = 0
        lastDirectPanVelocity = .zero
        lastDirectPanVelocityAt = nil
        loggedDirectScrollFields = false

        guard userIntent == .enabled else {
            TouchBridgeLogger.info(.semantic, "Pan gesture observed, but interaction is SUPPRESSED (UserIntent is DISABLED).")
            return
        }

        // Resolve backend once at pan start and latch for gesture lifetime
        let point = session.startGlobalPoint.cgGlobal
        let backend = scrollCoordinator.resolveBackend(for: session, at: point)
        self.activeScrollBackend = backend
        session.scrollDeliveryBackend = backend
        _ = backend.begin(session: session, touchPoint: point)

        let appName = session.context?.applicationName ?? "Application"
        TouchBridgeLogger.info(
            .semantic,
            "Direct Pan STARTED on [\(appName)] [Backend: \(backend.diagnosticName)] (Contacts: \(session.contactCount))"
        )
        delegate?.semanticRouter(self, didUpdateFeedback: "Pan Started [\(appName)]", invariantPassed: true)
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanDeltaWithSession session: InteractionSession, deltaPixels: CGVector) {
        guard userIntent == .enabled else { return }

        if abs(deltaPixels.dx) > 0.01 || abs(deltaPixels.dy) > 0.01 {
            lastDirectPanVelocity = session.filteredVelocity
            lastDirectPanVelocityAt = session.lastMovementVelocitySampleAt
        }

        if abs(deltaPixels.dy) > 0.01 {
            lastDirectPanVelocityY = session.filteredVelocity.dy
        } else {
            lastDirectPanVelocityY = 0
        }
        // Zero trailing coast: do not emit synthetic tail deltas while finger is held still on screen
        haltFingerDownSmoothing()

        activeScrollBackend?.update(
            delta: deltaPixels,
            velocity: session.filteredVelocity,
            currentTouchPoint: session.latestGlobalPoint.cgGlobal
        )
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didUpdatePanWithSession session: InteractionSession, targetValue: Double) {
        // Obsolete P3-02 direct write hook. The production hybrid backend in didUpdatePanDeltaWithSession
        // owns the normalized mapping and write dispatching.
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didCompletePanWithSession session: InteractionSession) {
        guard userIntent == .enabled else { return }
        if session.state == .releasePending {
            beginReleaseLease(session: session, recognizer: recognizer)
            return
        }
        guard session.state != .momentum else {
            TouchBridgeLogger.debug(.semantic, "Direct pan contact lifted -> Latching active backend for momentum.")
            return
        }
        haltMomentum()
        haltFingerDownSmoothing()

        activeScrollBackend?.end(session: session)
        activeScrollBackend = nil

        let cursorBefore = SafetyInvariants.currentCursorPosition()
        let cursorAfter = SafetyInvariants.currentCursorPosition()
        SafetyInvariants.assertPointerIsolation(cursorBefore: cursorBefore, cursorAfter: cursorAfter, context: "Pan Complete")

        session.cursorBefore = cursorBefore
        session.cursorAfter = cursorAfter

        let totalDeltaY = session.latestGlobalPoint.cgGlobal.y - session.startGlobalPoint.cgGlobal.y
        let appName = session.context?.applicationName ?? "Application"
        let summary = "PAN_COMPLETED on [\(appName)]: Updates=\(session.panUpdatesCount) | DeltaY=\(String(format: "%.1f", totalDeltaY)) pt"

        TouchBridgeLogger.info(.semantic, summary)
        delegate?.semanticRouter(self, didUpdateFeedback: summary, invariantPassed: true)
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didEnterMomentumWithSession session: InteractionSession, initialVelocity: CGVector) {
        guard userIntent == .enabled else { return }
        guard activeScrollBackend != nil else {
            TouchBridgeLogger.error(.semantic, "P3-06R3 momentum_start rejected: selected scroll backend already ended.")
            return
        }
        haltMomentum()
        haltFingerDownSmoothing()
        if releaseLeaseSession === session {
            cancelReleaseSettle?()
            cancelReleaseSettle = nil
        }

        self.activeMomentumSession = session
        self.momentumRecognizer = recognizer
        self.momentumElapsedSec = 0
        self.momentumAccumulatedDistancePt = 0
        self.momentumTimerTickCount = 0
        self.lastMomentumTickUptime = ProcessInfo.processInfo.systemUptime
        loggedMomentumFields = false

        let isFallback = activeScrollBackend is TransientPointerScrollBackend
        let maxVelocity = isFallback ?
            GestureArbitrationConfig.compatibilityMaxReleaseVelocityPtPerSec :
            GestureArbitrationConfig.maxReleaseVelocityPtPerSec
        let decayFactor = isFallback ?
            GestureArbitrationConfig.compatibilityMomentumDecayFactor :
            GestureArbitrationConfig.momentumDecayFactor
        let stopVelocity = isFallback ?
            GestureArbitrationConfig.compatibilityMinMomentumVelocityPtPerSec :
            GestureArbitrationConfig.minMomentumVelocityPtPerSec
        let maxDuration = isFallback ?
            GestureArbitrationConfig.compatibilityMaxMomentumDurationSec :
            GestureArbitrationConfig.maxMomentumDurationSec
        let maxDistance = isFallback ?
            GestureArbitrationConfig.compatibilityMaxMomentumDistancePt :
            GestureArbitrationConfig.maxMomentumDistancePt

        // Clamp starting release velocity to prevent uncontrolled overshoots
        var clampedVel = initialVelocity
        let speed = hypot(clampedVel.dx, clampedVel.dy)
        if speed > maxVelocity && speed > 0 {
            let scale = maxVelocity / speed
            clampedVel.dx *= scale
            clampedVel.dy *= scale
        }
        self.currentMomentumVelocity = clampedVel

        let dt: Double = 0.016
        let initialStepX = clampedVel.dx * dt
        let initialStepY = clampedVel.dy * dt
        let initialStepMag = hypot(initialStepX, initialStepY)
        self.momentumAccumulatedDistancePt += initialStepMag
        momentumFrameCount = 1
        activeScrollBackend?.momentumUpdate(
            delta: CGVector(dx: initialStepX, dy: initialStepY),
            velocity: clampedVel
        )

        let initialSpeed = hypot(clampedVel.dx, clampedVel.dy)
        let backendName = activeScrollBackend?.diagnosticName ?? (isFallback ? "TRANSIENT_POINTER_FALLBACK" : "AX_SEMANTIC")
        TouchBridgeLogger.info(
            .semantic,
            "P3-06R3 momentum_start: backend=\(backendName) speed=\(String(format: "%.1f", initialSpeed))pt/s raw=\(String(format: "%.1f", speed)) initialDelta=\(String(format: "%.2f", initialStepY))pt decay=\(decayFactor) cutoff=\(stopVelocity)pt/s maxDur=\(maxDuration)s maxDist=\(maxDistance)pt"
        )

        self.cancelMomentumTimer = momentumTickScheduler(dt) { [weak self] in
            guard let self else { return }
            self.momentumTimerTickCount += 1
            self.advanceMomentumFrame(
                interval: dt,
                decayFactor: decayFactor,
                stopVelocity: stopVelocity,
                maxDuration: maxDuration,
                maxDistance: maxDistance
            )
        }
        TouchBridgeLogger.info(.semantic, "P3-06R3 momentum_timer scheduled: intervalMs=16.")
    }

    private func advanceMomentumFrame(
        interval dt: Double,
        decayFactor: Double,
        stopVelocity: Double,
        maxDuration: Double,
        maxDistance: Double
    ) {
        guard let active = activeMomentumSession else {
            stopMomentumTimer()
            return
        }

        let effectiveDt: Double
        let effectiveDecay: Double
        if usesCustomMomentumSchedulerForTesting {
            effectiveDt = dt
            effectiveDecay = decayFactor
        } else {
            let nowUptime = ProcessInfo.processInfo.systemUptime
            let rawElapsed = nowUptime - lastMomentumTickUptime
            lastMomentumTickUptime = nowUptime
            effectiveDt = min(0.050, max(0.004, rawElapsed > 0 ? rawElapsed : dt))
            effectiveDecay = pow(decayFactor, effectiveDt / dt)
        }

        momentumElapsedSec += effectiveDt
        currentMomentumVelocity.dx *= effectiveDecay
        currentMomentumVelocity.dy *= effectiveDecay
        let currentSpeed = hypot(currentMomentumVelocity.dx, currentMomentumVelocity.dy)
        let stepX = currentMomentumVelocity.dx * effectiveDt
        let stepY = currentMomentumVelocity.dy * effectiveDt
        let stepMag = hypot(stepX, stepY)
        momentumAccumulatedDistancePt += stepMag
        momentumFrameCount += 1

        let reachedLimit = currentSpeed < stopVelocity ||
                           momentumElapsedSec >= maxDuration ||
                           momentumAccumulatedDistancePt >= maxDistance
        let termination = currentSpeed < stopVelocity ? "speed_cutoff" :
            (momentumElapsedSec >= maxDuration ? "max_duration" :
                (momentumAccumulatedDistancePt >= maxDistance ? "max_distance" : "none"))
        TouchBridgeLogger.info(
            .semantic,
            "P3-06R3 momentum_tick: timerTick=\(momentumTimerTickCount) frame=\(momentumFrameCount) elapsedMs=\(Int((momentumElapsedSec * 1000).rounded())) velocityY=\(String(format: "%.1f", currentMomentumVelocity.dy)) deltaY=\(String(format: "%.3f", stepY)) delivery=\(reachedLimit ? "skipped_at_termination" : "sent_to_backend") termination=\(termination)"
        )
        guard reachedLimit else {
            activeScrollBackend?.momentumUpdate(
                delta: CGVector(dx: stepX, dy: stepY),
                velocity: currentMomentumVelocity
            )
            return
        }

        let reason: String
        if currentSpeed < stopVelocity {
            reason = "speed_cutoff (\(String(format: "%.1f", currentSpeed)) < \(String(format: "%.1f", stopVelocity)) pt/s)"
        } else if momentumElapsedSec >= maxDuration {
            reason = "max_duration (\(String(format: "%.3f", momentumElapsedSec))s >= \(String(format: "%.3f", maxDuration))s)"
        } else {
            reason = "max_distance (\(String(format: "%.1f", momentumAccumulatedDistancePt))pt >= \(String(format: "%.1f", maxDistance))pt)"
        }

        let elapsed = momentumElapsedSec
        let distance = momentumAccumulatedDistancePt
        let frames = momentumFrameCount
        TouchBridgeLogger.info(
            .semantic,
            "P3-06R3 momentum_timer stopped: reason=\(reason), dur=\(String(format: "%.3f", elapsed))s, dist=\(String(format: "%.1f", distance))pt, frames=\(frames), endSpeed=\(String(format: "%.1f", currentSpeed))pt/s."
        )
        finishReleaseTransaction(active, reason: "momentum_\(reason)")
    }

    public func gestureRecognizer(_ recognizer: TouchGestureRecognizer, didInterruptMomentumWithSession session: InteractionSession) {
        haltFingerDownSmoothing()
        if releaseLeaseSession === session {
            TouchBridgeLogger.info(.semantic, "P3-06R2 release lease interrupted by retouch; cancel timers and close previous backend exactly once.")
            finishReleaseTransaction(session, reason: "retouch_during_release_or_momentum")
            return
        }
        if let active = activeMomentumSession {
            let elapsed = momentumElapsedSec
            let distance = momentumAccumulatedDistancePt
            haltMomentum()
            finishReleaseTransaction(active, reason: "retouch_during_momentum")
            TouchBridgeLogger.info(
                .semantic,
                "Kinetic momentum INTERRUPTED immediately by new touch: dur=\(String(format: "%.3f", elapsed))s, dist=\(String(format: "%.1f", distance))pt."
            )
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
        transientPointerBackend.cancelDrag()
        if releaseLeaseSession === session {
            finishReleaseTransaction(session, reason: "cancelled_\(reason)")
            return
        }
        haltMomentum()
        activeScrollBackend?.cancel(session: session, reason: reason)
        activeScrollBackend = nil
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
            self.activeScrollBackend?.update(deltaY: delta, velocityY: 0, currentTouchPoint: session.latestGlobalPoint.cgGlobal)
        }
    }

    private func haltFingerDownSmoothing() {
        fingerDownSmoothingTimer?.invalidate()
        fingerDownSmoothingTimer = nil
        fingerDownSmoothingTail = nil
    }

    private func haltMomentum() {
        stopMomentumTimer()
        momentumElapsedSec = 0
        momentumAccumulatedDistancePt = 0
        momentumFrameCount = 0
    }

    private func stopMomentumTimer() {
        cancelMomentumTimer?()
        cancelMomentumTimer = nil
    }

    private func beginReleaseLease(session: InteractionSession, recognizer: TouchGestureRecognizer) {
        guard activeScrollBackend != nil else {
            TouchBridgeLogger.error(.semantic, "P3-06R2 releasePending rejected: no selected scroll backend remains.")
            session.markMomentumEnded()
            recognizer.releaseLifecycleDidEnd(session)
            return
        }
        cancelReleaseLeaseTimers()
        releaseLeaseSession = session
        releaseLeaseRecognizer = recognizer
        releaseLeaseStartedAt = session.releasePendingAt ?? Date()
        let backendName = activeScrollBackend?.diagnosticName ?? "unknown"
        TouchBridgeLogger.info(
            .semantic,
            "P3-06R2 release_lease_started: backend=\(backendName) settleMs=\(Int(GestureArbitrationConfig.releaseSettleWindowSec * 1000)) ceilingMs=\(Int(GestureArbitrationConfig.releaseTransactionCeilingSec * 1000)) lastDirectVelocity=\(String(format: "%.1f,%.1f", lastDirectPanVelocity.dx, lastDirectPanVelocity.dy)) lastDirectSampleAt=\(lastDirectPanVelocityAt.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "none")"
        )
        cancelReleaseSettle = releaseLeaseScheduler(GestureArbitrationConfig.releaseSettleWindowSec) { [weak self, weak session] in
            guard let self, let session else { return }
            self.releaseSettleExpired(session)
        }
        cancelReleaseCeiling = releaseLeaseScheduler(GestureArbitrationConfig.releaseTransactionCeilingSec) { [weak self, weak session] in
            guard let self, let session else { return }
            self.releaseCeilingExpired(session)
        }
    }

    private func releaseSettleExpired(_ session: InteractionSession) {
        guard releaseLeaseSession === session, session.state == .releasePending else { return }
        TouchBridgeLogger.info(.semantic, "P3-06R2 release_settle_expired: no momentum started within \(Int(GestureArbitrationConfig.releaseSettleWindowSec * 1000))ms; ending backend and restoring once if safe.")
        finishReleaseTransaction(session, reason: "release_settle_expired_no_momentum")
    }

    private func releaseCeilingExpired(_ session: InteractionSession) {
        guard releaseLeaseSession === session else { return }
        let age = releaseLeaseStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        TouchBridgeLogger.error(.semantic, "P3-06R2 release_hard_ceiling: closing stuck release transaction after \(String(format: "%.0f", age * 1000))ms.")
        finishReleaseTransaction(session, reason: "release_hard_ceiling")
    }

    private func finishReleaseTransaction(_ session: InteractionSession, reason: String) {
        let timerScheduled = cancelMomentumTimer != nil
        let timerTicks = momentumTimerTickCount
        let releaseAgeMs = releaseLeaseStartedAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0
        stopMomentumTimer()
        cancelReleaseLeaseTimers()
        activeScrollBackend?.end(session: session)
        activeScrollBackend = nil
        session.markMomentumEnded()
        TouchBridgeLogger.info(.semantic, "P3-06R2 backend_end: reason=\(reason) releaseAgeMs=\(String(format: "%.1f", releaseAgeMs)) momentumTimerScheduled=\(timerScheduled) timerTicks=\(timerTicks); release transaction closed.")
        delegate?.semanticRouter(self, didCompleteSession: session, evidenceBlock: session.formattedEvidenceBlock())
        let recognizer = releaseLeaseRecognizer ?? momentumRecognizer
        recognizer?.releaseLifecycleDidEnd(session)
        activeMomentumSession = nil
        momentumRecognizer = nil
        momentumTimerTickCount = 0
        releaseLeaseRecognizer = nil
        releaseLeaseSession = nil
        releaseLeaseStartedAt = nil
    }

    private func cancelReleaseLeaseTimers() {
        cancelReleaseSettle?()
        cancelReleaseSettle = nil
        cancelReleaseCeiling?()
        cancelReleaseCeiling = nil
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

// MARK: - On-Screen Keyboard Controller (Text Input Helper)

public final class OnScreenKeyboardController: NSObject {
    public static let shared = OnScreenKeyboardController()

    private var pillPanel: NSPanel?
    private var dismissTimer: Timer?
    private let assistiveControlURL = URL(fileURLWithPath: "/System/Library/Input Methods/AssistiveControl.app")

    private override init() {
        super.init()
    }

    @objc public func toggleOnScreenKeyboard() {
        dismissPill()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.inputmethod.AssistiveControl")
        if let app = running.first, !app.isTerminated {
            app.terminate()
            TouchBridgeLogger.info(.lifecycle, "On-screen Accessibility Keyboard hidden.")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: assistiveControlURL, configuration: config) { _, error in
            if let error {
                TouchBridgeLogger.warning(.lifecycle, "Could not launch AssistiveControl.app: \(error.localizedDescription)")
            } else {
                TouchBridgeLogger.info(.lifecycle, "On-screen Accessibility Keyboard opened.")
            }
        }
    }

    public func showFloatingPill(near globalCGPoint: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            self?.presentPillOnMain(near: globalCGPoint)
        }
    }

    public func dismissPill() {
        DispatchQueue.main.async { [weak self] in
            self?.dismissTimer?.invalidate()
            self?.dismissTimer = nil
            self?.pillPanel?.orderOut(nil)
        }
    }

    private func presentPillOnMain(near globalCGPoint: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
        let appKitPoint = NSPoint(x: globalCGPoint.x, y: primaryHeight - globalCGPoint.y)

        let width: CGFloat = 116
        let height: CGFloat = 34
        let origin = NSPoint(x: appKitPoint.x - width / 2.0, y: max(20, appKitPoint.y - height - 28))

        let panel: NSPanel
        if let existing = pillPanel {
            panel = existing
            panel.setFrameOrigin(origin)
        } else {
            let created = NSPanel(
                contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isFloatingPanel = true
            created.level = .statusBar
            created.backgroundColor = .clear
            created.isOpaque = false
            created.hasShadow = true
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            container.material = .hudWindow
            container.state = .active
            container.wantsLayer = true
            container.layer?.cornerRadius = 17
            container.layer?.masksToBounds = true

            let button = NSButton(title: "⌨️ Bàn phím", target: self, action: #selector(toggleOnScreenKeyboard))
            button.frame = container.bounds
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            button.contentTintColor = .white
            container.addSubview(button)

            created.contentView = container
            self.pillPanel = created
            panel = created
        }

        panel.orderFrontRegardless()
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            self?.pillPanel?.orderOut(nil)
        }
    }
}
