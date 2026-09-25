import Foundation
import IOKit.hid

enum HIDNames {
    static func usagePageName(_ page: UInt32) -> String {
        switch page {
        case 0x01: return "Generic Desktop (0x01)"
        case 0x02: return "Simulation Controls (0x02)"
        case 0x03: return "VR Controls (0x03)"
        case 0x04: return "Sport Controls (0x04)"
        case 0x05: return "Game Controls (0x05)"
        case 0x06: return "Generic Device Controls (0x06)"
        case 0x07: return "Keyboard/Keypad (0x07)"
        case 0x08: return "LED (0x08)"
        case 0x09: return "Button (0x09)"
        case 0x0A: return "Ordinal (0x0A)"
        case 0x0B: return "Telephony (0x0B)"
        case 0x0C: return "Consumer (0x0C)"
        case 0x0D: return "Digitizer (0x0D)"
        case 0x0E: return "Haptics (0x0E)"
        case 0x14: return "Auxiliary Display (0x14)"
        case 0x20: return "Sensor (0x20)"
        case 0xFF00...0xFFFF: return String(format: "Vendor-Defined (0x%04X)", page)
        default: return String(format: "UsagePage(0x%04X)", page)
        }
    }

    static func usageName(page: UInt32, usage: UInt32) -> String {
        switch page {
        case 0x01: // Generic Desktop
            switch usage {
            case 0x01: return "Pointer (0x01)"
            case 0x02: return "Mouse (0x02)"
            case 0x04: return "Joystick (0x04)"
            case 0x05: return "Game Pad (0x05)"
            case 0x06: return "Keyboard (0x06)"
            case 0x07: return "Keypad (0x07)"
            case 0x08: return "Multi-axis Controller (0x08)"
            case 0x30: return "X (0x30)"
            case 0x31: return "Y (0x31)"
            case 0x32: return "Z (0x32)"
            case 0x33: return "Rx (0x33)"
            case 0x34: return "Ry (0x34)"
            case 0x35: return "Rz (0x35)"
            case 0x36: return "Slider (0x36)"
            case 0x37: return "Dial (0x37)"
            case 0x38: return "Wheel (0x38)"
            case 0x39: return "Hat Switch (0x39)"
            case 0x3A: return "Counted Buffer (0x3A)"
            case 0x3B: return "Byte Count (0x3B)"
            case 0x3D: return "Motion Wakeup (0x3D)"
            case 0x80: return "System Control (0x80)"
            default: return String(format: "GenericDesktop(0x%02X)", usage)
            }
        case 0x07: // Keyboard
            return String(format: "Keycode(0x%02X)", usage)
        case 0x09: // Button
            return String(format: "Button %d (0x%02X)", usage, usage)
        case 0x0D: // Digitizer
            switch usage {
            case 0x01: return "Digitizer (0x01)"
            case 0x02: return "Pen (0x02)"
            case 0x03: return "Light Pen (0x03)"
            case 0x04: return "Touch Screen (0x04)"
            case 0x05: return "Touch Pad (0x05)"
            case 0x06: return "Whiteboard (0x06)"
            case 0x20: return "Stylus (0x20)"
            case 0x21: return "Puck (0x21)"
            case 0x22: return "Finger (0x22)"
            case 0x30: return "Tip Pressure (0x30)"
            case 0x31: return "Barrel Pressure (0x31)"
            case 0x32: return "In Range (0x32)"
            case 0x33: return "Touch (0x33)"
            case 0x34: return "Untouch (0x34)"
            case 0x35: return "Tap (0x35)"
            case 0x36: return "Quality (0x36)"
            case 0x37: return "Data Valid (0x37)"
            case 0x38: return "Transducer Index (0x38)"
            case 0x39: return "Tablet Function Keys (0x39)"
            case 0x3A: return "Program Change Keys (0x3A)"
            case 0x3B: return "Battery Strength (0x3B)"
            case 0x3C: return "Invert (0x3C)"
            case 0x3D: return "X Tilt (0x3D)"
            case 0x3E: return "Y Tilt (0x3E)"
            case 0x3F: return "Azimuth (0x3F)"
            case 0x40: return "Altitude (0x40)"
            case 0x41: return "Twist (0x41)"
            case 0x42: return "Tip Switch (0x42)"
            case 0x43: return "Secondary Tip Switch (0x43)"
            case 0x44: return "Barrel Switch (0x44)"
            case 0x45: return "Eraser (0x45)"
            case 0x46: return "Tablet Pick (0x46)"
            case 0x47: return "Confidence (0x47)"
            case 0x48: return "Width (0x48)"
            case 0x49: return "Height (0x49)"
            case 0x51: return "Contact Identifier (0x51)"
            case 0x52: return "Device Mode (0x52)"
            case 0x53: return "Device Settings (0x53)"
            case 0x54: return "Contact Count (0x54)"
            case 0x55: return "Contact Count Maximum (0x55)"
            case 0x56: return "Scan Time (0x56)"
            case 0x57: return "Surface Switch (0x57)"
            case 0x58: return "Button Switch (0x58)"
            default: return String(format: "Digitizer(0x%02X)", usage)
            }
        default:
            return String(format: "Usage(0x%02X)", usage)
        }
    }

    static func elementTypeName(_ type: IOHIDElementType) -> String {
        switch type {
        case kIOHIDElementTypeInput_Misc: return "Input_Misc"
        case kIOHIDElementTypeInput_Button: return "Input_Button"
        case kIOHIDElementTypeInput_Axis: return "Input_Axis"
        case kIOHIDElementTypeInput_ScanCodes: return "Input_ScanCodes"
        case kIOHIDElementTypeOutput: return "Output"
        case kIOHIDElementTypeFeature: return "Feature"
        case kIOHIDElementTypeCollection: return "Collection"
        default: return "Type(\(type.rawValue))"
        }
    }
}
