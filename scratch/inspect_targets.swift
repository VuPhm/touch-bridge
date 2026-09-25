import Foundation
import Cocoa
import ApplicationServices

func inspectApp(bundleID: String, name: String) {
    print("\n=======================================================")
    print("INSPECTING APPLICATION: \(name) (\(bundleID))")
    print("=======================================================")
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard let app = apps.first else {
        print("  [!] Application not running.")
        return
    }
    let pid = app.processIdentifier
    let appElem = AXUIElementCreateApplication(pid)
    
    var winRef: AnyObject?
    guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &winRef) == .success,
          let windows = winRef as? [AXUIElement], let win = windows.first else {
        print("  [!] No window found.")
        return
    }
    
    print("  Found Window. Inspecting UI elements...")
    inspectTree(element: win, depth: 0, maxDepth: 4)
}

func inspectTree(element: AXUIElement, depth: Int, maxDepth: Int) {
    if depth > maxDepth { return }
    var roleRef: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    let role = (roleRef as? String) ?? "UnknownRole"
    
    var titleRef: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
    let title = titleRef as? String
    
    var valRef: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef)
    let val = valRef != nil ? String(describing: valRef!) : nil
    
    var isValSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isValSettable)
    
    var isFocusSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &isFocusSettable)
    
    var actionsRef: CFArray?
    var actions: [String] = []
    if AXUIElementCopyActionNames(element, &actionsRef) == .success, let arr = actionsRef as? [AnyObject] {
        actions = arr.map { String(describing: $0) }
    }
    
    let indent = String(repeating: "  ", count: depth)
    let desc = "[\(role)] \(title != nil ? "\"\(title!)\" " : "")\(val != nil ? "Val: \(val!) " : "")Actions: \(actions) | ValSettable: \(isValSettable.boolValue) | FocusSettable: \(isFocusSettable.boolValue)"
    
    if role.contains("Scroll") || role.contains("Button") || role.contains("Text") || role.contains("Table") || role.contains("Outline") || role.contains("Row") || role.contains("PopUp") || role.contains("Menu") || role.contains("Web") || role.contains("Group") {
        print("\(indent)\(desc)")
    }
    
    var childrenRef: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement] {
        for c in children.prefix(8) {
            inspectTree(element: c, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

inspectApp(bundleID: "com.apple.Calculator", name: "Calculator")
inspectApp(bundleID: "com.apple.TextEdit", name: "TextEdit")
inspectApp(bundleID: "com.apple.finder", name: "Finder")
inspectApp(bundleID: "com.apple.Safari", name: "Safari")
