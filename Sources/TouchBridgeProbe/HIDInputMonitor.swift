import Foundation
import IOKit
import IOKit.hid
import Darwin

struct ElementRouting {
    let fingerIndex: Int // -1 for global, 0..N for finger collections
    let usagePage: UInt32
    let usage: UInt32
    let pageName: String
    let usageName: String
    let logMin: CFIndex
    let logMax: CFIndex
    let physMin: CFIndex
    let physMax: CFIndex
}

struct FingerContact {
    var slot: Int
    var contactID: Int
    var isDown: Bool = false
    var x: Int = 0
    var y: Int = 0
    var width: Int = 0
    var logMinX: CFIndex = 0
    var logMaxX: CFIndex = 4096
    var logMinY: CFIndex = 0
    var logMaxY: CFIndex = 4096
    var physMinX: CFIndex = 0
    var physMaxX: CFIndex = 2169
    var physMinY: CFIndex = 0
    var physMaxY: CFIndex = 1356
    var lastUpdate: Double = 0.0
}

struct SessionStatistics {
    var totalEvents: Int = 0
    var touchDownCount: Int = 0
    var touchUpCount: Int = 0
    var contactIDsObserved: Set<Int> = []
    var observedXMin: Int = Int.max
    var observedXMax: Int = Int.min
    var observedYMin: Int = Int.max
    var observedYMax: Int = Int.min
    var candidateDeviceEvents: Int = 0
    var nonCandidateDeviceEvents: Int = 0
}

final class HIDInputMonitor {
    private let monitoredDevices: [IOHIDDevice]
    private let candidateDeviceLocations: Set<Int>
    private let candidateDevicePIDs: Set<Int>
    private let filterCandidatesOnly: Bool
    private let rawLoggingEnabled: Bool

    private let startTime: UInt64
    private var timebaseInfo = mach_timebase_info()

    private var routingTable: [IOHIDElementCookie: ElementRouting] = [:]
    private var fingerContacts: [Int: FingerContact] = [:]
    private(set) var stats = SessionStatistics()

    init(devicesToMonitor: [IOHIDDevice], candidates: [DeviceMetadata], filterCandidatesOnly: Bool = true, rawLogging: Bool = true) {
        self.monitoredDevices = devicesToMonitor
        self.candidateDeviceLocations = Set(candidates.map { $0.locationID })
        self.candidateDevicePIDs = Set(candidates.map { $0.productID })
        self.filterCandidatesOnly = filterCandidatesOnly
        self.rawLoggingEnabled = rawLogging
        self.startTime = mach_absolute_time()
        mach_timebase_info(&self.timebaseInfo)

        // Build element routing table
        for dev in candidates {
            var currentFingerIndex = -1
            for elem in dev.elements {
                if elem.type == kIOHIDElementTypeCollection && elem.usagePage == 0x0D && elem.usage == 0x22 {
                    currentFingerIndex += 1
                }
                let slot = (elem.parentUsagePage == 0x0D && elem.parentUsage == 0x22) ? max(0, currentFingerIndex) : -1
                routingTable[elem.cookie] = ElementRouting(
                    fingerIndex: slot,
                    usagePage: elem.usagePage,
                    usage: elem.usage,
                    pageName: elem.usagePageName,
                    usageName: elem.usageName,
                    logMin: elem.logicalMin,
                    logMax: elem.logicalMax,
                    physMin: elem.physicalMin,
                    physMax: elem.physicalMax
                )

                if slot >= 0 && fingerContacts[slot] == nil {
                    var fc = FingerContact(slot: slot, contactID: slot)
                    if elem.isAbsoluteX {
                        fc.logMinX = elem.logicalMin
                        fc.logMaxX = elem.logicalMax
                        fc.physMinX = elem.physicalMin
                        fc.physMaxX = elem.physicalMax
                    }
                    if elem.isAbsoluteY {
                        fc.logMinY = elem.logicalMin
                        fc.logMaxY = elem.logicalMax
                        fc.physMinY = elem.physicalMin
                        fc.physMaxY = elem.physicalMax
                    }
                    fingerContacts[slot] = fc
                }
            }
        }
    }

    private func elapsedTime(for machTime: UInt64) -> Double {
        let elapsedMach = (machTime >= startTime) ? (machTime - startTime) : 0
        let nanos = elapsedMach * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        return Double(nanos) / 1_000_000_000.0
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOHIDValueCallback = { context, result, sender, value in
            guard let context = context else { return }
            let monitor = Unmanaged<HIDInputMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleValue(value, sender: sender)
        }

        print("\nOpening HID input streams (passive, non-exclusive):")
        for device in monitoredDevices {
            let openRes = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            let devName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Unknown Device"
            if openRes == kIOReturnSuccess {
                print("  [✓] Passively opened: \(devName)")
                IOHIDDeviceRegisterInputValueCallback(device, callback, context)
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            } else {
                print("  [!] Skipping device \(devName): IOHIDDeviceOpen returned 0x\(String(format: "%08X", openRes))")
            }
        }
    }

    private func handleValue(_ value: IOHIDValue, sender: UnsafeMutableRawPointer?) {
        guard let sender = sender else { return }
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()

        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0
        let devName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Unknown Device"

        let isCandidate = candidateDevicePIDs.contains(productID) || candidateDeviceLocations.contains(locationID)

        if filterCandidatesOnly && !isCandidate {
            stats.nonCandidateDeviceEvents += 1
            return
        }

        stats.totalEvents += 1
        stats.candidateDeviceEvents += 1

        let element = IOHIDValueGetElement(value)
        let cookie = IOHIDElementGetCookie(element)
        let intVal = IOHIDValueGetIntegerValue(value)
        let machTime = IOHIDValueGetTimeStamp(value)
        let elapsed = elapsedTime(for: machTime)

        let routing = routingTable[cookie]
        let usagePage = routing?.usagePage ?? IOHIDElementGetUsagePage(element)
        let usage = routing?.usage ?? IOHIDElementGetUsage(element)
        let pageName = routing?.pageName ?? HIDNames.usagePageName(usagePage)
        let uName = routing?.usageName ?? HIDNames.usageName(page: usagePage, usage: usage)
        let logMin = routing?.logMin ?? IOHIDElementGetLogicalMin(element)
        let logMax = routing?.logMax ?? IOHIDElementGetLogicalMax(element)
        let physMin = routing?.physMin ?? IOHIDElementGetPhysicalMin(element)
        let physMax = routing?.physMax ?? IOHIDElementGetPhysicalMax(element)
        let slot = routing?.fingerIndex ?? -1

        if rawLoggingEnabled {
            let slotStr = (slot >= 0) ? " [Slot #\(slot)]" : ""
            let line = String(
                format: "[RAW] +%6.3fs dev=%@ (0x%04X:0x%04X)%@ page=%@ usage=%@ val=%d [log: %ld..%ld, phys: %ld..%ld]",
                elapsed,
                devName,
                vendorID,
                productID,
                slotStr,
                pageName,
                uName,
                intVal,
                logMin,
                logMax,
                physMin,
                physMax
            )
            print(line)
            fflush(stdout)
        }

        // Process touch semantics
        if slot >= 0 {
            var contact = fingerContacts[slot] ?? FingerContact(slot: slot, contactID: slot)
            contact.lastUpdate = elapsed

            if usagePage == 0x0D { // Digitizer
                switch usage {
                case 0x42: // Tip Switch (Touch Down / Up)
                    let wasDown = contact.isDown
                    let isDown = (intVal != 0)
                    contact.isDown = isDown
                    if !wasDown && isDown {
                        stats.touchDownCount += 1
                        let normX = (contact.logMaxX > contact.logMinX) ? Double(contact.x - contact.logMinX) / Double(contact.logMaxX - contact.logMinX) : 0.0
                        let normY = (contact.logMaxY > contact.logMinY) ? Double(contact.y - contact.logMinY) / Double(contact.logMaxY - contact.logMinY) : 0.0
                        print(String(format: ">>> [TOUCH DOWN] +%6.3fs Slot #%d (ID: %d): X=%d (norm: %.4f), Y=%d (norm: %.4f)",
                                     elapsed, slot, contact.contactID, contact.x, normX, contact.y, normY))
                        fflush(stdout)
                    } else if wasDown && !isDown {
                        stats.touchUpCount += 1
                        print(String(format: "<<< [TOUCH UP]   +%6.3fs Slot #%d (ID: %d): X=%d, Y=%d",
                                     elapsed, slot, contact.contactID, contact.x, contact.y))
                        fflush(stdout)
                    }
                case 0x51: // Contact Identifier
                    contact.contactID = intVal
                    stats.contactIDsObserved.insert(intVal)
                case 0x48: // Width
                    contact.width = intVal
                default:
                    break
                }
            } else if usagePage == 0x01 { // Generic Desktop
                switch usage {
                case 0x30: // Absolute X
                    contact.x = intVal
                    if intVal < stats.observedXMin { stats.observedXMin = intVal }
                    if intVal > stats.observedXMax { stats.observedXMax = intVal }
                    if contact.isDown {
                        let normX = (contact.logMaxX > contact.logMinX) ? Double(intVal - contact.logMinX) / Double(contact.logMaxX - contact.logMinX) : 0.0
                        let normY = (contact.logMaxY > contact.logMinY) ? Double(contact.y - contact.logMinY) / Double(contact.logMaxY - contact.logMinY) : 0.0
                        print(String(format: "    [TOUCH MOVE] +%6.3fs Slot #%d (ID: %d): X=%d (norm: %.4f), Y=%d (norm: %.4f)",
                                     elapsed, slot, contact.contactID, intVal, normX, contact.y, normY))
                        fflush(stdout)
                    }
                case 0x31: // Absolute Y
                    contact.y = intVal
                    if intVal < stats.observedYMin { stats.observedYMin = intVal }
                    if intVal > stats.observedYMax { stats.observedYMax = intVal }
                    if contact.isDown {
                        let normX = (contact.logMaxX > contact.logMinX) ? Double(contact.x - contact.logMinX) / Double(contact.logMaxX - contact.logMinX) : 0.0
                        let normY = (contact.logMaxY > contact.logMinY) ? Double(intVal - contact.logMinY) / Double(contact.logMaxY - contact.logMinY) : 0.0
                        print(String(format: "    [TOUCH MOVE] +%6.3fs Slot #%d (ID: %d): X=%d (norm: %.4f), Y=%d (norm: %.4f)",
                                     elapsed, slot, contact.contactID, contact.x, normX, intVal, normY))
                        fflush(stdout)
                    }
                default:
                    break
                }
            }
            fingerContacts[slot] = contact
        } else {
            // Global elements (e.g. Contact Count 0x54)
            if usagePage == 0x0D && usage == 0x54 { // Contact Count
                if intVal > 0 {
                    // Contact count reported in multi-touch frame
                }
            }
        }
    }

    func printSessionSummary() {
        print("\n=======================================================")
        print("                 SESSION SUMMARY                       ")
        print("=======================================================")
        print("Total candidate events processed: \(stats.candidateDeviceEvents)")
        print("Non-candidate events ignored:     \(stats.nonCandidateDeviceEvents)")
        print("Touch DOWN count:                 \(stats.touchDownCount)")
        print("Touch UP count:                   \(stats.touchUpCount)")
        print("Contact IDs observed:             \(stats.contactIDsObserved.sorted())")
        if stats.observedXMin <= stats.observedXMax {
            print("Observed X Range:                 [\(stats.observedXMin) .. \(stats.observedXMax)]")
        } else {
            print("Observed X Range:                 None")
        }
        if stats.observedYMin <= stats.observedYMax {
            print("Observed Y Range:                 [\(stats.observedYMin) .. \(stats.observedYMax)]")
        } else {
            print("Observed Y Range:                 None")
        }
        print("=======================================================\n")
        fflush(stdout)
    }
}
