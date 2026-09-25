import Foundation
import CoreGraphics

/// Space A: Raw HID Logical Coordinates reported directly by the digitizer descriptor.
/// - Range: [0 .. 4096] in X, [0 .. 4096] in Y.
/// - Origin: (0, 0) is top-left of sensor surface.
/// - Axis orientation: X points right, Y points down.
public struct RawHIDPoint: Codable, CustomStringConvertible {
    public let x: Int
    public let y: Int
    
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
    
    public var description: String {
        "RawHID(\(x), \(y))"
    }
    
    /// Converts Space A -> Space B (Normalized Sensor [0..1])
    public func toNormalized(minX: Int = 0, maxX: Int = 4096, minY: Int = 0, maxY: Int = 4096) -> NormalizedSensorPoint {
        let spanX = Double(max(1, maxX - minX))
        let spanY = Double(max(1, maxY - minY))
        let u = Double(x - minX) / spanX
        let v = Double(y - minY) / spanY
        return NormalizedSensorPoint(u: max(0.0, min(1.0, u)), v: max(0.0, min(1.0, v)))
    }
}

/// Space B: Normalized Sensor Coordinates.
/// - Range: [0.0 .. 1.0] in u and v.
/// - Origin: (0, 0) is top-left of sensor surface.
/// - Axis orientation: u points right, v points down.
public struct NormalizedSensorPoint: Codable, CustomStringConvertible {
    public let u: Double
    public let v: Double
    
    public init(u: Double, v: Double) {
        self.u = u
        self.v = v
    }
    
    public var description: String {
        String(format: "NormSensor(u: %.4f, v: %.4f)", u, v)
    }
}

/// Space C: Calibrated Visible-Area Normalized Coordinates.
/// - Range: [0.0 .. 1.0] across the actively visible macOS viewport on the target display.
/// - Origin: (0, 0) is the top-left corner of the visible macOS display area.
/// - Axis orientation: u points right, v points down.
/// - Directly accounts for physical bezel obstruction and underscan through calibrated transform.
public struct CalibratedVisiblePoint: Codable, CustomStringConvertible {
    public let u: Double
    public let v: Double
    
    public init(u: Double, v: Double) {
        self.u = u
        self.v = v
    }
    
    public var description: String {
        String(format: "CalibratedVis(u: %.4f, v: %.4f)", u, v)
    }
    
    /// Converts Space C -> Space D (Target Display Local Coordinates)
    public func toDisplayLocal(displayWidth: Double, displayHeight: Double) -> DisplayLocalPoint {
        let localX = u * displayWidth
        let localY_CG = v * displayHeight
        let localY_AppKit = displayHeight - localY_CG // Y-inversion for AppKit bottom-left origin
        return DisplayLocalPoint(
            cgPoint: CGPoint(x: localX, y: localY_CG),
            appKitPoint: CGPoint(x: localX, y: localY_AppKit),
            displayWidth: displayWidth,
            displayHeight: displayHeight
        )
    }
}

/// Space D: Target Display Local Coordinates.
/// - Distinctly exposes CoreGraphics (Top-Left, Y-Down) and AppKit (Bottom-Left, Y-Up) coordinates.
/// - Measured in logical points (1 pt = 1 px on standard displays, 2 px on Retina).
public struct DisplayLocalPoint: CustomStringConvertible {
    /// Origin: (0, 0) at TOP-LEFT of target display. Y points DOWN.
    public let cgPoint: CGPoint
    
    /// Origin: (0, 0) at BOTTOM-LEFT of target display. Y points UP.
    public let appKitPoint: CGPoint
    
    public let displayWidth: Double
    public let displayHeight: Double
    
    public var description: String {
        String(format: "Local(CG: [%.1f, %.1f], AppKit: [%.1f, %.1f])",
               cgPoint.x, cgPoint.y, appKitPoint.x, appKitPoint.y)
    }
    
    /// Converts Space D -> Space E (macOS Global Display Coordinates)
    public func toGlobal(display: DisplayMetadata) -> GlobalDisplayPoint {
        // CoreGraphics Global:
        // Origin is top-left of primary screen.
        let cgGlobalX = display.cgOriginX + cgPoint.x
        let cgGlobalY = display.cgOriginY + cgPoint.y
        let cgGlobal = CGPoint(x: cgGlobalX, y: cgGlobalY)
        
        // AppKit Global:
        // Origin is bottom-left of primary screen.
        let appKitGlobalX = display.appKitOriginX + appKitPoint.x
        let appKitGlobalY = display.appKitOriginY + appKitPoint.y
        let appKitGlobal = CGPoint(x: appKitGlobalX, y: appKitGlobalY)
        
        return GlobalDisplayPoint(
            cgGlobal: cgGlobal,
            appKitGlobal: appKitGlobal,
            targetDisplayID: display.id
        )
    }
}

/// Space E: macOS Global Desktop Coordinates.
/// - Spans all connected displays.
/// - CoreGraphics Global: (0, 0) at top-left of primary screen, Y-down.
/// - AppKit Global: (0, 0) at bottom-left of primary screen, Y-up.
public struct GlobalDisplayPoint: CustomStringConvertible {
    public let cgGlobal: CGPoint
    public let appKitGlobal: CGPoint
    public let targetDisplayID: CGDirectDisplayID
    
    public var description: String {
        String(format: "Global(CG: [%.1f, %.1f], AppKit: [%.1f, %.1f], DisplayID: %d)",
               cgGlobal.x, cgGlobal.y, appKitGlobal.x, appKitGlobal.y, targetDisplayID)
    }
}
