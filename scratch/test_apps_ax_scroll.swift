import Cocoa
import ApplicationServices

func desc(_ obj: CFTypeRef?) -> String {
    if let o = obj { return "\(o)" }
    return "nil"
}

struct AppScrollReport {
    let name: String
    let bundleID: String
    var windowTitle: String = ""
    var windowBounds: CGRect = .zero
    var foundScrollArea: Bool = false
    var scrollAreaRole: String = ""
    var scrollAreaActions: [String] = []
    var foundVSB: Bool = false
    var vsbValue: String = ""
    var vsbMin: String = ""
    var vsbMax: String = ""
    var vsbInc: String = ""
    var vsbSettable: Bool = false
    var vsbActions: [String] = []
    var writeSuccess: Bool = false
    var writeLatencyMs: Double = 0.0
    var writeError: Int32 = 0
    var readbackValue: String = ""
    var visualShiftObserved: Bool = false
    var visualShiftDelta: Double = 0.0
    var cursorDelta: Double = 0.0
    var frontmostChanged: Bool = false
    var keyWindowChanged: Bool = false
    var notes: String = ""
}

func testApp(bundleID: String, name: String) -> AppScrollReport {
    var report = AppScrollReport(name: name, bundleID: bundleID)
    
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard let app = apps.first else {
        report.notes = "Application not running"
        return report
    }
    
    let appElem = AXUIElementCreateApplication(app.processIdentifier)
    var windowsRef: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
    guard let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
        report.notes = "No AX windows found"
        return report
    }
    
    // Pick the primary document window or the one on external display if possible
    var targetWindow = windows.first!
    for w in windows {
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef)
        var pos = CGPoint.zero
        if let p = posRef, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        // If on external display (x >= 1792)
        if pos.x >= 1790.0 {
            targetWindow = w
            break
        }
    }
    
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(targetWindow, kAXTitleAttribute as CFString, &titleRef)
    report.windowTitle = (titleRef as? String) ?? ""
    
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(targetWindow, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(targetWindow, kAXSizeAttribute as CFString, &sizeRef)
    var winPos = CGPoint.zero
    var winSize = CGSize.zero
    if let p = posRef, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &winPos) }
    if let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() { AXValueGetValue(s as! AXValue, .cgSize, &winSize) }
    report.windowBounds = CGRect(origin: winPos, size: winSize)
    
    // Find scroll area and scroll bar
    var scrollArea: AXUIElement? = nil
    var scrollBar: AXUIElement? = nil
    var contentChild: AXUIElement? = nil
    
    func traverse(elem: AXUIElement, depth: Int = 0) {
        if depth > 7 { return }
        var rRef: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &rRef)
        let role = (rRef as? String) ?? ""
        
        if role == "AXScrollArea" && scrollArea == nil {
            scrollArea = elem
            var vsb: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, "AXVerticalScrollBar" as CFString, &vsb) == .success, let b = vsb {
                scrollBar = (b as! AXUIElement)
            }
            var hsb: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(elem, "AXHorizontalScrollBar" as CFString, &hsb)
            
            // Look for first scrollable content child inside AXScrollArea
            var cRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &cRef) == .success,
               let children = cRef as? [AXUIElement] {
                for c in children {
                    var crRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &crRef)
                    let cr = (crRef as? String) ?? ""
                    if cr != "AXScrollBar" && contentChild == nil {
                        contentChild = c
                    }
                }
            }
        } else if role == "AXScrollBar" && scrollBar == nil {
            scrollBar = elem
        }
        
        var cRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &cRef) == .success,
           let children = cRef as? [AXUIElement] {
            for c in children { traverse(elem: c, depth: depth + 1) }
        }
    }
    
    traverse(elem: targetWindow)
    
    if let sa = scrollArea {
        report.foundScrollArea = true
        var rRef: CFTypeRef?
        AXUIElementCopyAttributeValue(sa, kAXRoleAttribute as CFString, &rRef)
        report.scrollAreaRole = (rRef as? String) ?? "AXScrollArea"
        
        var actsRef: CFArray?
        AXUIElementCopyActionNames(sa, &actsRef)
        report.scrollAreaActions = (actsRef as? [String]) ?? []
    }
    
    guard let sb = scrollBar else {
        report.notes = "ScrollArea found: \(report.foundScrollArea), but NO AXVerticalScrollBar present."
        return report
    }
    
    report.foundVSB = true
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
    
    var actsRef: CFArray?
    AXUIElementCopyActionNames(sb, &actsRef)
    report.vsbActions = (actsRef as? [String]) ?? []
    
    report.vsbValue = desc(valRef)
    report.vsbMin = desc(minRef)
    report.vsbMax = desc(maxRef)
    report.vsbInc = desc(incRef)
    report.vsbSettable = isSettable.boolValue
    
    if !report.vsbSettable {
        report.notes = "AXVerticalScrollBar exists but AXValue is NOT settable."
        return report
    }
    
    // Test write
    let cursorBefore = CGEvent(source: nil)?.location ?? .zero
    let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    var isMainBefore: CFTypeRef?
    AXUIElementCopyAttributeValue(targetWindow, "AXMain" as CFString, &isMainBefore)
    
    // Initial content pos
    var posBefore = CGPoint.zero
    if let cc = contentChild {
        var pRef: CFTypeRef?
        AXUIElementCopyAttributeValue(cc, kAXPositionAttribute as CFString, &pRef)
        if let p = pRef, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &posBefore) }
    }
    
    // Write test value: if current is 0, write 0.3, else write 0.0
    let curVal = Double(report.vsbValue) ?? 0.0
    let targetVal: Double = (curVal < 0.1) ? 0.3 : 0.0
    
    let t0 = CFAbsoluteTimeGetCurrent()
    let setErr = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, targetVal as CFTypeRef)
    let t1 = CFAbsoluteTimeGetCurrent()
    report.writeLatencyMs = (t1 - t0) * 1000.0
    report.writeError = setErr.rawValue
    
    usleep(50000) // 50ms wait for UI update
    
    var readBack: CFTypeRef?
    AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &readBack)
    report.readbackValue = desc(readBack)
    report.writeSuccess = (setErr == .success)
    
    var posAfter = CGPoint.zero
    if let cc = contentChild {
        var pRef: CFTypeRef?
        AXUIElementCopyAttributeValue(cc, kAXPositionAttribute as CFString, &pRef)
        if let p = pRef, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &posAfter) }
        report.visualShiftDelta = posAfter.y - posBefore.y
        report.visualShiftObserved = abs(report.visualShiftDelta) > 0.5
    }
    
    let cursorAfter = CGEvent(source: nil)?.location ?? .zero
    report.cursorDelta = hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y)
    
    let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    report.frontmostChanged = (frontmostBefore != frontmostAfter)
    
    var isMainAfter: CFTypeRef?
    AXUIElementCopyAttributeValue(targetWindow, "AXMain" as CFString, &isMainAfter)
    report.keyWindowChanged = (desc(isMainBefore) != desc(isMainAfter))
    
    // Restore original value
    _ = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, curVal as CFTypeRef)
    
    return report
}

let appsToTest = [
    ("com.apple.TextEdit", "TextEdit (Native AppKit)"),
    ("com.apple.Safari", "Safari (WebKit)"),
    ("com.brave.Browser", "Brave Browser (Chromium)")
]

print("================================================================================")
print("             AX SEMANTIC SCROLL FEASIBILITY MATRIX ACROSS APPS                  ")
print("================================================================================")

for (bundleID, name) in appsToTest {
    let rep = testApp(bundleID: bundleID, name: name)
    print("\n--------------------------------------------------------------------------------")
    print("Application: \(rep.name) [\(rep.bundleID)]")
    print("Window: \"\(rep.windowTitle)\" | Bounds: \(rep.windowBounds)")
    print("ScrollArea: \(rep.foundScrollArea ? "FOUND" : "NOT FOUND") [Role: \(rep.scrollAreaRole)]")
    if !rep.scrollAreaActions.isEmpty {
        print("  Actions: \(rep.scrollAreaActions.joined(separator: ", "))")
    }
    print("Vertical ScrollBar: \(rep.foundVSB ? "FOUND" : "NOT FOUND")")
    if rep.foundVSB {
        print("  Value: \(rep.vsbValue), Min: \(rep.vsbMin), Max: \(rep.vsbMax), Inc: \(rep.vsbInc)")
        print("  Settable: \(rep.vsbSettable)")
        if !rep.vsbActions.isEmpty {
            print("  Actions: \(rep.vsbActions.joined(separator: ", "))")
        }
        print("  Write Latency: \(String(format: "%.3f", rep.writeLatencyMs)) ms (error=\(rep.writeError))")
        print("  Readback Value: \(rep.readbackValue)")
        print("  Visual/Structural Shift Observed: \(rep.visualShiftObserved) (deltaY = \(String(format: "%.1f", rep.visualShiftDelta)) pt)")
        print("  Cursor Delta: \(String(format: "%.2f", rep.cursorDelta)) pt")
        print("  Frontmost Changed: \(rep.frontmostChanged) | Key Window Changed: \(rep.keyWindowChanged)")
    }
    if !rep.notes.isEmpty {
        print("Notes: \(rep.notes)")
    }
}
print("\n================================================================================\n")
