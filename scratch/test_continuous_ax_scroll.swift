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

var scrollBar: AXUIElement?
func findScrollBar(elem: AXUIElement) {
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
            findScrollBar(elem: c)
            if scrollBar != nil { return }
        }
    }
}
findScrollBar(elem: targetWindow)

guard let sb = scrollBar else {
    print("ScrollBar not found")
    exit(1)
}

print("================================================================================")
print("     CONTINUOUS AX SCROLL STREAM BENCHMARK — FINDER (DOWNLOADS WINDOW)         ")
print("================================================================================")

// We will stream 60 updates simulating a 1-second continuous swipe from 0.0 to 0.8
let frames = 60
let targetIntervalSec = 1.0 / 60.0 // ~16.6ms per frame (60Hz)

var latencies: [Double] = []
var errors: [Int32] = []
var readbacks: [Double] = []

let cursorBefore = CGEvent(source: nil)?.location ?? .zero
let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

let suiteStart = CFAbsoluteTimeGetCurrent()

for i in 1...frames {
    let tFrameStart = CFAbsoluteTimeGetCurrent()
    let value = Double(i) / Double(frames) * 0.8 // smooth ramp from 0.0 to 0.8
    
    let tWrite0 = CFAbsoluteTimeGetCurrent()
    let err = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, value as CFTypeRef)
    let tWrite1 = CFAbsoluteTimeGetCurrent()
    
    let latencyMs = (tWrite1 - tWrite0) * 1000.0
    latencies.append(latencyMs)
    errors.append(err.rawValue)
    
    // Readback every 10 frames
    if i % 10 == 0 {
        var rb: CFTypeRef?
        AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &rb)
        if let num = rb as? NSNumber {
            readbacks.append(num.doubleValue)
        }
    }
    
    let elapsed = CFAbsoluteTimeGetCurrent() - tFrameStart
    let sleepTime = targetIntervalSec - elapsed
    if sleepTime > 0 {
        usleep(useconds_t(sleepTime * 1_000_000.0))
    }
}

let suiteTotalDuration = CFAbsoluteTimeGetCurrent() - suiteStart
let cursorAfter = CGEvent(source: nil)?.location ?? .zero
let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

// Reset to 0.0
_ = AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 0.0 as CFTypeRef)

let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
let maxLatency = latencies.max() ?? 0
let minLatency = latencies.min() ?? 0
let successCount = errors.filter { $0 == 0 }.count
let failCount = errors.filter { $0 != 0 }.count
let effectiveFPS = Double(frames) / suiteTotalDuration

print("Test Summary:")
print("  Total Frames Streamed: \(frames)")
print("  Total Duration:        \(String(format: "%.3f", suiteTotalDuration)) s")
print("  Effective Stream Rate: \(String(format: "%.1f", effectiveFPS)) updates/sec")
print("  Success Rate:          \(successCount)/\(frames) (\(failCount) errors)")
print("  Write Latency (ms):    avg=\(String(format: "%.3f", avgLatency)) | min=\(String(format: "%.3f", minLatency)) | max=\(String(format: "%.3f", maxLatency))")
print("  Cursor Delta:          \(String(format: "%.3f", hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y))) pt")
print("  Frontmost Changed:     \(frontmostBefore != frontmostAfter)")
print("  Readback Samples:      \(readbacks.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
print("================================================================================\n")
