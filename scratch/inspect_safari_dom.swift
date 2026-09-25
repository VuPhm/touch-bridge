import Foundation
import Cocoa
import ApplicationServices

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
guard let app = apps.first else {
    print("Safari not running")
    exit(1)
}
let appElem = AXUIElementCreateApplication(app.processIdentifier)
var winRef: AnyObject?
AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &winRef)
guard let windows = winRef as? [AXUIElement], let win = windows.first else {
    print("No Safari window found")
    exit(1)
}

func findWebArea(elem: AXUIElement) -> AXUIElement? {
    var roleRef: AnyObject?
    AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
    if let r = roleRef as? String, r == "AXWebArea" {
        return elem
    }
    var childrenRef: AnyObject?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement] {
        for c in children {
            if let found = findWebArea(elem: c) { return found }
        }
    }
    return nil
}

guard let webArea = findWebArea(elem: win) else {
    print("No AXWebArea found in Safari window")
    exit(1)
}

print("Found AXWebArea. Inspecting DOM elements inside Safari...")

func inspectDOM(elem: AXUIElement, depth: Int) {
    if depth > 5 { return }
    var roleRef: AnyObject?
    AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
    let role = (roleRef as? String) ?? "UnknownRole"
    
    var titleRef: AnyObject?
    AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &titleRef)
    let title = titleRef as? String
    
    var valRef: AnyObject?
    AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &valRef)
    let val = valRef != nil ? String(describing: valRef!) : nil
    
    var isValSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(elem, kAXValueAttribute as CFString, &isValSettable)
    
    var isFocusSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(elem, kAXFocusedAttribute as CFString, &isFocusSettable)
    
    var actionsRef: CFArray?
    var actions: [String] = []
    if AXUIElementCopyActionNames(elem, &actionsRef) == .success, let arr = actionsRef as? [AnyObject] {
        actions = arr.map { String(describing: $0) }
    }
    
    let indent = String(repeating: "  ", count: depth)
    print("\(indent)[\(role)] \(title != nil ? "\"\(title!)\" " : "")\(val != nil ? "Val: \"\(val!)\" " : "")Actions: \(actions) | ValSettable: \(isValSettable.boolValue) | FocusSettable: \(isFocusSettable.boolValue)")
    
    var childrenRef: AnyObject?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement] {
        for c in children {
            inspectDOM(elem: c, depth: depth + 1)
        }
    }
}

inspectDOM(elem: webArea, depth: 0)

