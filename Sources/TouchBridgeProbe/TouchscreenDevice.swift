import Foundation
import IOKit
import IOKit.hid

// MARK: - Touchscreen Device Lifecycle & Ownership (P3-01 Section 4)

public protocol TouchscreenDeviceDelegate: AnyObject {
    func touchscreenDevice(_ device: TouchscreenDevice, didChangeState state: DeviceState)
    func touchscreenDevice(_ device: TouchscreenDevice, didReceiveRawElement value: IOHIDValue)
}

public final class TouchscreenDevice {
    public static let targetVendorID: Int = 0x1A86  // 6790 (wch.cn)
    public static let targetProductID: Int = 0xE5E3 // 58851 (USB2IIC_CTP_CONTROL)
    public static let targetNameHint: String = "USB2IIC_CTP_CONTROL"
    
    public weak var delegate: TouchscreenDeviceDelegate?
    
    private var hidManager: IOHIDManager?
    private(set) var activeDevice: IOHIDDevice?
    private(set) var deviceState: DeviceState = .disconnected
    
    // Extracted ranges
    public private(set) var logMinX: Int = 0
    public private(set) var logMaxX: Int = 4096
    public private(set) var logMinY: Int = 0
    public private(set) var logMaxY: Int = 4096
    public private(set) var deviceName: String = targetNameHint
    
    public init() {}
    
    public func start() {
        guard hidManager == nil else { return }
        
        TouchBridgeLogger.info(.hid, "Starting passive IOHIDManager for Target Touchscreen (VID: 0x\(String(format: "%04X", TouchscreenDevice.targetVendorID)), PID: 0x\(String(format: "%04X", TouchscreenDevice.targetProductID)))")
        
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager
        
        // Exact hardware identity match by VID/PID
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey: TouchscreenDevice.targetVendorID,
            kIOHIDProductIDKey: TouchscreenDevice.targetProductID
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        // Device Matching (Connect / Reconnect)
        let matchingCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let selfRef = Unmanaged<TouchscreenDevice>.fromOpaque(context).takeUnretainedValue()
            selfRef.handleDeviceConnected(device)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, context)
        
        // Device Removal (Disconnect)
        let removalCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let selfRef = Unmanaged<TouchscreenDevice>.fromOpaque(context).takeUnretainedValue()
            selfRef.handleDeviceDisconnected(device)
        }
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, context)
        
        // Raw Input Value Stream
        let inputCallback: IOHIDValueCallback = { context, result, sender, value in
            guard let context = context else { return }
            let selfRef = Unmanaged<TouchscreenDevice>.fromOpaque(context).takeUnretainedValue()
            selfRef.handleInputValue(value)
        }
        IOHIDManagerRegisterInputValueCallback(manager, inputCallback, context)
        
        // Schedule on Main RunLoop CommonModes for uninterrupted tracking during menu interactions
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        
        // Open PASSIVELY (NEVER SEIZE)
        let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openRes != kIOReturnSuccess {
            TouchBridgeLogger.error(.hid, "Failed to open IOHIDManager: 0x\(String(format: "%08X", openRes))")
            transition(to: .error("IOHIDManagerOpen failed: 0x\(String(format: "%08X", openRes))"))
        } else {
            TouchBridgeLogger.debug(.hid, "IOHIDManager opened passively (kIOHIDOptionsTypeNone)")
        }
    }
    
    public func stop() {
        guard let manager = hidManager else { return }
        TouchBridgeLogger.info(.hid, "Stopping IOHIDManager and releasing callbacks.")
        
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = nil
        self.activeDevice = nil
        transition(to: .disconnected)
    }
    
    private func handleDeviceConnected(_ device: IOHIDDevice) {
        self.activeDevice = device
        
        // Explicitly open the matched device passively
        let devOpenRes = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if devOpenRes != kIOReturnSuccess && devOpenRes != kIOReturnStillOpen {
            TouchBridgeLogger.warning(.hid, "IOHIDDeviceOpen returned 0x\(String(format: "%08X", devOpenRes))")
        }
        
        // Register input value callback directly on the device as well to guarantee delivery
        let devContext = Unmanaged.passUnretained(self).toOpaque()
        let devInputCallback: IOHIDValueCallback = { context, result, sender, value in
            guard let context = context else { return }
            let selfRef = Unmanaged<TouchscreenDevice>.fromOpaque(context).takeUnretainedValue()
            selfRef.handleInputValue(value)
        }
        IOHIDDeviceRegisterInputValueCallback(device, devInputCallback, devContext)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        
        // Read device name and properties
        let prodName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? TouchscreenDevice.targetNameHint
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? TouchscreenDevice.targetVendorID
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? TouchscreenDevice.targetProductID
        self.deviceName = prodName
        
        // Inspect elements for coordinate ranges
        inspectDeviceElements(device)
        
        TouchBridgeLogger.info(
            .hid,
            "Target Touchscreen CONNECTED & OPENED: \"\(prodName)\" (0x\(String(format: "%04X", vid)):0x\(String(format: "%04X", pid))) | X: [\(logMinX)..\(logMaxX)], Y: [\(logMinY)..\(logMaxY)]"
        )
        
        transition(to: .available(name: prodName, vid: vid, pid: pid))
    }
    
    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        TouchBridgeLogger.warning(.hid, "Target Touchscreen DISCONNECTED.")
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.activeDevice = nil
        transition(to: .disconnected)
    }
    
    private func handleInputValue(_ value: IOHIDValue) {
        guard deviceState.isConnected else { return }
        delegate?.touchscreenDevice(self, didReceiveRawElement: value)
    }
    
    private func inspectDeviceElements(_ device: IOHIDDevice) {
        guard let rawElements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return
        }
        
        for elem in rawElements {
            let page = IOHIDElementGetUsagePage(elem)
            let usage = IOHIDElementGetUsage(elem)
            if page == 0x01 && usage == 0x30 { // Generic Desktop X
                logMinX = Int(IOHIDElementGetLogicalMin(elem))
                logMaxX = Int(IOHIDElementGetLogicalMax(elem))
            } else if page == 0x01 && usage == 0x31 { // Generic Desktop Y
                logMinY = Int(IOHIDElementGetLogicalMin(elem))
                logMaxY = Int(IOHIDElementGetLogicalMax(elem))
            }
        }
    }
    
    private func transition(to newState: DeviceState) {
        guard deviceState != newState else { return }
        deviceState = newState
        delegate?.touchscreenDevice(self, didChangeState: newState)
    }
}
