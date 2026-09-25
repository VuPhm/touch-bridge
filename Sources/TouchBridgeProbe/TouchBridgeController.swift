import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

public enum SessionMode {
    case calibration
    case verification
    case semanticGate
}

public enum SemanticSubTest: String {
    case testA_appKit = "Test A: TouchBridge AppKit"
    case testB_calculator = "Test B: Native External App (Calculator)"
    case testC_textEdit = "Test C: TextEdit Document"
    case testD_finder = "Test D: Finder List View"
    case testE_browser = "Test E: Browser Accessibility (HTML)"
}

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

public final class TouchBridgeController: NSObject, NSApplicationDelegate, CalibrationDelegate, NSWindowDelegate, SemanticTestViewDelegate {
    private var window: NSWindow?
    private var calibrationView: CalibrationView?
    private var diagnosticView: DiagnosticView?
    private var semanticTestView: SemanticTestView?
    
    private let displayManager = DisplayManager.shared
    private var targetDisplay: DisplayMetadata?
    private var activeProfile: CalibrationProfile?
    
    private var hidManager: IOHIDManager?
    private var touchAggregator: TouchFrameAggregator?
    private var tapRecognizer: SingleTapRecognizer?
    
    private var targetDisplayIDOverride: CGDirectDisplayID?
    private var forceCalibrate: Bool = false
    private var profilePathOverride: String?
    
    // P2-B Options
    private var sessionMode: SessionMode
    private var probeOnly: Bool = false
    private var currentSubTest: SemanticSubTest = .testA_appKit
    
    public init(
        targetDisplayID: CGDirectDisplayID? = nil,
        forceCalibrate: Bool = false,
        profilePath: String? = nil,
        sessionMode: SessionMode = .semanticGate,
        probeOnly: Bool = false,
        initialSubTest: SemanticSubTest = .testA_appKit
    ) {
        self.targetDisplayIDOverride = targetDisplayID
        self.forceCalibrate = forceCalibrate
        self.profilePathOverride = profilePath
        self.sessionMode = sessionMode
        self.probeOnly = probeOnly
        self.currentSubTest = initialSubTest
        super.init()
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupSession()
    }
    
    public func setupSession() {
        print("\n================================================================================")
        print("    TouchBridge P2-B — Real-World Semantic Interaction Coverage                 ")
        print("================================================================================\n")
        
        // Phase 1: Accessibility permission check
        AXPermissionManager.shared.printStatusBanner()
        let permStatus = AXPermissionManager.shared.checkPermission(requestPromptIfNeeded: true)
        if permStatus != .granted {
            print("\n[CRITICAL] Accessibility permission is currently UNAVAILABLE.")
            print("           macOS requires explicit user authorization for AX hit-testing.")
            print("           Please grant Accessibility permissions in System Settings and relaunch.\n")
            if sessionMode == .semanticGate {
                print("[HALTED] Cannot perform semantic AX interaction without Accessibility permissions.")
                exit(1)
            }
        }
        
        // 1. Resolve Target Display
        let displays = displayManager.enumerateDisplays()
        print("[1] Discovered \(displays.count) active display(s):")
        for d in displays {
            print(d.description)
        }
        
        if let overrideID = targetDisplayIDOverride {
            guard let matched = displays.first(where: { $0.id == overrideID }) else {
                print("[ERROR] Specified display ID \(overrideID) not found.")
                exit(1)
            }
            targetDisplay = matched
            print("\n[✓] Bound to user-specified display: \"\(matched.name)\" (#\(matched.id))")
        } else {
            guard let autoTarget = displayManager.findExternalTouchscreenDisplay() else {
                print("[ERROR] No external touchscreen display discovered.")
                print("        Please connect the external touchscreen or specify --display-id <id>.")
                exit(1)
            }
            targetDisplay = autoTarget
            print("\n[✓] Bound to target external touchscreen display: \"\(autoTarget.name)\" (#\(autoTarget.id))")
        }
        
        guard let display = targetDisplay else { return }
        
        // 2. Start Display Change Monitoring
        displayManager.startMonitoring { [weak self] event in
            self?.handleDisplayChange(event)
        }
        
        // 3. Find target NSScreen
        guard let targetScreen = NSScreen.screens.first(where: { screen in
            let sNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return sNum == display.id
        }) else {
            print("[ERROR] Could not match display #\(display.id) with an active NSScreen.")
            exit(1)
        }
        
        // 4. Create Native AppKit Window on Target Screen
        let win = KeyableWindow(
            contentRect: targetScreen.frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )
        win.setFrame(targetScreen.frame, display: true)
        win.isReleasedWhenClosed = false
        win.title = "TouchBridge Semantic Probe"
        win.delegate = self
        win.acceptsMouseMovedEvents = true
        self.window = win
        
        // 5. Load calibration profile
        var existingProfile: CalibrationProfile? = nil
        if let path = profilePathOverride {
            let url = URL(fileURLWithPath: path)
            existingProfile = try? CalibrationProfile.load(from: url)
        } else {
            let defaultURL = CalibrationProfile.defaultProfileURL(for: display.id)
            existingProfile = try? CalibrationProfile.load(from: defaultURL)
            if existingProfile == nil {
                let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TouchBridgeCalibration.json")
                existingProfile = try? CalibrationProfile.load(from: cwdURL)
            }
        }
        
        if let prof = existingProfile, !forceCalibrate {
            let staleCheck = prof.isStale(for: display)
            if staleCheck.stale {
                print("[WARNING] Existing calibration profile is stale: \(staleCheck.reason ?? "")")
                print("          Launching 4-point calibration UI...")
                activeProfile = prof
                startCalibration(on: win, display: display)
            } else {
                print("[✓] Loaded valid calibration profile for Display #\(display.id):")
                print("    - Mean residual error: \(String(format: "%.2f", prof.meanResidualError)) pt")
                print("    - Max residual error:  \(String(format: "%.2f", prof.maxResidualError)) pt")
                activeProfile = prof
                
                switch sessionMode {
                case .semanticGate:
                    startSemanticGate(on: win, display: display, profile: prof)
                case .verification:
                    startVerification(on: win, display: display, profile: prof)
                case .calibration:
                    startCalibration(on: win, display: display)
                }
            }
        } else {
            print("\n[INFO] Starting 4-point calibration on display: \"\(display.name)\"")
            startCalibration(on: win, display: display)
        }
        
        // 6. Initialize HID Touch Aggregator, Tap Recognizer, and Input Stream
        setupHIDStream()
        
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        switch currentSubTest {
        case .testA_appKit:
            switchToTestA()
        case .testB_calculator:
            switchToTestB()
        case .testC_textEdit:
            switchToTestC_TextEdit()
        case .testD_finder:
            switchToTestD_Finder()
        case .testE_browser:
            switchToTestE_Browser()
        }
        
        // Setup keyboard event monitor for shortcuts (S=save, Q=quit, 1..5=tests)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if chars == "q" || event.keyCode == 53 { // 'q' or Esc
                    self.saveAndQuit()
                    return nil
                } else if chars == "s" {
                    self.saveAllEvidence()
                    return nil
                } else if chars == "1" {
                    self.switchToTestA()
                    return nil
                } else if chars == "2" {
                    self.switchToTestB()
                    return nil
                } else if chars == "3" {
                    self.switchToTestC_TextEdit()
                    return nil
                } else if chars == "4" {
                    self.switchToTestD_Finder()
                    return nil
                } else if chars == "5" {
                    self.switchToTestE_Browser()
                    return nil
                }
            }
            return event
        }
    }
    
    private func setupHIDStream() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager
        
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey: 0x1A86,
            kIOHIDProductIDKey: 0xE5E3
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
        
        print("[✓] Passively connecting to HID Touchscreen (VID: 0x1A86, PID: 0xE5E3)")
        
        let aggregator = TouchFrameAggregator(
            logMinX: 0, logMaxX: 4096,
            logMinY: 0, logMaxY: 4096
        ) { [weak self] sample in
            self?.routeTouchSample(sample)
        }
        self.touchAggregator = aggregator
        
        // Setup SingleTapRecognizer if profile & display are available
        if let prof = activeProfile, let disp = targetDisplay {
            setupTapRecognizer(display: disp, profile: prof)
        }
        
        // Register raw IOHID callback
        let context = Unmanaged.passUnretained(aggregator).toOpaque()
        let callback: IOHIDValueCallback = { context, result, sender, value in
            guard let context = context else { return }
            let agg = Unmanaged<TouchFrameAggregator>.fromOpaque(context).takeUnretainedValue()
            
            let elem = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(elem)
            let usage = IOHIDElementGetUsage(elem)
            let val = IOHIDValueGetIntegerValue(value)
            let machTime = IOHIDValueGetTimeStamp(value)
            
            agg.handleElement(usagePage: page, usage: usage, value: val, machTime: machTime)
        }
        
        IOHIDManagerRegisterInputValueCallback(manager, callback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openRes == kIOReturnSuccess {
            print("  [✓] Passively opened IOHIDManager and scheduled on CommonModes.")
        } else {
            print("  [!] Failed to open IOHIDManager: 0x\(String(format: "%08X", openRes))")
        }
    }
    
    private func setupTapRecognizer(display: DisplayMetadata, profile: CalibrationProfile) {
        self.tapRecognizer = SingleTapRecognizer(
            display: display,
            profile: profile,
            onTap: { [weak self] tapEvent in
                self?.handleRecognizedTap(tapEvent)
            },
            onCancelled: { reason, movement, duration in
                print("[TAP CANCELLED] Reason: \(reason.rawValue) (Movement: \(String(format: "%.1f", movement)) pt, Duration: \(String(format: "%.3f", duration))s)")
            }
        )
    }
    
    private func routeTouchSample(_ sample: TouchSample) {
        if let cal = calibrationView {
            cal.handleTouchSample(sample)
        } else if let diag = diagnosticView {
            diag.handleTouchSample(sample)
        } else if sessionMode == .semanticGate {
            guard let prof = activeProfile, let disp = targetDisplay else { return }
            let local = prof.mapToDisplayLocal(sensor: sample.normalizedSensorPoint)
            let global = local.toGlobal(display: disp)
            let globalCG = global.cgGlobal
            
            switch sample.phase {
            case .down:
                _ = SemanticScrollController.shared.handleTouchDown(globalCG: globalCG)
                tapRecognizer?.processSample(sample)
                
            case .move:
                SemanticScrollController.shared.handleTouchMove(globalCG: globalCG)
                tapRecognizer?.processSample(sample)
                
            case .up:
                if let scrollRec = SemanticScrollController.shared.handleTouchUp(globalCG: globalCG) {
                    if scrollRec.success {
                        semanticTestView?.updateEvidenceFeedback(
                            "Scroll [\(scrollRec.targetApplication)]: \(scrollRec.resultSummary)",
                            invariantPassed: scrollRec.cursorDelta < 0.001
                        )
                    }
                }
                tapRecognizer?.processSample(sample)
            }
        }
    }
    
    private func handleRecognizedTap(_ tap: PhysicalTapEvent) {
        let testCaseName = currentSubTest.rawValue
        
        if probeOnly {
            print("\n[PROBE ONLY] Hit-testing element at calibrated Global CG: (\(String(format: "%.1f, %.1f", tap.calibratedGlobalCG.x, tap.calibratedGlobalCG.y)))...")
            let (elemOpt, _, err) = AXSemanticEngine.shared.probeElementAt(globalCG: tap.calibratedGlobalCG)
            if err == .success, let elem = elemOpt {
                let inspection = AXCapabilityInspector.shared.inspect(element: elem)
                print("  Hit Element -> App: \(inspection.applicationName) (PID: \(inspection.pid)) | Role: \(inspection.hitNode.role) | Subrole: \(inspection.hitNode.subrole ?? "nil") | Title: \"\(inspection.hitNode.title ?? "")\" | Value: \"\(inspection.hitNode.value ?? "")\"")
                print("  Actions: \(inspection.hitNode.supportedActions)")
                print("  Settable Attributes: \(inspection.hitNode.settableAttributes)")
                print("  Scroll Mechanism: \(inspection.scrollCapability.mechanism)")
            } else {
                print("  Hit-test failed with error: \(AXSemanticEngine.shared.axErrorDescription(err))")
            }
            return
        }
        
        // 1. Probe element to detect class of interaction
        let (elemOpt, _, err) = AXSemanticEngine.shared.probeElementAt(globalCG: tap.calibratedGlobalCG)
        guard err == .success, let elem = elemOpt else {
            let record = AXSemanticEngine.shared.performSemanticTap(tap: tap, testCase: testCaseName)
            semanticTestView?.updateEvidenceFeedback(record.visibleResult, invariantPassed: record.cursor.invariantSatisfied)
            return
        }
        
        let inspection = AXCapabilityInspector.shared.inspect(element: elem)
        let role = inspection.hitNode.role
        
        // Interaction Class C: Text field focus
        if role == "AXTextField" || role == "AXTextArea" || (inspection.hitNode.isFocusSettable && role != "AXButton" && role != "AXCheckBox" && role != "AXPopUpButton") {
            let focusRec = SemanticFocusController.shared.attemptFocus(element: elem)
            semanticTestView?.updateEvidenceFeedback(
                "Focus [\(inspection.applicationName) \(role)]: \(focusRec.classification) (Cursor delta: \(String(format: "%.2f", focusRec.cursorDelta)) pt)",
                invariantPassed: focusRec.cursorDelta < 0.001
            )
            return
        }
        
        // Interaction Class B / E: PopUp, Menu, List Selection, Standard Buttons
        let record = AXSemanticEngine.shared.performSemanticTap(tap: tap, testCase: testCaseName)
        semanticTestView?.updateEvidenceFeedback(record.visibleResult, invariantPassed: record.cursor.invariantSatisfied)
        
        // Auto-save evidence after every successful tap
        try? AXSemanticEngine.shared.saveEvidenceToFile(
            at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("semantic_verification_records.json")
        )
    }
    
    // MARK: - Mode Transitions
    
    private func startSemanticGate(on win: NSWindow, display: DisplayMetadata, profile: CalibrationProfile) {
        diagnosticView = nil
        calibrationView = nil
        
        let semView = SemanticTestView(frame: win.contentView?.bounds ?? .zero, display: display, profile: profile)
        semView.delegate = self
        win.contentView = semView
        self.semanticTestView = semView
        self.sessionMode = .semanticGate
        if currentSubTest == .testA_appKit {
            print("\n[INFO] Semantic Tap Gate UI active on external display \"\(display.name)\".")
            print("       Test A: Native AppKit Controls (NSButton, NSCheckbox, NSSwitch, NSTextField, NSScrollView, NSTableView).")
            print("       Perform physical taps and pans on the touchscreen.")
            print("       (System mouse cursor remains completely stationary.)\n")
        }
    }
    
    private func startCalibration(on win: NSWindow, display: DisplayMetadata) {
        diagnosticView = nil
        semanticTestView = nil
        let calView = CalibrationView(frame: win.contentView?.bounds ?? .zero, display: display)
        calView.delegate = self
        win.contentView = calView
        self.calibrationView = calView
    }
    
    private func startVerification(on win: NSWindow, display: DisplayMetadata, profile: CalibrationProfile) {
        calibrationView = nil
        semanticTestView = nil
        let diagView = DiagnosticView(frame: win.contentView?.bounds ?? .zero, display: display, profile: profile)
        win.contentView = diagView
        self.diagnosticView = diagView
    }
    
    public func calibrationDidComplete(profile: CalibrationProfile) {
        self.activeProfile = profile
        guard let win = self.window, let display = self.targetDisplay else { return }
        setupTapRecognizer(display: display, profile: profile)
        startSemanticGate(on: win, display: display, profile: profile)
    }
    
    public func calibrationDidCancel() {
        saveAndQuit()
    }
    
    // MARK: - SemanticTestViewDelegate
    
    public func semanticTestViewDidRequestSwitchToAppKit() {
        switchToTestA()
    }
    
    public func semanticTestViewDidRequestSwitchToCalculator() {
        switchToTestB()
    }
    
    public func semanticTestViewDidRequestSwitchToTextEdit() {
        switchToTestC_TextEdit()
    }
    
    public func semanticTestViewDidRequestSwitchToFinder() {
        switchToTestD_Finder()
    }
    
    public func semanticTestViewDidRequestSwitchToBrowser() {
        switchToTestE_Browser()
    }
    
    public func semanticTestViewDidRequestSaveReport() {
        saveAllEvidence()
    }
    
    private func moveTouchBridgeHUDToPrimaryScreen() {
        guard let win = self.window else { return }
        if let primaryScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        }) {
            let hudRect = NSRect(x: primaryScreen.frame.origin.x + 20, y: primaryScreen.frame.origin.y + 40, width: 620, height: 420)
            win.setFrame(hudRect, display: true)
        }
    }
    
    public func switchToTestA() {
        guard let win = self.window, let display = self.targetDisplay, let profile = self.activeProfile else { return }
        currentSubTest = .testA_appKit
        
        // Restore window to full frame on external screen
        guard let targetScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.id
        }) else { return }
        
        win.setFrame(targetScreen.frame, display: true)
        startSemanticGate(on: win, display: display, profile: profile)
        print("\n>>> ACTIVE TEST: Test A — TouchBridge Native AppKit Controls")
        print("    External screen now presents native NSButton, NSCheckbox, NSSwitch, NSTextField, NSScrollView, NSTableView.")
    }
    
    public func switchToTestB() {
        currentSubTest = .testB_calculator
        print("\n>>> ACTIVE TEST: Test B — Separate Native macOS Application (Calculator)")
        print("    Moving TouchBridge window to Primary Display HUD to UNCOVER external touchscreen.")
        moveTouchBridgeHUDToPrimaryScreen()
        launchAndPositionCalculator()
    }
    
    public func switchToTestC_TextEdit() {
        currentSubTest = .testC_textEdit
        print("\n>>> ACTIVE TEST: Test C — TextEdit Long Document (Text Focus & Semantic Scroll)")
        print("    Moving TouchBridge window to Primary Display HUD to UNCOVER external touchscreen.")
        moveTouchBridgeHUDToPrimaryScreen()
        launchAndPositionTextEdit()
    }
    
    public func switchToTestD_Finder() {
        currentSubTest = .testD_finder
        print("\n>>> ACTIVE TEST: Test D — Finder List View (Row Selection & Semantic Scroll)")
        print("    Moving TouchBridge window to Primary Display HUD to UNCOVER external touchscreen.")
        moveTouchBridgeHUDToPrimaryScreen()
        launchAndPositionFinder()
    }
    
    public func switchToTestE_Browser() {
        currentSubTest = .testE_browser
        print("\n>>> ACTIVE TEST: Test E — Browser Accessibility (Safari / test_browser_ax.html)")
        print("    Moving TouchBridge window to Primary Display HUD to UNCOVER external touchscreen.")
        moveTouchBridgeHUDToPrimaryScreen()
        launchAndPositionBrowser()
    }
    
    private func launchAndPositionCalculator() {
        let calcURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        NSWorkspace.shared.openApplication(at: calcURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] app, err in
            guard let app = app, err == nil else {
                print("[ERROR] Could not launch Calculator: \(err?.localizedDescription ?? "")")
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self = self, let display = self.targetDisplay else { return }
                let appElem = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: AnyObject?
                AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
                if let windows = windowsRef as? [AXUIElement], let calcWin = windows.first {
                    // Position Calculator on external touchscreen: center of display
                    var targetPos = CGPoint(x: display.cgOriginX + 150, y: display.cgOriginY + 120)
                    if let posVal = AXValueCreate(.cgPoint, &targetPos) {
                        AXUIElementSetAttributeValue(calcWin, kAXPositionAttribute as CFString, posVal)
                        print("  [✓] Positioned Calculator on external display at (\(targetPos.x), \(targetPos.y))")
                        print("  [✓] External screen is UNCOVERED. Tap Calculator buttons on the touchscreen!")
                    }
                }
            }
        }
    }
    
    private func launchAndPositionTextEdit() {
        let docPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scratch/long_document.txt")
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let conf = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([docPath], withApplicationAt: textEditURL, configuration: conf) { [weak self] app, err in
            guard let app = app, err == nil else {
                print("[ERROR] Could not launch TextEdit: \(err?.localizedDescription ?? "")")
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let self = self, let display = self.targetDisplay else { return }
                let appElem = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: AnyObject?
                AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
                if let windows = windowsRef as? [AXUIElement], let teWin = windows.first {
                    var targetPos = CGPoint(x: display.cgOriginX + 60, y: display.cgOriginY + 60)
                    var targetSize = CGSize(width: 780, height: 720)
                    if let pVal = AXValueCreate(.cgPoint, &targetPos), let sVal = AXValueCreate(.cgSize, &targetSize) {
                        AXUIElementSetAttributeValue(teWin, kAXPositionAttribute as CFString, pVal)
                        AXUIElementSetAttributeValue(teWin, kAXSizeAttribute as CFString, sVal)
                        print("  [✓] Positioned TextEdit on external display at (\(targetPos.x), \(targetPos.y))")
                        print("  [✓] External screen is UNCOVERED. Touch to scroll and focus editable text!")
                    }
                }
            }
        }
    }
    
    private func launchAndPositionFinder() {
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
                    print("  [✓] Positioned Finder on external display at (\(targetPos.x), \(targetPos.y))")
                    print("  [✓] External screen is UNCOVERED. Touch to select rows and scroll list view!")
                }
            }
        }
    }
    
    private func launchAndPositionBrowser() {
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
                var targetSize = CGSize(width: 820, height: 750)
                if let pVal = AXValueCreate(.cgPoint, &targetPos), let sVal = AXValueCreate(.cgSize, &targetSize) {
                    AXUIElementSetAttributeValue(safWin, kAXPositionAttribute as CFString, pVal)
                    AXUIElementSetAttributeValue(safWin, kAXSizeAttribute as CFString, sVal)
                    print("  [✓] Positioned Safari on external display at (\(targetPos.x), \(targetPos.y))")
                    print("  [✓] External screen is UNCOVERED. Tap controls, text input, select, and test nested scroll!")
                }
            }
        }
    }
    
    private func handleDisplayChange(_ event: DisplayChangeEvent) {
        print("\n[DISPLAY RECONFIG] Received display event: \(event)")
    }
    
    private func saveAllEvidence() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let evidenceURL = cwd.appendingPathComponent("semantic_verification_records.json")
        let scrollURL = cwd.appendingPathComponent("scroll_verification_records.json")
        let focusURL = cwd.appendingPathComponent("focus_verification_records.json")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            try AXSemanticEngine.shared.saveEvidenceToFile(at: evidenceURL)
            let all = AXSemanticEngine.shared.getAllEvidence()
            print("\n[✓] Semantic tap verification evidence saved to: \(evidenceURL.path) (\(all.count) records)")
        } catch {
            print("[WARNING] Could not save semantic tap evidence: \(error)")
        }
        
        do {
            let scrolls = SemanticScrollController.shared.getScrollRecords()
            let scrollData = try encoder.encode(scrolls)
            try scrollData.write(to: scrollURL)
            print("[✓] Scroll verification evidence saved to: \(scrollURL.path) (\(scrolls.count) records)")
        } catch {
            print("[WARNING] Could not save scroll evidence: \(error)")
        }
        
        do {
            let focuses = SemanticFocusController.shared.getFocusRecords()
            let focusData = try encoder.encode(focuses)
            try focusData.write(to: focusURL)
            print("[✓] Focus verification evidence saved to: \(focusURL.path) (\(focuses.count) records)")
        } catch {
            print("[WARNING] Could not save focus evidence: \(error)")
        }
    }
    
    private func saveAndQuit() {
        saveAllEvidence()
        print("\n[INFO] Exiting TouchBridge probe session.")
        NSApp.terminate(nil)
    }
}
