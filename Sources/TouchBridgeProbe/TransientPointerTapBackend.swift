import Foundation
import CoreGraphics
import Cocoa

public enum TapBackendMode: String, CaseIterable {
    case semantic
    case transientPointer = "transient-pointer"

    public var diagnosticName: String {
        switch self {
        case .semantic: return "SEMANTIC"
        case .transientPointer: return "TRANSIENT_POINTER"
        }
    }
}

public struct PointerTransactionResult {
    public let initialCursor: CGPoint?
    public let interactionPoint: CGPoint
    public let visualConcealmentAttempted: Bool
    public let visualConcealmentResult: String
    public let visibilityRestoreResult: String
    public let relocationResult: String
    public let mouseDownCreated: Bool
    public let mouseDownPosted: Bool
    public let mouseUpCreated: Bool
    public let mouseUpPosted: Bool
    public let physicalMouseInterferenceDetected: Bool
    public let restoreAttempted: Bool
    public let restoreResult: String
    public let finalCursor: CGPoint?
    public let finalDisplacement: Double?
    public let transactionDurationMs: Double
    public let classification: String

    public var succeeded: Bool { relocationResult == "SUCCESS" && mouseDownPosted && mouseUpPosted }
}

/// Narrow injectable boundary around public CoreGraphics cursor and mouse APIs.
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
    func hideCursor(at point: CGPoint) -> String
    func showCursor(at point: CGPoint) -> String
    func warpCursor(to point: CGPoint) -> Bool
    func makeMouseEvent(type: CGEventType, at point: CGPoint) -> PointerMouseEvent?
    func post(_ event: PointerMouseEvent)
}

public extension PointerTransactionOperating {
    func prepareForTransactions() {}
    func pointerActivitySnapshot() -> PointerMouseActivitySnapshot {
        PointerMouseActivitySnapshot(isObservable: canObservePhysicalMouse, generation: physicalMouseGeneration)
    }
}

public enum PointerRestoreDecision: Equatable {
    case safe
    case physicalMouseInterference
    case observationUnavailable
}

/// Snapshots the physical mouse activity generation before TouchBridge changes
/// the cursor, then decides whether restoring the old location remains safe.
public struct PointerTransactionGuard {
    private let startGeneration: UInt64
    private let wasObservingAtStart: Bool

    public init(operations: PointerTransactionOperating) {
        let snapshot = operations.pointerActivitySnapshot()
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
    public init(nativeEvent: CGEvent? = nil) { self.nativeEvent = nativeEvent }
}

public final class TransientPointerTapBackend {
    private let operations: PointerTransactionOperating
    private let displacementTolerance: Double

    public init(operations: PointerTransactionOperating = CoreGraphicsPointerTransactionOperations(), displacementTolerance: Double = 1.0) {
        self.operations = operations
        self.displacementTolerance = displacementTolerance
    }

    public func prepareForTransactions() { operations.prepareForTransactions() }

    @discardableResult
    public func performClick(at point: CGPoint, appName: String? = nil) -> PointerTransactionResult {
        let started = ProcessInfo.processInfo.systemUptime
        let guardState = PointerTransactionGuard(operations: operations)
        let initial = operations.cursorPosition()
        let concealmentPoint = initial ?? point
        let concealment = operations.hideCursor(at: concealmentPoint)
        var downPosted = false
        var upPosted = false
        var downCreated = false
        var upCreated = false
        var interference = false
        var restoreAttempted = false
        var restoreResult = "NOT_NEEDED"
        var relocationResult = "NOT_ATTEMPTED"
        var visibilityRestoreResult = "NOT_REQUIRED"

        if operations.warpCursor(to: point), let warpedPosition = operations.cursorPosition(), hypot(warpedPosition.x - point.x, warpedPosition.y - point.y) <= 1.0 {
            relocationResult = "SUCCESS"
            let down = operations.makeMouseEvent(type: .leftMouseDown, at: point)
            let up = operations.makeMouseEvent(type: .leftMouseUp, at: point)
            downCreated = down != nil
            upCreated = up != nil
            // Both events are prepared before posting the down so an event-creation
            // failure cannot leave a synthetic mouse button logically held.
            if let down, let up {
                operations.post(down)
                downPosted = true // CGEvent.post has no observable result.
                operations.post(up)
                upPosted = true // CGEvent.post has no observable result.
            }
        } else {
            relocationResult = "FAILED"
        }

        let restoreDecision = guardState.restoreDecision(using: operations)
        interference = restoreDecision == .physicalMouseInterference

        if let initial {
            if restoreDecision == .physicalMouseInterference {
                restoreResult = "SUPPRESSED_PHYSICAL_MOUSE_INTERFERENCE_DETECTED"
            } else if restoreDecision == .observationUnavailable {
                restoreResult = "SUPPRESSED_PHYSICAL_MOUSE_OBSERVER_UNAVAILABLE"
            } else {
                restoreAttempted = true
                restoreResult = operations.warpCursor(to: initial) ? "SUCCESS" : "FAILED"
            }
        } else {
            restoreResult = "SUPPRESSED_INITIAL_CURSOR_UNAVAILABLE"
        }

        // hideCursor returns a status string. Only SUCCESS means this transaction owns
        // one hide count, so only that result is balanced with showCursor.
        if concealment == "SUCCESS" {
            visibilityRestoreResult = operations.showCursor(at: concealmentPoint)
        }

        let final = operations.cursorPosition()
        let displacement: Double? = initial.flatMap { start in final.map { Double(hypot($0.x - start.x, $0.y - start.y)) } }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000.0
        let result = PointerTransactionResult(
            initialCursor: initial,
            interactionPoint: point,
            visualConcealmentAttempted: true,
            visualConcealmentResult: concealment,
            visibilityRestoreResult: visibilityRestoreResult,
            relocationResult: relocationResult,
            mouseDownCreated: downCreated,
            mouseDownPosted: downPosted,
            mouseUpCreated: upCreated,
            mouseUpPosted: upPosted,
            physicalMouseInterferenceDetected: interference,
            restoreAttempted: restoreAttempted,
            restoreResult: restoreResult,
            finalCursor: final,
            finalDisplacement: displacement,
            transactionDurationMs: elapsedMs,
            classification: "TRANSIENT_POINTER_CLICK"
        )
        printEvidence(result, appName: appName)
        return result
    }

    private func printEvidence(_ result: PointerTransactionResult, appName: String?) {
        func point(_ p: CGPoint?) -> String {
            guard let p else { return "unavailable" }
            return String(format: "(%.1f, %.1f)", p.x, p.y)
        }
        let displacement = result.finalDisplacement.map { String(format: "%.2f pt", $0) } ?? "unavailable"
        let restored = result.finalDisplacement.map { $0 <= displacementTolerance && result.restoreResult == "SUCCESS" } ?? false
        print("""

        TRANSIENT POINTER INTERACTION EVIDENCE
        App under touch: \(appName ?? "Unknown")
        Calibrated touch point: \(point(result.interactionPoint))
        Initial cursor: \(point(result.initialCursor))
        Visual concealment attempted: \(result.visualConcealmentAttempted ? "YES" : "NO")
        Visual concealment result: \(result.visualConcealmentResult)
        Cursor visibility restore result: \(result.visibilityRestoreResult)
        Relocation result: \(result.relocationResult)
        MouseDown created/posted: \(result.mouseDownCreated ? "YES" : "NO")/\(result.mouseDownPosted ? "YES" : "NO")
        MouseUp created/posted: \(result.mouseUpCreated ? "YES" : "NO")/\(result.mouseUpPosted ? "YES" : "NO")
        Physical mouse interference detected: \(result.physicalMouseInterferenceDetected ? "YES" : "NO")
        \(result.physicalMouseInterferenceDetected ? "PHYSICAL_MOUSE_INTERFERENCE_DETECTED" : "")
        cursorRestoreSuppressed: \(result.restoreResult.hasPrefix("SUPPRESSED") ? "true" : "false")
        Restore attempted: \(result.restoreAttempted ? "YES" : "NO")
        Restore result: \(result.restoreResult)
        Cursor after: \(point(result.finalCursor))
        Final displacement: \(displacement)
        Cursor Position Restored: \(restored ? "YES" : "NO")
        Transaction duration: \(String(format: "%.3f ms", result.transactionDurationMs))
        Classification: \(result.classification)
        """)
        fflush(stdout)
    }
}

/// Observes global mouse activity on a dedicated run loop so synchronous touch
/// transactions can compare a generation counter without delaying their sequence.
public final class CoreGraphicsPointerTransactionOperations: PointerTransactionOperating {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var eventTap: CFMachPort?
    private var ready = false
    private var starting = false
    private let marker: Int64 = 0x54425054584E

    public init() {}

    public func prepareForTransactions() {
        lock.lock()
        guard !ready, !starting else { lock.unlock(); return }
        starting = true
        lock.unlock()

        let readySemaphore = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [weak self] in
            guard let self else { readySemaphore.signal(); return }
            let mask = Self.mouseEventMask
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: Self.eventTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else {
                self.lock.lock(); self.starting = false; self.lock.unlock()
                readySemaphore.signal()
                return
            }
            self.lock.lock(); self.eventTap = tap; self.ready = true; self.starting = false; self.lock.unlock()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            readySemaphore.signal()
            CFRunLoopRun()
        }
        _ = readySemaphore.wait(timeout: .now() + 0.2)
    }

    public var canObservePhysicalMouse: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    public var physicalMouseGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    public func pointerActivitySnapshot() -> PointerMouseActivitySnapshot {
        lock.lock(); defer { lock.unlock() }
        return PointerMouseActivitySnapshot(isObservable: ready, generation: generation)
    }

    public func cursorPosition() -> CGPoint? { CGEvent(source: nil)?.location }

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
        return PointerMouseEvent(nativeEvent: event)
    }

    public func post(_ event: PointerMouseEvent) { event.nativeEvent?.post(tap: .cghidEventTap) }

    private func recordExternalMouseEvent() {
        lock.lock(); generation &+= 1; lock.unlock()
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
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) != owner.marker {
            owner.recordExternalMouseEvent()
        }
        return Unmanaged.passUnretained(event)
    }
}
