import Foundation
import CoreGraphics

// MARK: - Explicit Runtime Domain States (P3-01 & P3-01.1)

/// Represents the explicit user intent to engage or disengage TouchBridge semantic interaction.
/// Hardware availability alone CANNOT transition interaction into an active/ready state.
public enum UserIntent: String, Equatable, CustomStringConvertible {
    case disabled = "DISABLED"
    case enabled  = "ENABLED"
    
    public var description: String {
        switch self {
        case .disabled: return "Disabled"
        case .enabled:  return "Enabled"
        }
    }
    
    public var isEnabled: Bool {
        return self == .enabled
    }
}

/// Represents core input, display, and calibration readiness. AX enrichment is
/// reported separately by AccessibilityState and does not gate pointer delivery.
public enum RuntimeCapability: Equatable, CustomStringConvertible {
    case unavailable(reason: String)
    case suspended(reason: String)
    case ready
    case active
    
    public var description: String {
        switch self {
        case .unavailable(let reason):
            return "Unavailable (\(reason))"
        case .suspended(let reason):
            return "Suspended (\(reason))"
        case .ready:
            return "Ready"
        case .active:
            return "Active"
        }
    }
    
    public var isReadyOrActive: Bool {
        switch self {
        case .ready, .active: return true
        default: return false
        }
    }
}

/// Represents the physical and connection state of the target USB touchscreen hardware.
public enum DeviceState: Equatable, CustomStringConvertible {
    case disconnected
    case detected(name: String, vid: Int, pid: Int)
    case available(name: String, vid: Int, pid: Int)
    case unavailableBusy
    case error(String)
    
    public var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .detected(let name, let vid, let pid):
            return "Detected: \(name) (0x\(String(format: "%04X", vid)):0x\(String(format: "%04X", pid)))"
        case .available(let name, _, _):
            return "Connected (\(name))"
        case .unavailableBusy:
            return "Unavailable (Device Busy)"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
    
    public var isConnected: Bool {
        switch self {
        case .available, .detected:
            return true
        default:
            return false
        }
    }
}

/// Represents the binding and configuration state of the target external display.
public enum DisplayState: Equatable, CustomStringConvertible {
    case targetMissing
    case targetDetected(DisplayMetadata)
    case bound(DisplayMetadata)
    case configurationChanged(reason: String)
    
    public var description: String {
        switch self {
        case .targetMissing:
            return "Target Missing (No External Display)"
        case .targetDetected(let d):
            return "Detected: \(d.name) (#\(d.id))"
        case .bound(let d):
            return "\(d.name) (#\(d.id), \(Int(d.cgWidth))x\(Int(d.cgHeight)))"
        case .configurationChanged(let reason):
            return "Configuration Changed: \(reason)"
        }
    }
    
    public var boundDisplay: DisplayMetadata? {
        switch self {
        case .bound(let d):
            return d
        default:
            return nil
        }
    }
}

/// Represents the applicability and freshness of the calibration profile.
public enum CalibrationState: Equatable, CustomStringConvertible {
    case missing
    case valid(profile: CalibrationProfile)
    case stale(reason: String)
    case calibrating
    
    public var description: String {
        switch self {
        case .missing:
            return "Missing (Calibration Required)"
        case .valid(let prof):
            return String(format: "Valid (Mean Error: %.2f pt)", prof.meanResidualError)
        case .stale(let reason):
            return "Stale: \(reason)"
        case .calibrating:
            return "Calibrating In Progress…"
        }
    }
    
    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
    
    public var activeProfile: CalibrationProfile? {
        if case .valid(let p) = self { return p }
        return nil
    }
}

/// Represents the overall operational state of the TouchBridge input and gesture runtime.
/// When user intent is Disabled, EngineState is strictly .disabled.
public enum EngineState: Equatable, CustomStringConvertible {
    case disabled
    case ready
    case active
    case suspended(reason: String)
    case error(String)
    
    public var description: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .ready:
            return "Ready"
        case .active:
            return "Active (Processing Touches)"
        case .suspended(let reason):
            return "Suspended (\(reason))"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
    
    public var isOperational: Bool {
        switch self {
        case .ready, .active:
            return true
        default:
            return false
        }
    }
}

/// Represents the macOS Accessibility API permission state.
public enum AccessibilityState: Equatable, CustomStringConvertible {
    case permissionMissing
    case available
    
    public var description: String {
        switch self {
        case .permissionMissing:
            return "Permission Missing"
        case .available:
            return "Allowed"
        }
    }
    
    public var isAvailable: Bool {
        return self == .available
    }
}

/// Consolidated snapshot of the entire runtime state for UI rendering and diagnostics.
public struct RuntimeSnapshot: Equatable {
    public let userIntent: UserIntent
    public let capability: RuntimeCapability
    public let device: DeviceState
    public let display: DisplayState
    public let calibration: CalibrationState
    public let accessibility: AccessibilityState
    public let engine: EngineState
    public var isUserEnabled: Bool { userIntent == .enabled }
    
    public init(
        userIntent: UserIntent,
        capability: RuntimeCapability,
        device: DeviceState,
        display: DisplayState,
        calibration: CalibrationState,
        accessibility: AccessibilityState,
        engine: EngineState
    ) {
        self.userIntent = userIntent
        self.capability = capability
        self.device = device
        self.display = display
        self.calibration = calibration
        self.accessibility = accessibility
        self.engine = engine
    }
}
