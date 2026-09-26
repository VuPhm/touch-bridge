import Cocoa
import CoreGraphics

// MARK: - Native Calibration Window Controller (P3-01 Section 6)

public final class CalibrationWindowController: NSWindowController, CalibrationDelegate {
    public static let shared = CalibrationWindowController()
    
    private var calibrationView: CalibrationView?
    
    private init() {
        super.init(window: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    public func startCalibrationSession() {
        guard let display = TouchBridgeRuntime.shared.displayState.boundDisplay else {
            TouchBridgeLogger.error(.calibration, "Cannot calibrate: no external display bound.")
            return
        }
        
        guard let targetScreen = NSScreen.screens.first(where: { screen in
            let sNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return sNum == display.id
        }) else {
            TouchBridgeLogger.error(.calibration, "Could not match display #\(display.id) to an active NSScreen.")
            return
        }
        
        TouchBridgeRuntime.shared.markCalibrating()
        
        let win = KeyableWindow(
            contentRect: targetScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )
        win.setFrame(targetScreen.frame, display: true)
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.title = "TouchBridge 4-Point Calibration"
        
        let calView = CalibrationView(frame: win.contentView?.bounds ?? .zero, display: display)
        calView.delegate = self
        win.contentView = calView
        self.calibrationView = calView
        self.window = win
        
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        TouchBridgeLogger.info(.calibration, "4-point calibration window opened on display \"\(display.name)\".")
    }
    
    public func handleTouchSample(_ sample: TouchSample) {
        calibrationView?.handleTouchSample(sample)
    }
    
    // MARK: - CalibrationDelegate
    
    public func calibrationDidComplete(profile: CalibrationProfile) {
        TouchBridgeLogger.info(.calibration, "Calibration successfully completed. Mean residual error: \(String(format: "%.2f", profile.meanResidualError)) pt")
        TouchBridgeRuntime.shared.handleCalibrationCompleted(profile: profile)
        closeCalibration()
    }
    
    public func calibrationDidCancel() {
        TouchBridgeLogger.info(.calibration, "Calibration cancelled by user.")
        TouchBridgeRuntime.shared.evaluateEngineState()
        closeCalibration()
    }
    
    private func closeCalibration() {
        window?.close()
        self.window = nil
        self.calibrationView = nil
    }
}
