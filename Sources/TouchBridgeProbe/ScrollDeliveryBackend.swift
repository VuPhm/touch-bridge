import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

public enum ScrollBackendClassification: String, Codable {
    case nativeCursorIndependent = "NATIVE_CURSOR_INDEPENDENT"
    case compatibilityCursorTransaction = "COMPATIBILITY_CURSOR_TRANSACTION"
}

public protocol ScrollDeliveryBackend: AnyObject {
    var classification: ScrollBackendClassification { get }
    var diagnosticName: String { get }
    var writeFailureCount: Int { get }
    var totalOperationsCount: Int { get }

    func begin(session: InteractionSession, touchPoint: CGPoint) -> Bool
    func update(deltaY: Double, velocityY: Double, currentTouchPoint: CGPoint)
    func momentumUpdate(deltaY: Double, velocityY: Double)
    func end(session: InteractionSession)
    func cancel(session: InteractionSession, reason: String)
}

// MARK: - Backend A: AX Semantic Scroll (Preferred)

public final class AXSemanticScrollBackend: ScrollDeliveryBackend {
    public let classification: ScrollBackendClassification = .nativeCursorIndependent
    public let diagnosticName: String = "AX_SEMANTIC"

    public let scrollBarElement: AXUIElement
    public let scrollAreaElement: AXUIElement?
    public let applicationName: String
    public let targetPID: pid_t
    public let windowTitle: String?
    public let windowBounds: CGRect?
    public let scrollAreaHeight: Double
    public let contentHeight: Double?
    public let initialValue: Double
    public let minValue: Double
    public let maxValue: Double

    public private(set) var currentValue: Double
    public private(set) var accumulatedDeltaY: Double = 0.0
    public private(set) var writeFailureCount: Int = 0
    public private(set) var totalOperationsCount: Int = 0
    public private(set) var coalescedSkipCount: Int = 0
    public private(set) var isCompleted: Bool = false

    /// Optional hook for deterministic unit testing.
    public var customValueSetter: ((Double) -> AXError)? = nil

    public init(
        scrollBarElement: AXUIElement,
        scrollAreaElement: AXUIElement?,
        applicationName: String,
        targetPID: pid_t,
        windowTitle: String? = nil,
        windowBounds: CGRect? = nil,
        scrollAreaHeight: Double = 500.0,
        contentHeight: Double? = nil,
        initialValue: Double = 0.0,
        minValue: Double = 0.0,
        maxValue: Double = 1.0
    ) {
        self.scrollBarElement = scrollBarElement
        self.scrollAreaElement = scrollAreaElement
        self.applicationName = applicationName
        self.targetPID = targetPID
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
        self.scrollAreaHeight = scrollAreaHeight
        self.contentHeight = contentHeight
        self.initialValue = initialValue
        self.minValue = minValue
        self.maxValue = maxValue <= minValue ? (minValue + 1.0) : maxValue
        self.currentValue = initialValue
    }

    public convenience init(context: AXInteractionContext, initialPoint: CGPoint) {
        let sb = context.scrollBarElement ?? context.hitElement
        let sa = context.scrollAreaElement
        let app = context.applicationName
        let pid = context.pid
        let height = context.scrollAreaHeight

        var initVal = context.scrollCapability.verticalValue ?? 0.0
        var minVal = context.scrollCapability.verticalMin ?? 0.0
        var maxVal = context.scrollCapability.verticalMax ?? 1.0

        var valRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &valRef) == .success,
           let num = valRef as? NSNumber {
            initVal = num.doubleValue
        }
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sb, kAXMinValueAttribute as CFString, &minRef) == .success,
           let num = minRef as? NSNumber {
            minVal = num.doubleValue
        }
        var maxRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sb, kAXMaxValueAttribute as CFString, &maxRef) == .success,
           let num = maxRef as? NSNumber {
            maxVal = num.doubleValue
        }
        if maxVal <= minVal {
            maxVal = minVal + 1.0
        }

        var cHeight: Double? = nil
        if let sa = sa {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(sa, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for c in children {
                    var rRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &rRef)
                    if (rRef as? String) != "AXScrollBar" {
                        var szRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(c, kAXSizeAttribute as CFString, &szRef) == .success,
                           let s = szRef, CFGetTypeID(s) == AXValueGetTypeID() {
                            var sz = CGSize.zero
                            AXValueGetValue(s as! AXValue, .cgSize, &sz)
                            if sz.height > 10 { cHeight = Double(sz.height); break }
                        }
                    }
                }
            }
        }

        self.init(
            scrollBarElement: sb,
            scrollAreaElement: sa,
            applicationName: app,
            targetPID: pid,
            windowTitle: context.hitNode.title,
            windowBounds: nil,
            scrollAreaHeight: max(100.0, height),
            contentHeight: cHeight,
            initialValue: initVal,
            minValue: minVal,
            maxValue: maxVal
        )
    }

    public func begin(session: InteractionSession, touchPoint: CGPoint) -> Bool {
        isCompleted = false
        currentValue = initialValue
        accumulatedDeltaY = 0.0
        totalOperationsCount = 1

        let role = scrollAreaElement != nil ? "AXScrollArea" : "AXScrollBar"
        TouchBridgeLogger.info(
            .semantic,
            "SCROLL_BACKEND: AX_SEMANTIC app=\"\(applicationName)\" window=\"\(windowTitle ?? "")\" role=\"\(role)\" initialValue=\(String(format: "%.3f", initialValue)) range=[\(minValue)..\(maxValue)]"
        )
        session.panActionResult = "NATIVE_CURSOR_INDEPENDENT (AX_SEMANTIC) on [\(applicationName)]: initial=\(String(format: "%.3f", initialValue))"
        return true
    }

    public func update(deltaY: Double, velocityY: Double, currentTouchPoint: CGPoint) {
        guard !isCompleted else { return }
        accumulatedDeltaY += deltaY

        let effectiveTrack: Double
        if let ch = contentHeight, ch > scrollAreaHeight + 10.0 {
            effectiveTrack = ch - scrollAreaHeight
        } else {
            effectiveTrack = max(200.0, scrollAreaHeight * 1.5)
        }

        // Natural touch scroll: dragging finger UP (deltaY < 0) reveals content below (value increases)
        let normalizedDelta = -deltaY / effectiveTrack * (maxValue - minValue)
        let targetValue = min(maxValue, max(minValue, currentValue + normalizedDelta))

        if abs(targetValue - currentValue) < 0.0005 {
            coalescedSkipCount += 1
            return
        }

        dispatchWrite(value: targetValue)
    }

    public func momentumUpdate(deltaY: Double, velocityY: Double) {
        guard !isCompleted else { return }
        let effectiveTrack: Double
        if let ch = contentHeight, ch > scrollAreaHeight + 10.0 {
            effectiveTrack = ch - scrollAreaHeight
        } else {
            effectiveTrack = max(200.0, scrollAreaHeight * 1.5)
        }
        let normalizedDelta = -deltaY / effectiveTrack * (maxValue - minValue)
        let targetValue = min(maxValue, max(minValue, currentValue + normalizedDelta))
        if abs(targetValue - currentValue) < 0.0005 {
            coalescedSkipCount += 1
            return
        }
        dispatchWrite(value: targetValue)
    }

    private func dispatchWrite(value: Double) {
        totalOperationsCount += 1
        let err: AXError
        if let customSetter = customValueSetter {
            err = customSetter(value)
        } else {
            err = AXUIElementSetAttributeValue(scrollBarElement, kAXValueAttribute as CFString, value as CFTypeRef)
        }

        if err == .success {
            currentValue = value
        } else {
            writeFailureCount += 1
            TouchBridgeLogger.warning(.semantic, "AX scroll write failed (error \(err.rawValue)). Backend remains latched; cursor unchanged.")
        }
    }

    public func end(session: InteractionSession) {
        guard !isCompleted else { return }
        isCompleted = true
        let summary = "NATIVE_CURSOR_INDEPENDENT (AX_SEMANTIC) on [\(applicationName)]: initial=\(String(format: "%.3f", initialValue)), terminal=\(String(format: "%.3f", currentValue)), writes=\(totalOperationsCount), failures=\(writeFailureCount)"
        session.panActionResult = summary
        TouchBridgeLogger.info(
            .semantic,
            "AX_SEMANTIC_SCROLL_COMPLETED app=\"\(applicationName)\" window=\"\(windowTitle ?? "")\" initial=\(String(format: "%.3f", initialValue)) terminal=\(String(format: "%.3f", currentValue)) writes=\(totalOperationsCount) failures=\(writeFailureCount)"
        )
    }

    public func cancel(session: InteractionSession, reason: String) {
        guard !isCompleted else { return }
        isCompleted = true
        TouchBridgeLogger.info(.semantic, "AX_SEMANTIC scroll cancelled: \(reason)")
    }
}

// MARK: - Backend B: Transient Pointer Scroll (Compatibility Fallback)

public final class TransientPointerScrollBackend: ScrollDeliveryBackend {
    public let classification: ScrollBackendClassification = .compatibilityCursorTransaction
    public let diagnosticName: String = "TRANSIENT_POINTER_FALLBACK"

    public let operations: PointerTransactionOperating
    public let anchorPoint: CGPoint
    public private(set) var initialPhysicalCursor: CGPoint?
    public private(set) var relocated: Bool = false
    public private(set) var guardSnapshot: PointerTransactionGuard?
    public private(set) var restorationSuppressedReason: String?
    public private(set) var totalOperationsCount: Int = 0
    public private(set) var writeFailureCount: Int = 0
    public private(set) var isCompleted: Bool = false
    public private(set) var physicalMouseInterferenceDetected: Bool = false

    public init(
        operations: PointerTransactionOperating = CoreGraphicsPointerTransactionOperations(),
        anchorPoint: CGPoint
    ) {
        self.operations = operations
        self.anchorPoint = anchorPoint
        operations.prepareForTransactions()
    }

    public func begin(session: InteractionSession, touchPoint: CGPoint) -> Bool {
        isCompleted = false
        initialPhysicalCursor = operations.cursorPosition()
        let snapshot = operations.pointerActivitySnapshot()
        guardSnapshot = PointerTransactionGuard(snapshot: snapshot)

        // Relocate cursor at most once at start if not already at anchor
        if let initPos = initialPhysicalCursor, hypot(initPos.x - anchorPoint.x, initPos.y - anchorPoint.y) < 1.0 {
            relocated = false
        } else {
            relocated = operations.warpCursor(to: anchorPoint)
        }

        // Post began scroll event at fixed anchor
        operations.postScrollWheel(at: anchorPoint, deltaY: 0, phase: 1, momentumPhase: 0)
        totalOperationsCount = 1

        let cursorStr = initialPhysicalCursor.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil"
        TouchBridgeLogger.info(
            .semantic,
            "SCROLL_BACKEND: TRANSIENT_POINTER_FALLBACK initialCursor=\(cursorStr) anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))) relocated=\(relocated)"
        )
        session.panActionResult = "DIRECT_PAN -> CG_SCROLL_WHEEL (transient pointer fallback)"
        return true
    }

    public func update(deltaY: Double, velocityY: Double, currentTouchPoint: CGPoint) {
        guard !isCompleted else { return }
        // Crucial invariant: never move cursor with touch updates. Always post at fixed anchorPoint!
        operations.postScrollWheel(at: anchorPoint, deltaY: deltaY, phase: 2, momentumPhase: 0)
        totalOperationsCount += 1
    }

    public func momentumUpdate(deltaY: Double, velocityY: Double) {
        guard !isCompleted else { return }
        // During momentum, cursor remains stationary at anchorPoint
        operations.postScrollWheel(at: anchorPoint, deltaY: deltaY, phase: 0, momentumPhase: 2)
        totalOperationsCount += 1
    }

    public func end(session: InteractionSession) {
        guard !isCompleted else { return }
        isCompleted = true
        operations.postScrollWheel(at: anchorPoint, deltaY: 0, phase: 4, momentumPhase: 0)

        let appName = session.context?.applicationName ?? "Application"
        let cursorStr = initialPhysicalCursor.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil"
        var restoreStatus = "no_relocation"

        if relocated, let initial = initialPhysicalCursor {
            let decision = guardSnapshot?.restoreDecision(using: operations) ?? .observationUnavailable
            if decision == .safe {
                _ = operations.warpCursor(to: initial)
                restoreStatus = "RESTORED"
                TouchBridgeLogger.info(.semantic, "Transient pointer scroll restored cursor to (\(Int(initial.x)), \(Int(initial.y))).")
                session.panActionResult = "COMPATIBILITY_CURSOR_TRANSACTION (TRANSIENT_POINTER_FALLBACK) on [\(appName)]: anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))), events=\(totalOperationsCount), restored=true"
            } else {
                physicalMouseInterferenceDetected = (decision == .physicalMouseInterference)
                restorationSuppressedReason = "\(decision)"
                restoreStatus = "SUPPRESSED_\(decision)"
                TouchBridgeLogger.info(.semantic, "Transient pointer scroll restore suppressed: \(decision).")
                session.panActionResult = "COMPATIBILITY_CURSOR_TRANSACTION (TRANSIENT_POINTER_FALLBACK) on [\(appName)]: anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))), events=\(totalOperationsCount), restored=false (\(decision))"
            }
        } else {
            session.panActionResult = "COMPATIBILITY_CURSOR_TRANSACTION (TRANSIENT_POINTER_FALLBACK) on [\(appName)]: anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))), events=\(totalOperationsCount), no_relocation"
        }

        TouchBridgeLogger.info(
            .semantic,
            "TRANSIENT_POINTER_FALLBACK_COMPLETED initialCursor=\(cursorStr) anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))) relocated=\(relocated) interference=\(physicalMouseInterferenceDetected) restoration=\(restoreStatus)"
        )
    }

    public func cancel(session: InteractionSession, reason: String) {
        guard !isCompleted else { return }
        isCompleted = true
        operations.postScrollWheel(at: anchorPoint, deltaY: 0, phase: 4, momentumPhase: 0)
        if relocated, let initial = initialPhysicalCursor {
            let decision = guardSnapshot?.restoreDecision(using: operations) ?? .observationUnavailable
            if decision == .safe {
                _ = operations.warpCursor(to: initial)
            }
        }
    }
}

// MARK: - Hybrid Scroll Delivery Coordinator

public final class HybridScrollDeliveryCoordinator {
    public static let shared = HybridScrollDeliveryCoordinator()

    public var pointerOperations: PointerTransactionOperating
    public var forceFallback: Bool = false
    public var axCustomValueSetter: ((Double) -> AXError)? = nil

    public init(pointerOperations: PointerTransactionOperating = CoreGraphicsPointerTransactionOperations()) {
        self.pointerOperations = pointerOperations
        self.pointerOperations.prepareForTransactions()
    }

    public func resolveBackend(for session: InteractionSession, at point: CGPoint) -> ScrollDeliveryBackend {
        if !forceFallback, let axBackend = resolveAXBackend(for: session, at: point) {
            return axBackend
        }
        return TransientPointerScrollBackend(operations: pointerOperations, anchorPoint: point)
    }

    public func resolveAXBackend(for session: InteractionSession, at point: CGPoint) -> AXSemanticScrollBackend? {
        if let ctx = session.context,
           ctx.scrollBarElement != nil,
           ctx.scrollCapability.isVerticalValueSettable {
            let backend = AXSemanticScrollBackend(context: ctx, initialPoint: point)
            backend.customValueSetter = axCustomValueSetter
            return backend
        }

        guard AXPermissionManager.shared.isTrusted() else {
            return nil
        }

        let (elemOpt, _, err) = AXSemanticEngine.shared.probeElementAt(globalCG: point)
        guard err == .success, let elem = elemOpt else {
            return nil
        }

        let context = AXCapabilityInspector.shared.discoverContext(element: elem, maxAncestors: 8)
        guard context.scrollBarElement != nil,
              context.scrollCapability.isVerticalValueSettable else {
            return nil
        }

        session.applyAXEnrichment(context)
        let backend = AXSemanticScrollBackend(context: context, initialPoint: point)
        backend.customValueSetter = axCustomValueSetter
        return backend
    }
}
