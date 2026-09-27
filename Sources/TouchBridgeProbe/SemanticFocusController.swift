import Foundation
import Cocoa
import ApplicationServices

public struct FocusEvidenceRecord: Codable {
    public let id: String
    public let timestamp: Date
    public let targetApplication: String
    public let elementRole: String
    public let elementTitle: String?
    public let wasFocusSettable: Bool
    public let focusAttributeMutationResult: Int32?
    public let pressActionDispatched: Bool
    public let isFocusedAfter: Bool
    public let appBefore: String
    public let appAfter: String
    public let cursorBefore: [Double]
    public let cursorAfter: [Double]
    public let cursorDelta: Double
    public let classification: String
}

public final class SemanticFocusController {
    public static let shared = SemanticFocusController()
    
    private var recordedFocusEvents: [FocusEvidenceRecord] = []
    
    private init() {}
    
    public func getFocusRecords() -> [FocusEvidenceRecord] {
        return recordedFocusEvents
    }
    
    public func attemptFocus(element: AXUIElement) -> FocusEvidenceRecord {
        let appBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let targetAppName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
        
        let node = AXCapabilityInspector.shared.inspectNode(element)
        let cursorBefore = NSEvent.mouseLocation
        
        var focusErrCode: Int32? = nil
        // 1. If targeting another application, activate it so physical keyboard input routes to it
        if let targetApp = NSRunningApplication(processIdentifier: pid) {
            targetApp.activate()
        }
        
        // 2. If AXFocused is explicitly settable, set it
        if node.isFocusSettable {
            let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
            focusErrCode = err.rawValue
        }
        
        // 3. Inspect focus state after the focus mutation. Press is a separate
        // tap backend and must not be dispatched as a side effect of focusing.
        var isFocusedAfter = false
        var focusedRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedRef) == .success,
           let b = focusedRef as? Bool {
            isFocusedAfter = b
        }
        
        let cursorAfter = NSEvent.mouseLocation
        let appAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        
        let dx = cursorAfter.x - cursorBefore.x
        let dy = cursorAfter.y - cursorBefore.y
        let delta = sqrt(Double(dx * dx + dy * dy))
        
        let classification: String
        if isFocusedAfter {
            classification = "SEMANTIC_SUCCESS"
        } else if !node.isFocusSettable {
            classification = "ATTRIBUTE_NOT_SETTABLE"
        } else {
            classification = "ACTION_FAILED"
        }
        
        let record = FocusEvidenceRecord(
            id: "FOC-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))",
            timestamp: Date(),
            targetApplication: targetAppName,
            elementRole: node.role,
            elementTitle: node.title,
            wasFocusSettable: node.isFocusSettable,
            focusAttributeMutationResult: focusErrCode,
            pressActionDispatched: false,
            isFocusedAfter: isFocusedAfter,
            appBefore: appBefore,
            appAfter: appAfter,
            cursorBefore: [cursorBefore.x, cursorBefore.y],
            cursorAfter: [cursorAfter.x, cursorAfter.y],
            cursorDelta: delta,
            classification: classification
        )
        
        recordedFocusEvents.append(record)
        print("\n================================================================================")
        print("TEXT FOCUS INTERACTION EVIDENCE RECORD [\(record.id)]")
        print("  App: \(record.targetApplication) (Before: \(record.appBefore) -> After: \(record.appAfter))")
        print("  Role: \(record.elementRole) [\(record.elementTitle ?? "")]")
        print("  Focus Settable: \(record.wasFocusSettable) | Press Dispatched: NO (focus is isolated from AXPress)")
        print("  Focused Result: \(record.isFocusedAfter ? "FOCUSED [YES]" : "UNFOCUSED [NO]")")
        print("  Focus Classification: \(record.classification) (setter result: \(record.focusAttributeMutationResult.map(String.init) ?? "not attempted"))")
        print("  Cursor Delta: \(String(format: "%.2f", record.cursorDelta)) pt (Invariant: \(delta < 0.001 ? "PASS" : "FAIL"))")
        print("================================================================================\n")
        
        return record
    }
}
