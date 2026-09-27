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
    func prepareForTransactions()
    func cursorPosition() -> CGPoint?
    func advanceCursorVerification()
    func hideCursor(at point: CGPoint) -> String
    func showCursor(at point: CGPoint) -> String
    func warpCursor(to point: CGPoint) -> Bool
    func makeMouseEvent(type: CGEventType, at point: CGPoint) -> PointerMouseEvent?
    func markedMouseUpAcknowledgementToken() -> UInt64?
    func waitForMarkedMouseUp(after token: UInt64, timeout: TimeInterval) -> PointerMouseUpAcknowledgement
    func post(_ event: PointerMouseEvent)
}

public extension PointerTransactionOperating {
    func prepareForTransactions() {}
    func advanceCursorVerification() { CFRunLoopRunInMode(.defaultMode, 0.002, true) }
    func pointerActivitySnapshot() -> PointerMouseActivitySnapshot {
        PointerMouseActivitySnapshot(isObservable: canObservePhysicalMouse, generation: physicalMouseGeneration)
    }
    func markedMouseUpAcknowledgementToken() -> UInt64? { canObservePhysicalMouse ? physicalMouseGeneration : nil }
    func waitForMarkedMouseUp(after token: UInt64, timeout: TimeInterval) -> PointerMouseUpAcknowledgement { .unavailable }
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
        let started = ProcessInfo.processInfo.systemUptime
        let frontmostPIDBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windowUnderTouch = windowDescription(at: point)
        let initial = operations.cursorPosition()
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
            let down = operations.makeMouseEvent(type: .leftMouseDown, at: point)
            let up = operations.makeMouseEvent(type: .leftMouseUp, at: point)
            downCreated = down != nil
            upCreated = up != nil
            if let down, let up {
                operations.post(down)
                downPosted = true
                operations.post(up)
                upPosted = true
                phase = .clickPosted
                if let acknowledgementToken {
                    acknowledgement = operations.waitForMarkedMouseUp(after: acknowledgementToken, timeout: acknowledgementTimeout)
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
            } else if !downCreated || !upCreated {
                // No button event was posted, so there is no asynchronous click
                // transaction to acknowledge before restoring the cursor.
                if let initial {
                    restoreAttempted = true
                    let apiSuccess = operations.warpCursor(to: initial)
                    restoreAPIResult = apiSuccess ? "SUCCESS" : "FAILED"
                    restorationVerified = apiSuccess && verifyCursor(at: initial).verified
                } else {
                    suppressedReason = "INITIAL_CURSOR_UNAVAILABLE"
                    restoreAPIResult = "SUPPRESSED_INITIAL_CURSOR_UNAVAILABLE"
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
                } else if let initial {
                    restoreAttempted = true
                    let apiSuccess = operations.warpCursor(to: initial)
                    restoreAPIResult = apiSuccess ? "SUCCESS" : "FAILED"
                    let verification = apiSuccess ? verifyCursor(at: initial) : PointerCursorVerification(verified: false, finalPoint: operations.cursorPosition(), attempts: 0, errorDistance: distance(operations.cursorPosition(), initial))
                    restorationVerified = verification.verified
                    if !apiSuccess { restoreAPIResult = "FAILED" }
                } else {
                    suppressedReason = "INITIAL_CURSOR_UNAVAILABLE"
                    restoreAPIResult = "SUPPRESSED_INITIAL_CURSOR_UNAVAILABLE"
                }
            } else {
                suppressedReason = acknowledgement == .timedOut ? "ACKNOWLEDGEMENT_TIMEOUT" : "ACKNOWLEDGEMENT_UNAVAILABLE"
                restoreAPIResult = acknowledgement == .timedOut ? "SUPPRESSED_ACKNOWLEDGEMENT_TIMEOUT" : "SUPPRESSED_ACKNOWLEDGEMENT_UNAVAILABLE"
            }
            if suppressedReason != nil { phase = .restoreSuppressed }
        } else {
            // A failed/unverified relocation never posts a mouse button event.
            if let initial, operations.warpCursor(to: initial) {
                restoreAttempted = true
                restoreAPIResult = "SUCCESS"
                restorationVerified = verifyCursor(at: initial).verified
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

    public init() {}

    public func prepareForTransactions() {
        condition.lock()
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
        guard let button: CGMouseButton = type == .leftMouseDown || type == .leftMouseUp ? .left : nil,
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
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock(); defer { condition.unlock() }
        guard ready, eventTap.map(CFMachPortIsValid) == true else { return .unavailable }
        while acknowledgementGeneration <= token {
            if !condition.wait(until: deadline) { return .timedOut }
            guard ready, eventTap.map(CFMachPortIsValid) == true else { return .unavailable }
        }
        return .observed
    }
    public func post(_ event: PointerMouseEvent) { event.nativeEvent?.post(tap: .cghidEventTap) }
    private func recordExternalMouseEvent() {
        condition.lock(); generation &+= 1; condition.broadcast(); condition.unlock()
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
            if type == .leftMouseUp { owner.recordMarkedMouseUp() }
        } else {
            owner.recordExternalMouseEvent()
        }
        return Unmanaged.passUnretained(event)
    }
}
