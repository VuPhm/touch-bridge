import Foundation
import CoreGraphics

// MARK: - Consolidated Calibration Profile Store (P3-01 Section 6)

public final class CalibrationProfileStore {
    public static let shared = CalibrationProfileStore()
    
    public static var authoritativeDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".touchbridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    public static func profileURL(for displayID: CGDirectDisplayID) -> URL {
        authoritativeDirectory.appendingPathComponent("calibration_display_\(displayID).json")
    }
    
    private init() {}
    
    /// Loads the authoritative profile for the given display ID.
    /// Falls back to local directory `TouchBridgeCalibration.json` if not yet migrated.
    public func loadProfile(for displayID: CGDirectDisplayID, customPath: String? = nil) -> CalibrationProfile? {
        if let custom = customPath {
            let customURL = URL(fileURLWithPath: custom)
            if let prof = try? CalibrationProfile.load(from: customURL) {
                TouchBridgeLogger.info(.calibration, "Loaded custom calibration profile from: \(customURL.path)")
                return prof
            }
        }
        
        let authURL = CalibrationProfileStore.profileURL(for: displayID)
        if let prof = try? CalibrationProfile.load(from: authURL) {
            TouchBridgeLogger.debug(.calibration, "Loaded authoritative profile from: \(authURL.path)")
            return prof
        }
        
        // Workspace fallback / migration check
        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TouchBridgeCalibration.json")
        if let fallback = try? CalibrationProfile.load(from: cwdURL) {
            if fallback.displayID == displayID {
                TouchBridgeLogger.info(.calibration, "Migrating workspace calibration profile to authoritative store: \(authURL.path)")
                try? fallback.save(to: authURL)
                return fallback
            }
        }
        
        return nil
    }
    
    /// Saves a newly calibrated profile into the authoritative store.
    public func saveProfile(_ profile: CalibrationProfile) throws {
        let authURL = CalibrationProfileStore.profileURL(for: profile.displayID)
        try profile.save(to: authURL)
        TouchBridgeLogger.info(.calibration, "Saved calibration profile to authoritative store: \(authURL.path) (Mean error: \(String(format: "%.2f", profile.meanResidualError)) pt)")
        
        // Also sync local workspace file for development consistency
        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TouchBridgeCalibration.json")
        try? profile.save(to: cwdURL)
    }
    
    /// Evaluates whether an existing profile matches the active hardware (device + display).
    /// Returns domain CalibrationState: .valid, .stale(reason), or .missing.
    public func evaluate(
        profile: CalibrationProfile?,
        targetDisplay: DisplayMetadata?,
        targetDeviceVID: Int = 0x1A86,
        targetDevicePID: Int = 0xE5E3
    ) -> CalibrationState {
        guard let prof = profile else {
            return .missing
        }
        
        guard let disp = targetDisplay else {
            return .stale(reason: "No target display bound")
        }
        
        // 1. Device identity check
        if prof.deviceVendorID != targetDeviceVID || prof.deviceProductID != targetDevicePID {
            return .stale(reason: "HID Device mismatch (Profile: 0x\(String(format: "%04X", prof.deviceVendorID)):0x\(String(format: "%04X", prof.deviceProductID)), Active: 0x\(String(format: "%04X", targetDeviceVID)):0x\(String(format: "%04X", targetDevicePID)))")
        }
        
        // 2. Display identity check
        if prof.displayID != disp.id {
            return .stale(reason: "Display ID mismatch (Profile: #\(prof.displayID), Active: #\(disp.id))")
        }
        
        // 3. Display geometry check (Resolution)
        if abs(disp.cgWidth - prof.displayWidth) > 1.0 || abs(disp.cgHeight - prof.displayHeight) > 1.0 {
            return .stale(reason: "Resolution changed (Profile was \(Int(prof.displayWidth))x\(Int(prof.displayHeight)), Active is \(Int(disp.cgWidth))x\(Int(disp.cgHeight)))")
        }
        
        // 4. Orientation check
        if abs(disp.rotationDegrees - prof.rotationDegrees) > 0.1 {
            return .stale(reason: "Orientation changed (Profile was \(prof.rotationDegrees)°, Active is \(disp.rotationDegrees)°)")
        }
        
        // 5. Backing scale check
        if abs(disp.backingScaleFactor - prof.backingScaleFactor) > 0.01 {
            return .stale(reason: "Scale factor changed (Profile was \(prof.backingScaleFactor)x, Active is \(disp.backingScaleFactor)x)")
        }
        
        return .valid(profile: prof)
    }
}
