import Foundation
import Cocoa
import ApplicationServices

public struct ScrollEvidenceRecord: Codable {
    public let id: String
    public let timestamp: Date
    public let targetApplication: String
    public let mechanism: String // DIRECT_VALUE, INCREMENTAL_ACTION, SEMANTIC_OTHER, UNSUPPORTED
    public let initialScrollValue: Double?
    public let finalScrollValue: Double?
    public let touchDeltaY: Double
    public let cursorBefore: [Double]
    public let cursorAfter: [Double]
    public let cursorDelta: Double
    public let success: Bool
    public let resultSummary: String
}

public final class SemanticScrollController {
    public static let shared = SemanticScrollController()
    
    private var activeSession: ActiveScrollSession? = nil
    private var recordedScrolls: [ScrollEvidenceRecord] = []
    
    private struct ActiveScrollSession {
        let startGlobalCG: CGPoint
        let targetApp: String
        let mechanism: String
        let scrollBarElem: AXUIElement?
        let scrollAreaElem: AXUIElement?
        let initialValue: Double
        let minValue: Double
        let maxValue: Double
        let visibleHeight: Double
        let actions: [String]
        var currentValue: Double
        var totalDeltaY: Double = 0.0
        var actionsDispatched: Int = 0
        var lastActionThresholdY: Double = 0.0
        let cursorStart: CGPoint
    }
    
    private init() {}
    
    public func getScrollRecords() -> [ScrollEvidenceRecord] {
        return recordedScrolls
    }
    
    public func handleTouchDown(globalCG: CGPoint) -> Bool {
        guard AXPermissionManager.shared.isTrusted() else { return false }
        
        let (elemOpt, _, err) = AXSemanticEngine.shared.probeElementAt(globalCG: globalCG)
        guard err == .success, let elem = elemOpt else { return false }
        
        let inspection = AXCapabilityInspector.shared.inspect(element: elem)
        let cap = inspection.scrollCapability
        
        guard cap.mechanism != "UNSUPPORTED" else {
            return false
        }
        
        // Find scrollbar element or scroll area
        var targetScrollBar: AXUIElement? = nil
        var targetScrollArea: AXUIElement? = nil
        
        // Check element itself or parent chain for AXScrollArea
        var curr: AXUIElement? = elem
        for _ in 0..<4 {
            guard let c = curr else { break }
            let node = AXCapabilityInspector.shared.inspectNode(c)
            if node.role == "AXScrollArea" {
                targetScrollArea = c
                var vsbRef: AnyObject?
                if AXUIElementCopyAttributeValue(c, "AXVerticalScrollBar" as CFString, &vsbRef) == .success, let b = vsbRef {
                    targetScrollBar = (b as! AXUIElement)
                }
                break
            } else if node.role == "AXScrollBar" {
                targetScrollBar = c
                break
            }
            var pRef: AnyObject?
            if AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &pRef) == .success, let p = pRef {
                curr = (p as! AXUIElement)
            } else {
                break
            }
        }
        
        let cursorLoc = NSEvent.mouseLocation
        let startPos = CGPoint(x: cursorLoc.x, y: cursorLoc.y)
        let height = inspection.hitNode.size?[1] ?? 400.0
        
        activeSession = ActiveScrollSession(
            startGlobalCG: globalCG,
            targetApp: inspection.applicationName,
            mechanism: cap.mechanism,
            scrollBarElem: targetScrollBar,
            scrollAreaElem: targetScrollArea,
            initialValue: cap.verticalValue ?? 0.0,
            minValue: cap.verticalMin ?? 0.0,
            maxValue: cap.verticalMax ?? 1.0,
            visibleHeight: max(100.0, height),
            actions: cap.verticalActions.isEmpty ? cap.scrollAreaActions : cap.verticalActions,
            currentValue: cap.verticalValue ?? 0.0,
            totalDeltaY: 0.0,
            actionsDispatched: 0,
            lastActionThresholdY: 0.0,
            cursorStart: startPos
        )
        
        print("\n[SCROLL ENGAGED] App: \(inspection.applicationName) | Mechanism: \(cap.mechanism)")
        print("                 Initial Val: \(String(format: "%.3f", cap.verticalValue ?? 0.0)) | Range: [\(cap.verticalMin ?? 0.0) .. \(cap.verticalMax ?? 1.0)]")
        return true
    }
    
    public func handleTouchMove(globalCG: CGPoint) {
        guard var session = activeSession else { return }
        
        let dy = globalCG.y - session.startGlobalCG.y
        session.totalDeltaY = dy
        
        // Deadband: micro-movements (< 6 pt) do not trigger scrolling to keep taps clean
        if abs(dy) < 6.0 {
            self.activeSession = session
            return
        }
        
        if session.mechanism == "DIRECT_VALUE", let bar = session.scrollBarElem {
            let valueSpan = session.maxValue - session.minValue
            // Natural touch scroll: dragging finger UP (dy < 0) reveals content below (scrollbar value INCREASES)
            let proportionalDelta = -dy / session.visibleHeight * valueSpan
            let newVal = max(session.minValue, min(session.maxValue, session.initialValue + proportionalDelta))
            
            let cursorBefore = NSEvent.mouseLocation
            let err = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, newVal as CFTypeRef)
            let cursorAfter = NSEvent.mouseLocation
            
            if err == .success {
                session.currentValue = newVal
            }
            
            let cdx = cursorAfter.x - cursorBefore.x
            let cdy = cursorAfter.y - cursorBefore.y
            let cDelta = sqrt(Double(cdx * cdx + cdy * cdy))
            if cDelta > 0.001 {
                print("[WARNING] Cursor moved during scroll! Delta: \(cDelta) pt")
            }
        } else if session.mechanism == "INCREMENTAL_ACTION" {
            let stepThreshold = 30.0
            let stepDiff = dy - session.lastActionThresholdY
            
            if abs(stepDiff) >= stepThreshold {
                let targetAction = (stepDiff < 0) ? "AXIncrement" : "AXDecrement"
                let targetElem = session.scrollBarElem ?? session.scrollAreaElem
                if let target = targetElem {
                    let err = AXUIElementPerformAction(target, targetAction as CFString)
                    if err == .success {
                        session.actionsDispatched += 1
                        session.lastActionThresholdY = dy
                    }
                }
            }
        }
        
        self.activeSession = session
    }
    
    public func handleTouchUp(globalCG: CGPoint) -> ScrollEvidenceRecord? {
        guard let session = activeSession else { return nil }
        activeSession = nil
        
        let cursorEnd = NSEvent.mouseLocation
        let cdx = cursorEnd.x - session.cursorStart.x
        let cdy = cursorEnd.y - session.cursorStart.y
        let cDelta = sqrt(Double(cdx * cdx + cdy * cdy))
        
        let record = ScrollEvidenceRecord(
            id: "SCR-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))",
            timestamp: Date(),
            targetApplication: session.targetApp,
            mechanism: session.mechanism,
            initialScrollValue: session.initialValue,
            finalScrollValue: session.currentValue,
            touchDeltaY: session.totalDeltaY,
            cursorBefore: [session.cursorStart.x, session.cursorStart.y],
            cursorAfter: [cursorEnd.x, cursorEnd.y],
            cursorDelta: cDelta,
            success: (session.mechanism == "DIRECT_VALUE" && session.currentValue != session.initialValue) || (session.actionsDispatched > 0),
            resultSummary: "Mechanism: \(session.mechanism) | DeltaY: \(String(format: "%.1f", session.totalDeltaY)) pt | Scroll: \(String(format: "%.3f -> %.3f", session.initialValue, session.currentValue)) | CursorDelta: \(String(format: "%.2f", cDelta)) pt"
        )
        
        recordedScrolls.append(record)
        print("\n================================================================================")
        print("SCROLL INTERACTION EVIDENCE RECORD [\(record.id)]")
        print("  App: \(record.targetApplication)")
        print("  Mechanism: \(record.mechanism)")
        print("  Touch Delta Y: \(String(format: "%.1f", record.touchDeltaY)) pt")
        print("  Value Shift: \(String(format: "%.3f -> %.3f", record.initialScrollValue ?? 0, record.finalScrollValue ?? 0))")
        print("  Cursor Before/After: (\(String(format: "%.1f, %.1f", record.cursorBefore[0], record.cursorBefore[1]))) -> (\(String(format: "%.1f, %.1f", record.cursorAfter[0], record.cursorAfter[1])))")
        print("  Cursor Delta: \(String(format: "%.2f", record.cursorDelta)) pt (Invariant: \(cDelta < 0.001 ? "PASS" : "FAIL"))")
        print("================================================================================\n")
        
        return record
    }
}
