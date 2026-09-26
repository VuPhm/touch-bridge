import Cocoa

// MARK: - Native AppKit Application Delegate (P3-01 Section 1)

public final class AppDelegate: NSObject, NSApplicationDelegate, MenuBarActionDelegate, TouchBridgeRuntimeDelegate {
    public static let shared = AppDelegate()
    
    private var menuBarController: MenuBarController?
    private let runtime = TouchBridgeRuntime.shared
    
    public override init() {
        super.init()
    }
    
    public var sessionDuration: Double? = nil
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        TouchBridgeLogger.info(.lifecycle, "TouchBridge application launched.")
        
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
    
    public func applicationWillTerminate(_ notification: Notification) {
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
        // Auto-save evidence records if needed
        try? AXSemanticEngine.shared.saveEvidenceToFile(
            at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("semantic_verification_records.json")
        )
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
