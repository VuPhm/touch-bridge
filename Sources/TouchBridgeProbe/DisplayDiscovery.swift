import Foundation
import Cocoa
import CoreGraphics

public struct DisplayMetadata: Codable, CustomStringConvertible {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let isMain: Bool
    public let vendorNumber: UInt32
    public let modelNumber: UInt32
    public let serialNumber: UInt32
    public let unitNumber: UInt32
    
    // Geometry
    public let appKitOriginX: Double
    public let appKitOriginY: Double
    public let appKitWidth: Double
    public let appKitHeight: Double
    
    public let cgOriginX: Double
    public let cgOriginY: Double
    public let cgWidth: Double
    public let cgHeight: Double
    
    public let pixelWidth: Double
    public let pixelHeight: Double
    public let backingScaleFactor: Double
    public let rotationDegrees: Double
    
    public var appKitFrame: CGRect {
        CGRect(x: appKitOriginX, y: appKitOriginY, width: appKitWidth, height: appKitHeight)
    }
    
    public var cgBounds: CGRect {
        CGRect(x: cgOriginX, y: cgOriginY, width: cgWidth, height: cgHeight)
    }
    
    public var description: String {
        return """
        Display #\(id): "\(name)" [\(isBuiltIn ? "Built-in" : "External")]
          - Vendor: 0x\(String(format: "%04X", vendorNumber)), Model: 0x\(String(format: "%04X", modelNumber)), Serial: \(serialNumber)
          - AppKit Frame: \(appKitFrame) (Origin BL, Y-Up)
          - CG Bounds:    \(cgBounds) (Origin TL, Y-Down)
          - Logical Size: \(Int(cgWidth))x\(Int(cgHeight)), Pixel Size: \(Int(pixelWidth))x\(Int(pixelHeight)), Scale: \(backingScaleFactor)x
          - Rotation:     \(rotationDegrees)°
        """
    }
}

public enum DisplayChangeEvent {
    case displayAdded(CGDirectDisplayID)
    case displayRemoved(CGDirectDisplayID)
    case boundsOrModeChanged(CGDirectDisplayID)
    case arrangementChanged
}

public final class DisplayManager {
    public static let shared = DisplayManager()
    
    private var isReconfigRegistered = false
    private var changeHandler: ((DisplayChangeEvent) -> Void)?
    
    private init() {}
    
    public func enumerateDisplays() -> [DisplayMetadata] {
        var results: [DisplayMetadata] = []
        let screens = NSScreen.screens
        
        let maxDisplays: UInt32 = 16
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)
        
        let mainID = CGMainDisplayID()
        
        for i in 0..<Int(displayCount) {
            let dID = activeDisplays[i]
            let isBuiltIn = (CGDisplayIsBuiltin(dID) != 0)
            let isMain = (dID == mainID)
            let vendor = CGDisplayVendorNumber(dID)
            let model = CGDisplayModelNumber(dID)
            let serial = CGDisplaySerialNumber(dID)
            let unit = CGDisplayUnitNumber(dID)
            let rot = CGDisplayRotation(dID)
            let cgBounds = CGDisplayBounds(dID)
            
            let mode = CGDisplayCopyDisplayMode(dID)
            let pixelW = Double(mode?.pixelWidth ?? Int(cgBounds.width))
            let pixelH = Double(mode?.pixelHeight ?? Int(cgBounds.height))
            
            // Find corresponding NSScreen
            let matchingScreen = screens.first { screen in
                let sNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return sNum == dID
            }
            
            let name = matchingScreen?.localizedName ?? (isBuiltIn ? "Built-in Display" : "External Display #\(dID)")
            let appKitFrame = matchingScreen?.frame ?? CGRect.zero
            let scaleFactor = matchingScreen?.backingScaleFactor ?? 1.0
            
            let meta = DisplayMetadata(
                id: dID,
                name: name,
                isBuiltIn: isBuiltIn,
                isMain: isMain,
                vendorNumber: vendor,
                modelNumber: model,
                serialNumber: serial,
                unitNumber: unit,
                appKitOriginX: Double(appKitFrame.origin.x),
                appKitOriginY: Double(appKitFrame.origin.y),
                appKitWidth: Double(appKitFrame.width),
                appKitHeight: Double(appKitFrame.height),
                cgOriginX: Double(cgBounds.origin.x),
                cgOriginY: Double(cgBounds.origin.y),
                cgWidth: Double(cgBounds.width),
                cgHeight: Double(cgBounds.height),
                pixelWidth: pixelW,
                pixelHeight: pixelH,
                backingScaleFactor: Double(scaleFactor),
                rotationDegrees: rot
            )
            results.append(meta)
        }
        
        return results
    }
    
    /// Auto-discovers the candidate external touchscreen display without hardcoding array indices.
    public func findExternalTouchscreenDisplay() -> DisplayMetadata? {
        let displays = enumerateDisplays()
        
        // 1. Filter out built-in displays
        let externals = displays.filter { !$0.isBuiltIn }
        if externals.isEmpty {
            return nil
        }
        
        // 2. If an external display matches known touchscreen labels like "TYPE C" or contains "touch"
        if let matched = externals.first(where: {
            let lower = $0.name.lowercased()
            return lower.contains("type c") || lower.contains("touch") || lower.contains("ctp")
        }) {
            return matched
        }
        
        // 3. If there is exactly one external display, it is the target
        if externals.count == 1 {
            return externals.first
        }
        
        // 4. Fallback to first external display
        return externals.first
    }
    
    public func findDisplay(byID id: CGDirectDisplayID) -> DisplayMetadata? {
        return enumerateDisplays().first { $0.id == id }
    }
    
    public func startMonitoring(onChange: @escaping (DisplayChangeEvent) -> Void) {
        self.changeHandler = onChange
        
        if !isReconfigRegistered {
            isReconfigRegistered = true
            let context = Unmanaged.passUnretained(self).toOpaque()
            
            CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
                guard let userInfo = userInfo else { return }
                let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
                
                if flags.contains(.addFlag) {
                    manager.changeHandler?(.displayAdded(displayID))
                } else if flags.contains(.removeFlag) {
                    manager.changeHandler?(.displayRemoved(displayID))
                } else if flags.contains(.movedFlag) || flags.contains(.setModeFlag) {
                    manager.changeHandler?(.boundsOrModeChanged(displayID))
                }
            }, context)
            
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.changeHandler?(.arrangementChanged)
            }
        }
    }
}
