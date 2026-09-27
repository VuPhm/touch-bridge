import Cocoa
import ApplicationServices

let finderApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
guard let finder = finderApps.first else {
    print("Finder not running")
    exit(1)
}

let finderElem = AXUIElementCreateApplication(finder.processIdentifier)
var windowsRef: CFTypeRef?
_ = AXUIElementCopyAttributeValue(finderElem, kAXWindowsAttribute as CFString, &windowsRef)

guard let windows = windowsRef as? [AXUIElement] else {
    print("No windows found")
    exit(1)
}

var downloadsWindow: AXUIElement? = nil
for w in windows {
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
    if let title = titleRef as? String, title == "Downloads" {
        downloadsWindow = w
        break
    }
}

guard let targetWindow = downloadsWindow else {
    print("Downloads window not found")
    exit(1)
}

print("=== Found Downloads Window ===")

func printDetails(elem: AXUIElement, depth: Int = 0) {
    if depth > 4 { return } // limit depth
    let indent = String(repeating: "  ", count: depth)
    var roleRef: CFTypeRef?
    var subroleRef: CFTypeRef?
    var titleRef: CFTypeRef?
    var valRef: CFTypeRef?
    var minRef: CFTypeRef?
    var maxRef: CFTypeRef?
    var incRef: CFTypeRef?
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    
    AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
    AXUIElementCopyAttributeValue(elem, kAXSubroleAttribute as CFString, &subroleRef)
    AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &titleRef)
    AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &valRef)
    AXUIElementCopyAttributeValue(elem, kAXMinValueAttribute as CFString, &minRef)
    AXUIElementCopyAttributeValue(elem, kAXMaxValueAttribute as CFString, &maxRef)
    AXUIElementCopyAttributeValue(elem, kAXValueIncrementAttribute as CFString, &incRef)
    AXUIElementCopyAttributeValue(elem, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(elem, kAXSizeAttribute as CFString, &sizeRef)
    
    var pos = CGPoint.zero
    if let p = posRef, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    var sz = CGSize.zero
    if let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
    
    var isSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(elem, kAXValueAttribute as CFString, &isSettable)
    
    var actionsRef: CFArray?
    AXUIElementCopyActionNames(elem, &actionsRef)
    let actions = (actionsRef as? [String]) ?? []
    
    let role = roleRef as? String ?? "nil"
    let subrole = subroleRef as? String ?? "nil"
    let title = titleRef as? String ?? ""
    
    print("\(indent)- Role: \(role), Subrole: \(subrole), Title: \"\(title)\"")
    print("\(indent)  Bounds: pos=\(pos) sz=\(sz)")
    if valRef != nil || minRef != nil || maxRef != nil || incRef != nil {
        let vStr = valRef != nil ? "\(valRef!)" : "nil"
        let minStr = minRef != nil ? "\(minRef!)" : "nil"
        let maxStr = maxRef != nil ? "\(maxRef!)" : "nil"
        let incStr = incRef != nil ? "\(incRef!)" : "nil"
        print("\(indent)  Value: \(vStr), Min: \(minStr), Max: \(maxStr), Inc: \(incStr), Settable: \(isSettable.boolValue)")
    }
    if !actions.isEmpty {
        print("\(indent)  Actions: \(actions.joined(separator: ", "))")
    }
    
    // Check for Scrollbars specifically if scroll area
    if role == "AXScrollArea" {
        var vsb: CFTypeRef?
        var hsb: CFTypeRef?
        let vErr = AXUIElementCopyAttributeValue(elem, "AXVerticalScrollBar" as CFString, &vsb)
        let hErr = AXUIElementCopyAttributeValue(elem, "AXHorizontalScrollBar" as CFString, &hsb)
        print("\(indent)  [ScrollArea details] VSB: \(vsb != nil ? "present" : "nil (\(vErr.rawValue))"), HSB: \(hsb != nil ? "present" : "nil (\(hErr.rawValue))")")
        if let vElem = vsb {
            print("\(indent)  --- Vertical Scrollbar ---")
            printDetails(elem: vElem as! AXUIElement, depth: depth + 2)
        }
    }
    
    // Recurse children
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement] {
        for child in children {
            printDetails(elem: child, depth: depth + 1)
        }
    }
}

printDetails(elem: targetWindow)
