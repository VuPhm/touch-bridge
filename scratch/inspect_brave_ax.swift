import Cocoa
import ApplicationServices

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.brave.Browser")
guard let app = apps.first else { exit(1) }
let appElem = AXUIElementCreateApplication(app.processIdentifier)
var windowsRef: CFTypeRef?
_ = AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
guard let windows = windowsRef as? [AXUIElement], let win = windows.first else { exit(1) }

func printTree(elem: AXUIElement, depth: Int = 0) {
    if depth > 4 { return }
    let indent = String(repeating: "  ", count: depth)
    var rRef: CFTypeRef?
    var sRef: CFTypeRef?
    var tRef: CFTypeRef?
    AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &rRef)
    AXUIElementCopyAttributeValue(elem, kAXSubroleAttribute as CFString, &sRef)
    AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &tRef)
    let role = (rRef as? String) ?? "nil"
    let subrole = (sRef as? String) ?? "nil"
    let title = (tRef as? String) ?? ""
    
    var actsRef: CFArray?
    AXUIElementCopyActionNames(elem, &actsRef)
    let actions = (actsRef as? [String]) ?? []
    
    var isSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(elem, kAXValueAttribute as CFString, &isSettable)
    
    print("\(indent)- Role: \(role), Subrole: \(subrole), Title: \"\(title)\"")
    if !actions.isEmpty {
        print("\(indent)  Actions: \(actions.joined(separator: ", "))")
    }
    
    var cRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &cRef) == .success,
       let children = cRef as? [AXUIElement] {
        for c in children { printTree(elem: c, depth: depth + 1) }
    }
}

print("=== Brave Browser AX Tree ===")
printTree(elem: win)
