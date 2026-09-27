import Cocoa
import ApplicationServices

let finderApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
guard let finder = finderApps.first else { exit(1) }
let finderElem = AXUIElementCreateApplication(finder.processIdentifier)
var windowsRef: CFTypeRef?
_ = AXUIElementCopyAttributeValue(finderElem, kAXWindowsAttribute as CFString, &windowsRef)
guard let windows = windowsRef as? [AXUIElement] else { exit(1) }
guard let targetWindow = windows.first(where: {
    var title: CFTypeRef?
    AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &title)
    return (title as? String) == "Downloads"
}) else {
    print("Downloads window not found")
    exit(1)
}

var scrollArea: AXUIElement?
var scrollBar: AXUIElement?
var listElem: AXUIElement?

func findElements(elem: AXUIElement) {
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
    let role = roleRef as? String
    if role == "AXScrollArea" {
        scrollArea = elem
    }
    if role == "AXScrollBar" {
        scrollBar = elem
    }
    if role == "AXList" {
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, kAXSubroleAttribute as CFString, &subroleRef)
        if (subroleRef as? String) == "AXCollectionList" {
            listElem = elem
        }
    }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement] {
        for c in children { findElements(elem: c) }
    }
}

findElements(elem: targetWindow)
print("scrollArea: \(scrollArea != nil), scrollBar: \(scrollBar != nil), listElem: \(listElem != nil)")

guard let sb = scrollBar else {
    print("ScrollBar not found")
    exit(1)
}

func getFirstItemPosition() -> CGPoint {
    guard let list = listElem else { return .zero }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement], let first = children.first {
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(first, kAXPositionAttribute as CFString, &posRef)
        var pos = CGPoint.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        return pos
    }
    return .zero
}

print("--- Testing Visual / Structural Scroll in Finder ---")

// Set to 0.0
_ = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 0.0 as CFTypeRef)
usleep(100000)
let posAt0 = getFirstItemPosition()
var valAt0: CFTypeRef?
AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &valAt0)
print("At AXValue = 0.0 -> ScrollBar Val = \(valAt0 != nil ? "\(valAt0!)" : "nil"), First Item Pos: \(posAt0)")

// Set to 0.5
_ = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 0.5 as CFTypeRef)
usleep(100000)
let posAt05 = getFirstItemPosition()
var valAt05: CFTypeRef?
AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &valAt05)
print("At AXValue = 0.5 -> ScrollBar Val = \(valAt05 != nil ? "\(valAt05!)" : "nil"), First Item Pos: \(posAt05)")

// Set to 1.0
_ = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 1.0 as CFTypeRef)
usleep(100000)
let posAt1 = getFirstItemPosition()
var valAt1: CFTypeRef?
AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &valAt1)
print("At AXValue = 1.0 -> ScrollBar Val = \(valAt1 != nil ? "\(valAt1!)" : "nil"), First Item Pos: \(posAt1)")

// Reset to 0.0
_ = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 0.0 as CFTypeRef)
print("Shift from 0.0 to 0.5: deltaY = \(posAt05.y - posAt0.y) pt")
print("Shift from 0.0 to 1.0: deltaY = \(posAt1.y - posAt0.y) pt")
