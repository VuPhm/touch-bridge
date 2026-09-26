import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - P3-02 Rollback Reproducer & Empirical Diagnostics (Section 1 & 6)

public final class RollbackReproducer: NSObject, TouchBridgeRuntimeDelegate {
    public static let shared = RollbackReproducer()
    
    private let runtime = TouchBridgeRuntime.shared
    private var targetDisplay: DisplayMetadata?
    
    public override init() {
        super.init()
    }
    
    public func runReproductionSuite(targetFilter: String? = nil, completion: @escaping () -> Void) {
        TouchBridgeLogger.info(.lifecycle, "================================================================================")
        TouchBridgeLogger.info(.lifecycle, "    TOUCHBRIDGE P3-02 SCROLL ROLLBACK REPRODUCTION SUITE                        ")
        TouchBridgeLogger.info(.lifecycle, "================================================================================")
        
        guard let display = DisplayManager.shared.findExternalTouchscreenDisplay() else {
            TouchBridgeLogger.error(.display, "Cannot run reproduction: external display not found.")
            completion()
            return
        }
        self.targetDisplay = display
        
        runtime.delegate = self
        runtime.start()
        runtime.setEnabled(true)
        
        // Show test window
        ArbitrationTestWindowController.shared.showTestWindow()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.executeSequence(display: display, targetFilter: targetFilter, completion: completion)
        }
    }
    
    private func executeSequence(display: DisplayMetadata, targetFilter: String?, completion: @escaping () -> Void) {
        // Step 1: Test TouchBridge logScrollView (AXTextArea)
        // Step 2: Test TouchBridge testAScrollView (AXButton/AXScrollArea)
        // Step 3: Test Finder
        // Step 4: Test TextEdit
        
        var tasks: [(String, (DisplayMetadata, @escaping () -> Void) -> Void)] = []
        
        tasks.append(("TouchBridge logScrollView", { d, done in self.testLogScrollView(display: d, done: done) }))
        tasks.append(("TouchBridge testAScrollView", { d, done in self.testTestAScrollView(display: d, done: done) }))
        tasks.append(("Finder list view", { d, done in self.testFinder(display: d, done: done) }))
        tasks.append(("TextEdit long document", { d, done in self.testTextEdit(display: d, done: done) }))
        tasks.append(("TouchBridge NSScrollView 10-pan sequence", { d, done in self.test10PansTouchBridge(display: d, done: done) }))
        tasks.append(("Finder list view 10-pan sequence", { d, done in self.test10PansFinder(display: d, done: done) }))
        tasks.append(("TextEdit long document 10-pan sequence", { d, done in self.test10PansTextEdit(display: d, done: done) }))
        
        if let filter = targetFilter?.lowercased() {
            tasks = tasks.filter { $0.0.lowercased().contains(filter) }
        }
        
        func runNext(index: Int) {
            guard index < tasks.count else {
                TouchBridgeLogger.info(.lifecycle, "\n[REPRODUCTION COMPLETED] All target surfaces evaluated.")
                completion()
                return
            }
            let (name, fn) = tasks[index]
            TouchBridgeLogger.info(.lifecycle, "\n================================================================================")
            TouchBridgeLogger.info(.lifecycle, "▶ EVALUATING TARGET SURFACE: [\(name)]")
            TouchBridgeLogger.info(.lifecycle, "================================================================================")
            fn(display) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    runNext(index: index + 1)
                }
            }
        }
        
        runNext(index: 0)
    }
    
    // MARK: - Surface Tests
    
    private func focusTouchBridgeWindow() {
        let script = "tell application \"Finder\" to close every window\ntell application \"TextEdit\" to close every window saving no"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        NSApp.activate(ignoringOtherApps: true)
        ArbitrationTestWindowController.shared.showTestWindow()
        if let win = ArbitrationTestWindowController.shared.window {
            win.level = .floating
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
    }
    
    private func testLogScrollView(display: DisplayMetadata, done: @escaping () -> Void) {
        focusTouchBridgeWindow()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Center of right column in ArbitrationTestWindow:
            let startPoint = CGPoint(x: display.cgOriginX + 800.0, y: display.cgOriginY + 500.0)
            self.runSixGestures(on: startPoint, surfaceName: "TouchBridge logScrollView", done: done)
        }
    }
    
    private func testTestAScrollView(display: DisplayMetadata, done: @escaping () -> Void) {
        focusTouchBridgeWindow()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Center of left column in ArbitrationTestWindow:
            let startPoint = CGPoint(x: display.cgOriginX + 300.0, y: display.cgOriginY + 500.0)
            self.runSixGestures(on: startPoint, surfaceName: "TouchBridge testAScrollView", done: done)
        }
    }
    
    private func testFinder(display: DisplayMetadata, done: @escaping () -> Void) {
        if let win = ArbitrationTestWindowController.shared.window {
            win.level = .normal
        }
        let appsURL = URL(fileURLWithPath: "/System/Applications")
        NSWorkspace.shared.open(appsURL)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            if let finder = apps.first {
                finder.activate(options: .activateIgnoringOtherApps)
                let appElem = AXUIElementCreateApplication(finder.processIdentifier)
                var windowsRef: AnyObject?
                AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
                if let windows = windowsRef as? [AXUIElement], let fWin = windows.first {
                    var targetPos = CGPoint(x: display.cgOriginX + 60, y: display.cgOriginY + 60)
                    var targetSize = CGSize(width: 800, height: 720)
                    if let pVal = AXValueCreate(.cgPoint, &targetPos), let sVal = AXValueCreate(.cgSize, &targetSize) {
                        AXUIElementSetAttributeValue(fWin, kAXPositionAttribute as CFString, pVal)
                        AXUIElementSetAttributeValue(fWin, kAXSizeAttribute as CFString, sVal)
                    }
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let startPoint = CGPoint(x: display.cgOriginX + 400.0, y: display.cgOriginY + 400.0)
                self.runSixGestures(on: startPoint, surfaceName: "Finder list view", done: done)
            }
        }
    }
    
    private func testTextEdit(display: DisplayMetadata, done: @escaping () -> Void) {
        if let win = ArbitrationTestWindowController.shared.window {
            win.level = .normal
        }
        let docPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scratch/long_document.txt")
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let conf = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([docPath], withApplicationAt: textEditURL, configuration: conf) { [weak self] app, err in
            guard let self = self, let app = app, err == nil else {
                done()
                return
            }
            app.activate(options: .activateIgnoringOtherApps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let appElem = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: AnyObject?
                AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
                if let windows = windowsRef as? [AXUIElement], let teWin = windows.first {
                    var targetPos = CGPoint(x: display.cgOriginX + 60, y: display.cgOriginY + 60)
                    var targetSize = CGSize(width: 780, height: 720)
                    if let pVal = AXValueCreate(.cgPoint, &targetPos), let sVal = AXValueCreate(.cgSize, &targetSize) {
                        AXUIElementSetAttributeValue(teWin, kAXPositionAttribute as CFString, pVal)
                        AXUIElementSetAttributeValue(teWin, kAXSizeAttribute as CFString, sVal)
                    }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let startPoint = CGPoint(x: display.cgOriginX + 400.0, y: display.cgOriginY + 400.0)
                    self.runSixGestures(on: startPoint, surfaceName: "TextEdit long document", done: done)
                }
            }
        }
    }
    
    private func test10PansTouchBridge(display: DisplayMetadata, done: @escaping () -> Void) {
        focusTouchBridgeWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let startPoint = CGPoint(x: display.cgOriginX + 300.0, y: display.cgOriginY + 500.0)
            self.runTenConsecutivePans(on: startPoint, surfaceName: "TouchBridge NSScrollView", done: done)
        }
    }
    
    private func test10PansFinder(display: DisplayMetadata, done: @escaping () -> Void) {
        if let win = ArbitrationTestWindowController.shared.window {
            win.level = .normal
        }
        let appsURL = URL(fileURLWithPath: "/System/Applications")
        NSWorkspace.shared.open(appsURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let startPoint = CGPoint(x: display.cgOriginX + 400.0, y: display.cgOriginY + 400.0)
            self.runTenConsecutivePans(on: startPoint, surfaceName: "Finder list view", done: done)
        }
    }
    
    private func test10PansTextEdit(display: DisplayMetadata, done: @escaping () -> Void) {
        if let win = ArbitrationTestWindowController.shared.window {
            win.level = .normal
        }
        let startPoint = CGPoint(x: display.cgOriginX + 400.0, y: display.cgOriginY + 400.0)
        self.runTenConsecutivePans(on: startPoint, surfaceName: "TextEdit long document", done: done)
    }
    
    private func runTenConsecutivePans(on start: CGPoint, surfaceName: String, done: @escaping () -> Void) {
        let recognizer = runtime.recognizer
        var panIndex = 1
        
        func nextPan() {
            guard panIndex <= 10 else {
                TouchBridgeLogger.info(.gesture, "[SUCCESS] Completed 10 consecutive pans on [\(surfaceName)].")
                done()
                return
            }
            let idx = panIndex
            panIndex += 1
            let deltaY = (idx % 2 == 1) ? -120.0 : 120.0
            TouchBridgeLogger.info(.gesture, "--- Executing Pan #\(idx)/10 (\(deltaY > 0 ? "Down" : "Up")) on [\(surfaceName)] ---")
            
            self.performPan(recognizer: recognizer, start: start, deltaY: deltaY, steps: 10, stepIntervalSec: 0.016, holdBeforeReleaseSec: 0.0) {
                // Rapid chaining: wait 60ms to expose any post-release or cross-session mutation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.060) {
                    nextPan()
                }
            }
        }
        
        nextPan()
    }
    
    // MARK: - 6 Gestures Execution
    
    private func runSixGestures(on start: CGPoint, surfaceName: String, done: @escaping () -> Void) {
        let recognizer = runtime.recognizer
        
        let gestures: [(String, (CGPoint, @escaping () -> Void) -> Void)] = [
            ("1. Slow short pan", { pt, next in self.performPan(recognizer: recognizer, start: pt, deltaY: -45.0, steps: 15, stepIntervalSec: 0.03, holdBeforeReleaseSec: 0.0, done: next) }),
            ("2. Long pan", { pt, next in self.performPan(recognizer: recognizer, start: pt, deltaY: -220.0, steps: 20, stepIntervalSec: 0.016, holdBeforeReleaseSec: 0.0, done: next) }),
            ("3. Fast flick without inertia", { pt, next in self.performPan(recognizer: recognizer, start: pt, deltaY: -160.0, steps: 4, stepIntervalSec: 0.008, holdBeforeReleaseSec: 0.0, done: next) }),
            ("4. Pan then hold stationary before release", { pt, next in self.performPan(recognizer: recognizer, start: pt, deltaY: -100.0, steps: 10, stepIntervalSec: 0.02, holdBeforeReleaseSec: 0.35, done: next) }),
            ("5. Consecutive pans in same direction", { pt, next in
                self.performPan(recognizer: recognizer, start: pt, deltaY: -80.0, steps: 8, stepIntervalSec: 0.016, holdBeforeReleaseSec: 0.0) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.performPan(recognizer: recognizer, start: pt, deltaY: -80.0, steps: 8, stepIntervalSec: 0.016, holdBeforeReleaseSec: 0.0, done: next)
                    }
                }
            }),
            ("6. Alternating direction pans", { pt, next in
                self.performPan(recognizer: recognizer, start: pt, deltaY: -120.0, steps: 10, stepIntervalSec: 0.016, holdBeforeReleaseSec: 0.0) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.performPan(recognizer: recognizer, start: pt, deltaY: 120.0, steps: 10, stepIntervalSec: 0.016, holdBeforeReleaseSec: 0.0, done: next)
                    }
                }
            })
        ]
        
        func runGesture(index: Int) {
            guard index < gestures.count else {
                done()
                return
            }
            let (title, gFn) = gestures[index]
            TouchBridgeLogger.info(.gesture, "--- Executing: [\(title)] on [\(surfaceName)] ---")
            gFn(start) {
                // Wait for +100ms post-release readback to settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    runGesture(index: index + 1)
                }
            }
        }
        
        runGesture(index: 0)
    }
    
    private func performPan(
        recognizer: TouchGestureRecognizer,
        start: CGPoint,
        deltaY: Double,
        steps: Int,
        stepIntervalSec: Double,
        holdBeforeReleaseSec: Double,
        done: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async {
            let display = self.targetDisplay ?? DisplayManager.shared.findExternalTouchscreenDisplay()!
            
            func makePoints(x: Double, y: Double) -> (DisplayLocalPoint, GlobalDisplayPoint) {
                let local = DisplayLocalPoint(cgPoint: CGPoint(x: x - display.cgOriginX, y: y - display.cgOriginY))
                let global = GlobalDisplayPoint(cgGlobal: CGPoint(x: x, y: y))
                return (local, global)
            }
            
            // 1. Touch DOWN
            let (downLocal, downGlobal) = makePoints(x: start.x, y: start.y)
            recognizer.processMappedPoint(phase: .down, local: downLocal, global: downGlobal)
            
            // 2. MOVE steps
            var curStep = 0
            func dispatchMove() {
                curStep += 1
                let progress = Double(curStep) / Double(steps)
                let curY = start.y + (deltaY * progress)
                let (mvLocal, mvGlobal) = makePoints(x: start.x, y: curY)
                
                recognizer.processMappedPoint(phase: .move, local: mvLocal, global: mvGlobal)
                
                if curStep < steps {
                    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + stepIntervalSec) {
                        dispatchMove()
                    }
                } else {
                    // Reached final move step. Check if hold is needed
                    if holdBeforeReleaseSec > 0.0 {
                        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + holdBeforeReleaseSec) {
                            dispatchUp(finalY: curY)
                        }
                    } else {
                        dispatchUp(finalY: curY)
                    }
                }
            }
            
            func dispatchUp(finalY: Double) {
                let (upLocal, upGlobal) = makePoints(x: start.x, y: finalY)
                recognizer.processMappedPoint(phase: .up, local: upLocal, global: upGlobal)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    done()
                }
            }
            
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + stepIntervalSec) {
                dispatchMove()
            }
        }
    }
    
    // MARK: - Delegate
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateSnapshot snapshot: RuntimeSnapshot) {}
    public func runtime(_ runtime: TouchBridgeRuntime, didExecuteSemanticRecord record: SemanticEvidenceRecord) {}
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateFeedback feedback: String, invariantPassed: Bool) {}
    public func runtime(_ runtime: TouchBridgeRuntime, didCompleteSession session: InteractionSession, evidenceBlock: String) {}
}
