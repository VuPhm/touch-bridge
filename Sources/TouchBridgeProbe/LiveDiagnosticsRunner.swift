import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

// MARK: - P3-03R Live Touch Diagnostics Runner

public final class LiveDiagnosticsRunner: NSObject, TouchBridgeRuntimeDelegate {
    public static let shared = LiveDiagnosticsRunner()
    
    private let runtime = TouchBridgeRuntime.shared
    private var isRunning: Bool = false
    private var timer: Timer? = nil
    
    public override init() {
        super.init()
    }
    
    @discardableResult
    public func start(duration: Double? = nil) -> Bool {
        let permissionManager = AXPermissionManager.shared
        let trustedBeforeRequest = permissionManager.isTrusted()
        if !trustedBeforeRequest {
            // Release any stale ownership before prompting. No device start/seize is
            // attempted until trust has actually become available.
            runtime.setEnabled(false)
            runtime.shutdown()
        }
        _ = permissionManager.checkPermission(requestPromptIfNeeded: true)
        let trustedAfterRequest = permissionManager.isTrusted()
        print("Accessibility permission before diagnostics: \(trustedBeforeRequest ? "TRUSTED" : "UNTRUSTED")")
        print("Accessibility permission request issued: \(permissionManager.promptRequestIssuedByLastCheck ? "YES" : "NO")")
        print("Accessibility permission after request: \(trustedAfterRequest ? "TRUSTED" : "UNTRUSTED")")
        if !trustedAfterRequest {
            print("macOS permission UI may appear asynchronously.")
            print("Enable TouchBridgeProbe in System Settings → Privacy & Security → Accessibility.")
            print("Accessibility permission required — touchscreen interaction not enabled")
            fflush(stdout)
            return false
        }

        guard runtime.start() else {
            print("Accessibility permission required — touchscreen interaction not enabled")
            fflush(stdout)
            return false
        }
        self.isRunning = true

        let boundDisplay = DisplayManager.shared.findExternalTouchscreenDisplay()
        
        print("""
        ================================================================================
                    TOUCHBRIDGE P3-03R — LIVE INTERACTION DIAGNOSTICS
        ================================================================================
        Tap Backend:       \(runtime.router.tapBackendMode.diagnosticName)
        Target Display:    \(boundDisplay?.name ?? "External") (ID: \(boundDisplay?.id ?? 0), Bounds: \(boundDisplay?.cgWidth ?? 0)x\(boundDisplay?.cgHeight ?? 0))
        Target Touchscreen: USB2IIC_CTP_CONTROL (VID: 0x1A86, PID: 0xE5E3)
        Exclusive Seize:   kIOHIDOptionsTypeSeizeDevice (Digitizer Collection Exclusive)
        Pan Threshold:     \(GestureArbitrationConfig.panThresholdPt) pt
        Velocity Decay:    \(GestureArbitrationConfig.momentumDecayFactor) per frame (~60Hz)
        Min Flick Speed:   \(GestureArbitrationConfig.minFlickVelocityPtPerSec) pt/s
        ================================================================================
        Touch the physical touchscreen to observe real-time gesture telemetry.
        Interact with:
          - Finder controls / table rows
          - TextEdit editable area
          - Safari web links and content
          - Rapid alternating tap/pan
          - External mouse (verify independent usability)
        Press Ctrl+C to stop.
        ================================================================================
        """)
        fflush(stdout)
        
        runtime.delegate = self
        runtime.setEnabled(true)
        
        // Print Seize status
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let seized = self.runtime.device.isExclusivelySeized
            let status = seized ? "EXCLUSIVE SEIZED [PASS]" : "OWNERSHIP UNAVAILABLE [INTERACTION DISABLED]"
            print("[HID OWNERSHIP] Device status: \(status)")
            if seized {
                print("  -> macOS WindowServer / IOHIDEventSystem digitizer observation DETACHED.")
                print("  -> TouchBridge is the SOLE consumer of physical touchscreen contacts.")
            }
            fflush(stdout)
        }
        
        // Periodic telemetry inspection timer (30 Hz)
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.sampleTelemetry()
        }
        
        if let d = duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                print("\n[INFO] Diagnostic session duration of \(d)s reached.")
                self?.stop()
                exit(0)
            }
        }
        
        signal(SIGINT) { _ in
            print("\n[INFO] Diagnostic session terminated by user.")
            LiveDiagnosticsRunner.shared.stop()
            exit(0)
        }
        return true
    }
    
    public func stop() {
        self.isRunning = false
        timer?.invalidate()
        timer = nil
        runtime.shutdown()
    }
    
    private var lastPrintedState: String = ""
    
    private func sampleTelemetry() {
        guard let session = runtime.recognizer.activeSession else { return }
        
        let contactsCount = runtime.recognizer.activeContacts.count
        let contactIDs = runtime.recognizer.activeContacts.keys.sorted().map { String($0) }.joined(separator: ", ")
        let primaryID = session.contactID
        let rawPt = session.startRawPoint
        let globalPt = session.latestGlobalPoint.cgGlobal
        let state = session.state.description
        let vel = session.filteredVelocity
        let speed = hypot(vel.dx, vel.dy)
        let seized = runtime.device.isExclusivelySeized ? "EXCLUSIVE" : "SHARED"
        
        let backend = session.diagnosticBackend
        
        let line = String(
            format: "[DIAG] Contacts: %d [IDs: %@] | PrimID: %d | Raw: (%4d, %4d) -> Mapped: (%6.1f, %6.1f) | State: %-12@ | Speed: %5.1f pt/s | Backend: %-16@ | Seize: %@",
            contactsCount,
            contactIDs.isEmpty ? "None" : contactIDs,
            primaryID,
            rawPt.x, rawPt.y,
            globalPt.x, globalPt.y,
            state,
            speed,
            backend,
            seized
        )
        
        if line != lastPrintedState {
            print(line)
            fflush(stdout)
            lastPrintedState = line
        }
    }
    
    // MARK: - TouchBridgeRuntimeDelegate
    
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateSnapshot snapshot: RuntimeSnapshot) {}
    
    public func runtime(_ runtime: TouchBridgeRuntime, didExecuteSemanticRecord record: SemanticEvidenceRecord) {
        let app = record.axHitTest?.applicationName ?? "Unknown"
        let role = record.axHitTest?.role ?? "Unknown"
        let title = record.axHitTest?.title ?? ""
        print("\n--------------------------------------------------------------------------------")
        print("[SEMANTIC ACTION DISPATCHED]")
        print("Target:   [\(app)] \(role) (\"\(title)\")")
        print("Backend:  AX_PRESS (Semantic)")
        print("Result:   \(record.visibleResult)")
        print("Cursor:   Before=(\(record.cursor.beforeX), \(record.cursor.beforeY)) -> After=(\(record.cursor.afterX), \(record.cursor.afterY)) [Isolated: \(record.cursor.invariantSatisfied)]")
        print("--------------------------------------------------------------------------------\n")
        fflush(stdout)
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateFeedback feedback: String, invariantPassed: Bool) {
        if runtime.router.tapBackendMode == .transientPointer {
            print("[EVENT FEEDBACK] \(feedback) (Cursor Position Restored: \(invariantPassed ? "YES" : "NO"))")
        } else {
            print("[EVENT FEEDBACK] \(feedback) (Cursor Isolated: \(invariantPassed ? "YES" : "NO"))")
        }
        fflush(stdout)
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didCompleteSession session: InteractionSession, evidenceBlock: String) {
        let seized = runtime.device.isExclusivelySeized ? "EXCLUSIVE" : "SHARED"
        print("\n================================================================================")
        print("SESSION COMPLETED — EVIDENCE RECORD [Seized: \(seized)]")
        print("================================================================================")
        print(evidenceBlock)
        print("================================================================================\n")
        fflush(stdout)
    }
}
