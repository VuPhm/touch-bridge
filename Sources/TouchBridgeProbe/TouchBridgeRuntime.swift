import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices
import ServiceManagement

// MARK: - Central TouchBridge Prototype Runtime (P3-01 Section 2 & 3)

public protocol TouchBridgeRuntimeDelegate: AnyObject {
    func runtime(_ runtime: TouchBridgeRuntime, didUpdateSnapshot snapshot: RuntimeSnapshot)
    func runtime(_ runtime: TouchBridgeRuntime, didExecuteSemanticRecord record: SemanticEvidenceRecord)
    func runtime(_ runtime: TouchBridgeRuntime, didUpdateFeedback feedback: String, invariantPassed: Bool)
    func runtime(_ runtime: TouchBridgeRuntime, didCompleteSession session: InteractionSession, evidenceBlock: String)
}

public extension TouchBridgeRuntimeDelegate {
    func runtime(_ runtime: TouchBridgeRuntime, didCompleteSession session: InteractionSession, evidenceBlock: String) {}
}

public final class TouchBridgeRuntime: NSObject, TouchscreenDeviceDelegate, HIDFrameSourceDelegate, SemanticInteractionRouterDelegate {
    public static let shared = TouchBridgeRuntime()
    
    public weak var delegate: TouchBridgeRuntimeDelegate?
    
    // Core Pipeline Layers
    public let device: TouchscreenDevice
    public let frameSource: HIDFrameSource
    public let mapper: CoordinateMapper
    public let recognizer: TouchGestureRecognizer
    public let router: InteractionDeliveryRouter
    
    // External Managers
    public let displayManager = DisplayManager.shared
    public let profileStore = CalibrationProfileStore.shared
    public let permissionManager = AXPermissionManager.shared
    
    // Explicit Domain States (P3-01 & P3-01.1)
    public private(set) var userIntent: UserIntent = .disabled
    public private(set) var runtimeCapability: RuntimeCapability = .unavailable(reason: "Initializing")
    public private(set) var deviceState: DeviceState = .disconnected
    public private(set) var displayState: DisplayState = .targetMissing
    public private(set) var calibrationState: CalibrationState = .missing
    public private(set) var accessibilityState: AccessibilityState = .permissionMissing
    public private(set) var engineState: EngineState = .disabled
    public var isEnabled: Bool { userIntent == .enabled }
    
    // Overrides
    public var targetDisplayIDOverride: CGDirectDisplayID? = nil
    public var customProfilePath: String? = nil
    private var hasStartedRuntime: Bool = false
    
    public var currentSnapshot: RuntimeSnapshot {
        RuntimeSnapshot(
            userIntent: userIntent,
            capability: runtimeCapability,
            device: deviceState,
            display: displayState,
            calibration: calibrationState,
            accessibility: accessibilityState,
            engine: engineState
        )
    }
    
    private let kPrefUserEnabled = "touchbridge.user_enabled"
    private let kPrefDirectTouch = "touchbridge.direct_touch_mode"
    private let kPrefInvertQuarterTurn = "touchbridge.invert_quarter_turn"

    public override init() {
        self.device = TouchscreenDevice()
        self.frameSource = HIDFrameSource()
        self.mapper = CoordinateMapper()
        self.recognizer = TouchGestureRecognizer(mapper: mapper)
        self.router = InteractionDeliveryRouter()
        
        super.init()
        
        // Restore user preferences
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: kPrefUserEnabled) != nil ? defaults.bool(forKey: kPrefUserEnabled) : true
        self.userIntent = savedEnabled ? .enabled : .disabled

        let savedDirectTouch = defaults.object(forKey: kPrefDirectTouch) != nil ? defaults.bool(forKey: kPrefDirectTouch) : true
        recognizer.directTouchModeEnabled = savedDirectTouch
        recognizer.experimentalOneFingerPanEnabled = savedDirectTouch

        let savedInvert = defaults.object(forKey: kPrefInvertQuarterTurn) != nil ? defaults.bool(forKey: kPrefInvertQuarterTurn) : false
        CalibrationProfile.invertQuarterTurnDirection = savedInvert
        router.showKeyboardPillOnTextTap = false

        // Wire pipeline delegates
        device.delegate = self
        frameSource.delegate = self
        recognizer.delegate = router
        router.delegate = self
        router.userIntent = userIntent
    }

    public func setDirectTouchModeEnabled(_ enabled: Bool) {
        recognizer.directTouchModeEnabled = enabled
        recognizer.experimentalOneFingerPanEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: kPrefDirectTouch)
        TouchBridgeLogger.info(.gesture, "Direct-Touch 1-Finger Mode: \(enabled ? "ENABLED" : "DISABLED")")
        evaluateEngineState()
    }

    public func setInvertQuarterTurnRotation(_ inverted: Bool) {
        CalibrationProfile.invertQuarterTurnDirection = inverted
        UserDefaults.standard.set(inverted, forKey: kPrefInvertQuarterTurn)
        TouchBridgeLogger.info(.calibration, "Quarter-turn rotation mapping direction inverted: \(inverted)")
        resolveAndBindDisplay()
        evaluateEngineState()
    }

    public var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                        TouchBridgeLogger.info(.lifecycle, "Launch at login enabled via SMAppService.")
                    } else {
                        try SMAppService.mainApp.unregister()
                        TouchBridgeLogger.info(.lifecycle, "Launch at login disabled via SMAppService.")
                    }
                } catch {
                    TouchBridgeLogger.warning(.lifecycle, "Failed to update launch at login: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Lifecycle
    
    @discardableResult
    public func start(requestAccessibilityPermission: Bool = false) -> Bool {
        TouchBridgeLogger.info(.lifecycle, "Starting TouchBridge Prototype Runtime (P3-01)...")
        
        // AX enrichment is optional. HID ownership remains protected by the
        // existing device lifecycle and macOS security boundaries.
        _ = permissionManager.checkPermission(requestPromptIfNeeded: requestAccessibilityPermission)
        updateAccessibilityState()
        router.prepareTapBackendForRuntime()
        guard !hasStartedRuntime else { return true }
        hasStartedRuntime = true
        
        // 2. Discover Display Target
        resolveAndBindDisplay()
        
        // 3. Start Display Monitoring
        displayManager.startMonitoring { [weak self] event in
            self?.handleDisplayChangeEvent(event)
        }
        
        // 4. Start Touchscreen Device Monitoring (Dynamic matching & removal)
        device.start()
        
        // 5. Evaluate overall engine state
        evaluateEngineState()
        
        TouchBridgeLogger.info(.lifecycle, "TouchBridge Runtime initialized: Intent=\(userIntent), Capability=\(runtimeCapability), Engine=\(engineState)")
        return true
    }
    
    public func shutdown() {
        TouchBridgeLogger.info(.lifecycle, "Shutting down TouchBridge Runtime...")
        recognizer.reset()
        router.resetGestureState()
        device.stop()
        displayManager.stopMonitoring()
        hasStartedRuntime = false
        evaluateEngineState()
    }
    
    // MARK: - Explicit User Enable / Disable (P3-01 Section 8 & P3-01.1 Invariant 1)
    
    public func setEnabled(_ enabled: Bool) {
        let newIntent: UserIntent = enabled ? .enabled : .disabled
        UserDefaults.standard.set(enabled, forKey: kPrefUserEnabled)
        guard userIntent != newIntent else { return }
        userIntent = newIntent
        router.userIntent = newIntent
        if newIntent == .disabled {
            recognizer.reset()
            router.resetGestureState()
        }
        
        TouchBridgeLogger.info(.lifecycle, "User toggled TouchBridge: \(userIntent.description.uppercased())")
        evaluateEngineState()
    }
    
    public func setUserIntent(_ intent: UserIntent) {
        setEnabled(intent == .enabled)
    }
    
    public func toggleEnabled() {
        setEnabled(!isEnabled)
    }
    
    // MARK: - Accessibility Permission (P3-01 Section 9)
    
    public func updateAccessibilityState() {
        let trusted = permissionManager.isTrusted()
        let newState: AccessibilityState = trusted ? .available : .permissionMissing
        if accessibilityState != newState {
            accessibilityState = newState
            TouchBridgeLogger.info(.accessibility, "Accessibility permission state: \(newState.description)")
            evaluateEngineState()
        }
    }
    
    /// User-triggered explicit action to request Accessibility permission or open System Settings.
    public func requestAccessibilityPermissionExplicitly() {
        TouchBridgeLogger.info(.accessibility, "User explicitly requested Accessibility permission prompt/settings.")
        let status = permissionManager.checkPermission(requestPromptIfNeeded: true)
        if status == .granted {
            accessibilityState = .available
            evaluateEngineState()
            _ = start()
        } else {
            // Open System Settings -> Privacy & Security -> Accessibility
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            print("Accessibility enrichment is unavailable; pointer-primary interaction remains available.")
            print("Enable TouchBridgeProbe in System Settings → Privacy & Security → Accessibility to use semantic-only diagnostics.")
        }
    }
    
    // MARK: - Display Lifecycle & Binding (P3-01 Section 5)
    
    public func resolveAndBindDisplay() {
        let displays = displayManager.enumerateDisplays()
        
        let target: DisplayMetadata?
        if let overrideID = targetDisplayIDOverride {
            target = displays.first(where: { $0.id == overrideID })
        } else {
            target = displayManager.findExternalTouchscreenDisplay()
        }
        
        if let disp = target {
            displayState = .bound(disp)
            TouchBridgeLogger.info(.display, "Bound to Target Display: \"\(disp.name)\" (#\(disp.id), \(Int(disp.cgWidth))x\(Int(disp.cgHeight)))")
            
            // Check & evaluate calibration profile
            resolveCalibrationProfile(for: disp)
        } else {
            displayState = .targetMissing
            calibrationState = .missing
            mapper.updateBinding(display: nil, profile: nil)
            recognizer.updateBinding()
            TouchBridgeLogger.warning(.display, "No external display found for touchscreen binding.")
        }
        
        evaluateEngineState()
    }
    
    private func resolveCalibrationProfile(for display: DisplayMetadata) {
        let profile = profileStore.loadProfile(for: display.id, targetDisplay: display, customPath: customProfilePath)
        let evalState = profileStore.evaluate(
            profile: profile,
            targetDisplay: display,
            targetDeviceVID: TouchscreenDevice.targetVendorID,
            targetDevicePID: TouchscreenDevice.targetProductID
        )
        
        self.calibrationState = evalState
        switch evalState {
        case .valid(let validProfile):
            TouchBridgeLogger.info(.calibration, "Applicable calibration profile LOADED (Mean residual: \(String(format: "%.2f", validProfile.meanResidualError)) pt)")
            mapper.updateBinding(display: display, profile: validProfile)
            recognizer.updateBinding()
            
        case .stale(let reason):
            TouchBridgeLogger.warning(.calibration, "Calibration is STALE for active display: \(reason). Recalibration required.")
            mapper.updateBinding(display: display, profile: nil)
            recognizer.updateBinding()
            
        case .missing:
            TouchBridgeLogger.info(.calibration, "No calibration profile found for Display #\(display.id). Calibration required.")
            mapper.updateBinding(display: display, profile: nil)
            recognizer.updateBinding()
            
        case .calibrating:
            break
        }
    }
    
    private func handleDisplayChangeEvent(_ event: DisplayChangeEvent) {
        TouchBridgeLogger.info(.display, "Display reconfiguration event: \(event)")
        
        if case .systemWillSleep = event {
            self.recognizer.reset()
            self.router.resetGestureState()
            TouchBridgeLogger.info(.lifecycle, "System entering sleep: Active gestures, drag transactions and pointer states safely cleared.")
            return
        }
        
        let delay: Double
        if case .systemDidWake = event {
            delay = 0.35
        } else {
            delay = 0.1
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            
            let displays = self.displayManager.enumerateDisplays()
            let currentDisplay: DisplayMetadata?
            if let overrideID = self.targetDisplayIDOverride {
                currentDisplay = displays.first(where: { $0.id == overrideID })
            } else if let prevID = self.displayState.boundDisplay?.id,
                      let sameID = displays.first(where: { $0.id == prevID }) {
                currentDisplay = sameID
            } else {
                currentDisplay = self.displayManager.findExternalTouchscreenDisplay()
            }
            
            guard let boundDisplay = currentDisplay else {
                // Target display missing or removed
                self.recognizer.reset()
                self.router.resetGestureState()
                self.displayState = .targetMissing
                self.calibrationState = .missing
                self.mapper.updateBinding(display: nil, profile: nil)
                self.recognizer.updateBinding()
                self.evaluateEngineState()
                return
            }
            
            self.displayState = .bound(boundDisplay)
            self.resolveCalibrationProfile(for: boundDisplay)
            if case .stale(let reason) = self.calibrationState {
                self.displayState = .configurationChanged(reason: reason)
            }
            self.evaluateEngineState()
        }
    }
    
    // MARK: - Calibration Actions (P3-01 Section 6)
    
    public func markCalibrating() {
        calibrationState = .calibrating
        evaluateEngineState()
    }
    
    public func handleCalibrationCompleted(profile: CalibrationProfile) {
        do {
            try profileStore.saveProfile(profile)
            if let disp = displayState.boundDisplay {
                resolveCalibrationProfile(for: disp)
            } else {
                calibrationState = .valid(profile: profile)
            }
        } catch {
            TouchBridgeLogger.error(.calibration, "Failed to save calibrated profile: \(error)")
        }
        evaluateEngineState()
    }
    
    // MARK: - TouchscreenDeviceDelegate
    
    public func touchscreenDevice(_ device: TouchscreenDevice, didChangeState state: DeviceState) {
        self.deviceState = state
        frameSource.touchscreenDevice(device, didChangeState: state)
        
        if state == .disconnected {
            // Hot-plug disconnect: reset active contact state, gesture recognizer, and any held pointer/scroll transactions immediately
            recognizer.reset()
            router.resetGestureState()
            TouchBridgeLogger.warning(.hid, "Touchscreen DISCONNECTED: Active contact and gesture states reset immediately.")
        } else if case .available = state {
            frameSource.updateRanges(
                logMinX: device.logMinX, logMaxX: device.logMaxX,
                logMinY: device.logMinY, logMaxY: device.logMaxY
            )
            // Re-evaluate calibration if display is bound
            if let disp = displayState.boundDisplay {
                resolveCalibrationProfile(for: disp)
            }
        }
        
        evaluateEngineState()
    }
    
    public func touchscreenDevice(_ device: TouchscreenDevice, didReceiveRawElement value: IOHIDValue) {
        // Forward raw element to HIDFrameSource
        frameSource.touchscreenDevice(device, didReceiveRawElement: value)
    }
    
    // MARK: - HIDFrameSourceDelegate
    
    public func hidFrameSource(_ source: HIDFrameSource, didProduceSample sample: TouchSample) {
        if calibrationState == .calibrating {
            CalibrationWindowController.shared.handleTouchSample(sample)
            return
        }
        // Forward sample to recognizer. Active contact state and gestures are tracked,
        // while SemanticInteractionRouter strictly suppresses semantic actions when UserIntent is DISABLED.
        recognizer.processSample(sample)
    }
    
    // MARK: - SemanticInteractionRouterDelegate
    
    public func semanticRouter(_ router: SemanticInteractionRouter, didExecuteRecord record: SemanticEvidenceRecord) {
        delegate?.runtime(self, didExecuteSemanticRecord: record)
    }
    
    public func semanticRouter(_ router: SemanticInteractionRouter, didUpdateFeedback feedback: String, invariantPassed: Bool) {
        delegate?.runtime(self, didUpdateFeedback: feedback, invariantPassed: invariantPassed)
    }
    
    public func semanticRouter(_ router: SemanticInteractionRouter, didCompleteSession session: InteractionSession, evidenceBlock: String) {
        delegate?.runtime(self, didCompleteSession: session, evidenceBlock: evidenceBlock)
    }
    
    // MARK: - Runtime Capability & Engine State Machine (P3-01 & P3-01.1)
    
    public func evaluateCapability() -> RuntimeCapability {
        if !deviceState.isConnected {
            return .suspended(reason: "Touchscreen disconnected")
        } else if displayState.boundDisplay == nil {
            return .suspended(reason: "Target display missing")
        } else {
            switch calibrationState {
            case .valid:
                return .ready
            case .stale(let reason):
                return .suspended(reason: "Calibration stale: \(reason)")
            case .calibrating:
                return .suspended(reason: "Calibration in progress")
            case .missing:
                return .suspended(reason: "Calibration missing")
            }
        }
    }
    
    public func evaluateEngineState() {
        let oldEngine = engineState
        let oldCap = runtimeCapability
        
        runtimeCapability = evaluateCapability()
        
        // Product Invariant 1 (P3-01.1):
        // User Intent == .disabled -> EngineState is strictly .disabled
        // regardless of hardware availability, display binding, calibration, or AX permission.
        if userIntent == .disabled {
            engineState = .disabled
        } else {
            switch runtimeCapability {
            case .ready:
                engineState = .ready
            case .active:
                engineState = .active
            case .suspended(let reason):
                engineState = .suspended(reason: reason)
            case .unavailable(let reason):
                engineState = .suspended(reason: reason)
            }
        }
        
        if oldCap != runtimeCapability {
            TouchBridgeLogger.info(.lifecycle, "Runtime capability transition: [\(oldCap)] -> [\(runtimeCapability)]")
        }
        if oldEngine != engineState {
            TouchBridgeLogger.info(.lifecycle, "Engine state transition: [\(oldEngine)] -> [\(engineState)] (UserIntent: \(userIntent))")
        }
        
        delegate?.runtime(self, didUpdateSnapshot: currentSnapshot)
    }
}
