import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - P3-02 Interaction Arbitration Testbed Window (Section 15)

public final class ArbitrationTestWindowController: NSObject, NSWindowDelegate, TouchBridgeRuntimeDelegate {
    public static let shared = ArbitrationTestWindowController()
    
    public private(set) var window: NSWindow?
    private let runtime = TouchBridgeRuntime.shared
    
    // Top HUD Labels
    private let titleLabel = NSTextField(labelWithString: "TouchBridge P3-03 — Gesture Layer & Arbitration Testbed")
    private let stateLabel = NSTextField(labelWithString: "Gesture State: IDLE")
    private let movementLabel = NSTextField(labelWithString: "Movement: 0.0 pt | Threshold: 18.0 pt | Duration: 0.000s")
    private let elementLabel = NSTextField(labelWithString: "AX Hit Discovery: None")
    private let lastActionLabel = NSTextField(labelWithString: "Last Semantic Result: Ready for gestures.")
    private let cursorInvariantLabel = NSTextField(labelWithString: "Cursor Isolation: ISOLATED (Delta: 0.00 pt)")
    private let buttonStatsLabel = NSTextField(labelWithString: "Buttons Activated: 0 | Last: None")
    
    // Test A Controls (Embedded Scroll View)
    private let testAScrollView = NSScrollView()
    private let testADocumentView = NSView()
    private var testButtons: [NSButton] = []
    private var testButtonCounts: [Int] = []
    private let nestedTextField = NSTextField()
    private var totalButtonActivations: Int = 0
    
    // External App Switchers
    private let btnTestA = NSButton()
    private let btnTestB = NSButton()
    private let btnTestC = NSButton()
    private let btnTestD = NSButton()
    private let btnSaveReport = NSButton()
    
    // Live Event Log
    private let logTextView = NSTextView()
    private let logScrollView = NSScrollView()
    
    // Metrics Accumulator for Report
    public private(set) var physicalRecords: [String] = []
    public private(set) var stationaryJitterSamples: [Double] = []
    public private(set) var swipeDisplacements: [Double] = []
    public private(set) var swipeUpdateRates: [Double] = []
    
    public override init() {
        super.init()
    }
    
    public func showTestWindow() {
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            return
        }
        
        let displayManager = DisplayManager.shared
        guard let targetDisplay = displayManager.findExternalTouchscreenDisplay() else {
            TouchBridgeLogger.error(.display, "Cannot open Arbitration Test Window: External display missing.")
            return
        }
        
        let screenRect = NSRect(
            x: targetDisplay.cgOriginX,
            y: targetDisplay.cgOriginY,
            width: targetDisplay.cgWidth,
            height: targetDisplay.cgHeight
        )
        
        // Find corresponding NSScreen
        let targetScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == targetDisplay.id
        })
        
        let winFrame = targetScreen?.frame ?? screenRect
        let win = KeyableWindow(
            contentRect: winFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TouchBridge P3-03 Gesture Layer & Arbitration Testbed"
        win.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        win.setFrame(NSRect(x: winFrame.origin.x, y: winFrame.origin.y, width: winFrame.width, height: winFrame.height - 30), display: true)
        win.delegate = self
        self.window = win
        
        setupUI(in: win.contentView!, bounds: win.contentView!.bounds)
        
        // Ensure runtime is active and enabled
        if runtime.delegate == nil {
            runtime.delegate = self
        }
        runtime.setEnabled(true)
        
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        TouchBridgeLogger.info(.lifecycle, "Arbitration Test Window opened on Display #\(targetDisplay.id) at \(winFrame)")
    }
    
    private func setupUI(in parent: NSView, bounds: NSRect) {
        parent.wantsLayer = true
        parent.layer?.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1.0).cgColor
        
        let padding: CGFloat = 24.0
        var topY: CGFloat = bounds.height - 40
        
        // 1. Header
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = NSColor.white
        titleLabel.frame = NSRect(x: padding, y: topY, width: 800, height: 26)
        parent.addSubview(titleLabel)
        topY -= 30
        
        // HUD Stats Box
        let hudBox = NSBox(frame: NSRect(x: padding, y: topY - 80, width: bounds.width - (padding * 2), height: 100))
        hudBox.title = "Live Arbitration Telemetry"
        hudBox.titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        hudBox.contentView?.wantsLayer = true
        
        stateLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        stateLabel.textColor = NSColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1.0)
        stateLabel.frame = NSRect(x: 16, y: 52, width: 340, height: 20)
        hudBox.contentView?.addSubview(stateLabel)
        
        movementLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        movementLabel.textColor = NSColor.lightGray
        movementLabel.frame = NSRect(x: 16, y: 30, width: 440, height: 18)
        hudBox.contentView?.addSubview(movementLabel)
        
        cursorInvariantLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        cursorInvariantLabel.textColor = NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        cursorInvariantLabel.frame = NSRect(x: 16, y: 8, width: 440, height: 18)
        hudBox.contentView?.addSubview(cursorInvariantLabel)
        
        elementLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        elementLabel.textColor = NSColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
        elementLabel.frame = NSRect(x: 480, y: 52, width: 460, height: 20)
        hudBox.contentView?.addSubview(elementLabel)
        
        lastActionLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        lastActionLabel.textColor = NSColor.white
        lastActionLabel.frame = NSRect(x: 480, y: 30, width: 460, height: 18)
        hudBox.contentView?.addSubview(lastActionLabel)
        
        buttonStatsLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        buttonStatsLabel.textColor = NSColor(red: 0.4, green: 0.9, blue: 0.5, alpha: 1.0)
        buttonStatsLabel.frame = NSRect(x: 480, y: 8, width: 460, height: 18)
        hudBox.contentView?.addSubview(buttonStatsLabel)
        
        parent.addSubview(hudBox)
        topY -= 120
        
        // Split Columns: Left = Test A ScrollView with Buttons; Right = Switcher & Event Log
        let colWidth: CGFloat = (bounds.width - (padding * 3)) / 2.0
        let colHeight: CGFloat = topY - padding
        
        // ----------------- LEFT COLUMN: TEST A SCROLL VIEW -----------------
        let scrollTitle = NSTextField(labelWithString: "Test A: Scrollable Document View with 25 Embedded Buttons")
        scrollTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        scrollTitle.textColor = NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0)
        scrollTitle.frame = NSRect(x: padding, y: topY, width: colWidth, height: 20)
        parent.addSubview(scrollTitle)
        
        testAScrollView.frame = NSRect(x: padding, y: padding, width: colWidth, height: colHeight - 26)
        testAScrollView.hasVerticalScroller = true
        testAScrollView.hasHorizontalScroller = false
        testAScrollView.autohidesScrollers = false
        testAScrollView.borderType = .bezelBorder
        
        // Document View of 2600 pt height
        let docHeight: CGFloat = 2600.0
        testADocumentView.frame = NSRect(x: 0, y: 0, width: colWidth - 20, height: docHeight)
        testADocumentView.wantsLayer = true
        testADocumentView.layer?.backgroundColor = NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0).cgColor
        
        buildTestAContents(docView: testADocumentView, docWidth: colWidth - 20, docHeight: docHeight)
        testAScrollView.documentView = testADocumentView
        parent.addSubview(testAScrollView)
        
        // ----------------- RIGHT COLUMN: SWITCHER & EVENT LOG -----------------
        let rightX = padding * 2 + colWidth
        var rightY = topY
        
        let switchTitle = NSTextField(labelWithString: "Test Target Launcher & Mode Controls:")
        switchTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        switchTitle.textColor = NSColor.white
        switchTitle.frame = NSRect(x: rightX, y: rightY, width: colWidth, height: 20)
        parent.addSubview(switchTitle)
        rightY -= 36
        
        btnTestA.title = "Test A: Scroll View (Active)"
        btnTestA.bezelStyle = .rounded
        btnTestA.frame = NSRect(x: rightX, y: rightY, width: 145, height: 32)
        btnTestA.target = self
        btnTestA.action = #selector(handleTestAAction(_:))
        parent.addSubview(btnTestA)
        
        btnTestB.title = "Test B: Finder"
        btnTestB.bezelStyle = .rounded
        btnTestB.frame = NSRect(x: rightX + 152, y: rightY, width: 125, height: 32)
        btnTestB.target = self
        btnTestB.action = #selector(handleTestBAction(_:))
        parent.addSubview(btnTestB)
        
        btnTestC.title = "Test C: TextEdit"
        btnTestC.bezelStyle = .rounded
        btnTestC.frame = NSRect(x: rightX + 284, y: rightY, width: 125, height: 32)
        btnTestC.target = self
        btnTestC.action = #selector(handleTestCAction(_:))
        parent.addSubview(btnTestC)
        
        btnTestD.title = "Test D: Safari"
        btnTestD.bezelStyle = .rounded
        btnTestD.frame = NSRect(x: rightX + 416, y: rightY, width: 115, height: 32)
        btnTestD.target = self
        btnTestD.action = #selector(handleTestDAction(_:))
        parent.addSubview(btnTestD)
        rightY -= 42
        
        btnSaveReport.title = "Export P3-03 Physical Interaction Evidence"
        btnSaveReport.bezelStyle = .rounded
        btnSaveReport.frame = NSRect(x: rightX, y: rightY, width: 320, height: 32)
        btnSaveReport.target = self
        btnSaveReport.action = #selector(handleSaveReportAction(_:))
        parent.addSubview(btnSaveReport)
        rightY -= 36
        
        let logTitle = NSTextField(labelWithString: "Live Physical Interaction & Arbitration Log:")
        logTitle.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        logTitle.textColor = NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0)
        logTitle.frame = NSRect(x: rightX, y: rightY, width: colWidth, height: 18)
        parent.addSubview(logTitle)
        rightY -= 24
        
        let logHeight = rightY - padding
        logScrollView.frame = NSRect(x: rightX, y: padding, width: colWidth, height: logHeight)
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .bezelBorder
        
        logTextView.frame = NSRect(x: 0, y: 0, width: colWidth - 20, height: logHeight)
        logTextView.isEditable = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        logTextView.textColor = NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
        logTextView.string = "TouchBridge P3-02 Interaction Arbitrator Initialized.\nReady for direct physical contact gestures on external panel.\n"
        logScrollView.documentView = logTextView
        parent.addSubview(logScrollView)
    }
    
    private func buildTestAContents(docView: NSView, docWidth: CGFloat, docHeight: CGFloat) {
        var curY: CGFloat = docHeight - 40
        let btnWidth: CGFloat = 340.0
        let btnHeight: CGFloat = 36.0
        let btnX: CGFloat = (docWidth - btnWidth) / 2.0
        
        for i in 1...25 {
            let btn = NSButton()
            btn.title = "Button #\(i) (0 taps)"
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            btn.tag = i
            btn.target = self
            btn.action = #selector(handleTestButtonTapped(_:))
            btn.frame = NSRect(x: btnX, y: curY - btnHeight, width: btnWidth, height: btnHeight)
            docView.addSubview(btn)
            testButtons.append(btn)
            testButtonCounts.append(0)
            curY -= (btnHeight + 14)
            
            // Add blank gap and nested text field around Button 10
            if i == 5 || i == 15 {
                let blankLabel = NSTextField(labelWithString: "--- Blank Scroll Area (Swipe here to test pan without controls) ---")
                blankLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
                blankLabel.textColor = NSColor(red: 0.5, green: 0.5, blue: 0.6, alpha: 1.0)
                blankLabel.alignment = .center
                blankLabel.frame = NSRect(x: 20, y: curY - 30, width: docWidth - 40, height: 20)
                docView.addSubview(blankLabel)
                curY -= 60
            } else if i == 10 {
                let tfHeader = NSTextField(labelWithString: "Nested Control Test: NSTextField (Tap to focus, swipe to scroll ancestor)")
                tfHeader.font = NSFont.systemFont(ofSize: 11, weight: .bold)
                tfHeader.textColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
                tfHeader.frame = NSRect(x: btnX, y: curY - 20, width: btnWidth, height: 18)
                docView.addSubview(tfHeader)
                curY -= 24
                
                nestedTextField.frame = NSRect(x: btnX, y: curY - 32, width: btnWidth, height: 32)
                nestedTextField.placeholderString = "Tap to focus text field. Type on keyboard..."
                nestedTextField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
                docView.addSubview(nestedTextField)
                curY -= 55
            }
        }
    }
    
    // MARK: - Action Handlers
    
    @objc private func handleTestButtonTapped(_ sender: NSButton) {
        let idx = sender.tag - 1
        guard idx >= 0 && idx < testButtonCounts.count else { return }
        testButtonCounts[idx] += 1
        totalButtonActivations += 1
        sender.title = "Button #\(sender.tag) (\(testButtonCounts[idx]) taps)"
        
        buttonStatsLabel.stringValue = "Buttons Activated: \(totalButtonActivations) | Last: Button #\(sender.tag)"
        appendLog("[BUTTON ACTIVATED] Physical tap successfully dispatched to Button #\(sender.tag) (Count: \(testButtonCounts[idx]))")
    }
    
    @objc private func handleTestAAction(_ sender: NSButton) {
        appendLog("[TEST A] Refocusing TouchBridge AppKit Scroll View.")
    }
    
    @objc private func handleTestBAction(_ sender: NSButton) {
        appendLog("[TEST B] Launching & Positioning Finder on Touchscreen...")
        let appsURL = URL(fileURLWithPath: "/System/Applications")
        NSWorkspace.shared.open(appsURL)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, let display = DisplayManager.shared.findExternalTouchscreenDisplay() else { return }
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
                    self.appendLog("  [✓] Finder positioned at (\(targetPos.x), \(targetPos.y)) on external touchscreen.")
                }
            }
        }
    }
    
    @objc private func handleTestCAction(_ sender: NSButton) {
        appendLog("[TEST C] Launching & Positioning TextEdit on Touchscreen...")
        let docPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scratch/long_document.txt")
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let conf = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([docPath], withApplicationAt: textEditURL, configuration: conf) { [weak self] app, err in
            guard let app = app, err == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let self = self, let display = DisplayManager.shared.findExternalTouchscreenDisplay() else { return }
                let appElem = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: AnyObject?
                AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
                if let windows = windowsRef as? [AXUIElement], let teWin = windows.first {
                    var targetPos = CGPoint(x: display.cgOriginX + 60, y: display.cgOriginY + 60)
                    var targetSize = CGSize(width: 780, height: 720)
                    if let pVal = AXValueCreate(.cgPoint, &targetPos), let sVal = AXValueCreate(.cgSize, &targetSize) {
                        AXUIElementSetAttributeValue(teWin, kAXPositionAttribute as CFString, pVal)
                        AXUIElementSetAttributeValue(teWin, kAXSizeAttribute as CFString, sVal)
                        self.appendLog("  [✓] TextEdit positioned at (\(targetPos.x), \(targetPos.y)) on external touchscreen.")
                    }
                }
            }
        }
    }
    
    @objc private func handleTestDAction(_ sender: NSButton) {
        appendLog("[TEST D] Launching Safari for negative test (Unsupported Pan Suppression)...")
        let htmlPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test_browser_ax.html")
        NSWorkspace.shared.open(htmlPath)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, let display = DisplayManager.shared.findExternalTouchscreenDisplay() else { return }
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
                    self.appendLog("  [✓] Safari positioned at (\(targetPos.x), \(targetPos.y)) on external touchscreen.")
                }
            }
        }
    }
    
    @objc private func handleSaveReportAction(_ sender: NSButton) {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let reportURL = cwd.appendingPathComponent("p3_02_interaction_evidence.json")
        let dataDict: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "totalButtonActivations": totalButtonActivations,
            "buttonCounts": testButtonCounts,
            "stationaryJitterSamples": stationaryJitterSamples,
            "swipeDisplacements": swipeDisplacements,
            "physicalRecords": physicalRecords
        ]
        
        if let json = try? JSONSerialization.data(withJSONObject: dataDict, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: reportURL)
            appendLog("[SAVED] Physical evidence exported to \(reportURL.lastPathComponent)")
        }
    }
    
    public func appendLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timeStr = formatter.string(from: Date())
            let line = "[\(timeStr)] \(message)\n"
            
            self.physicalRecords.append(line)
            if let tv = self.logTextView.textStorage {
                tv.append(NSAttributedString(string: line, attributes: [
                    .foregroundColor: NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0),
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                ]))
                let scroller = self.logScrollView.verticalScroller
                let isNearBottom = (scroller?.doubleValue ?? 1.0) >= 0.98
                let isGestureActive = (TouchBridgeRuntime.shared.recognizer.activeSession != nil)
                if isNearBottom && !isGestureActive {
                    self.logTextView.scrollToEndOfDocument(nil)
                }
            }
        }
    }
    
    // MARK: - TouchBridgeRuntimeDelegate
    
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateSnapshot snapshot: RuntimeSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLabel.stringValue = "Engine: \(snapshot.engine) | Capability: \(snapshot.capability)"
        }
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didExecuteSemanticRecord record: SemanticEvidenceRecord) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastActionLabel.stringValue = "Result: \(record.classification.rawValue) [\(record.semanticAction.requestedAction)]"
            self.cursorInvariantLabel.stringValue = "Cursor Delta: \(String(format: "%.2f", record.cursor.deltaPt)) pt (Invariant: \(record.cursor.invariantSatisfied ? "PASS" : "FAIL"))"
            self.appendLog("[AX PRESS RECORD] \(record.classification.rawValue): \(record.visibleResult)")
        }
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateFeedback feedback: String, invariantPassed: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastActionLabel.stringValue = feedback
            self.cursorInvariantLabel.stringValue = "Cursor Invariant: \(invariantPassed ? "ISOLATED [PASS]" : "VIOLATION [FAIL]")"
            self.appendLog("[ROUTER FEEDBACK] \(feedback) [Invariant: \(invariantPassed ? "PASS" : "FAIL")]")
        }
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didCompleteSession session: InteractionSession, evidenceBlock: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.appendLog("\n" + evidenceBlock + "\n")
            LiveArbitrationValidator.shared.runtime(runtime, didCompleteSession: session, evidenceBlock: evidenceBlock)
        }
    }
    
    public func updateLiveTelemetry(state: GestureState, movement: Double, duration: Double, context: AXInteractionContext?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLabel.stringValue = "Gesture State: \(state.description)"
            self.movementLabel.stringValue = "Movement: \(String(format: "%.1f", movement)) pt | Thresh: \(GestureArbitrationConfig.panThresholdPt) pt | Dur: \(String(format: "%.3f", duration))s"
            
            if let ctx = context {
                self.elementLabel.stringValue = "AX Hit: [\(ctx.applicationName)] \(ctx.hitNode.role) (ScrollArea: \(ctx.scrollCapability.hasScrollArea ? "YES" : "NO"))"
            }
            
            if state == .tapExecuted && movement > 0 {
                self.stationaryJitterSamples.append(movement)
            } else if (state == .semanticPan || state == .unsupportedPan) && movement > 0 {
                self.swipeDisplacements.append(movement)
            }
        }
    }
}
