import Cocoa

// MARK: - Native AppKit Application Delegate (P3-01 Section 1)

public final class AppDelegate: NSObject, NSApplicationDelegate, MenuBarActionDelegate, TouchBridgeRuntimeDelegate {
    public static let shared = AppDelegate()
    
    private var menuBarController: MenuBarController?
    private let runtime = TouchBridgeRuntime.shared
    private var permissionRefreshTimer: Timer?
    
    public override init() {
        super.init()
    }
    
    public var sessionDuration: Double? = nil
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        TouchBridgeLogger.info(.lifecycle, "TouchBridge application launched.")
        
        // Single Instance Check: Only one instance handles hardware exclusively
        let bundleID = Bundle.main.bundleIdentifier ?? "com.antigravity.touchbridge.dev"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        if let existing = otherInstances.first {
            existing.activate(options: .activateIgnoringOtherApps)
            TouchBridgeLogger.info(.lifecycle, "Another TouchBridge instance (PID \(existing.processIdentifier)) is already active. Terminating duplicate instance.")
            NSApp.terminate(nil)
            return
        }
        
        // 1. Establish Menu Bar Accessory UX (No Dock Icon by default)
        NSApp.setActivationPolicy(.accessory)
        
        // 2. Setup Menu Bar Controller
        let menuBar = MenuBarController()
        menuBar.actionDelegate = self
        self.menuBarController = menuBar
        
        // 3. Setup Runtime Delegate
        runtime.delegate = self
        
        // 4. Start Runtime (Device, Display, Calibration, AX)
        _ = runtime.start(requestAccessibilityPermission: true)

        // Only poll while Accessibility permission is missing; once trusted, stop idle timer
        // and rely on app activation notifications so zero background timer runs while idle.
        if !runtime.permissionManager.isTrusted() {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                self.runtime.updateAccessibilityState()
                if self.runtime.permissionManager.isTrusted() {
                    t.invalidate()
                    self.permissionRefreshTimer = nil
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionRefreshTimer = timer
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        TouchBridgeLogger.info(.accessibility,
            "AXIsProcessTrusted=\(runtime.permissionManager.isTrusted()); bundle=\(Bundle.main.bundleIdentifier ?? "unbundled"); path=\(Bundle.main.bundleURL.path); pid=\(ProcessInfo.processInfo.processIdentifier)")
        
        // 5. Update Menu Bar and Settings with Initial Snapshot
        menuBar.update(with: runtime.currentSnapshot)
        StatusSettingsWindowController.shared.update(with: runtime.currentSnapshot)
        
        TouchBridgeLogger.info(.lifecycle, "TouchBridge Menu-Bar application ready.")
        
        if let dur = sessionDuration {
            DispatchQueue.main.asyncAfter(deadline: .now() + dur) {
                TouchBridgeLogger.info(.lifecycle, "Session duration of \(dur)s elapsed. Terminating cleanly.")
                NSApp.terminate(nil)
            }
        }
    }
    
    @objc private func handleAppDidBecomeActive() {
        runtime.updateAccessibilityState()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
        NotificationCenter.default.removeObserver(self)
        TouchBridgeLogger.info(.lifecycle, "TouchBridge terminating. Releasing all hardware and display callbacks...")
        runtime.shutdown()
        TouchBridgeLogger.info(.lifecycle, "Shutdown complete.")
    }
    
    // MARK: - TouchBridgeRuntimeDelegate
    
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateSnapshot snapshot: RuntimeSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBarController?.update(with: snapshot)
            StatusSettingsWindowController.shared.update(with: snapshot)
        }
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didExecuteSemanticRecord record: SemanticEvidenceRecord) {
        // Avoid synchronous disk I/O on every live touch interaction; records stay in memory
        // and can be exported on demand from Diagnostics.
    }
    
    public func runtime(_ runtime: TouchBridgeRuntime, didUpdateFeedback feedback: String, invariantPassed: Bool) {
        TouchBridgeLogger.debug(.semantic, "Feedback: \(feedback) [Invariant: \(invariantPassed ? "PASS" : "FAIL")]")
    }
    
    // MARK: - MenuBarActionDelegate
    
    public func menuBarDidToggleEnabled() {
        runtime.toggleEnabled()
    }
    
    public func menuBarDidRequestCalibration() {
        CalibrationWindowController.shared.startCalibrationSession()
    }
    
    public func menuBarDidRequestDiagnostics() {
        DiagnosticsWindowController.shared.showWindowToFront()
    }
    
    public func menuBarDidRequestSettings() {
        StatusSettingsWindowController.shared.showWindowToFront()
    }
    
    public func menuBarDidRequestAccessibilityPermission() {
        runtime.requestAccessibilityPermissionExplicitly()
    }
    
    public func menuBarDidRequestQuit() {
        TouchBridgeLogger.info(.lifecycle, "User requested quit from menu bar.")
        NSApp.terminate(nil)
    }
}
