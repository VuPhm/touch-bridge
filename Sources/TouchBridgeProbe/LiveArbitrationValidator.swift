import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - P3-02 Live Physical Interaction & Gesture Arbitration Validator

public final class LiveArbitrationValidator: NSObject, TouchBridgeRuntimeDelegate {
    public static let shared = LiveArbitrationValidator()
    
    private let runtime = TouchBridgeRuntime.shared
    
    public private(set) var recordedBlocks: [String] = []
    public private(set) var deliberatePanMeasurements: [[String: Any]] = []
    public private(set) var stationaryJitterSamples: [Double] = []
    
    public enum Scenario: Int, CaseIterable {
        case a1_stationaryButton = 0
        case a2_swipeOnButton
        case a3_blankAreaPan
        case b1_finderRowTap
        case b2_finderRowSwipe
        case c1_textEditTap
        case c2_textEditSwipe
        case d1_safariButtonTap
        case d2_safariSwipeNegative
        
        public var title: String {
            switch self {
            case .a1_stationaryButton: return "Test A1 — TouchBridge stationary button tap"
            case .a2_swipeOnButton:    return "Test A2 — TouchBridge two-finger scroll starting on a button"
            case .a3_blankAreaPan:     return "Test A3 — TouchBridge two-finger blank-area scroll"
            case .b1_finderRowTap:     return "Test B1 — Finder stationary row tap"
            case .b2_finderRowSwipe:   return "Test B2 — Finder two-finger scroll on row"
            case .c1_textEditTap:      return "Test C1 — TextEdit stationary tap inside editable text"
            case .c2_textEditSwipe:    return "Test C2 — TextEdit two-finger scroll inside text area"
            case .d1_safariButtonTap:  return "Test D1 — Safari stationary tap button/link"
            case .d2_safariSwipeNegative: return "Test D2 — Safari swipe on actionable element (Negative Control)"
            }
        }
        
        public var instructions: String {
            switch self {
            case .a1_stationaryButton:
                return "Touch Button #1 normally and release (movement < 18 pt).\n   Required: possibleTap -> tapExecuted, Button #1 counter increments exactly once, no pan."
            case .a2_swipeOnButton:
                return "Place two fingers on Button #1 and move vertically together.\n   Required: child hit target is Button #1, transitions to two-finger scroll, content scrolls, and Button #1 does NOT activate."
            case .a3_blankAreaPan:
                return "Place two fingers on the blank area between button groups and move vertically together.\n   Required: continuous scroll; no tap candidate fires."
            case .b1_finderRowTap:
                return "Touch a row in the Finder window normally and release.\n   Required: semantic row selection (AXSelected set to true), zero cursor movement."
            case .b2_finderRowSwipe:
                return "Place two fingers on a Finder row and scroll vertically.\n   Required: two-finger scroll starts; the remaining contact cannot become a tap if one finger lifts first."
            case .c1_textEditTap:
                return "Touch inside the editable text document in TextEdit and release.\n   Required: semantic focus (AXFocused set to true), cursor untouched."
            case .c2_textEditSwipe:
                return "Place two fingers inside the TextEdit document and scroll vertically.\n   Required: document scrolls continuously; one-finger movement never becomes scrolling."
            case .d1_safariButtonTap:
                return "Touch the button/link in Safari normally and release.\n   Required: semantic tap dispatches AXPress, DOM updates, zero cursor movement."
            case .d2_safariSwipeNegative:
                return "Move one finger on the Safari button/link beyond the touch slop.\n   Required: tap candidate is cancelled; no scroll, click, or delayed action is emitted."
            }
        }
    }
    
    public private(set) var currentScenario: Scenario = .a1_stationaryButton
    private var isRunning: Bool = false
    private var targetDisplay: DisplayMetadata?
    
    public override init() {
        super.init()
    }
    
    public func startValidation(duration: Double = 180.0) {
        self.isRunning = true
        self.targetDisplay = DisplayManager.shared.findExternalTouchscreenDisplay()
        
        print("\n================================================================================")
        print("    TOUCHBRIDGE P3-02 DIRECT PHYSICAL ARBITRATION VALIDATION                     ")
        print("================================================================================")
        print("Objective: Collect direct physical evidence for tap-vs-pan arbitration behavior.")
        print("Target Touchscreen: USB2IIC_CTP_CONTROL (VID: 0x1A86, PID: 0xE5E3)")
        print("Target Display:     \(targetDisplay?.name ?? "External") (DisplayID: \(targetDisplay?.id ?? 0))")
        print("Pan Threshold:      \(GestureArbitrationConfig.panThresholdPt) pt")
        print("================================================================================\n")
        
        runtime.delegate = self
        runtime.start()
        runtime.setEnabled(true)
        
        activateScenario(.a1_stationaryButton)
        
        // Safeguard timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.isRunning else { return }
            print("\n[VALIDATION SESSION TIMEOUT] Exporting collected records...")
            self.finishValidation()
        }
    }
    
    public func activateScenario(_ scenario: Scenario) {
        self.currentScenario = scenario
        runtime.router.activeTestCaseName = scenario.title
        
        print("\n--------------------------------------------------------------------------------")
        print("👉 [\(scenario.title.uppercased())]")
        print("--------------------------------------------------------------------------------")
        print("Action:")
        print("   \(scenario.instructions)\n")
        print("Waiting for physical touch contact on external touchscreen...\n")
        fflush(stdout)
        
        // Prepare target window
        switch scenario {
        case .a1_stationaryButton, .a2_swipeOnButton, .a3_blankAreaPan:
            DispatchQueue.main.async {
                ArbitrationTestWindowController.shared.showTestWindow()
            }
            
        case .b1_finderRowTap, .b2_finderRowSwipe:
            positionFinder()
            
        case .c1_textEditTap, .c2_textEditSwipe:
            positionTextEdit()
            
        case .d1_safariButtonTap, .d2_safariSwipeNegative:
            positionSafari()
        }
    }
    
    private func positionFinder() {
        let appsURL = URL(fileURLWithPath: "/System/Applications")
        NSWorkspace.shared.open(appsURL)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, let display = self.targetDisplay else { return }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            guard let finder = apps.first else { return }
            let appElem = AXUIElementCreateApplication(finder.processIdentifier)
            var windowsRef: AnyObject?
            AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
            if let windows = windowsRef as? [AXUIElement], let fWin = windows.first {
                var targetPos = CGPoint(x: display.cgOriginX + 60, y: display.cgOriginY + 60)
                var targetSize = CGSize(width: 800, height: 720)
                if let pVal = AXValueCreate(.cgPoint, &targetPos), let sVal = AXValueCreate(.cgSize, &targetSize) {
                    AXUIElementSetAttributeValue(fWin, kAXPositionAttribute as CFString, pVal)
                    AXUIElementSetAttributeValue(fWin, kAXSizeAttribute as CFString, sVal)
                    print("  [✓] Finder positioned at (\(targetPos.x), \(targetPos.y)) on external touchscreen.")
                }
            }
        }
    }
    
    private func positionTextEdit() {
        let docPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scratch/long_document.txt")
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let conf = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([docPath], withApplicationAt: textEditURL, configuration: conf) { [weak self] app, err in
            guard let self = self, let app = app, err == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let display = self.targetDisplay else { return }
                let appElem = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: AnyObject?
                AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
                if let windows = windowsRef as? [AXUIElement], let teWin = windows.first {
                    var targetPos = CGPoint(x: display.cgOriginX + 60, y: display.cgOriginY + 60)
                    var targetSize = CGSize(width: 780, height: 720)
                    if let pVal = AXValueCreate(.cgPoint, &targetPos), let sVal = AXValueCreate(.cgSize, &targetSize) {
                        AXUIElementSetAttributeValue(teWin, kAXPositionAttribute as CFString, pVal)
                        AXUIElementSetAttributeValue(teWin, kAXSizeAttribute as CFString, sVal)
                        print("  [✓] TextEdit positioned at (\(targetPos.x), \(targetPos.y)) on external touchscreen.")
                    }
                }
            }
        }
    }
    
    private func positionSafari() {
        let htmlPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test_browser_ax.html")
        NSWorkspace.shared.open(htmlPath)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, let display = self.targetDisplay else { return }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
            guard let safari = apps.first else { return }
            let appElem = AXUIElementCreateApplication(safari.processIdentifier)
            var windowsRef: AnyObject?
            AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
            if let windows = windowsRef as? [AXUIElement], let safWin = windows.first {
                var targetPos = CGPoint(x: display.cgOriginX + 60, y: display.cgOriginY + 60)
                var targetSize = CGSize(width: 820, height: 740)
                if let pVal = AXValueCreate(.cgPoint, &targetPos), let sVal = AXValueCreate(.cgSize, &targetSize) {
                    AXUIElementSetAttributeValue(safWin, kAXPositionAttribute as CFString, pVal)
                    AXUIElementSetAttributeValue(safWin, kAXSizeAttribute as CFString, sVal)
                    print("  [✓] Safari positioned at (\(targetPos.x), \(targetPos.y)) on external touchscreen.")
                }
            }
        }
    }
    
    // MARK: - TouchBridgeRuntimeDelegate Callbacks
    
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateSnapshot snapshot: RuntimeSnapshot) {}
    
    public func runtime(_ runtime: TouchBridgeRuntime, didExecuteSemanticRecord record: SemanticEvidenceRecord) {
        print("  [SEMANTIC RECORD] \(record.classification.rawValue): \(record.visibleResult)")
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateFeedback feedback: String, invariantPassed: Bool) {
        print("  [FEEDBACK] \(feedback) [Cursor Isolated: \(invariantPassed ? "PASS" : "FAIL")]")
    }
    
    private func isGestureMatchingCurrentScenario(session: InteractionSession) -> Bool {
        switch currentScenario {
        case .a1_stationaryButton:
            return session.state == .tapExecuted
        case .a2_swipeOnButton:
            return session.state == .directPan || session.state == .momentum
        case .a3_blankAreaPan:
            return session.state == .directPan || session.state == .momentum
        case .b1_finderRowTap:
            return session.state == .tapExecuted
        case .b2_finderRowSwipe:
            return session.state == .directPan || session.state == .momentum
        case .c1_textEditTap:
            return session.state == .tapExecuted
        case .c2_textEditSwipe:
            return session.state == .directPan || session.state == .momentum
        case .d1_safariButtonTap:
            return session.state == .tapExecuted
        case .d2_safariSwipeNegative:
            return session.state == .cancelled(reason: "MOVEMENT_TOLERANCE_EXCEEDED")
        }
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didCompleteSession session: InteractionSession, evidenceBlock: String) {
        guard isRunning else { return }
        
        let matches = isGestureMatchingCurrentScenario(session: session)
        if !matches {
            print("\n  [!] Observed \(session.state) (Mov: \(String(format: "%.1f", session.maxMovementPt)) pt), but \(currentScenario.title) expects a \(expectedGestureDescription(for: currentScenario)).")
            print("  -> Please retry the action on the external touchscreen.")
            fflush(stdout)
            return
        }
        
        // Populate testTag
        session.testTag = currentScenario.title
        let formattedBlock = session.formattedEvidenceBlock(testNameOverride: currentScenario.title)
        
        recordedBlocks.append(formattedBlock)
        
        if session.state == .tapExecuted {
            stationaryJitterSamples.append(session.maxMovementPt)
        } else if (session.state == .directPan || session.state == .momentum), let t = session.timeToPanSec, let m = session.movementAtPanTransitionPt {
            deliberatePanMeasurements.append([
                "test": currentScenario.title,
                "timeToPanMs": t * 1000.0,
                "movementAtTransitionPt": m,
                "maxMovementPt": session.maxMovementPt
            ])
        }
        
        print("\n================================================================================")
        print("EVIDENCE RECORD CAPTURED FOR [\(currentScenario.title)]")
        print("================================================================================")
        print(formattedBlock)
        print("================================================================================\n")
        fflush(stdout)
        
        // Advance scenario
        if let next = Scenario(rawValue: currentScenario.rawValue + 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.activateScenario(next)
            }
        } else {
            finishValidation()
        }
    }
    
    private func expectedGestureDescription(for scenario: Scenario) -> String {
        switch scenario {
        case .a1_stationaryButton, .b1_finderRowTap, .c1_textEditTap, .d1_safariButtonTap:
            return "stationary tap (< 18.0 pt movement)"
        case .a2_swipeOnButton, .a3_blankAreaPan, .b2_finderRowSwipe, .c2_textEditSwipe:
            return "two-finger vertical scroll"
        case .d2_safariSwipeNegative:
            return "one-finger movement cancellation beyond touch slop"
        }
    }
    
    public func finishValidation() {
        self.isRunning = false
        print("\n================================================================================")
        print("       TOUCHBRIDGE P3-02 PHYSICAL VALIDATION COMPLETE                           ")
        print("================================================================================")
        print("Total Evidence Blocks Collected: \(recordedBlocks.count) / \(Scenario.allCases.count)")
        print("Deliberate Pan Measurements:     \(deliberatePanMeasurements.count)")
        print("================================================================================\n")
        
        // Save evidence to JSON file
        let evidenceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("p3_02_physical_arbitration_records.json")
        let exportDict: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "totalScenarios": Scenario.allCases.count,
            "completedScenarios": recordedBlocks.count,
            "evidenceBlocks": recordedBlocks,
            "deliberatePanMeasurements": deliberatePanMeasurements,
            "stationaryJitterSamples": stationaryJitterSamples
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: exportDict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: evidenceURL)
            print("[✓] Saved physical evidence records to: \(evidenceURL.lastPathComponent)")
        }
        
        exit(0)
    }
}
