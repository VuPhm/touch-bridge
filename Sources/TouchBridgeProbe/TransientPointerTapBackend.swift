import Foundation
import CoreGraphics
import Cocoa

public enum PointerMouseUpAcknowledgement: String {
    case observed = "OBSERVED"
    case unavailable = "UNAVAILABLE"
    case timedOut = "TIMEOUT"
}

public enum PointerTransactionPhase: String {
    case prepared, observing, relocated, clickPosted, clickAcknowledged, restoreSuppressed, restored, failedDegraded
}

public struct PointerCursorVerification {
    public let verified: Bool
    public let finalPoint: CGPoint?
    public let attempts: Int
    public let errorDistance: Double?
}

public struct PointerTransactionResult {
    public let initialCursor: CGPoint?
    public let interactionPoint: CGPoint
    public let visualConcealmentAttempted: Bool
    public let visualConcealmentResult: String
    public let visibilityRestoreResult: String
    public let relocationAPIResult: String
    public let relocationVerification: PointerCursorVerification
    public let mouseDownCreated: Bool
    public let mouseDownPosted: Bool
    public let mouseUpCreated: Bool
    public let mouseUpPosted: Bool
    public let mouseUpAcknowledgement: PointerMouseUpAcknowledgement
    public let physicalMouseInterferenceDetected: Bool
    public let observationUnavailable: Bool
    public let restoreAttempted: Bool
    public let restorationSuppressedReason: String?
    public let restoreAPIResult: String
    public let finalCursor: CGPoint?
    public let finalDisplacement: Double?
    public let restorationVerified: Bool
    public let transactionDurationMs: Double
    public let finalPhase: PointerTransactionPhase
    public let classification: String

    public var relocationResult: String { relocationVerification.verified ? "SUCCESS" : (relocationAPIResult == "SUCCESS" ? "UNVERIFIED" : "FAILED") }
    public var restoreResult: String { restoreAPIResult }
    public var succeeded: Bool { relocationVerification.verified && mouseDownPosted && mouseUpPosted }
}

public struct PointerMouseActivitySnapshot {
    public let isObservable: Bool
    public let generation: UInt64
    public init(isObservable: Bool, generation: UInt64) {
        self.isObservable = isObservable
        self.generation = generation
    }
}

public protocol PointerTransactionOperating {
    var canObservePhysicalMouse: Bool { get }
    var physicalMouseGeneration: UInt64 { get }
    func pointerActivitySnapshot() -> PointerMouseActivitySnapshot
    func lastPhysicalCursorPosition() -> CGPoint?
    func prepareForTransactions()
    func cursorPosition() -> CGPoint?
    func advanceCursorVerification()
    func hideCursor(at point: CGPoint) -> String
    func showCursor(at point: CGPoint) -> String
    func warpCursor(to point: CGPoint) -> Bool
    func makeMouseEvent(type: CGEventType, at point: CGPoint) -> PointerMouseEvent?
    func markedMouseUpAcknowledgementToken() -> UInt64?
    func waitForMarkedMouseUp(after token: UInt64, timeout: TimeInterval) -> PointerMouseUpAcknowledgement
    func waitForMarkedMouseUps(after token: UInt64, count: Int, timeout: TimeInterval) -> PointerMouseUpAcknowledgement
    func post(_ event: PointerMouseEvent)
    @discardableResult func postScrollWheel(at point: CGPoint, deltaY: Double, phase: UInt32, momentumPhase: UInt32) -> Bool
    @discardableResult func postScrollWheel2D(at point: CGPoint, deltaX: Double, deltaY: Double, phase: UInt32, momentumPhase: UInt32) -> Bool
    @discardableResult func postMagnify(at point: CGPoint, phase: Int64, magnification: Double, windowID: CGWindowID?) -> Bool
    @discardableResult func postRotate(at point: CGPoint, phase: Int64, rotationDegrees: Double, windowID: CGWindowID?) -> Bool
}

public extension PointerTransactionOperating {
    func prepareForTransactions() {}
    func lastPhysicalCursorPosition() -> CGPoint? { cursorPosition() }
    func advanceCursorVerification() { CFRunLoopRunInMode(.defaultMode, 0.002, true) }
    func pointerActivitySnapshot() -> PointerMouseActivitySnapshot {
        PointerMouseActivitySnapshot(isObservable: canObservePhysicalMouse, generation: physicalMouseGeneration)
    }
    func markedMouseUpAcknowledgementToken() -> UInt64? { canObservePhysicalMouse ? physicalMouseGeneration : nil }
    func waitForMarkedMouseUp(after token: UInt64, timeout: TimeInterval) -> PointerMouseUpAcknowledgement { .unavailable }
    func waitForMarkedMouseUps(after token: UInt64, count: Int, timeout: TimeInterval) -> PointerMouseUpAcknowledgement {
        count == 1 ? waitForMarkedMouseUp(after: token, timeout: timeout) : .unavailable
    }
    @discardableResult func postScrollWheel(at point: CGPoint, deltaY: Double, phase: UInt32, momentumPhase: UInt32) -> Bool {
        let pixels = deltaY * 1.5
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(round(pixels)),
            wheel2: 0,
            wheel3: 0
        ) else { return false }
        event.location = point
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase))
        event.setIntegerValueField(.eventSourceUserData, value: 0x54425054584E)
        event.post(tap: .cghidEventTap)
        return true
    }
    @discardableResult func postScrollWheel2D(at point: CGPoint, deltaX: Double, deltaY: Double, phase: UInt32, momentumPhase: UInt32) -> Bool {
        postScrollWheel(at: point, deltaY: deltaY, phase: phase, momentumPhase: momentumPhase)
    }
    @discardableResult func postMagnify(at point: CGPoint, phase: Int64, magnification: Double, windowID: CGWindowID?) -> Bool {
        guard let gestureType = CGEventType(rawValue: 29),
              let event = CGEvent(source: nil) else { return false }
        event.type = gestureType
        event.location = point
        if let wid = windowID ?? AXCapabilityInspector.shared.resolveTopmostWindow(at: point)?.windowID {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid))
        }
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8) // kIOHIDEventTypeZoom
        event.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        event.setDoubleValueField(CGEventField(rawValue: 116)!, value: magnification)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setIntegerValueField(.eventSourceUserData, value: 0x54425054584E)
        event.post(tap: .cghidEventTap)
        return true
    }
    @discardableResult func postRotate(at point: CGPoint, phase: Int64, rotationDegrees: Double, windowID: CGWindowID?) -> Bool {
        guard let gestureType = CGEventType(rawValue: 29),
              let event = CGEvent(source: nil) else { return false }
        event.type = gestureType
        event.location = point
        if let wid = windowID ?? AXCapabilityInspector.shared.resolveTopmostWindow(at: point)?.windowID {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid))
        }
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 5) // kIOHIDEventTypeRotation
        event.setDoubleValueField(CGEventField(rawValue: 114)!, value: rotationDegrees)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setIntegerValueField(.eventSourceUserData, value: 0x54425054584E)
        event.post(tap: .cghidEventTap)
        return true
    }
}

public enum PointerRestoreDecision: Equatable {
    case safe
    case physicalMouseInterference
    case observationUnavailable
}

public struct PointerTransactionGuard {
    private let startGeneration: UInt64
    private let wasObservingAtStart: Bool

    public init(snapshot: PointerMouseActivitySnapshot) {
        wasObservingAtStart = snapshot.isObservable
        startGeneration = snapshot.generation
    }

    public func restoreDecision(using operations: PointerTransactionOperating) -> PointerRestoreDecision {
        let snapshot = operations.pointerActivitySnapshot()
        guard wasObservingAtStart, snapshot.isObservable else { return .observationUnavailable }
        return snapshot.generation == startGeneration ? .safe : .physicalMouseInterference
    }
}

public final class PointerMouseEvent {
    fileprivate let nativeEvent: CGEvent?
    public let type: CGEventType
    public var clickState: Int64 = 1
    public init(nativeEvent: CGEvent? = nil, type: CGEventType = .null) {
        self.nativeEvent = nativeEvent
        self.type = type
    }
}

public final class TransientPointerTapBackend {
    private let operations: PointerTransactionOperating
    private let displacementTolerance: Double
    private let relocationAttemptLimit: Int
    private let acknowledgementTimeout: TimeInterval

    /// Predicate to check whether a point lies on the external touchscreen display.
    /// Points not on touchscreen are treated as belonging to the primary/working display.
    public var isTouchscreenPoint: (CGPoint) -> Bool = { _ in false }
    public static var enableEvidencePrinting: Bool = true

    /// Active 1-finger drag state. Guaranteed to emit `leftMouseUp` on `endDrag` or `cancelDrag`.
    public private(set) var isDragging: Bool = false
    public private(set) var isWordSelectionDrag: Bool = false
    public private(set) var lastDragPoint: CGPoint? = nil
    private var dragSnapshot: PointerMouseActivitySnapshot? = nil
    private var dragInitialCursor: CGPoint? = nil
    private var dragShouldRestoreToMain: Bool = false

    public static func isPointWithinActiveDisplays(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return true }
        return displays.contains { CGDisplayBounds($0).contains(point) }
    }

    public init(
        operations: PointerTransactionOperating = CoreGraphicsPointerTransactionOperations(),
        displacementTolerance: Double = 1.0,
        relocationAttemptLimit: Int = 4,
        acknowledgementTimeout: TimeInterval = 0.12
    ) {
        self.operations = operations
        self.displacementTolerance = displacementTolerance
        self.relocationAttemptLimit = max(1, relocationAttemptLimit)
        self.acknowledgementTimeout = max(0, acknowledgementTimeout)
    }

    public func prepareForTransactions() { operations.prepareForTransactions() }

    @discardableResult
    public func performClick(at point: CGPoint, appName: String? = nil) -> PointerTransactionResult {
        performButtonTransaction(at: point, downType: .leftMouseDown, upType: .leftMouseUp, clickState: 1, appName: appName)
    }

    @discardableResult
    public func performPairedClick(at point: CGPoint, appName: String? = nil) -> PointerTransactionResult {
        performButtonTransaction(at: point, downType: .leftMouseDown, upType: .leftMouseUp, clickState: 2, appName: appName)
    }

    @discardableResult
    public func performTripleClick(at point: CGPoint, appName: String? = nil) -> PointerTransactionResult {
        performButtonTransaction(at: point, downType: .leftMouseDown, upType: .leftMouseUp, clickState: 3, appName: appName)
    }

    @discardableResult
    public func performRightClick(at point: CGPoint, appName: String? = nil) -> PointerTransactionResult {
        performButtonTransaction(at: point, downType: .rightMouseDown, upType: .rightMouseUp, clickState: 1, appName: appName)
    }

    @discardableResult
    public func beginDrag(at startPoint: CGPoint) -> Bool {
        if isDragging {
            cancelDrag()
        }
        let initial = operations.lastPhysicalCursorPosition() ?? operations.cursorPosition()
        let shouldRestore = initial.map { !isTouchscreenPoint($0) } ?? false
        dragInitialCursor = initial
        dragShouldRestoreToMain = shouldRestore

        guard operations.warpCursor(to: startPoint),
              let down = operations.makeMouseEvent(type: .leftMouseDown, at: startPoint) else {
            dragInitialCursor = nil
            dragShouldRestoreToMain = false
            return false
        }
        down.clickState = 1
        operations.post(down)
        isDragging = true
        isWordSelectionDrag = false
        lastDragPoint = startPoint
        dragSnapshot = operations.pointerActivitySnapshot()
        return true
    }

    public func updateDrag(to currentPoint: CGPoint) {
        guard isDragging && !isWordSelectionDrag else { return }
        if let dragSnapshot, operations.pointerActivitySnapshot().generation != dragSnapshot.generation {
            TouchBridgeLogger.info(.semantic, "Direct touch drag interrupted by physical mouse activity. Yielding control to physical mouse.")
            yieldDragToPhysicalMouse()
            return
        }
        _ = operations.warpCursor(to: currentPoint)
        if let drag = operations.makeMouseEvent(type: .leftMouseDragged, at: currentPoint) {
            drag.clickState = 1
            operations.post(drag)
        }
        lastDragPoint = currentPoint
    }

    public func endDrag(at endPoint: CGPoint) {
        guard isDragging && !isWordSelectionDrag else { return }
        let shouldRestore = dragShouldRestoreToMain
        let initial = dragInitialCursor
        let currentSnapshot = operations.pointerActivitySnapshot()
        let interference = (dragSnapshot != nil && currentSnapshot.generation != dragSnapshot!.generation)

        isDragging = false
        dragSnapshot = nil
        dragInitialCursor = nil
        dragShouldRestoreToMain = false

        _ = operations.warpCursor(to: endPoint)
        if let up = operations.makeMouseEvent(type: .leftMouseUp, at: endPoint) {
            up.clickState = 1
            operations.post(up)
        }
        lastDragPoint = nil

        if shouldRestore, !interference, let initial, Self.isPointWithinActiveDisplays(initial) {
            if operations.pointerActivitySnapshot().generation == currentSnapshot.generation {
                _ = operations.warpCursor(to: initial)
                TouchBridgeLogger.info(.semantic, "Drag completed; restored cursor to main display at \(initial)")
            } else {
                TouchBridgeLogger.info(.semantic, "Drag completed; restoration suppressed due to physical mouse activity.")
            }
        }
    }

    @discardableResult
    public func beginWordSelectionDrag(at startPoint: CGPoint) -> Bool {
        if isDragging {
            cancelDrag()
        }
        let initial = operations.lastPhysicalCursorPosition() ?? operations.cursorPosition()
        let shouldRestore = initial.map { !isTouchscreenPoint($0) } ?? false
        dragInitialCursor = initial
        dragShouldRestoreToMain = shouldRestore

        guard operations.warpCursor(to: startPoint),
              let down = operations.makeMouseEvent(type: .leftMouseDown, at: startPoint) else {
            dragInitialCursor = nil
            dragShouldRestoreToMain = false
            return false
        }
        down.clickState = 2
        operations.post(down)
        isDragging = true
        isWordSelectionDrag = true
        lastDragPoint = startPoint
        dragSnapshot = operations.pointerActivitySnapshot()
        TouchBridgeLogger.info(.semantic, "Started word selection drag (clickState: 2) at \(startPoint), shouldRestoreToMain: \(shouldRestore)")
        return true
    }

    public func updateWordSelectionDrag(to currentPoint: CGPoint) {
        guard isDragging && isWordSelectionDrag else { return }
        if let dragSnapshot, operations.pointerActivitySnapshot().generation != dragSnapshot.generation {
            TouchBridgeLogger.info(.semantic, "Word selection drag interrupted by physical mouse activity. Yielding control to physical mouse.")
            yieldDragToPhysicalMouse()
            return
        }
        _ = operations.warpCursor(to: currentPoint)
        if let drag = operations.makeMouseEvent(type: .leftMouseDragged, at: currentPoint) {
            drag.clickState = 2
            operations.post(drag)
        }
        lastDragPoint = currentPoint
    }

    public func endWordSelectionDrag(at endPoint: CGPoint) {
        guard isDragging && isWordSelectionDrag else { return }
        let shouldRestore = dragShouldRestoreToMain
        let initial = dragInitialCursor
        let currentSnapshot = operations.pointerActivitySnapshot()
        let interference = (dragSnapshot != nil && currentSnapshot.generation != dragSnapshot!.generation)

        isDragging = false
        isWordSelectionDrag = false
        dragSnapshot = nil
        dragInitialCursor = nil
        dragShouldRestoreToMain = false

        _ = operations.warpCursor(to: endPoint)
        if let up = operations.makeMouseEvent(type: .leftMouseUp, at: endPoint) {
            up.clickState = 2
            operations.post(up)
        }
        lastDragPoint = nil

        if shouldRestore, !interference, let initial, Self.isPointWithinActiveDisplays(initial) {
            if operations.pointerActivitySnapshot().generation == currentSnapshot.generation {
                _ = operations.warpCursor(to: initial)
                TouchBridgeLogger.info(.semantic, "Word selection drag completed; restored cursor to main display at \(initial)")
            } else {
                TouchBridgeLogger.info(.semantic, "Word selection drag completed; restoration suppressed due to physical mouse activity.")
            }
        }
        TouchBridgeLogger.info(.semantic, "Ended word selection drag (clickState: 2) at \(endPoint)")
    }

    /// Yields drag immediately to physical mouse or cancels unconditionally on reset/hotplug.
    private func yieldDragToPhysicalMouse() {
        guard isDragging else { return }
        let releaseClickState: Int64 = isWordSelectionDrag ? 2 : 1
        isDragging = false
        isWordSelectionDrag = false
        dragSnapshot = nil
        dragInitialCursor = nil
        dragShouldRestoreToMain = false
        let releasePoint = lastDragPoint ?? operations.cursorPosition() ?? .zero
        if let up = operations.makeMouseEvent(type: .leftMouseUp, at: releasePoint) {
            up.clickState = releaseClickState
            operations.post(up)
        }
        lastDragPoint = nil
    }

    /// Unconditionally releases any held mouse-down state (on disconnect, disable, or gesture cancellation).
    public func cancelDrag() {
        yieldDragToPhysicalMouse()
    }

    @discardableResult
    public func postMagnify(at point: CGPoint, phase: Int64, magnification: Double, windowID: CGWindowID? = nil) -> Bool {
        operations.postMagnify(at: point, phase: phase, magnification: magnification, windowID: windowID)
    }

    @discardableResult
    public func postRotate(at point: CGPoint, phase: Int64, rotationDegrees: Double, windowID: CGWindowID? = nil) -> Bool {
        operations.postRotate(at: point, phase: phase, rotationDegrees: rotationDegrees, windowID: windowID)
    }

    @discardableResult
    private func performButtonTransaction(
        at point: CGPoint,
        downType: CGEventType,
        upType: CGEventType,
        clickState: Int64,
        appName: String?
    ) -> PointerTransactionResult {
        let started = ProcessInfo.processInfo.systemUptime
        let frontmostPIDBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windowUnderTouch = windowDescription(at: point)
        let initial = operations.lastPhysicalCursorPosition() ?? operations.cursorPosition()
        let shouldRestoreToMain = initial.map { !isTouchscreenPoint($0) } ?? false
        let observerEstablished = operations.pointerActivitySnapshot()
        let transactionGuard = PointerTransactionGuard(snapshot: observerEstablished)
        var phase: PointerTransactionPhase = observerEstablished.isObservable ? .observing : .prepared
        let concealmentPoint = initial ?? point
        let concealment = operations.hideCursor(at: concealmentPoint)
        var visibilityRestoreResult = "NOT_REQUIRED"
        var relocationAPIResult = "NOT_ATTEMPTED"
        var relocationVerification = PointerCursorVerification(verified: false, finalPoint: nil, attempts: 0, errorDistance: nil)
        var downPosted = false, upPosted = false, downCreated = false, upCreated = false
        var acknowledgement: PointerMouseUpAcknowledgement = .unavailable
        var interference = false, observationUnavailable = false
        var restoreAttempted = false, suppressedReason: String?
        var restoreAPIResult = "NOT_ATTEMPTED"
        var restorationVerified = false

        let warpSucceeded = operations.warpCursor(to: point)
        relocationAPIResult = warpSucceeded ? "SUCCESS" : "FAILED"
        if warpSucceeded { relocationVerification = verifyCursor(at: point) }

        if relocationVerification.verified {
            phase = .relocated
            // Keep the interference baseline after TouchBridge's relocation so only
            // real activity during click delivery/restoration arbitration counts.
            let observerAtRelocation = operations.pointerActivitySnapshot()
            observationUnavailable = !observerEstablished.isObservable || !observerAtRelocation.isObservable
            let acknowledgementToken = operations.markedMouseUpAcknowledgementToken()
            let down = operations.makeMouseEvent(type: downType, at: point)
            let up = operations.makeMouseEvent(type: upType, at: point)
            down?.clickState = clickState
            up?.clickState = clickState
            downCreated = down != nil
            upCreated = up != nil
            if let down, let up {
                operations.post(down)
                downPosted = true
                operations.post(up)
                upPosted = true
                phase = .clickPosted
                if let acknowledgementToken {
                    acknowledgement = operations.waitForMarkedMouseUps(
                        after: acknowledgementToken,
                        count: 1,
                        timeout: acknowledgementTimeout
                    )
                } else {
                    acknowledgement = .unavailable
                }
                if acknowledgement == .observed { phase = .clickAcknowledged }
            }

            let decision = transactionGuard.restoreDecision(using: operations)
            interference = decision == .physicalMouseInterference
            observationUnavailable = observationUnavailable || decision == .observationUnavailable
            if interference {
                suppressedReason = "PHYSICAL_MOUSE_ACTIVITY"
                restoreAPIResult = "SUPPRESSED_PHYSICAL_MOUSE_ACTIVITY"
            } else if observationUnavailable {
                suppressedReason = "OBSERVATION_UNAVAILABLE"
                restoreAPIResult = "SUPPRESSED_OBSERVATION_UNAVAILABLE"
            } else if !shouldRestoreToMain {
                // User intentionally moved cursor to touchscreen; retain it there normally.
                restoreAPIResult = "NOT_REQUIRED_CURSOR_ON_TOUCHSCREEN"
                restorationVerified = true
            } else if !downCreated || !upCreated {
                // No button event was posted, so there is no asynchronous click
                // transaction to acknowledge before restoring the cursor.
                if let initial, Self.isPointWithinActiveDisplays(initial) {
                    restoreAttempted = true
                    let apiSuccess = operations.warpCursor(to: initial)
                    restoreAPIResult = apiSuccess ? "SUCCESS" : "FAILED"
                    restorationVerified = apiSuccess && verifyCursor(at: initial).verified
                } else {
                    suppressedReason = initial == nil ? "INITIAL_CURSOR_UNAVAILABLE" : "TARGET_DISPLAY_UNAVAILABLE"
                    restoreAPIResult = initial == nil ? "SUPPRESSED_INITIAL_CURSOR_UNAVAILABLE" : "SUPPRESSED_TARGET_DISPLAY_UNAVAILABLE"
                }
            } else if acknowledgement == .observed {
                let finalRestoreDecision = transactionGuard.restoreDecision(using: operations)
                if finalRestoreDecision == .physicalMouseInterference {
                    interference = true
                    suppressedReason = "PHYSICAL_MOUSE_ACTIVITY"
                    restoreAPIResult = "SUPPRESSED_PHYSICAL_MOUSE_ACTIVITY"
                } else if finalRestoreDecision == .observationUnavailable {
                    observationUnavailable = true
                    suppressedReason = "OBSERVATION_UNAVAILABLE"
                    restoreAPIResult = "SUPPRESSED_OBSERVATION_UNAVAILABLE"
                } else if let initial, Self.isPointWithinActiveDisplays(initial) {
                    restoreAttempted = true
                    let apiSuccess = operations.warpCursor(to: initial)
                    restoreAPIResult = apiSuccess ? "SUCCESS" : "FAILED"
                    let verification = apiSuccess ? verifyCursor(at: initial) : PointerCursorVerification(verified: false, finalPoint: operations.cursorPosition(), attempts: 0, errorDistance: distance(operations.cursorPosition(), initial))
                    restorationVerified = verification.verified
                    if !apiSuccess { restoreAPIResult = "FAILED" }
                } else {
                    suppressedReason = initial == nil ? "INITIAL_CURSOR_UNAVAILABLE" : "TARGET_DISPLAY_UNAVAILABLE"
                    restoreAPIResult = initial == nil ? "SUPPRESSED_INITIAL_CURSOR_UNAVAILABLE" : "SUPPRESSED_TARGET_DISPLAY_UNAVAILABLE"
                }
            } else {
                suppressedReason = acknowledgement == .timedOut ? "ACKNOWLEDGEMENT_TIMEOUT" : "ACKNOWLEDGEMENT_UNAVAILABLE"
                restoreAPIResult = acknowledgement == .timedOut ? "SUPPRESSED_ACKNOWLEDGEMENT_TIMEOUT" : "SUPPRESSED_ACKNOWLEDGEMENT_UNAVAILABLE"
            }
            if suppressedReason != nil { phase = .restoreSuppressed }
        } else {
            // A failed/unverified relocation never posts a mouse button event.
            if shouldRestoreToMain, let initial, Self.isPointWithinActiveDisplays(initial), operations.warpCursor(to: initial) {
                restoreAttempted = true
                restoreAPIResult = "SUCCESS"
                restorationVerified = verifyCursor(at: initial).verified
            } else if !shouldRestoreToMain {
                restoreAPIResult = "NOT_REQUIRED_CURSOR_ON_TOUCHSCREEN"
                restorationVerified = true
            } else {
                restoreAPIResult = initial == nil ? "SUPPRESSED_INITIAL_CURSOR_UNAVAILABLE" : "FAILED"
            }
            phase = .failedDegraded
        }

        if concealment == "SUCCESS" { visibilityRestoreResult = operations.showCursor(at: concealmentPoint) }
        let final = operations.cursorPosition()
        let finalDisplacement = distance(final, initial)
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000.0
        let frontmostPIDAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let classification: String
        if !relocationVerification.verified { classification = relocationAPIResult == "SUCCESS" ? "RELOCATION_READBACK_UNVERIFIED" : "RELOCATION_FAILED" }
        else if !downCreated || !upCreated { classification = "MOUSE_EVENT_CREATION_FAILED" }
        else if !downPosted || !upPosted { classification = "MOUSE_EVENT_POST_FAILED" }
        else if observationUnavailable { classification = "RESTORATION_SUPPRESSED_OBSERVATION_UNAVAILABLE" }
        else if acknowledgement == .unavailable { classification = "ACKNOWLEDGEMENT_UNAVAILABLE" }
        else if acknowledgement == .timedOut { classification = "ACKNOWLEDGEMENT_TIMEOUT" }
        else if interference { classification = "RESTORATION_SUPPRESSED_PHYSICAL_INTERFERENCE" }
        else if restoreAttempted && !restorationVerified { classification = "RESTORATION_READBACK_UNVERIFIED" }
        else if restorationVerified { classification = "CLICK_ACKNOWLEDGED_AND_RESTORED" }
        else { classification = "CLICK_ACKNOWLEDGED_RESTORATION_SUPPRESSED" }
        if restorationVerified { phase = .restored }
        else if classification == "MOUSE_EVENT_CREATION_FAILED" || classification == "MOUSE_EVENT_POST_FAILED" || classification == "RESTORATION_READBACK_UNVERIFIED" { phase = .failedDegraded }

        let result = PointerTransactionResult(
            initialCursor: initial, interactionPoint: point, visualConcealmentAttempted: true,
            visualConcealmentResult: concealment, visibilityRestoreResult: visibilityRestoreResult,
            relocationAPIResult: relocationAPIResult, relocationVerification: relocationVerification,
            mouseDownCreated: downCreated, mouseDownPosted: downPosted, mouseUpCreated: upCreated,
            mouseUpPosted: upPosted, mouseUpAcknowledgement: acknowledgement,
            physicalMouseInterferenceDetected: interference, observationUnavailable: observationUnavailable,
            restoreAttempted: restoreAttempted, restorationSuppressedReason: suppressedReason,
            restoreAPIResult: restoreAPIResult, finalCursor: final, finalDisplacement: finalDisplacement,
            restorationVerified: restorationVerified && finalDisplacement.map { $0 <= displacementTolerance } == true,
            transactionDurationMs: elapsedMs, finalPhase: phase, classification: classification
        )
        printEvidence(result, appName: appName, windowUnderTouch: windowUnderTouch, frontmostPIDBefore: frontmostPIDBefore, frontmostPIDAfter: frontmostPIDAfter)
        return result
    }

    private func windowDescription(at point: CGPoint) -> String {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return "unavailable" }
        for window in windows {
            guard let boundsObject = window[kCGWindowBounds as String] as? NSDictionary else { continue }
            let boundsDictionary = boundsObject as CFDictionary
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds), bounds.contains(point) else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? "unknown app"
            let title = window[kCGWindowName as String] as? String ?? "untitled window"
            let pid = window[kCGWindowOwnerPID as String].map { String(describing: $0) } ?? "unknown PID"
            return "\(owner) / \(title) (PID \(pid))"
        }
        return "no on-screen window"
    }

    private func verifyCursor(at target: CGPoint) -> PointerCursorVerification {
        var readback: CGPoint?
        var attempts = 0
        for attempt in 1...relocationAttemptLimit {
            attempts = attempt
            readback = operations.cursorPosition()
            if distance(readback, target).map({ $0 <= displacementTolerance }) == true { break }
            if attempt < relocationAttemptLimit { operations.advanceCursorVerification() }
        }
        let error = distance(readback, target)
        return PointerCursorVerification(verified: error.map { $0 <= displacementTolerance } == true, finalPoint: readback, attempts: attempts, errorDistance: error)
    }

    private func distance(_ a: CGPoint?, _ b: CGPoint?) -> Double? {
        guard let a, let b else { return nil }
        return hypot(Double(a.x - b.x), Double(a.y - b.y))
    }

    private func printEvidence(_ result: PointerTransactionResult, appName: String?, windowUnderTouch: String, frontmostPIDBefore: pid_t?, frontmostPIDAfter: pid_t?) {
        guard Self.enableEvidencePrinting else { return }
        func point(_ p: CGPoint?) -> String {
            guard let p else { return "unavailable" }
            return String(format: "(%.1f, %.1f)", p.x, p.y)
        }
        let displacement = result.finalDisplacement.map { String(format: "%.2f pt", $0) } ?? "unavailable"
        let relocationDistance = result.relocationVerification.errorDistance.map { String(format: "%.2f pt", $0) } ?? "unavailable"
        print("""

        TRANSIENT POINTER INTERACTION EVIDENCE
        App under touch: \(appName ?? "Unknown")
        Requested touch target: \(point(result.interactionPoint))
        Original cursor point: \(point(result.initialCursor))
        App/window under touch: \(windowUnderTouch)
        Frontmost app PID before delivery: \(frontmostPIDBefore.map(String.init) ?? "unavailable")
        Cursor concealment result: \(result.visualConcealmentResult)
        Relocation API result: \(result.relocationAPIResult)
        Relocation verified: \(result.relocationVerification.verified ? "YES" : "NO")
        Relocation readback: \(point(result.relocationVerification.finalPoint)) (error: \(relocationDistance), attempts: \(result.relocationVerification.attempts))
        MouseDown created/posted: \(result.mouseDownCreated ? "YES" : "NO")/\(result.mouseDownPosted ? "YES" : "NO")
        MouseUp created/posted: \(result.mouseUpCreated ? "YES" : "NO")/\(result.mouseUpPosted ? "YES" : "NO")
        Own marked mouseUp acknowledgement observed: \(result.mouseUpAcknowledgement == .observed ? "YES" : "NO") (\(result.mouseUpAcknowledgement.rawValue))
        Physical interference detected: \(result.physicalMouseInterferenceDetected ? "YES" : "NO")
        Observation unavailable: \(result.observationUnavailable ? "YES" : "NO")
        Restoration requested: \(result.restoreAttempted ? "YES" : "NO")
        Restoration suppressed: \(result.restorationSuppressedReason == nil ? "NO" : "YES") (\(result.restorationSuppressedReason ?? "none"))
        Restoration API result: \(result.restoreAPIResult)
        Final cursor point: \(point(result.finalCursor))
        Final displacement from original: \(displacement)
        Restoration verified: \(result.restorationVerified ? "YES" : "NO")
        Cursor visibility restoration result: \(result.visibilityRestoreResult)
        Frontmost app PID after delivery: \(frontmostPIDAfter.map(String.init) ?? "unavailable")
        Transaction duration: \(String(format: "%.3f ms", result.transactionDurationMs))
        Final transaction classification: \(result.classification)
        Final transaction phase: \(result.finalPhase.rawValue)
        """)
        fflush(stdout)
    }
}

/// Owns the listen-only observation tap. Synthetic events carry a private marker;
/// marked mouseUp advances an acknowledgement counter but never physical activity.
public final class CoreGraphicsPointerTransactionOperations: PointerTransactionOperating {
    private let condition = NSCondition()
    private var generation: UInt64 = 0
    private var acknowledgementGeneration: UInt64 = 0
    private var eventTap: CFMachPort?
    private var ready = false
    private var starting = false
    private let marker: Int64 = 0x54425054584E
    private var inMomentumScrollStream = false
    private var inDirectScrollStream = false
    private var lastRecordedPhysicalCursor: CGPoint? = nil

    public init() {}

    public func prepareForTransactions() {
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0.0
        condition.lock()
        if lastRecordedPhysicalCursor == nil {
            lastRecordedPhysicalCursor = cursorPosition()
        }
        guard !ready, !starting else { condition.unlock(); return }
        starting = true
        condition.unlock()
        let readySemaphore = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [weak self] in
            guard let self else { readySemaphore.signal(); return }
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: Self.mouseEventMask, callback: Self.eventTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else {
                self.condition.lock(); self.starting = false; self.condition.broadcast(); self.condition.unlock()
                readySemaphore.signal(); return
            }
            self.condition.lock(); self.eventTap = tap; self.ready = true; self.starting = false; self.condition.broadcast(); self.condition.unlock()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            readySemaphore.signal()
            CFRunLoopRun()
        }
        _ = readySemaphore.wait(timeout: .now() + 0.2)
    }

    public var canObservePhysicalMouse: Bool {
        condition.lock(); defer { condition.unlock() }
        return ready && eventTap.map(CFMachPortIsValid) == true
    }
    public var physicalMouseGeneration: UInt64 { pointerActivitySnapshot().generation }
    public func pointerActivitySnapshot() -> PointerMouseActivitySnapshot {
        condition.lock(); defer { condition.unlock() }
        return PointerMouseActivitySnapshot(isObservable: ready && eventTap.map(CFMachPortIsValid) == true, generation: generation)
    }
    public func cursorPosition() -> CGPoint? { CGEvent(source: nil)?.location }
    public func lastPhysicalCursorPosition() -> CGPoint? {
        condition.lock(); defer { condition.unlock() }
        return lastRecordedPhysicalCursor ?? cursorPosition()
    }
    public func advanceCursorVerification() { CFRunLoopRunInMode(.defaultMode, 0.002, true) }
    public func hideCursor(at point: CGPoint) -> String {
        let error = CGDisplayHideCursor(display(containing: point))
        return error == .success ? "SUCCESS" : "FAILED(CGError \(error.rawValue))"
    }
    public func showCursor(at point: CGPoint) -> String {
        let error = CGDisplayShowCursor(display(containing: point))
        return error == .success ? "SUCCESS" : "FAILED(CGError \(error.rawValue))"
    }
    private func display(containing point: CGPoint) -> CGDirectDisplayID {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return CGMainDisplayID() }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return CGMainDisplayID() }
        return displays.first(where: { CGDisplayBounds($0).contains(point) }) ?? CGMainDisplayID()
    }
    public func warpCursor(to point: CGPoint) -> Bool { CGWarpMouseCursorPosition(point) == .success }
    public func makeMouseEvent(type: CGEventType, at point: CGPoint) -> PointerMouseEvent? {
        let button: CGMouseButton?
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved:
            button = .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            button = .right
        default:
            button = nil
        }
        guard let button,
              let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return PointerMouseEvent(nativeEvent: event, type: type)
    }
    public func markedMouseUpAcknowledgementToken() -> UInt64? {
        condition.lock(); defer { condition.unlock() }
        guard ready, eventTap.map(CFMachPortIsValid) == true else { return nil }
        return acknowledgementGeneration
    }
    public func waitForMarkedMouseUp(after token: UInt64, timeout: TimeInterval) -> PointerMouseUpAcknowledgement {
        waitForMarkedMouseUps(after: token, count: 1, timeout: timeout)
    }
    public func waitForMarkedMouseUps(after token: UInt64, count: Int, timeout: TimeInterval) -> PointerMouseUpAcknowledgement {
        let deadline = Date(timeIntervalSinceNow: timeout)
        let targetAcknowledgement = token &+ UInt64(max(1, count))
        condition.lock(); defer { condition.unlock() }
        guard ready, eventTap.map(CFMachPortIsValid) == true else { return .unavailable }
        while acknowledgementGeneration < targetAcknowledgement {
            if !condition.wait(until: deadline) { return .timedOut }
            guard ready, eventTap.map(CFMachPortIsValid) == true else { return .unavailable }
        }
        return .observed
    }
    public func post(_ event: PointerMouseEvent) {
        event.nativeEvent?.setIntegerValueField(.mouseEventClickState, value: event.clickState)
        event.nativeEvent?.post(tap: .cghidEventTap)
    }

    @discardableResult
    public func postScrollWheel(at point: CGPoint, deltaY: Double, phase: UInt32, momentumPhase: UInt32) -> Bool {
        postScrollWheel2D(at: point, deltaX: 0, deltaY: deltaY, phase: phase, momentumPhase: momentumPhase)
    }

    @discardableResult
    public func postScrollWheel2D(at point: CGPoint, deltaX: Double, deltaY: Double, phase: UInt32, momentumPhase: UInt32) -> Bool {
        // Translate TouchBridge stream markers into native macOS NSEvent phases:
        // Direct scroll: phase 1 (.began) -> 2 (.changed) -> 4 (.ended)
        // Momentum scroll: momentumPhase 1 (.began) -> 2 (.changed) -> 3 (.ended)
        if phase == 1 {
            inDirectScrollStream = true
            inMomentumScrollStream = false
            return emitNativeScrollEvent(at: point, deltaX: 0, deltaY: 0, scrollPhase: 1, momentumPhase: 0)
        } else if phase == 2 {
            inDirectScrollStream = true
            return emitNativeScrollEvent(at: point, deltaX: deltaX, deltaY: deltaY, scrollPhase: 2, momentumPhase: 0)
        } else if momentumPhase == 2 {
            if inDirectScrollStream {
                inDirectScrollStream = false
                _ = emitNativeScrollEvent(at: point, deltaX: 0, deltaY: 0, scrollPhase: 4, momentumPhase: 0)
            }
            let effectiveMomentumPhase: UInt32 = inMomentumScrollStream ? 2 : 1
            inMomentumScrollStream = true
            return emitNativeScrollEvent(at: point, deltaX: deltaX, deltaY: deltaY, scrollPhase: 0, momentumPhase: effectiveMomentumPhase)
        } else if phase == 4 {
            if inMomentumScrollStream {
                inMomentumScrollStream = false
                inDirectScrollStream = false
                // Native macOS CGMomentumScrollPhase.end is 3 (maps to NSEvent.Phase.ended = 8)
                return emitNativeScrollEvent(at: point, deltaX: 0, deltaY: 0, scrollPhase: 0, momentumPhase: 3)
            } else {
                inDirectScrollStream = false
                return emitNativeScrollEvent(at: point, deltaX: 0, deltaY: 0, scrollPhase: 4, momentumPhase: 0)
            }
        }
        return emitNativeScrollEvent(at: point, deltaX: deltaX, deltaY: deltaY, scrollPhase: phase, momentumPhase: momentumPhase)
    }

    private func emitNativeScrollEvent(
        at point: CGPoint,
        deltaX: Double,
        deltaY: Double,
        scrollPhase: UInt32,
        momentumPhase: UInt32
    ) -> Bool {
        let pixelsY = Int32(round(deltaY * 1.5))
        let pixelsX = Int32(round(deltaX * 1.5))
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: pixelsY,
            wheel2: pixelsX,
            wheel3: 0
        ) else { return false }
        event.location = point
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pixelsY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(pixelsX))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY * 1.5)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltaX * 1.5)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase))
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
        return true
    }

    private func recordExternalMouseEvent(at point: CGPoint) {
        condition.lock(); generation &+= 1; lastRecordedPhysicalCursor = point; condition.broadcast(); condition.unlock()
    }
    private func recordMarkedMouseUp() {
        condition.lock(); acknowledgementGeneration &+= 1; condition.broadcast(); condition.unlock()
    }
    private static let mouseEventMask: CGEventMask = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()
    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<CoreGraphicsPointerTransactionOperations>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = owner.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            owner.condition.lock(); owner.ready = owner.eventTap.map(CFMachPortIsValid) == true; owner.condition.broadcast(); owner.condition.unlock()
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == owner.marker {
            if type == .leftMouseUp || type == .rightMouseUp { owner.recordMarkedMouseUp() }
        } else {
            owner.recordExternalMouseEvent(at: event.location)
        }
        return Unmanaged.passUnretained(event)
    }
}
