import Foundation
import CoreGraphics

// MARK: - Pipeline Layer 4: CoordinateMapper (P3-01 Section 3)

public final class CoordinateMapper {
    public private(set) var display: DisplayMetadata?
    public private(set) var profile: CalibrationProfile?
    
    public init(display: DisplayMetadata? = nil, profile: CalibrationProfile? = nil) {
        self.display = display
        self.profile = profile
    }
    
    public func updateBinding(display: DisplayMetadata?, profile: CalibrationProfile?) {
        self.display = display
        self.profile = profile
        if let d = display {
            TouchBridgeLogger.debug(.calibration, "CoordinateMapper updated: Display #\(d.id) (\(Int(d.cgWidth))x\(Int(d.cgHeight))), Profile: \(profile != nil ? "Valid" : "None")")
        } else {
            TouchBridgeLogger.debug(.calibration, "CoordinateMapper updated: No target display")
        }
    }
    
    /// Maps a normalized sensor point [0..1] into Local CG and Global CG spaces.
    public func map(sensor: NormalizedSensorPoint) -> (local: DisplayLocalPoint, global: GlobalDisplayPoint)? {
        guard let disp = display else { return nil }
        
        let local: DisplayLocalPoint
        if let prof = profile {
            local = prof.mapToDisplayLocal(sensor: sensor)
        } else {
            // Uncalibrated fallback mapping
            let lx = sensor.u * disp.cgWidth
            let ly = sensor.v * disp.cgHeight
            let lay = disp.cgHeight - ly
            local = DisplayLocalPoint(
                cgPoint: CGPoint(x: lx, y: ly),
                appKitPoint: CGPoint(x: lx, y: lay),
                displayWidth: disp.cgWidth,
                displayHeight: disp.cgHeight
            )
        }
        
        let global = local.toGlobal(display: disp)
        return (local, global)
    }
    
    /// Maps a TouchSample into Local CG and Global CG coordinates.
    public func map(sample: TouchSample) -> (local: DisplayLocalPoint, global: GlobalDisplayPoint)? {
        return map(sensor: sample.normalizedSensorPoint)
    }
}
