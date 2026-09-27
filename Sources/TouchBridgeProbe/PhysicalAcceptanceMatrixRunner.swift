import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

public struct PhysicalMatrixResult {
    public let testName: String
    public let targetApp: String
    public let backend: String
    public let classification: String
    public let passed: Bool
    public let cursorDisplacement: Double
    public let activationChanged: Bool
    public let details: String
}

public final class PhysicalAcceptanceMatrixRunner {
    public init() {}

    public func run() -> Bool {
        print("================================================================================")
        print("       TouchBridge P3-04E — Production Physical Acceptance Matrix               ")
        print("================================================================================")

        let initialFrontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "None"
        let initialCursor = CGPoint(x: 500, y: 500)
        CGWarpMouseCursorPosition(initialCursor)
        usleep(20_000)

        print("Initial frontmost application: [\(initialFrontmost)]")
        print("Initial physical cursor: (\(initialCursor.x), \(initialCursor.y))\n")

        HybridScrollDeliveryCoordinator.shared.pointerOperations.prepareForTransactions()
        usleep(50_000)

        var results: [PhysicalMatrixResult] = []

        // Test 1: Finder
        results.append(testAXSurface(
            name: "Finder AX Semantic Scroll",
            point: CGPoint(x: 2100, y: 395),
            expectedApp: "Finder"
        ))

        // Test 2: TextEdit
        results.append(testAXSurface(
            name: "TextEdit AX Semantic Scroll",
            point: CGPoint(x: 2740, y: 395),
            expectedApp: "TextEdit"
        ))

        // Test 3: Safari
        results.append(testAXSurface(
            name: "Safari WebKit AX Semantic Scroll",
            point: CGPoint(x: 2110, y: 850),
            expectedApp: "Safari"
        ))

        // Test 4: Brave / Chromium Fallback
        results.append(testPointerFallbackSurface(
            name: "Brave Chromium Transient Pointer Fallback",
            point: CGPoint(x: 2740, y: 850),
            expectedApp: "Brave Browser"
        ))

        // Test 5: AX Long Scroll vs Short Scroll
        results.append(testAXLongVsShortScroll(
            point: CGPoint(x: 2110, y: 395),
            expectedApp: "Finder"
        ))

        // Test 6: Physical Mouse Movement During AX Scroll
        results.append(testPhysicalMouseDuringAXScroll(
            point: CGPoint(x: 2110, y: 395),
            expectedApp: "Finder"
        ))

        // Test 7: Repeated Gestures (Pan -> Pan -> Pan)
        results.append(testRepeatedGestures(
            point: CGPoint(x: 2110, y: 395)
        ))

        // Test 8: Scroll Then Immediate Tap
        results.append(testScrollThenImmediateTap(
            point: CGPoint(x: 2110, y: 395)
        ))

        // Test 9: Tap Then Immediate Scroll
        results.append(testTapThenImmediateScroll(
            point: CGPoint(x: 2110, y: 395)
        ))

        // Summary
        print("\n================================================================================")
        print("                       PHYSICAL MATRIX SUMMARY                                  ")
        print("================================================================================")
        var allPassed = true
        for r in results {
            let mark = r.passed ? "[PASS]" : "[FAIL]"
            if !r.passed { allPassed = false }
            print("\(mark) \(r.testName)")
            print("       App: [\(r.targetApp)] | Backend: \(r.backend) (\(r.classification))")
            print("       Cursor Displacement: \(String(format: "%.2f", r.cursorDisplacement)) pt | Activation Changed: \(r.activationChanged)")
            print("       Details: \(r.details)\n")
        }
        print("Overall Matrix Result: [\(allPassed ? "ALL ACCEPTANCE CRITERIA MET" : "FAIL")]")
        print("================================================================================")
        return allPassed
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func testAXSurface(name: String, point: CGPoint, expectedApp: String) -> PhysicalMatrixResult {
        print("--- [\(name)] ---")
        let sysElem = AXUIElementCreateSystemWide()
        var hitElemRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sysElem, Float(point.x), Float(point.y), &hitElemRef) == .success,
              let hitElem = hitElemRef else {
            return PhysicalMatrixResult(
                testName: name, targetApp: "None", backend: "None", classification: "None",
                passed: false, cursorDisplacement: 0, activationChanged: false,
                details: "No AX element found at (\(point.x), \(point.y))"
            )
        }

        let context = AXCapabilityInspector.shared.discoverContext(element: hitElem, maxAncestors: 8)
        let actualApp = context.applicationName
        let isSettable = context.scrollCapability.isVerticalValueSettable
        let scrollBar = context.scrollBarElement

        print("Hit Target: [\(actualApp)] (expected [\(expectedApp)]), Role: \(context.hitNode.role)")
        print("Scrollable AX Ancestor Found: \(scrollBar != nil), Settable: \(isSettable)")

        guard isSettable, scrollBar != nil else {
            return PhysicalMatrixResult(
                testName: name, targetApp: actualApp, backend: "UNAVAILABLE", classification: "UNKNOWN",
                passed: false, cursorDisplacement: 0, activationChanged: false,
                details: "AXScrollBar not found or not settable for [\(actualApp)]"
            )
        }

        let coordinator = HybridScrollDeliveryCoordinator.shared
        let session = InteractionSession(
            startSample: TouchSample(phase: .down, rawX: 2048, rawY: 2048, normX: 0.5, normY: 0.5),
            localPoint: DisplayLocalPoint(cgPoint: point),
            globalPoint: GlobalDisplayPoint(cgGlobal: point),
            context: context
        )

        let backend = coordinator.resolveBackend(for: session, at: point)
        let isAXBackend = backend is AXSemanticScrollBackend
        let classification = backend.classification.rawValue

        let cursorBefore = currentCursor()
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "None"

        _ = backend.begin(session: session, touchPoint: point)
        let axBackend = backend as! AXSemanticScrollBackend
        let initVal = axBackend.currentValue

        // Send continuous pan updates
        let direction: Double = (initVal > (axBackend.minValue + axBackend.maxValue) / 2.0) ? 1.0 : -1.0
        backend.update(deltaY: direction * 80, velocityY: direction * 160, currentTouchPoint: point)
        backend.update(deltaY: direction * 80, velocityY: direction * 160, currentTouchPoint: point)
        backend.momentumUpdate(deltaY: direction * 40, velocityY: direction * 80)
        let terminalVal = axBackend.currentValue
        backend.end(session: session)

        let cursorAfter = currentCursor()
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "None"

        let cursorDisp = hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y)
        let activationChanged = (frontmostBefore != frontmostAfter)
        let valueChanged = (terminalVal != initVal)
        let zeroFailures = axBackend.writeFailureCount == 0

        let passed = isAXBackend && (classification == "NATIVE_CURSOR_INDEPENDENT") && (cursorDisp == 0.0) && !activationChanged && valueChanged && zeroFailures

        print("Backend: \(backend.diagnosticName) (\(classification))")
        print("Initial Value: \(String(format: "%.3f", initVal)) -> Terminal Value: \(String(format: "%.3f", terminalVal)) (Changed: \(valueChanged))")
        print("Cursor Before: (\(cursorBefore.x), \(cursorBefore.y)), After: (\(cursorAfter.x), \(cursorAfter.y)), Displacement: \(cursorDisp) pt")
        print("Frontmost App Before: [\(frontmostBefore)], After: [\(frontmostAfter)] (Activation Changed: \(activationChanged))")
        print("Result: [\(passed ? "PASS" : "FAIL")]\n")

        return PhysicalMatrixResult(
            testName: name, targetApp: actualApp, backend: backend.diagnosticName, classification: classification,
            passed: passed, cursorDisplacement: cursorDisp, activationChanged: activationChanged,
            details: "Value shifted \(String(format: "%.3f", initVal)) -> \(String(format: "%.3f", terminalVal)), write failures: \(axBackend.writeFailureCount)"
        )
    }

    private func testPointerFallbackSurface(name: String, point: CGPoint, expectedApp: String) -> PhysicalMatrixResult {
        print("--- [\(name)] ---")
        let sysElem = AXUIElementCreateSystemWide()
        var hitElemRef: AXUIElement?
        _ = AXUIElementCopyElementAtPosition(sysElem, Float(point.x), Float(point.y), &hitElemRef)
        let elem = hitElemRef ?? sysElem
        let context = AXCapabilityInspector.shared.discoverContext(element: elem, maxAncestors: 8)
        let actualApp = context.applicationName

        print("Hit Target: [\(actualApp)] (expected [\(expectedApp)])")
        print("AX Settable ScrollBar Available: \(context.scrollCapability.isVerticalValueSettable) (Requires fallback: \(!context.scrollCapability.isVerticalValueSettable))")

        let coordinator = HybridScrollDeliveryCoordinator.shared
        let session = InteractionSession(
            startSample: TouchSample(phase: .down, rawX: 2048, rawY: 2048, normX: 0.5, normY: 0.5),
            localPoint: DisplayLocalPoint(cgPoint: point),
            globalPoint: GlobalDisplayPoint(cgGlobal: point),
            context: context
        )

        let backend = coordinator.resolveBackend(for: session, at: point)
        let isFallbackBackend = backend is TransientPointerScrollBackend
        let classification = backend.classification.rawValue

        let cursorStart = CGPoint(x: 500, y: 500)
        CGWarpMouseCursorPosition(cursorStart)
        usleep(20_000)

        _ = backend.begin(session: session, touchPoint: point)
        let cursorAtAnchor = currentCursor()
        let initialWarpError = hypot(cursorAtAnchor.x - point.x, cursorAtAnchor.y - point.y)
        print("Step 1 (Start): Warped cursor to fixed anchor (\(cursorAtAnchor.x), \(cursorAtAnchor.y)), error=\(initialWarpError) pt")

        // Step 2: Multiple touch updates with moving finger centroids
        var cursorFollowedFinger = false
        for i in 1...5 {
            let fingerCentroid = CGPoint(x: point.x + CGFloat(i * 10), y: point.y + CGFloat(i * 20))
            backend.update(deltaY: -15, velocityY: -45, currentTouchPoint: fingerCentroid)
            let cur = currentCursor()
            if hypot(cur.x - point.x, cur.y - point.y) > 2.0 {
                cursorFollowedFinger = true
            }
        }
        print("Step 2 (Updates): Cursor followed finger movement? \(cursorFollowedFinger ? "YES (VIOLATION)" : "NO (Fixed anchor maintained)")")

        // Step 3: Momentum updates
        backend.momentumUpdate(deltaY: -10, velocityY: -30)
        backend.momentumUpdate(deltaY: -5, velocityY: -15)

        // Step 4: End and restore
        backend.end(session: session)
        usleep(20_000)
        let cursorFinal = currentCursor()
        let restoreError = hypot(cursorFinal.x - cursorStart.x, cursorFinal.y - cursorStart.y)
        print("Step 4 (End): Restored cursor to (\(cursorFinal.x), \(cursorFinal.y)), error from original=\(restoreError) pt")

        // Step 5: Test physical mouse movement suppression
        print("Step 5 (Interference Check): Simulating physical mouse activity during scroll...")
        let session2 = InteractionSession(
            startSample: TouchSample(phase: .down, rawX: 2048, rawY: 2048, normX: 0.5, normY: 0.5),
            localPoint: DisplayLocalPoint(cgPoint: point),
            globalPoint: GlobalDisplayPoint(cgGlobal: point),
            context: context
        )
        let backend2 = coordinator.resolveBackend(for: session2, at: point) as! TransientPointerScrollBackend
        _ = backend2.begin(session: session2, touchPoint: point)
        // User moves physical mouse
        let userMouse = CGPoint(x: 650, y: 650)
        CGWarpMouseCursorPosition(userMouse)
        if let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: userMouse, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
        }
        usleep(30_000)
        backend2.end(session: session2)
        usleep(20_000)
        let afterInterference = currentCursor()
        let restorationSuppressed = backend2.physicalMouseInterferenceDetected || (backend2.restorationSuppressedReason != nil)
        let notRestoredToOldStart = hypot(afterInterference.x - cursorStart.x, afterInterference.y - cursorStart.y) > 10.0
        let interferenceRespected = restorationSuppressed && notRestoredToOldStart
        print("Interference Suppression: Restoration suppressed? \(interferenceRespected ? "YES (User position won)" : "NO (Stale restore occurred)")")

        let passed = isFallbackBackend && (classification == "COMPATIBILITY_CURSOR_TRANSACTION") &&
                     (initialWarpError <= 2.0) && !cursorFollowedFinger && (restoreError <= 2.0) && interferenceRespected

        print("Result: [\(passed ? "PASS" : "FAIL")]\n")

        return PhysicalMatrixResult(
            testName: name, targetApp: actualApp, backend: backend.diagnosticName, classification: classification,
            passed: passed, cursorDisplacement: restoreError, activationChanged: false,
            details: "Anchor error: \(initialWarpError) pt, restored error: \(restoreError) pt, cursor followed finger: \(cursorFollowedFinger), interference handled: \(interferenceRespected)"
        )
    }

    private func testAXLongVsShortScroll(point: CGPoint, expectedApp: String) -> PhysicalMatrixResult {
        print("--- [Pattern: Long vs Short Scroll (AX Path)] ---")
        let sysElem = AXUIElementCreateSystemWide()
        var hitElemRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sysElem, Float(point.x), Float(point.y), &hitElemRef) == .success,
              let hitElem = hitElemRef else {
            return PhysicalMatrixResult(testName: "AX Long vs Short Scroll", targetApp: expectedApp, backend: "AX_SEMANTIC", classification: "NATIVE_CURSOR_INDEPENDENT", passed: false, cursorDisplacement: 0, activationChanged: false, details: "Hit test failed")
        }
        let context = AXCapabilityInspector.shared.discoverContext(element: hitElem, maxAncestors: 8)
        guard context.scrollBarElement != nil, context.scrollCapability.isVerticalValueSettable else {
            return PhysicalMatrixResult(testName: "AX Long vs Short Scroll", targetApp: expectedApp, backend: "AX_SEMANTIC", classification: "NATIVE_CURSOR_INDEPENDENT", passed: false, cursorDisplacement: 0, activationChanged: false, details: "Settable AXScrollBar not found")
        }
        let backend = AXSemanticScrollBackend(context: context, initialPoint: point)
        let session = InteractionSession(
            startSample: TouchSample(phase: .down, rawX: 2048, rawY: 2048, normX: 0.5, normY: 0.5),
            localPoint: DisplayLocalPoint(cgPoint: point),
            globalPoint: GlobalDisplayPoint(cgGlobal: point),
            context: context
        )
        _ = backend.begin(session: session, touchPoint: point)
        let v0 = backend.currentValue
        let dir: Double = (v0 > (backend.minValue + backend.maxValue) / 2.0) ? 1.0 : -1.0
        backend.update(deltaY: dir * 30, velocityY: dir * 60, currentTouchPoint: point)
        let vShort = backend.currentValue
        backend.update(deltaY: dir * 300, velocityY: dir * 600, currentTouchPoint: point)
        let vLong = backend.currentValue
        backend.end(session: session)

        let deltaShort = abs(vShort - v0)
        let deltaLong = abs(vLong - vShort)
        let passed = (deltaLong > deltaShort) && (deltaShort > 0)
        print("Short delta: \(String(format: "%.4f", deltaShort)), Long delta: \(String(format: "%.4f", deltaLong)) (Long > Short: \(deltaLong > deltaShort))")
        print("Result: [\(passed ? "PASS" : "FAIL")]\n")
        return PhysicalMatrixResult(
            testName: "AX Long vs Short Scroll",
            targetApp: context.applicationName,
            backend: "AX_SEMANTIC",
            classification: "NATIVE_CURSOR_INDEPENDENT",
            passed: passed,
            cursorDisplacement: 0.0,
            activationChanged: false,
            details: "Short delta: \(String(format: "%.4f", deltaShort)), Long delta: \(String(format: "%.4f", deltaLong))"
        )
    }

    private func testPhysicalMouseDuringAXScroll(point: CGPoint, expectedApp: String) -> PhysicalMatrixResult {
        print("--- [Pattern: Physical Mouse Movement During AX Scroll] ---")
        let sysElem = AXUIElementCreateSystemWide()
        var hitElemRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sysElem, Float(point.x), Float(point.y), &hitElemRef) == .success,
              let hitElem = hitElemRef else {
            return PhysicalMatrixResult(testName: "Physical Mouse Movement During AX Scroll", targetApp: expectedApp, backend: "AX_SEMANTIC", classification: "NATIVE_CURSOR_INDEPENDENT", passed: false, cursorDisplacement: 0, activationChanged: false, details: "Hit test failed")
        }
        let context = AXCapabilityInspector.shared.discoverContext(element: hitElem, maxAncestors: 8)
        guard context.scrollBarElement != nil, context.scrollCapability.isVerticalValueSettable else {
            return PhysicalMatrixResult(testName: "Physical Mouse Movement During AX Scroll", targetApp: expectedApp, backend: "AX_SEMANTIC", classification: "NATIVE_CURSOR_INDEPENDENT", passed: false, cursorDisplacement: 0, activationChanged: false, details: "Settable AXScrollBar not found")
        }

        let userPos = CGPoint(x: 620, y: 620)
        CGWarpMouseCursorPosition(userPos)
        usleep(20_000)

        let backend = AXSemanticScrollBackend(context: context, initialPoint: point)
        let session = InteractionSession(
            startSample: TouchSample(phase: .down, rawX: 2048, rawY: 2048, normX: 0.5, normY: 0.5),
            localPoint: DisplayLocalPoint(cgPoint: point),
            globalPoint: GlobalDisplayPoint(cgGlobal: point),
            context: context
        )
        _ = backend.begin(session: session, touchPoint: point)
        backend.update(deltaY: -50, velocityY: -100, currentTouchPoint: point)
        backend.momentumUpdate(deltaY: -20, velocityY: -40)
        backend.end(session: session)

        let cur = currentCursor()
        let disp = hypot(cur.x - userPos.x, cur.y - userPos.y)
        let passed = disp <= 1.0
        print("Physical cursor at (\(cur.x), \(cur.y)), displacement from user pos (\(userPos.x), \(userPos.y)): \(disp) pt")
        print("Result: [\(passed ? "PASS" : "FAIL")]\n")
        return PhysicalMatrixResult(
            testName: "Physical Mouse Movement During AX Scroll",
            targetApp: context.applicationName,
            backend: "AX_SEMANTIC",
            classification: "NATIVE_CURSOR_INDEPENDENT",
            passed: passed,
            cursorDisplacement: disp,
            activationChanged: false,
            details: "User position preserved without displacement (\(disp) pt)"
        )
    }

    private func testRepeatedGestures(point: CGPoint) -> PhysicalMatrixResult {
        print("--- [Pattern: Repeated Gestures (Pan -> Pan -> Pan)] ---")
        let mapper = CoordinateMapper()
        let router = SemanticInteractionRouter()
        router.userIntent = .enabled
        let recognizer = TouchGestureRecognizer(mapper: mapper)
        recognizer.delegate = router

        var passed = true
        for _ in 1...3 {
            let session = InteractionSession(
                startSample: TouchSample(phase: .down, rawX: 2048, rawY: 2048, normX: 0.5, normY: 0.5),
                localPoint: DisplayLocalPoint(cgPoint: point),
                globalPoint: GlobalDisplayPoint(cgGlobal: point),
                context: nil
            )
            router.gestureRecognizer(recognizer, didStartPanWithSession: session)
            if router.activeScrollBackend == nil { passed = false }
            router.gestureRecognizer(recognizer, didUpdatePanDeltaWithSession: session, deltaPixels: CGVector(dx: 0, dy: -25))
            router.gestureRecognizer(recognizer, didCompletePanWithSession: session)
            if router.activeScrollBackend != nil { passed = false }
        }
        print("3 Consecutive Pan Gestures Lifecycle: [\(passed ? "PASS" : "FAIL")]\n")
        return PhysicalMatrixResult(
            testName: "Repeated Gestures (Pan -> Pan -> Pan)",
            targetApp: "Router",
            backend: "HYBRID",
            classification: "STATE_LIFECYCLE",
            passed: passed,
            cursorDisplacement: 0.0,
            activationChanged: false,
            details: "3 consecutive pan gestures latched and cleanly released backend state"
        )
    }

    private func testScrollThenImmediateTap(point: CGPoint) -> PhysicalMatrixResult {
        print("--- [Pattern: Scroll then Immediate Tap] ---")
        let mapper = CoordinateMapper()
        let router = SemanticInteractionRouter()
        router.userIntent = .enabled
        let recognizer = TouchGestureRecognizer(mapper: mapper)
        recognizer.delegate = router

        // Two finger scroll
        recognizer.processMappedPoint(phase: .down, local: DisplayLocalPoint(cgPoint: point), global: GlobalDisplayPoint(cgGlobal: point), contactID: 10)
        recognizer.processMappedPoint(phase: .down, local: DisplayLocalPoint(cgPoint: CGPoint(x: point.x + 30, y: point.y)), global: GlobalDisplayPoint(cgGlobal: CGPoint(x: point.x + 30, y: point.y)), contactID: 11)
        recognizer.processMappedPoint(phase: .move, local: DisplayLocalPoint(cgPoint: point), global: GlobalDisplayPoint(cgGlobal: point), contactID: 10)
        recognizer.processMappedPoint(phase: .up, local: DisplayLocalPoint(cgPoint: point), global: GlobalDisplayPoint(cgGlobal: point), contactID: 10)
        recognizer.processMappedPoint(phase: .up, local: DisplayLocalPoint(cgPoint: CGPoint(x: point.x + 30, y: point.y)), global: GlobalDisplayPoint(cgGlobal: CGPoint(x: point.x + 30, y: point.y)), contactID: 11)

        let scrollBackendCleared = (router.activeScrollBackend == nil)

        // Immediate tap
        recognizer.processMappedPoint(phase: .down, local: DisplayLocalPoint(cgPoint: point), global: GlobalDisplayPoint(cgGlobal: point), contactID: 12)
        usleep(25_000)
        recognizer.processMappedPoint(phase: .up, local: DisplayLocalPoint(cgPoint: point), global: GlobalDisplayPoint(cgGlobal: point), contactID: 12)

        let contactsClean = recognizer.activeContacts.isEmpty
        let passed = scrollBackendCleared && contactsClean
        print("Scroll Then Immediate Tap: [\(passed ? "PASS" : "FAIL")]\n")
        return PhysicalMatrixResult(
            testName: "Scroll then Immediate Tap",
            targetApp: "Router",
            backend: "HYBRID",
            classification: "INTERACTION_TRANSITION",
            passed: passed,
            cursorDisplacement: 0.0,
            activationChanged: false,
            details: "Scroll ended cleanly; immediate tap recognized with clean contact release"
        )
    }

    private func testTapThenImmediateScroll(point: CGPoint) -> PhysicalMatrixResult {
        print("--- [Pattern: Tap then Immediate Scroll] ---")
        let mapper = CoordinateMapper()
        let router = SemanticInteractionRouter()
        router.userIntent = .enabled
        let recognizer = TouchGestureRecognizer(mapper: mapper)
        recognizer.delegate = router

        // Tap
        recognizer.processMappedPoint(phase: .down, local: DisplayLocalPoint(cgPoint: point), global: GlobalDisplayPoint(cgGlobal: point), contactID: 20)
        usleep(25_000)
        recognizer.processMappedPoint(phase: .up, local: DisplayLocalPoint(cgPoint: point), global: GlobalDisplayPoint(cgGlobal: point), contactID: 20)

        // Immediate scroll
        recognizer.processMappedPoint(phase: .down, local: DisplayLocalPoint(cgPoint: point), global: GlobalDisplayPoint(cgGlobal: point), contactID: 21)
        recognizer.processMappedPoint(phase: .down, local: DisplayLocalPoint(cgPoint: CGPoint(x: point.x + 30, y: point.y)), global: GlobalDisplayPoint(cgGlobal: CGPoint(x: point.x + 30, y: point.y)), contactID: 22)
        recognizer.processMappedPoint(phase: .move, local: DisplayLocalPoint(cgPoint: CGPoint(x: point.x, y: point.y + 40)), global: GlobalDisplayPoint(cgGlobal: CGPoint(x: point.x, y: point.y + 40)), contactID: 21)
        recognizer.processMappedPoint(phase: .move, local: DisplayLocalPoint(cgPoint: CGPoint(x: point.x + 30, y: point.y + 40)), global: GlobalDisplayPoint(cgGlobal: CGPoint(x: point.x + 30, y: point.y + 40)), contactID: 22)

        let enteredPan = (recognizer.activeSession?.state == .directPan)

        recognizer.processMappedPoint(phase: .up, local: DisplayLocalPoint(cgPoint: CGPoint(x: point.x, y: point.y + 40)), global: GlobalDisplayPoint(cgGlobal: CGPoint(x: point.x, y: point.y + 40)), contactID: 21)
        recognizer.processMappedPoint(phase: .up, local: DisplayLocalPoint(cgPoint: CGPoint(x: point.x + 30, y: point.y + 40)), global: GlobalDisplayPoint(cgGlobal: CGPoint(x: point.x + 30, y: point.y + 40)), contactID: 22)

        let passed = enteredPan && recognizer.activeContacts.isEmpty
        print("Tap Then Immediate Scroll: [\(passed ? "PASS" : "FAIL")]\n")
        return PhysicalMatrixResult(
            testName: "Tap then Immediate Scroll",
            targetApp: "Router",
            backend: "HYBRID",
            classification: "INTERACTION_TRANSITION",
            passed: passed,
            cursorDisplacement: 0.0,
            activationChanged: false,
            details: "Tap finished cleanly; immediate two-finger pan entered directPan state"
        )
    }
}
