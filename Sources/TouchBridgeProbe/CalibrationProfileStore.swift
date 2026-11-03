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
    
    public static func profileURL(for displayID: CGDirectDisplayID, rotationDegrees: Double? = nil) -> URL {
        if let rot = rotationDegrees {
            let deg = ((Int(rot.rounded()) % 360) + 360) % 360
            if deg != 0 {
                return authoritativeDirectory.appendingPathComponent("calibration_display_\(displayID)_rot\(deg).json")
            }
        }
        return authoritativeDirectory.appendingPathComponent("calibration_display_\(displayID).json")
    }
    
    private init() {}
    
    /// Loads the authoritative profile for the given display ID (and optional display metadata for rotation / hardware identity fallback).
    /// Falls back to local directory `TouchBridgeCalibration.json` if not yet migrated.
    public func loadProfile(
        for displayID: CGDirectDisplayID,
        targetDisplay: DisplayMetadata? = nil,
        customPath: String? = nil
    ) -> CalibrationProfile? {
        if let custom = customPath {
            let customURL = URL(fileURLWithPath: custom)
            if let prof = try? CalibrationProfile.load(from: customURL) {
                TouchBridgeLogger.info(.calibration, "Loaded custom calibration profile from: \(customURL.path)")
                return prof
            }
        }

        if let disp = targetDisplay {
            let rotURL = CalibrationProfileStore.profileURL(for: displayID, rotationDegrees: disp.rotationDegrees)
            if FileManager.default.fileExists(atPath: rotURL.path),
               let rotProf = try? CalibrationProfile.load(from: rotURL) {
                TouchBridgeLogger.debug(.calibration, "Loaded orientation-specific profile from: \(rotURL.path)")
                return rotProf
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
            if fallback.displayID == displayID || (targetDisplay != nil && fallback.matchesHardwareIdentity(of: targetDisplay!)) {
                TouchBridgeLogger.info(.calibration, "Migrating workspace calibration profile to authoritative store: \(authURL.path)")
                try? fallback.save(to: authURL)
                return fallback
            }
        }

        // Hardware-identity fallback across DisplayID changes (e.g. different USB-C port or sleep/wake re-enumeration)
        if let disp = targetDisplay,
           let files = try? FileManager.default.contentsOfDirectory(at: CalibrationProfileStore.authoritativeDirectory, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("calibration_display_") {
                if let candidate = try? CalibrationProfile.load(from: url),
                   candidate.matchesHardwareIdentity(of: disp) {
                    TouchBridgeLogger.info(.calibration, "Matched calibration profile \(url.lastPathComponent) by hardware identity (Vendor=0x\(String(format: "%04X", disp.vendorNumber)), Model=0x\(String(format: "%04X", disp.modelNumber)), Serial=\(disp.serialNumber))")
                    return candidate
                }
            }
        }
        
        return nil
    }
    
    /// Saves a newly calibrated profile into the authoritative store.
    public func saveProfile(_ profile: CalibrationProfile) throws {
        let targetURL: URL
        if profile.rotationDegrees != 0 {
            let rotURL = CalibrationProfileStore.profileURL(for: profile.displayID, rotationDegrees: profile.rotationDegrees)
            try profile.save(to: rotURL)
            targetURL = rotURL
        } else {
            let authURL = CalibrationProfileStore.profileURL(for: profile.displayID)
            try profile.save(to: authURL)
            targetURL = authURL
        }
        TouchBridgeLogger.info(.calibration, "Saved calibration profile to authoritative store: \(targetURL.path) (Mean error: \(String(format: "%.2f", profile.meanResidualError)) pt)")
        
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
        
        // 2. Display identity check (allow hardware vendor/model/serial match if DisplayID changed, or automatic rotation adaptation)
        if let adaptedProfile = prof.adapted(for: disp) {
            if adaptedProfile != prof {
                TouchBridgeLogger.info(.calibration, "Adapted calibration profile from \(Int(prof.displayWidth))x\(Int(prof.displayHeight)) @ \(Int(prof.rotationDegrees))° (#\(prof.displayID)) to \(Int(disp.cgWidth))x\(Int(disp.cgHeight)) @ \(Int(disp.rotationDegrees))° (#\(disp.id))")
            }
            return .valid(profile: adaptedProfile)
        }

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
