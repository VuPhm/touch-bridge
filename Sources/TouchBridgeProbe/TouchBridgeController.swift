import Foundation
import Cocoa
import CoreGraphics

public final class TouchBridgeController: NSObject, NSApplicationDelegate, CalibrationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var calibrationView: CalibrationView?
    private var diagnosticView: DiagnosticView?
    
    private let displayManager = DisplayManager.shared
    private var targetDisplay: DisplayMetadata?
    private var activeProfile: CalibrationProfile?
    
    private var hidManager: IOHIDManager?
    private var hidMonitor: HIDInputMonitor?
    private var touchAggregator: TouchFrameAggregator?
    
    private var targetDisplayIDOverride: CGDirectDisplayID?
    private var forceCalibrate: Bool = false
    private var profilePathOverride: String?
    
    public init(targetDisplayID: CGDirectDisplayID? = nil, forceCalibrate: Bool = false, profilePath: String? = nil) {
        self.targetDisplayIDOverride = targetDisplayID
        self.forceCalibrate = forceCalibrate
        self.profilePathOverride = profilePath
        super.init()
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupSession()
    }
    
    public func setupSession() {
        print("\n================================================================================")
        print("          TouchBridge P1 — Native Display Binding & Calibration                 ")
        print("================================================================================\n")
        
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
        let win = NSWindow(
            contentRect: targetScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )
        win.setFrame(targetScreen.frame, display: true)
        win.isReleasedWhenClosed = false
        win.title = "TouchBridge Diagnostic Window"
        win.delegate = self
        win.acceptsMouseMovedEvents = true
        self.window = win
        
        // 5. Initialize HID Touch Aggregator & Input Stream
        setupHIDStream()
        
        // 6. Check for existing calibration profile
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
                startCalibration(on: win, display: display)
            } else {
                print("[✓] Loaded valid calibration profile for Display #\(display.id):")
                print("    - Mean residual error: \(String(format: "%.2f", prof.meanResidualError)) pt")
                print("    - Max residual error:  \(String(format: "%.2f", prof.maxResidualError)) pt")
                activeProfile = prof
                startVerification(on: win, display: display, profile: prof)
            }
        } else {
            print("\n[INFO] Starting 4-point calibration on display: \"\(display.name)\"")
            startCalibration(on: win, display: display)
        }
        
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Setup keyboard event monitor for shortcuts (S=save, R=recalibrate, Q=quit)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if chars == "q" || event.keyCode == 53 { // 'q' or Esc
                    self?.saveAndQuit()
                    return nil
                } else if chars == "s" {
                    self?.saveVerificationReport()
                    return nil
                } else if chars == "r" {
                    self?.recalibrate()
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
        
        // Register raw IOHID callback directly on retained manager
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
    
    private func routeTouchSample(_ sample: TouchSample) {
        if let cal = calibrationView {
            cal.handleTouchSample(sample)
        } else if let diag = diagnosticView {
            diag.handleTouchSample(sample)
        }
    }
    
    private func startCalibration(on win: NSWindow, display: DisplayMetadata) {
        diagnosticView = nil
        let calView = CalibrationView(frame: win.contentView?.bounds ?? .zero, display: display)
        calView.delegate = self
        win.contentView = calView
        self.calibrationView = calView
    }
    
    private func startVerification(on win: NSWindow, display: DisplayMetadata, profile: CalibrationProfile) {
        calibrationView = nil
        let diagView = DiagnosticView(frame: win.contentView?.bounds ?? .zero, display: display, profile: profile)
        win.contentView = diagView
        self.diagnosticView = diagView
        print("\n[INFO] Diagnostic verification window active on display \"\(display.name)\".")
        print("       Touch the screen to test 4 corners, center, edges, and diagonal drag.")
        print("       (Note: The macOS system cursor remains completely untouched.)\n")
    }
    
    public func calibrationDidComplete(profile: CalibrationProfile) {
        self.activeProfile = profile
        guard let win = self.window, let display = self.targetDisplay else { return }
        startVerification(on: win, display: display, profile: profile)
    }
    
    public func calibrationDidCancel() {
        saveAndQuit()
    }
    
    private func recalibrate() {
        guard let win = self.window, let display = self.targetDisplay else { return }
        print("\n[INFO] Recalibration requested by user.")
        startCalibration(on: win, display: display)
    }
    
    private func handleDisplayChange(_ event: DisplayChangeEvent) {
        print("\n[DISPLAY RECONFIG] Received display event: \(event)")
        guard let display = targetDisplay else { return }
        
        let activeDisplays = displayManager.enumerateDisplays()
        guard let updated = activeDisplays.first(where: { $0.id == display.id }) else {
            print("[CRITICAL] Target display #\(display.id) was disconnected!")
            // Close window and report
            window?.orderOut(nil)
            return
        }
        
        if let prof = activeProfile {
            let staleCheck = prof.isStale(for: updated)
            if staleCheck.stale {
                print("[WARNING] Target display parameters changed: \(staleCheck.reason ?? "")")
                print("          Marking calibration stale. Recalibration required.")
                targetDisplay = updated
                if let win = window {
                    startCalibration(on: win, display: updated)
                }
            }
        }
    }
    
    private func saveVerificationReport() {
        guard let diag = diagnosticView else { return }
        let summary = diag.getVerificationSummary()
        let reportURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("verification_results.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL)
            print("\n[✓] Verification report successfully saved to: \(reportURL.path)")
        } catch {
            print("[WARNING] Could not save verification report: \(error)")
        }
    }
    
    private func saveAndQuit() {
        saveVerificationReport()
        print("\n[INFO] Exiting TouchBridge diagnostic session.")
        NSApp.terminate(nil)
    }
}
