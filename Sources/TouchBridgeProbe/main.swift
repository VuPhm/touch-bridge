import Foundation
import Cocoa
import IOKit
import IOKit.hid
import CoreGraphics

func printHelp() {
    print("""
    Usage: TouchBridgeProbe [options]

    Modes:
      (Default)           Launch native calibration & verification UI on the bound external touchscreen.
      --calibrate         Force a fresh 4-point calibration session (replaces existing profile).
      --verify            Run diagnostic verification window using saved calibration profile.
      --inspect-only      Enumerate HID and Display interfaces, print full technical metadata, then exit.
      --displays          List all connected displays with CoreGraphics and AppKit geometry.
      --test-timestamps   Empirically validate real HID frame timestamps across gestures (P1.5 requirement 1).
      --cli-monitor       Run passive terminal touch monitor using the coherent TouchFrameAggregator.
      --duration <sec>    In --cli-monitor or --test-timestamps mode, run for specified seconds then exit.

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

func main() {
    let args = CommandLine.arguments
    if args.contains("--help") || args.contains("-h") {
        printHelp()
        exit(0)
    }
    
    let inspectOnly = args.contains("--inspect-only")
    let listDisplays = args.contains("--displays")
    let testTimestamps = args.contains("--test-timestamps")
    let cliMonitor = args.contains("--cli-monitor")
    let forceCalibrate = args.contains("--calibrate")
    
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
        print("================================================================================\n")
        
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
    
    // Launch Native Cocoa GUI
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    
    let controller = TouchBridgeController(
        targetDisplayID: targetDisplay.id,
        forceCalibrate: forceCalibrate,
        profilePath: profilePath
    )
    app.delegate = controller
    
    app.run()
}

main()
