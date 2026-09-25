import Foundation
import IOKit
import IOKit.hid

struct ElementMetadata {
    let element: IOHIDElement
    let cookie: IOHIDElementCookie
    let type: IOHIDElementType
    let usagePage: UInt32
    let usage: UInt32
    let reportID: UInt32
    let reportSize: UInt32
    let reportCount: UInt32
    let logicalMin: CFIndex
    let logicalMax: CFIndex
    let physicalMin: CFIndex
    let physicalMax: CFIndex
    let unit: UInt32
    let unitExponent: UInt32
    let parentUsagePage: UInt32?
    let parentUsage: UInt32?

    var typeName: String {
        HIDNames.elementTypeName(type)
    }

    var usagePageName: String {
        HIDNames.usagePageName(usagePage)
    }

    var usageName: String {
        HIDNames.usageName(page: usagePage, usage: usage)
    }

    var isAbsoluteX: Bool {
        usagePage == 0x01 && usage == 0x30
    }

    var isAbsoluteY: Bool {
        usagePage == 0x01 && usage == 0x31
    }

    var isTipSwitch: Bool {
        usagePage == 0x0D && usage == 0x42
    }

    var isContactIdentifier: Bool {
        usagePage == 0x0D && usage == 0x51
    }

    var isInRange: Bool {
        usagePage == 0x0D && usage == 0x32
    }

    var isConfidence: Bool {
        usagePage == 0x0D && usage == 0x47
    }

    var isContactCount: Bool {
        usagePage == 0x0D && usage == 0x54
    }

    var isTipPressure: Bool {
        usagePage == 0x0D && usage == 0x30
    }
}

struct DeviceMetadata {
    let device: IOHIDDevice
    let name: String
    let manufacturer: String
    let vendorID: Int
    let productID: Int
    let primaryUsagePage: UInt32
    let primaryUsage: UInt32
    let deviceUsagePairs: [(page: UInt32, usage: UInt32)]
    let transport: String
    let locationID: Int
    let elements: [ElementMetadata]

    var isExternalTouchscreen: Bool {
        // Exclude Apple Inc. internal devices (Touch Bar, built-in trackpad)
        if vendorID == 0x05AC {
            return false
        }
        if primaryUsagePage == 0x0D && (primaryUsage == 0x04 || primaryUsage == 0x01) {
            return true
        }
        if elements.contains(where: { $0.usagePage == 0x0D && $0.usage == 0x04 }) {
            return true
        }
        let lowerName = name.lowercased()
        if lowerName.contains("ctp") || lowerName.contains("touchscreen") || lowerName.contains("touch") {
            return true
        }
        return false
    }

    var isCandidateTouchscreen: Bool {
        if isExternalTouchscreen {
            return true
        }
        if primaryUsagePage == 0x0D {
            return true
        }
        if deviceUsagePairs.contains(where: { $0.page == 0x0D }) {
            return true
        }
        if elements.contains(where: { $0.usagePage == 0x0D }) {
            return true
        }
        let lowerName = name.lowercased()
        if lowerName.contains("touch") || lowerName.contains("ctp") || lowerName.contains("digitizer") {
            return true
        }
        return false
    }

    var absoluteXElement: ElementMetadata? {
        elements.first(where: { $0.isAbsoluteX })
    }

    var absoluteYElement: ElementMetadata? {
        elements.first(where: { $0.isAbsoluteY })
    }

    var tipSwitchElement: ElementMetadata? {
        elements.first(where: { $0.isTipSwitch })
    }

    var contactIDElement: ElementMetadata? {
        elements.first(where: { $0.isContactIdentifier })
    }

    var inRangeElement: ElementMetadata? {
        elements.first(where: { $0.isInRange })
    }

    var confidenceElement: ElementMetadata? {
        elements.first(where: { $0.isConfidence })
    }

    var contactCountElement: ElementMetadata? {
        elements.first(where: { $0.isContactCount })
    }

    var tipPressureElement: ElementMetadata? {
        elements.first(where: { $0.isTipPressure })
    }

    var fingerCollectionsCount: Int {
        // Collections with UsagePage 0x0D and Usage 0x22 (Finger)
        elements.filter { $0.type == kIOHIDElementTypeCollection && $0.usagePage == 0x0D && $0.usage == 0x22 }.count
    }

    var contactIDCount: Int {
        elements.filter { $0.isContactIdentifier }.count
    }

    var tipSwitchCount: Int {
        elements.filter { $0.isTipSwitch }.count
    }
}

class HIDDeviceInspector {
    static func inspect(device: IOHIDDevice) -> DeviceMetadata {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Unknown Product"
        let manufacturer = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? "Unknown Manufacturer"
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "Unknown"

        let primaryUsagePage = UInt32((IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0)
        let primaryUsage = UInt32((IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0)

        var usagePairs: [(page: UInt32, usage: UInt32)] = []
        if let rawPairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] {
            for dict in rawPairs {
                let page = UInt32(dict[kIOHIDDeviceUsagePageKey] as? Int ?? 0)
                let usage = UInt32(dict[kIOHIDDeviceUsageKey] as? Int ?? 0)
                usagePairs.append((page: page, usage: usage))
            }
        }

        var elements: [ElementMetadata] = []
        if let rawElements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for elem in rawElements {
                let elemType = IOHIDElementGetType(elem)
                let uPage = IOHIDElementGetUsagePage(elem)
                let u = IOHIDElementGetUsage(elem)
                let rID = IOHIDElementGetReportID(elem)
                let rSize = IOHIDElementGetReportSize(elem)
                let rCount = IOHIDElementGetReportCount(elem)
                let lMin = IOHIDElementGetLogicalMin(elem)
                let lMax = IOHIDElementGetLogicalMax(elem)
                let pMin = IOHIDElementGetPhysicalMin(elem)
                let pMax = IOHIDElementGetPhysicalMax(elem)
                let unit = IOHIDElementGetUnit(elem)
                let unitExp = IOHIDElementGetUnitExponent(elem)

                var parentPage: UInt32? = nil
                var parentU: UInt32? = nil
                if let parent = IOHIDElementGetParent(elem) {
                    parentPage = IOHIDElementGetUsagePage(parent)
                    parentU = IOHIDElementGetUsage(parent)
                }

                let cookie = IOHIDElementGetCookie(elem)

                elements.append(ElementMetadata(
                    element: elem,
                    cookie: cookie,
                    type: elemType,
                    usagePage: uPage,
                    usage: u,
                    reportID: rID,
                    reportSize: rSize,
                    reportCount: rCount,
                    logicalMin: lMin,
                    logicalMax: lMax,
                    physicalMin: pMin,
                    physicalMax: pMax,
                    unit: unit,
                    unitExponent: unitExp,
                    parentUsagePage: parentPage,
                    parentUsage: parentU
                ))
            }
        }

        return DeviceMetadata(
            device: device,
            name: name,
            manufacturer: manufacturer,
            vendorID: vendorID,
            productID: productID,
            primaryUsagePage: primaryUsagePage,
            primaryUsage: primaryUsage,
            deviceUsagePairs: usagePairs,
            transport: transport,
            locationID: locationID,
            elements: elements
        )
    }

    static func enumerateAll(manager: IOHIDManager) -> [DeviceMetadata] {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        return deviceSet.map { inspect(device: $0) }
    }
}
