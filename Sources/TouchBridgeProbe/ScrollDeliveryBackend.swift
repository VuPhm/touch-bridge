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
    func update(delta: CGVector, velocity: CGVector, currentTouchPoint: CGPoint)
    func momentumUpdate(deltaY: Double, velocityY: Double)
    func momentumUpdate(delta: CGVector, velocity: CGVector)
    func end(session: InteractionSession)
    func cancel(session: InteractionSession, reason: String)
}

public extension ScrollDeliveryBackend {
    func update(delta: CGVector, velocity: CGVector, currentTouchPoint: CGPoint) {
        update(deltaY: Double(delta.dy), velocityY: Double(velocity.dy), currentTouchPoint: currentTouchPoint)
    }
    func momentumUpdate(delta: CGVector, velocity: CGVector) {
        momentumUpdate(deltaY: Double(delta.dy), velocityY: Double(velocity.dy))
    }
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
    private var pendingNormalizedDelta: Double = 0.0

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
        pendingNormalizedDelta = 0.0
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
        pendingNormalizedDelta += normalizedDelta

        let targetValue = min(maxValue, max(minValue, currentValue + pendingNormalizedDelta))

        if abs(targetValue - currentValue) < 0.0005 {
            coalescedSkipCount += 1
            return
        }

        pendingNormalizedDelta = 0.0
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
        pendingNormalizedDelta += normalizedDelta

        let targetValue = min(maxValue, max(minValue, currentValue + pendingNormalizedDelta))
        if abs(targetValue - currentValue) < 0.0005 {
            coalescedSkipCount += 1
            return
        }
        pendingNormalizedDelta = 0.0
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
        if abs(pendingNormalizedDelta) >= 0.0001 {
            let finalValue = min(maxValue, max(minValue, currentValue + pendingNormalizedDelta))
            pendingNormalizedDelta = 0.0
            if finalValue != currentValue {
                dispatchWrite(value: finalValue)
            }
        }
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
    public var isTouchscreenPoint: (CGPoint) -> Bool = { _ in false }
    public private(set) var shouldRestoreToMain: Bool = false
    public private(set) var targetWindowID: CGWindowID?
    public private(set) var targetPID: pid_t?
    public private(set) var initialPhysicalCursor: CGPoint?
    public private(set) var relocated: Bool = false
    public private(set) var guardSnapshot: PointerTransactionGuard?
    public private(set) var restorationSuppressedReason: String?
    public private(set) var totalOperationsCount: Int = 0
    public private(set) var writeFailureCount: Int = 0
    public private(set) var isCompleted: Bool = false
    public private(set) var physicalMouseInterferenceDetected: Bool = false
    public private(set) var directSubpixelRemainderX: Double = 0.0
    public private(set) var directSubpixelRemainderY: Double = 0.0
    private var subpixelRemainder: Double = 0.0
    private var subpixelRemainderX: Double = 0.0
    public private(set) var momentumInputFrameCount: Int = 0
    public private(set) var momentumPostedFrameCount: Int = 0
    public private(set) var momentumPostFailureCount: Int = 0
    public private(set) var momentumBufferedFrameCount: Int = 0
    private var momentumInputDeltaY: Double = 0.0
    private var momentumPostedDeltaY: Double = 0.0
    private var momentumPostedWheel1PixelDeltaY: Int = 0
    private(set) var momentumFrameDiagnostics: [String] = []

    public init(
        operations: PointerTransactionOperating = CoreGraphicsPointerTransactionOperations(),
        anchorPoint: CGPoint
    ) {
        self.operations = operations
        self.anchorPoint = anchorPoint
        operations.prepareForTransactions()
    }

    public func validateTargetWindowStillValid() -> Bool {
        guard let wid = targetWindowID else { return true }
        return AXCapabilityInspector.shared.isWindowStillValid(windowID: wid, expectedPID: targetPID)
    }

    public func begin(session: InteractionSession, touchPoint: CGPoint) -> Bool {
        isCompleted = false
        directSubpixelRemainderX = 0.0
        directSubpixelRemainderY = 0.0
        subpixelRemainder = 0.0
        subpixelRemainderX = 0.0
        momentumInputFrameCount = 0
        momentumPostedFrameCount = 0
        momentumPostFailureCount = 0
        momentumBufferedFrameCount = 0
        momentumInputDeltaY = 0.0
        momentumPostedDeltaY = 0.0
        momentumPostedWheel1PixelDeltaY = 0
        momentumFrameDiagnostics.removeAll(keepingCapacity: true)
        if let hitWindow = session.context?.windowHitInfo ?? AXCapabilityInspector.shared.resolveTopmostWindow(at: touchPoint) {
            targetWindowID = hitWindow.windowID
            targetPID = hitWindow.ownerPID
        } else {
            targetWindowID = nil
            targetPID = session.context?.pid
        }
        initialPhysicalCursor = operations.lastPhysicalCursorPosition() ?? operations.cursorPosition()
        shouldRestoreToMain = initialPhysicalCursor.map { !isTouchscreenPoint($0) } ?? false
        let snapshot = operations.pointerActivitySnapshot()
        guardSnapshot = PointerTransactionGuard(snapshot: snapshot)

        // Relocate cursor at most once at start if not already at anchor
        if let initPos = initialPhysicalCursor, hypot(initPos.x - anchorPoint.x, initPos.y - anchorPoint.y) < 1.0 {
            relocated = false
        } else {
            relocated = operations.warpCursor(to: anchorPoint)
        }

        // Post began scroll event at fixed anchor
        operations.postScrollWheel2D(at: anchorPoint, deltaX: 0, deltaY: 0, phase: 1, momentumPhase: 0)
        totalOperationsCount = 1

        let cursorStr = initialPhysicalCursor.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil"
        TouchBridgeLogger.info(
            .semantic,
            "SCROLL_BACKEND: TRANSIENT_POINTER_FALLBACK initialCursor=\(cursorStr) anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))) relocated=\(relocated) windowID=\(targetWindowID.map(String.init) ?? "none")"
        )
        session.panActionResult = "DIRECT_PAN -> CG_SCROLL_WHEEL (transient pointer fallback)"
        return true
    }

    public func update(deltaY: Double, velocityY: Double, currentTouchPoint: CGPoint) {
        update(delta: CGVector(dx: 0, dy: deltaY), velocity: CGVector(dx: 0, dy: velocityY), currentTouchPoint: currentTouchPoint)
    }

    public func update(delta: CGVector, velocity: CGVector, currentTouchPoint: CGPoint) {
        guard !isCompleted else { return }
        let totalX = Double(delta.dx) + directSubpixelRemainderX
        let totalY = Double(delta.dy) + directSubpixelRemainderY
        let wholeX = round(totalX)
        let wholeY = round(totalY)
        directSubpixelRemainderX = totalX - wholeX
        directSubpixelRemainderY = totalY - wholeY

        guard abs(wholeX) >= 1.0 || abs(wholeY) >= 1.0 else {
            return
        }
        // Crucial invariant: never move cursor with touch updates. Always post at fixed anchorPoint!
        operations.postScrollWheel2D(at: anchorPoint, deltaX: wholeX, deltaY: wholeY, phase: 2, momentumPhase: 0)
        totalOperationsCount += 1
    }

    public func momentumUpdate(deltaY: Double, velocityY: Double) {
        momentumUpdate(delta: CGVector(dx: 0, dy: deltaY), velocity: CGVector(dx: 0, dy: velocityY))
    }

    public func momentumUpdate(delta: CGVector, velocity: CGVector) {
        guard !isCompleted else { return }
        // During momentum, cursor remains stationary at anchorPoint
        let deltaY = Double(delta.dy)
        let deltaX = Double(delta.dx)
        momentumInputFrameCount += 1
        momentumInputDeltaY += deltaY
        let totalY = deltaY + subpixelRemainder
        let wholeY = round(totalY)
        subpixelRemainder = totalY - wholeY
        let totalX = deltaX + subpixelRemainderX
        let wholeX = round(totalX)
        subpixelRemainderX = totalX - wholeX

        if abs(wholeY) >= 1.0 || abs(wholeX) >= 1.0 {
            let posted = operations.postScrollWheel2D(at: anchorPoint, deltaX: wholeX, deltaY: wholeY, phase: 0, momentumPhase: 2)
            if posted {
                totalOperationsCount += 1
                momentumPostedFrameCount += 1
                momentumPostedDeltaY += wholeY
                momentumPostedWheel1PixelDeltaY += Int((wholeY * 1.5).rounded())
            } else {
                momentumPostFailureCount += 1
            }
            momentumFrameDiagnostics.append(
                "f\(momentumInputFrameCount):in=\(String(format: "%.3f", deltaY)),out=\(String(format: "%.0f", wholeY)),wheel1Px=\(Int((wholeY * 1.5).rounded())),post=\(posted),phase=0,momentum=2"
            )
        } else {
            momentumBufferedFrameCount += 1
            momentumFrameDiagnostics.append(
                "f\(momentumInputFrameCount):in=\(String(format: "%.3f", deltaY)),out=0,post=buffered,rem=\(String(format: "%.3f", subpixelRemainder)),phase=0,momentum=2"
            )
        }
    }

    public func end(session: InteractionSession) {
        guard !isCompleted else { return }
        isCompleted = true
        if abs(subpixelRemainder) >= 0.5 {
            let pendingRemainder = subpixelRemainder
            let finalDelta = round(subpixelRemainder)
            subpixelRemainder = 0.0
            if abs(finalDelta) >= 1.0 {
                let posted = operations.postScrollWheel(at: anchorPoint, deltaY: finalDelta, phase: 0, momentumPhase: 2)
                if posted {
                    totalOperationsCount += 1
                    momentumPostedFrameCount += 1
                    momentumPostedDeltaY += finalDelta
                    momentumPostedWheel1PixelDeltaY += Int((finalDelta * 1.5).rounded())
                } else {
                    momentumPostFailureCount += 1
                }
                momentumFrameDiagnostics.append(
                    "tail:in=\(String(format: "%.3f", pendingRemainder)),out=\(String(format: "%.0f", finalDelta)),wheel1Px=\(Int((finalDelta * 1.5).rounded())),post=\(posted),phase=0,momentum=2"
                )
            }
        }
        let endEventPosted = operations.postScrollWheel(at: anchorPoint, deltaY: 0, phase: 4, momentumPhase: 0)
        TouchBridgeLogger.info(
            .semantic,
            "P3-06R3 cg_momentum_delivery: units=pixel scale=1.5 inputFrames=\(momentumInputFrameCount) bufferedFrames=\(momentumBufferedFrameCount) postedFrames=\(momentumPostedFrameCount) postFailures=\(momentumPostFailureCount) inputDeltaY=\(String(format: "%.2f", momentumInputDeltaY)) postedDeltaY=\(String(format: "%.2f", momentumPostedDeltaY)) postedWheel1Px=\(momentumPostedWheel1PixelDeltaY) endPhase=4,endMomentumPhase=0,endPost=\(endEventPosted) finalRemainder=\(String(format: "%.2f", subpixelRemainder)) frames=[\(momentumFrameDiagnostics.joined(separator: ";"))]"
        )

        let appName = session.context?.applicationName ?? "Application"
        let cursorStr = initialPhysicalCursor.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil"
        var restoreStatus = "no_relocation"

        if relocated, shouldRestoreToMain, let initial = initialPhysicalCursor, TransientPointerTapBackend.isPointWithinActiveDisplays(initial) {
            let decision = guardSnapshot?.restoreDecision(using: operations) ?? .observationUnavailable
            if decision == .safe {
                _ = operations.warpCursor(to: initial)
                restoreStatus = "RESTORED"
                TouchBridgeLogger.info(.semantic, "Transient pointer scroll restored cursor to (\(Int(initial.x)), \(Int(initial.y))).")
                TouchBridgeLogger.info(.semantic, "P3-06R2 cursor_restore: restored exactly_once=true.")
                session.panActionResult = "COMPATIBILITY_CURSOR_TRANSACTION (TRANSIENT_POINTER_FALLBACK) on [\(appName)]: anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))), events=\(totalOperationsCount), restored=true"
            } else {
                physicalMouseInterferenceDetected = (decision == .physicalMouseInterference)
                restorationSuppressedReason = "\(decision)"
                restoreStatus = "SUPPRESSED_\(decision)"
                TouchBridgeLogger.info(.semantic, "Transient pointer scroll restore suppressed: \(decision).")
                TouchBridgeLogger.info(.semantic, "P3-06R2 cursor_restore: suppressed reason=\(decision).")
                session.panActionResult = "COMPATIBILITY_CURSOR_TRANSACTION (TRANSIENT_POINTER_FALLBACK) on [\(appName)]: anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))), events=\(totalOperationsCount), restored=false (\(decision))"
            }
        } else if !shouldRestoreToMain {
            restoreStatus = "NOT_REQUIRED_CURSOR_ON_TOUCHSCREEN"
            TouchBridgeLogger.info(.semantic, "Transient pointer scroll: cursor was already on touchscreen, retaining cursor location.")
            session.panActionResult = "COMPATIBILITY_CURSOR_TRANSACTION (TRANSIENT_POINTER_FALLBACK) on [\(appName)]: anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))), events=\(totalOperationsCount), cursor_retained_on_touchscreen"
        } else {
            session.panActionResult = "COMPATIBILITY_CURSOR_TRANSACTION (TRANSIENT_POINTER_FALLBACK) on [\(appName)]: anchor=(\(Int(anchorPoint.x)),\(Int(anchorPoint.y))), events=\(totalOperationsCount), no_relocation"
            TouchBridgeLogger.info(.semantic, "P3-06R2 cursor_restore: no_relocation transaction ended.")
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
        if relocated, shouldRestoreToMain, let initial = initialPhysicalCursor, TransientPointerTapBackend.isPointWithinActiveDisplays(initial) {
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
    public var isTouchscreenPoint: (CGPoint) -> Bool = { _ in false }

    public init(pointerOperations: PointerTransactionOperating = CoreGraphicsPointerTransactionOperations()) {
        self.pointerOperations = pointerOperations
        self.pointerOperations.prepareForTransactions()
    }

    public func resolveBackend(for session: InteractionSession, at point: CGPoint) -> ScrollDeliveryBackend {
        if !forceFallback, let axBackend = resolveAXBackend(for: session, at: point) {
            return axBackend
        }
        let fallback = TransientPointerScrollBackend(operations: pointerOperations, anchorPoint: point)
        fallback.isTouchscreenPoint = isTouchscreenPoint
        return fallback
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
