import Cocoa
import ApplicationServices

func benchmarkApp(bundleID: String, name: String) {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard let app = apps.first else {
        print("[\(name)] Not running.")
        return
    }
    let appElem = AXUIElementCreateApplication(app.processIdentifier)
    var windowsRef: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef)
    guard let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
        print("[\(name)] No windows.")
        return
    }
    
    var targetWindow = windows.first!
    for w in windows {
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef)
        var pos = CGPoint.zero
        if let p = posRef, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if pos.x >= 1790.0 { targetWindow = w; break }
    }
    
    var scrollBar: AXUIElement?
    func findScrollBar(elem: AXUIElement, depth: Int = 0) {
        if depth > 7 { return }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXScrollBar" {
            scrollBar = elem
            return
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for c in children {
                findScrollBar(elem: c, depth: depth + 1)
                if scrollBar != nil { return }
            }
        }
    }
    findScrollBar(elem: targetWindow)
    
    guard let sb = scrollBar else {
        print("[\(name)] ScrollBar NOT found.")
        return
    }
    
    var isSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(sb, kAXValueAttribute as CFString, &isSettable)
    guard isSettable.boolValue else {
        print("[\(name)] ScrollBar AXValue NOT settable.")
        return
    }
    
    // Read initial value
    var initValRef: CFTypeRef?
    AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &initValRef)
    let initVal = (initValRef as? NSNumber)?.doubleValue ?? 0.0
    
    let frames = 60
    let targetIntervalSec = 1.0 / 60.0
    var latencies: [Double] = []
    var errors: [Int32] = []
    
    let cursorBefore = CGEvent(source: nil)?.location ?? .zero
    let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let suiteStart = CFAbsoluteTimeGetCurrent()
    
    for i in 1...frames {
        let tFrameStart = CFAbsoluteTimeGetCurrent()
        let val = initVal + (Double(i) / Double(frames)) * 0.3
        
        let tWrite0 = CFAbsoluteTimeGetCurrent()
        let err = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, val as CFTypeRef)
        let tWrite1 = CFAbsoluteTimeGetCurrent()
        
        latencies.append((tWrite1 - tWrite0) * 1000.0)
        errors.append(err.rawValue)
        
        let elapsed = CFAbsoluteTimeGetCurrent() - tFrameStart
        let sleepTime = targetIntervalSec - elapsed
        if sleepTime > 0 { usleep(useconds_t(sleepTime * 1_000_000.0)) }
    }
    
    let suiteDuration = CFAbsoluteTimeGetCurrent() - suiteStart
    let cursorAfter = CGEvent(source: nil)?.location ?? .zero
    let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    
    // Restore
    _ = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, initVal as CFTypeRef)
    
    let avgLat = latencies.reduce(0, +) / Double(latencies.count)
    let maxLat = latencies.max() ?? 0
    let minLat = latencies.min() ?? 0
    let successCount = errors.filter { $0 == 0 }.count
    let fps = Double(frames) / suiteDuration
    let cursorDelta = hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y)
    
    print("[\(name)]")
    print("  Stream: \(frames) frames in \(String(format: "%.3f", suiteDuration))s (\(String(format: "%.1f", fps)) fps)")
    print("  Success: \(successCount)/\(frames), Errors: \(frames - successCount)")
    print("  Latency: avg=\(String(format: "%.3f", avgLat))ms, min=\(String(format: "%.3f", minLat))ms, max=\(String(format: "%.3f", maxLat))ms")
    print("  Cursor Delta: \(String(format: "%.3f", cursorDelta)) pt | Frontmost Changed: \(frontmostBefore != frontmostAfter)")
}

print("================================================================================")
print("       CONTINUOUS AX SCROLL STREAM BENCHMARK ACROSS APPLICATIONS                ")
print("================================================================================")
benchmarkApp(bundleID: "com.apple.finder", name: "Finder")
benchmarkApp(bundleID: "com.apple.TextEdit", name: "TextEdit (AppKit)")
benchmarkApp(bundleID: "com.apple.Safari", name: "Safari (WebKit)")
benchmarkApp(bundleID: "com.brave.Browser", name: "Brave Browser (Chromium)")
print("================================================================================\n")
