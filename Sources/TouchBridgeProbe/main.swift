import Foundation
import Cocoa
import IOKit
import IOKit.hid
import CoreGraphics

func printHelp() {
    print("""
    Usage: TouchBridgeProbe [options]

    Modes:
      (Default)           Launch native TouchBridge P3-01 Menu-Bar Prototype Runtime.
      --p2-gui            Launch legacy full-screen P2-A/B Semantic Tap Gate GUI.
      --probe-only        AX hit-test probe only (inspect element at physical tap without AXPress).
      --p2-cli            Run P2-A semantic tap gate in headless CLI mode.
      --calibrate         Force a fresh 4-point calibration session (replaces existing profile).
      --verify            Run P1 diagnostic verification window using saved calibration profile.
      --inspect-only      Enumerate HID and Display interfaces, print full technical metadata, then exit.
      --test-timestamps   Empirically validate real HID frame timestamps across gestures (P1.5 requirement 1).
      --test-arbitration  Launch P3-03 Interaction Router & Gesture Arbitration Testbed Window.
      --test-runtime      Run automated 29-test runtime and gesture arbitration validation suite.
      --live-diagnostics  Run real-time P3-03R live diagnostic telemetry stream (contacts, speed, backend, seize).
      --verify-arbitration Run live physical tap-vs-pan arbitration validation across all scenarios.
      --verify-gating     Run live hardware Enable/Disable gating verification.
      --verify-hotplug    Run live hardware USB hot-plug disconnect/reconnect verification.
      --duration <sec>    In CLI modes, run for specified seconds then exit.

    Display Binding Options:
      --display-id <id>   Manually bind to a specific CGDirectDisplayID instead of auto-discovering external display.
      --profile <path>    Load custom calibration profile JSON file.

    General Options:
      --help, -h          Show this help message.
    """)
}

func runCLIMonitor(display: DisplayMetadata, targetDevice: DeviceMetadata, duration: Double?) {
    print("================================================================================")
    print("       TouchBridge P1 — Coherent Terminal Touch Frame Monitor                   ")
    print("================================================================================")
    print("Target Device:  \(targetDevice.name) (VID: 0x\(String(format: "%04X", targetDevice.vendorID)), PID: 0x\(String(format: "%04X", targetDevice.productID)))")
    print("Target Display: \(display.name) (DisplayID: \(display.id), Size: \(Int(display.cgWidth))x\(Int(display.cgHeight)))")
    print("Mode:           Passive inspection (kIOHIDOptionsTypeNone) + Coherent Frame Aggregator")
    print("================================================================================\n")
    print("Touch the external touchscreen to observe coherent touch samples.")
    print("Press Ctrl+C to exit.\n")
    
    // Check for calibration profile
    let defaultURL = CalibrationProfile.defaultProfileURL(for: display.id)
    let profile = try? CalibrationProfile.load(from: defaultURL)
    if let prof = profile {
        print("[✓] Active calibration profile loaded (Mean residual error: \(String(format: "%.2f", prof.meanResidualError)) pt)")
    } else {
        print("[i] Running in uncalibrated mode (raw normalized mapping)")
    }
    
    let xElem = targetDevice.absoluteXElement
    let yElem = targetDevice.absoluteYElement
    let logMinX = xElem?.logicalMin ?? 0
    let logMaxX = xElem?.logicalMax ?? 4096
    let logMinY = yElem?.logicalMin ?? 0
    let logMaxY = yElem?.logicalMax ?? 4096
    
    var sampleCount = 0
    var downCount = 0
    var upCount = 0
    
    let aggregator = TouchFrameAggregator(
        logMinX: Int(logMinX), logMaxX: Int(logMaxX),
        logMinY: Int(logMinY), logMaxY: Int(logMaxY)
    ) { sample in
        sampleCount += 1
        if sample.phase == .down { downCount += 1 }
        if sample.phase == .up { upCount += 1 }
        
        let localStr: String
        if let prof = profile {
            let local = prof.mapToDisplayLocal(sensor: sample.normalizedSensorPoint)
            let g = local.toGlobal(display: display)
            localStr = String(format: " | LocalCG: [%6.1f, %6.1f] GlobalCG: [%6.1f, %6.1f]",
                              local.cgPoint.x, local.cgPoint.y, g.cgGlobal.x, g.cgGlobal.y)
        } else {
            let lx = sample.normX * display.cgWidth
            let ly = sample.normY * display.cgHeight
            localStr = String(format: " | UncalLocalCG: [%6.1f, %6.1f]", lx, ly)
        }
        
        print("\(sample.description)\(localStr)")
        fflush(stdout)
    }
    
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
    
    let openRes = IOHIDDeviceOpen(targetDevice.device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openRes == kIOReturnSuccess else {
        print("[ERROR] Failed to open HID device: 0x\(String(format: "%08X", openRes))")
        exit(1)
    }
    
    IOHIDDeviceRegisterInputValueCallback(targetDevice.device, callback, context)
    IOHIDDeviceScheduleWithRunLoop(targetDevice.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    
    if let dur = duration {
        print("[INFO] Monitoring for \(dur) seconds...")
        DispatchQueue.global().asyncAfter(deadline: .now() + dur) {
            print("\n[INFO] Duration of \(dur)s elapsed. Samples: \(sampleCount) (Down: \(downCount), Up: \(upCount))")
            exit(0)
        }
    }
    
    signal(SIGINT) { _ in
        print("\n\nSession terminated by Ctrl+C.")
        exit(0)
    }
    
    CFRunLoopRun()
}

func printTimestampSummary(_ summary: TimestampAnalysisSummary) {
    print("\n================================================================================")
    print("       TouchBridge P1.5 — Physical HID Timestamp Validation Summary             ")
    print("================================================================================")
    print("Total Raw Callbacks Processed: \(summary.totalCallbacks)")
    print("Total Discrete HID Reports:    \(summary.totalReports)")
    print("Inter-Report Arrival Delta:    Mean: \(String(format: "%.2f", summary.meanDeltaBetweenReportsMs)) ms (Min: \(String(format: "%.2f", summary.minDeltaBetweenReportsMs)) ms, Max: \(String(format: "%.2f", summary.maxDeltaBetweenReportsMs)) ms)")
    print("\nCallbacks per Report Distribution (Grouping by mach_absolute_time):")
    for (count, occurrences) in summary.callbacksPerReportDistribution.sorted(by: { $0.key < $1.key }) {
        let pct = Double(occurrences) / Double(max(1, summary.totalReports)) * 100.0
        print(String(format: "  %d callbacks/report: %4d reports (%5.1f%%)", count, occurrences, pct))
    }
    print("\nReports with Tip Switch + Coordinates: \(summary.reportsWithTipSwitchAndCoordinates)")
    print("Reports with Coordinates update only:   \(summary.reportsWithCoordinatesOnly)")
    
    print("\nRepresentative Physical Gesture Report Samples:")
    for (gesture, samples) in summary.representativeSamples.sorted(by: { $0.key < $1.key }) {
        print("\n  ▶ Gesture: [\(gesture.uppercased())] (\(samples.count) recorded)")
        for s in samples.prefix(3) {
            let tip = (s.tipSwitch != nil) ? "Tip=\(s.tipSwitch!) " : ""
            let xy = (s.x != nil && s.y != nil) ? "X=\(s.x!) Y=\(s.y!) " : ""
            let cid = (s.contactID != nil) ? "ID=\(s.contactID!) " : ""
            print(String(format: "    Report #%04d @ +%7.2fms (dt=%5.2fms) ts=%llu: %@%@%@(%d callbacks)",
                         s.reportIndex, s.timeOffsetMs, s.deltaFromLastReportMs, s.machTime, tip, xy, cid, s.callbackCount))
        }
    }
    
    print("\n--------------------------------------------------------------------------------")
    print("EMPIRICAL DETERMINATION (P1.5 Criterion 1):")
    if summary.allElementsInReportShareIdenticalTimestamp {
        print(">>> ALL callbacks belonging to one physical HID update share the EXACT SAME")
        print(">>> IOHIDValueGetTimeStamp timestamp (mach_absolute_time).")
        print(">>> Timestamp-based frame aggregation is 100% RELIABLE and VERIFIED.")
    } else {
        print(">>> WARNING: Mismatched timestamps observed within single update.")
    }
    print("================================================================================\n")
}

var globalTimestampValidator: TimestampValidator?

func runTimestampValidation(targetDevice: DeviceMetadata, duration: Double?) {
    let validator = TimestampValidator()
    globalTimestampValidator = validator
    
    print("================================================================================")
    print("       TouchBridge P1.5 — Physical HID Timestamp & Report Validation            ")
    print("================================================================================")
    print("Target Device:  \(targetDevice.name) (VID: 0x\(String(format: "%04X", targetDevice.vendorID)), PID: 0x\(String(format: "%04X", targetDevice.productID)))")
    print("Mode:           Passive raw IOHID callback inspection (kIOHIDOptionsTypeNone)")
    print("================================================================================\n")
    print("Physical Gesture Sequence to Perform on Touchscreen:")
    print("  1. [Touch Down]: Press finger firmly onto the glass.")
    print("  2. [Stationary Hold]: Hold completely still for ~1-2 seconds.")
    print("  3. [Slow Drag]: Drag finger slowly across the panel.")
    print("  4. [Fast Drag]: Drag finger rapidly across the panel.")
    print("  5. [Touch Up]: Lift finger from the glass.\n")
    print("Streaming real HID updates. Press Ctrl+C or wait for duration to finish...\n")
    fflush(stdout)
    
    let context = Unmanaged.passUnretained(validator).toOpaque()
    let callback: IOHIDValueCallback = { context, result, sender, value in
        guard let context = context else { return }
        let val = Unmanaged<TimestampValidator>.fromOpaque(context).takeUnretainedValue()
        let elem = IOHIDValueGetElement(value)
        let intVal = IOHIDValueGetIntegerValue(value)
        let machTime = IOHIDValueGetTimeStamp(value)
        val.recordCallback(elem: elem, val: intVal, machTime: machTime)
    }
    
    let openRes = IOHIDDeviceOpen(targetDevice.device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openRes == kIOReturnSuccess else {
        print("[ERROR] Failed to open HID device: 0x\(String(format: "%08X", openRes))")
        exit(1)
    }
    
    IOHIDDeviceRegisterInputValueCallback(targetDevice.device, callback, context)
    IOHIDDeviceScheduleWithRunLoop(targetDevice.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    
    let sigHandler: @convention(c) (Int32) -> Void = { _ in
        print("\n\nSignal received. Compiling timestamp analysis...")
        if let v = globalTimestampValidator {
            let summary = v.finishAndSaveSummary()
            printTimestampSummary(summary)
        }
        exit(0)
    }
    signal(SIGINT, sigHandler)
    signal(SIGTERM, sigHandler)
    
    if let dur = duration {
        print("[INFO] Session configured for \(dur) seconds...")
        DispatchQueue.global().asyncAfter(deadline: .now() + dur) {
            print("\n[INFO] Duration of \(dur)s elapsed. Compiling timestamp analysis...")
            let summary = validator.finishAndSaveSummary()
            printTimestampSummary(summary)
            exit(0)
        }
    }
    
    CFRunLoopRun()
}

func runCLISemanticGate(
    display: DisplayMetadata,
    targetDevice: DeviceMetadata,
    profile: CalibrationProfile,
    probeOnly: Bool,
    duration: Double?
) {
    print("================================================================================")
    print("       TouchBridge P2-A — CLI Pointer-Independent Semantic Gate                 ")
    print("================================================================================")
    print("Target Device:  \(targetDevice.name)")
    print("Target Display: \(display.name) (CG Bounds: [\(display.cgOriginX), \(display.cgOriginY), \(display.cgWidth), \(display.cgHeight)])")
    print("Mode:           \(probeOnly ? "Phase 2 AX Hit-Test Probe Only (No Actions)" : "Phase 4/5 Semantic Press (Pointer-Independent)")")
    print("================================================================================\n")
    
    let permStatus = AXPermissionManager.shared.checkPermission(requestPromptIfNeeded: true)
    if permStatus != .granted {
        print("[CRITICAL] Accessibility permission is UNAVAILABLE.")
        print("           Grant permission in System Settings -> Privacy & Security -> Accessibility.")
        exit(1)
    }
    print("[✓] Accessibility permission verified.")
    print("Ready for physical touchscreen taps. Press Ctrl+C to stop.\n")
    fflush(stdout)
    
    let xElem = targetDevice.absoluteXElement
    let yElem = targetDevice.absoluteYElement
    let logMinX = xElem?.logicalMin ?? 0
    let logMaxX = xElem?.logicalMax ?? 4096
    let logMinY = yElem?.logicalMin ?? 0
    let logMaxY = yElem?.logicalMax ?? 4096
    
    let tapRecognizer = SingleTapRecognizer(
        display: display,
        profile: profile,
        onTap: { tapEvent in
            if probeOnly {
                print("\n[PHYSICAL TAP OBSERVED] \(tapEvent)")
                let (_, snapshot, err) = AXSemanticEngine.shared.probeElementAt(globalCG: tapEvent.calibratedGlobalCG)
                if err == .success, let s = snapshot {
                    print("  Hit Element -> App: \(s.applicationName) (PID: \(s.pid)) | Role: \(s.role) | Subrole: \(s.subrole ?? "nil") | Title: \"\(s.title ?? "")\" | Value: \"\(s.value ?? "")\"")
                    print("  Supported Actions: \(s.supportedActions)")
                } else {
                    print("  Hit test returned error: \(AXSemanticEngine.shared.axErrorDescription(err))")
                }
            } else {
                _ = AXSemanticEngine.shared.performSemanticTap(tap: tapEvent, testCase: "CLI Semantic Tap")
                try? AXSemanticEngine.shared.saveEvidenceToFile(
                    at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("semantic_verification_records.json")
                )
            }
        },
        onCancelled: { reason, movement, duration in
            print("[TAP REJECTED] \(reason.rawValue): Movement: \(String(format: "%.1f", movement)) pt, Duration: \(String(format: "%.3f", duration))s")
        }
    )
    
    let aggregator = TouchFrameAggregator(
        logMinX: Int(logMinX), logMaxX: Int(logMaxX),
        logMinY: Int(logMinY), logMaxY: Int(logMaxY)
    ) { sample in
        tapRecognizer.processSample(sample)
    }
    
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
    
    let openRes = IOHIDDeviceOpen(targetDevice.device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openRes == kIOReturnSuccess else {
        print("[ERROR] Failed to open HID device: 0x\(String(format: "%08X", openRes))")
        exit(1)
    }
    
    IOHIDDeviceRegisterInputValueCallback(targetDevice.device, callback, context)
    IOHIDDeviceScheduleWithRunLoop(targetDevice.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    
    if let dur = duration {
        DispatchQueue.global().asyncAfter(deadline: .now() + dur) {
            print("\n[INFO] Duration of \(dur)s elapsed.")
            exit(0)
        }
    }
    
    signal(SIGINT) { _ in
        print("\nSession terminated by Ctrl+C.")
        exit(0)
    }
    
    CFRunLoopRun()
}

func main() {
    let args = CommandLine.arguments
    if args.contains("--help") || args.contains("-h") {
        printHelp()
        exit(0)
    }
    
    let testRuntime = args.contains("--test-runtime")
    if testRuntime {
        let report = RuntimeValidator.shared.runAllValidations()
        exit(report.allPassed ? 0 : 1)
    }
    
    let liveDiagnostics = args.contains("--live-diagnostics") || args.contains("--diagnostics")
    if liveDiagnostics {
        var dur: Double? = nil
        if let dIdx = args.firstIndex(of: "--duration"), dIdx + 1 < args.count, let d = Double(args[dIdx + 1]) {
            dur = d
        }
        LiveDiagnosticsRunner.shared.start(duration: dur)
        CFRunLoopRun()
        return
    }
    
    let verifyGating = args.contains("--verify-gating")
    if verifyGating {
        var dur: Double = 45.0
        if let dIdx = args.firstIndex(of: "--duration"), dIdx + 1 < args.count, let d = Double(args[dIdx + 1]) {
            dur = d
        }
        LiveInvariantValidator.shared.startGatingVerification(duration: dur)
        CFRunLoopRun()
        return
    }
    
    let verifyHotPlug = args.contains("--verify-hotplug")
    if verifyHotPlug {
        var dur: Double = 40.0
        if let dIdx = args.firstIndex(of: "--duration"), dIdx + 1 < args.count, let d = Double(args[dIdx + 1]) {
            dur = d
        }
        LiveInvariantValidator.shared.startHotPlugVerification(duration: dur)
        CFRunLoopRun()
        return
    }
    
    let testArbitration = args.contains("--test-arbitration")
    if testArbitration {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        
        let runtime = TouchBridgeRuntime.shared
        runtime.start()
        
        ArbitrationTestWindowController.shared.showTestWindow()
        
        if let dIdx = args.firstIndex(of: "--duration"), dIdx + 1 < args.count, let d = Double(args[dIdx + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                TouchBridgeLogger.info(.lifecycle, "Duration of \(d)s elapsed. Terminating arbitration testbed.")
                app.terminate(nil)
            }
        }
        
        app.run()
        return
    }
    
    let verifyArbitration = args.contains("--verify-arbitration")
    if verifyArbitration {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var dur: Double = 180.0
        if let dIdx = args.firstIndex(of: "--duration"), dIdx + 1 < args.count, let d = Double(args[dIdx + 1]) {
            dur = d
        }
        LiveArbitrationValidator.shared.startValidation(duration: dur)
        app.run()
        return
    }
    
    let testRollback = args.contains("--test-rollback")
    if testRollback {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var targetFilter: String? = nil
        if let fIdx = args.firstIndex(of: "--target"), fIdx + 1 < args.count {
            targetFilter = args[fIdx + 1]
        }
        RollbackReproducer.shared.runReproductionSuite(targetFilter: targetFilter) {
            TouchBridgeLogger.info(.lifecycle, "Rollback reproduction finished. Exiting.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                app.terminate(nil)
                exit(0)
            }
        }
        app.run()
        return
    }
    
    let inspectOnly = args.contains("--inspect-only")
    let listDisplays = args.contains("--displays")
    let testTimestamps = args.contains("--test-timestamps")
    let cliMonitor = args.contains("--cli-monitor")
    let forceCalibrate = args.contains("--calibrate")
    let runVerify = args.contains("--verify")
    let probeOnly = args.contains("--probe-only")
    let p2Cli = args.contains("--p2-cli")
    let testB = args.contains("--test-b") || args.contains("--test-calc")
    let testTextEdit = args.contains("--test-textedit")
    let testFinder = args.contains("--test-finder")
    let testC = args.contains("--test-c") || args.contains("--test-browser")
    
    var subTest: SemanticSubTest = .testA_appKit
    if testB { subTest = .testB_calculator }
    else if testTextEdit { subTest = .testC_textEdit }
    else if testFinder { subTest = .testD_finder }
    else if testC { subTest = .testE_browser }
    
    var duration: Double? = nil
    if let dIdx = args.firstIndex(of: "--duration"), dIdx + 1 < args.count {
        duration = Double(args[dIdx + 1])
    }
    
    var displayIDOverride: CGDirectDisplayID? = nil
    if let idIdx = args.firstIndex(of: "--display-id"), idIdx + 1 < args.count {
        displayIDOverride = CGDirectDisplayID(args[idIdx + 1])
    }
    
    var profilePath: String? = nil
    if let pIdx = args.firstIndex(of: "--profile"), pIdx + 1 < args.count {
        profilePath = args[pIdx + 1]
    }
    
    let displayManager = DisplayManager.shared
    let allDisplays = displayManager.enumerateDisplays()
    
    if listDisplays {
        print("================================================================================")
        print("                 TouchBridge — Connected Displays                               ")
        print("================================================================================")
        for d in allDisplays {
            print(d.description)
        }
        exit(0)
    }
    
    // HID Device Enumeration
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, nil)
    let allHID = HIDDeviceInspector.enumerateAll(manager: manager)
    let externalTouchscreens = allHID.filter { $0.isExternalTouchscreen }
    let candidateHID = allHID.filter { $0.isCandidateTouchscreen }
    let targetDevice = externalTouchscreens.first ?? candidateHID.first
    
    if inspectOnly {
        print("================================================================================")
        print("         TouchBridge P1 — Diagnostic Hardware & Display Inspection             ")
        print("================================================================================")
        
        print("[1] Connected Displays (\(allDisplays.count)):")
        for d in allDisplays {
            print(d.description)
        }
        
        print("\n[2] External Touchscreen Target Binding:")
        if let boundDisplay = displayManager.findExternalTouchscreenDisplay() {
            print("    [✓] Auto-bound to Display: \"\(boundDisplay.name)\" (ID: \(boundDisplay.id))")
            print("        Resolution: \(Int(boundDisplay.cgWidth))x\(Int(boundDisplay.cgHeight)) pt | Scale: \(boundDisplay.backingScaleFactor)x")
        } else {
            print("    [!] No external display identified.")
        }
        
        print("\n[3] HID Touchscreen Controller:")
        if let dev = targetDevice {
            print("    [✓] Found: \"\(dev.name)\" by \"\(dev.manufacturer)\"")
            print("        VID: 0x\(String(format: "%04X", dev.vendorID)), PID: 0x\(String(format: "%04X", dev.productID))")
            print("        Usage: \(HIDNames.usagePageName(dev.primaryUsagePage)) / \(HIDNames.usageName(page: dev.primaryUsagePage, usage: dev.primaryUsage))")
            if let x = dev.absoluteXElement, let y = dev.absoluteYElement {
                print("        Absolute X: [\(x.logicalMin) .. \(x.logicalMax)], Phys: [\(x.physicalMin) .. \(x.physicalMax)]")
                print("        Absolute Y: [\(y.logicalMin) .. \(y.logicalMax)], Phys: [\(y.physicalMin) .. \(y.physicalMax)]")
            }
            if let tip = dev.tipSwitchElement {
                print("        Tip Switch: Report ID \(tip.reportID), Range [\(tip.logicalMin) .. \(tip.logicalMax)]")
            }
            print("        Descriptor Collections: \(dev.fingerCollectionsCount) Finger collections (multitouch unverified at runtime)")
            if args.contains("--dump-elements") {
                print("        --- All Elements (\(dev.elements.count)): ---")
                for (idx, elem) in dev.elements.enumerated() {
                    let pStr = (elem.parentUsagePage != nil) ? " Parent:[0x\(String(format: "%02X", elem.parentUsagePage!)):0x\(String(format: "%02X", elem.parentUsage!))]" : ""
                    print("          [\(idx)] Cookie:0x\(String(format: "%04X", UInt32(elem.cookie))) Type:\(elem.typeName) Page:0x\(String(format: "%02X", elem.usagePage)) (\(elem.usagePageName)) Usage:0x\(String(format: "%02X", elem.usage)) (\(elem.usageName)) rID:\(elem.reportID) [\(elem.logicalMin)..\(elem.logicalMax)]\(pStr)")
                }
            }
        } else {
            print("    [!] No touchscreen HID controller found.")
        }
        
        print("\n[4] Existing Calibration Profiles:")
        if let boundDisplay = displayManager.findExternalTouchscreenDisplay() {
            let profURL = CalibrationProfile.defaultProfileURL(for: boundDisplay.id)
            if let prof = try? CalibrationProfile.load(from: profURL) {
                print("    [✓] Valid profile found: \(profURL.path)")
                print("        Created: \(prof.createdAt)")
                print("        Mean residual error: \(String(format: "%.2f", prof.meanResidualError)) pt, Max: \(String(format: "%.2f", prof.maxResidualError)) pt")
            } else {
                print("    [i] No saved profile found at \(profURL.path). Calibration required.")
            }
        }
        
        print("\n================================================================================\n")
        exit(0)
    }
    
    // Resolve target display for monitoring or GUI
    let targetDisplay: DisplayMetadata
    if let overrideID = displayIDOverride, let matched = allDisplays.first(where: { $0.id == overrideID }) {
        targetDisplay = matched
    } else if let auto = displayManager.findExternalTouchscreenDisplay() {
        targetDisplay = auto
    } else {
        print("[ERROR] No external touchscreen display discovered.")
        exit(1)
    }
    
    guard let dev = targetDevice else {
        print("[ERROR] Touchscreen HID device not found.")
        exit(1)
    }
    
    if testTimestamps {
        runTimestampValidation(targetDevice: dev, duration: duration)
        return
    }
    
    if cliMonitor {
        runCLIMonitor(display: targetDisplay, targetDevice: dev, duration: duration)
        return
    }
    
    // Load calibration profile for CLI mode
    var activeProfile: CalibrationProfile? = nil
    if let p = profilePath {
        activeProfile = try? CalibrationProfile.load(from: URL(fileURLWithPath: p))
    } else {
        let defURL = CalibrationProfile.defaultProfileURL(for: targetDisplay.id)
        activeProfile = (try? CalibrationProfile.load(from: defURL)) ?? (try? CalibrationProfile.load(from: URL(fileURLWithPath: "TouchBridgeCalibration.json")))
    }
    
    if p2Cli {
        guard let prof = activeProfile else {
            print("[ERROR] No valid calibration profile found. Run calibration first.")
            exit(1)
        }
        runCLISemanticGate(display: targetDisplay, targetDevice: dev, profile: prof, probeOnly: probeOnly, duration: duration)
        return
    }
    
    // Check whether to run the native P3-01 menu-bar prototype or legacy full-screen GUI
    let p2Gui = args.contains("--p2-gui")
    let hasTestFlags = testB || testTextEdit || testFinder || testC
    let runMenuBar = !runVerify && !forceCalibrate && !hasTestFlags && !probeOnly && !p2Gui
    
    let app = NSApplication.shared
    
    if runMenuBar {
        let delegate = AppDelegate.shared
        delegate.sessionDuration = duration
        app.delegate = delegate
        app.run()
        return
    }
    
    // Legacy Full-Screen Diagnostic GUI
    app.setActivationPolicy(.regular)
    
    let sessionMode: SessionMode
    if runVerify {
        sessionMode = .verification
    } else if forceCalibrate {
        sessionMode = .calibration
    } else {
        sessionMode = .semanticGate
    }
    
    let controller = TouchBridgeController(
        targetDisplayID: targetDisplay.id,
        forceCalibrate: forceCalibrate,
        profilePath: profilePath,
        sessionMode: sessionMode,
        probeOnly: probeOnly,
        initialSubTest: subTest
    )
    app.delegate = controller
    
    app.run()
}

main()

