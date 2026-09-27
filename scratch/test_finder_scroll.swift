import Cocoa
import ApplicationServices

func describe(_ obj: CFTypeRef?) -> String {
    if let o = obj { return "\(o)" }
    return "nil"
}

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

print("=== Finder Downloads Window Found ===")

// Locate the AXScrollArea and AXScrollBar
var scrollArea: AXUIElement? = nil
var scrollBar: AXUIElement? = nil

func findScrollElements(elem: AXUIElement) {
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
    if let role = roleRef as? String {
        if role == "AXScrollArea" && scrollArea == nil {
            scrollArea = elem
            var vsb: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, "AXVerticalScrollBar" as CFString, &vsb) == .success, let b = vsb {
                scrollBar = (b as! AXUIElement)
            }
        } else if role == "AXScrollBar" && scrollBar == nil {
            scrollBar = elem
        }
    }
    
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement] {
        for child in children {
            findScrollElements(elem: child)
        }
    }
}

findScrollElements(elem: targetWindow)

guard let sa = scrollArea, let sb = scrollBar else {
    print("Scroll elements not found. sa=\(String(describing: scrollArea)), sb=\(String(describing: scrollBar))")
    exit(1)
}

print("Found AXScrollArea and AXScrollBar:")

func printScrollbarAttributes(sb: AXUIElement) {
    var valRef: CFTypeRef?
    var minRef: CFTypeRef?
    var maxRef: CFTypeRef?
    var incRef: CFTypeRef?
    var isSettable: DarwinBoolean = false
    
    AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &valRef)
    AXUIElementCopyAttributeValue(sb, kAXMinValueAttribute as CFString, &minRef)
    AXUIElementCopyAttributeValue(sb, kAXMaxValueAttribute as CFString, &maxRef)
    AXUIElementCopyAttributeValue(sb, kAXValueIncrementAttribute as CFString, &incRef)
    AXUIElementIsAttributeSettable(sb, kAXValueAttribute as CFString, &isSettable)
    
    var typeStr = "unknown"
    if let v = valRef {
        typeStr = CFCopyTypeIDDescription(CFGetTypeID(v)) as String
    }
    
    print("  ScrollBar Value: \(describe(valRef)) (type: \(typeStr))")
    print("  ScrollBar Min: \(describe(minRef)), Max: \(describe(maxRef)), Inc: \(describe(incRef))")
    print("  ScrollBar Settable: \(isSettable.boolValue)")
    
    var actsRef: CFArray?
    AXUIElementCopyActionNames(sb, &actsRef)
    print("  ScrollBar Actions: \((actsRef as? [String])?.joined(separator: ", ") ?? "none")")
}

printScrollbarAttributes(sb: sb)

// Check current cursor, frontmost app, and key window
let cursorBefore = CGEvent(source: nil)?.location ?? .zero
let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
var isKeyBefore: CFTypeRef?
AXUIElementCopyAttributeValue(targetWindow, "AXMain" as CFString, &isKeyBefore)

print("\n--- Pre-Modification State ---")
print("Cursor: (\(cursorBefore.x), \(cursorBefore.y))")
print("Frontmost App: \(frontmostBefore)")
print("Downloads Window AXMain: \(describe(isKeyBefore))")

// Attempt 1: Setting AXValue on ScrollBar
print("\n--- Attempting AXValue modification on AXScrollBar ---")
let testValues: [Double] = [0.25, 0.5, 50.0]
for testVal in testValues {
    let t0 = CFAbsoluteTimeGetCurrent()
    let setErr = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, testVal as CFTypeRef)
    let t1 = CFAbsoluteTimeGetCurrent()
    let latencyMs = (t1 - t0) * 1000.0
    
    var readBack: CFTypeRef?
    let readErr = AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &readBack)
    
    print("  Set to \(testVal): error=\(setErr.rawValue) latency=\(String(format: "%.3f", latencyMs))ms | Readback: \(describe(readBack)) (error=\(readErr.rawValue))")
    
    if setErr == .success && describe(readBack) == "\(testVal)" {
        print("  --> AXValue accepted and updated successfully!")
        break
    }
}

let cursorAfterVal = CGEvent(source: nil)?.location ?? .zero
let frontmostAfterVal = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
var isKeyAfterVal: CFTypeRef?
AXUIElementCopyAttributeValue(targetWindow, "AXMain" as CFString, &isKeyAfterVal)

print("\n--- State after AXValue write ---")
print("Cursor: (\(cursorAfterVal.x), \(cursorAfterVal.y)) [Delta: \(hypot(cursorAfterVal.x - cursorBefore.x, cursorAfterVal.y - cursorBefore.y))]")
print("Frontmost App: \(frontmostAfterVal)")
print("Downloads Window AXMain: \(describe(isKeyAfterVal))")

// Attempt 2: Testing Actions on ScrollArea
print("\n--- Attempting Actions on AXScrollArea ---")
var saActsRef: CFArray?
AXUIElementCopyActionNames(sa, &saActsRef)
let saActions = (saActsRef as? [String]) ?? []
print("ScrollArea Actions: \(saActions.joined(separator: ", "))")

if saActions.contains("AXScrollDownByPage") {
    let t0 = CFAbsoluteTimeGetCurrent()
    let actErr = AXUIElementPerformAction(sa, "AXScrollDownByPage" as CFString)
    let t1 = CFAbsoluteTimeGetCurrent()
    let latencyMs = (t1 - t0) * 1000.0
    
    var valAfterAction: CFTypeRef?
    AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &valAfterAction)
    
    print("  AXScrollDownByPage: error=\(actErr.rawValue) latency=\(String(format: "%.3f", latencyMs))ms")
    print("  ScrollBar Value after action: \(describe(valAfterAction))")
}

let cursorAfterAct = CGEvent(source: nil)?.location ?? .zero
let frontmostAfterAct = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
var isKeyAfterAct: CFTypeRef?
AXUIElementCopyAttributeValue(targetWindow, "AXMain" as CFString, &isKeyAfterAct)

print("\n--- State after Action ---")
print("Cursor: (\(cursorAfterAct.x), \(cursorAfterAct.y)) [Delta: \(hypot(cursorAfterAct.x - cursorBefore.x, cursorAfterAct.y - cursorBefore.y))]")
print("Frontmost App: \(frontmostAfterAct)")
print("Downloads Window AXMain: \(describe(isKeyAfterAct))")
