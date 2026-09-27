import Foundation
import Cocoa
import ApplicationServices

public enum SemanticResultClassification: String, Codable {
    case semanticPressSuccess = "SEMANTIC_PRESS_SUCCESS"
    case noActionableElement  = "NO_ACTIONABLE_ELEMENT"
    case axPressUnsupported   = "AX_PRESS_UNSUPPORTED"
    case axPermissionRequired = "AX_PERMISSION_REQUIRED"
    case axHitTestFailed      = "AX_HIT_TEST_FAILED"
    case axActionFailed       = "AX_ACTION_FAILED"
}

public struct AXElementSnapshot: Codable {
    public let pid: Int32
    public let applicationName: String
    public let role: String
    public let subrole: String?
    public let title: String?
    public let descriptionText: String?
    public let value: String?
    public let isEnabled: Bool?
    public let isFocused: Bool?
    public let supportedActions: [String]
    public let elementFrame: [Double]?
    public let window: AXWindowSnapshot?
}

public struct AXWindowSnapshot: Codable {
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let position: [Double]?
    public let size: [Double]?
    public let isMain: Bool?
    public let isFocused: Bool?
}

public struct SemanticEvidenceRecord: Codable {
    public let id: String
    public let timestamp: Date
    public let testCase: String // e.g. "Test A: AppKit", "Test B: Native External App", "Test C: Browser"
    public let physicalTap: PhysicalTapRecord
    public let axHitTest: AXElementSnapshot?
    public let semanticAction: SemanticActionRecord
    public let cursor: CursorRecord
    public let classification: SemanticResultClassification
    public let visibleResult: String
    
    public struct PhysicalTapRecord: Codable {
        public let rawX: Int
        public let rawY: Int
        public let globalCGX: Double
        public let globalCGY: Double
        public let durationSec: Double
        public let movementPt: Double
    }
    
    public struct SemanticActionRecord: Codable {
        public let requestedAction: String
        public let axErrorCode: Int32
        public let axErrorName: String
        public let executed: Bool
    }
    
    public struct CursorRecord: Codable {
        public let beforeX: Double
        public let beforeY: Double
        public let afterX: Double
        public let afterY: Double
        public let deltaPt: Double
        public let invariantSatisfied: Bool
    }
    
    public func formattedOutput() -> String {
        let appStr = axHitTest?.applicationName ?? "None"
        let pidStr = (axHitTest != nil) ? "\(axHitTest!.pid)" : "N/A"
        let roleStr = axHitTest?.role ?? "N/A"
        let subroleStr = axHitTest?.subrole ?? "nil"
        let titleValStr = axHitTest?.title ?? (axHitTest?.value ?? "nil")
        let actionsStr = (axHitTest != nil) ? "\(axHitTest!.supportedActions)" : "[]"
        
        return """
        ================================================================================
        EVIDENCE RECORD [\(id)] — \(testCase)
        ================================================================================
        Physical Tap
          raw HID: (\(physicalTap.rawX), \(physicalTap.rawY))
          calibrated global CG: (\(String(format: "%.1f, %.1f", physicalTap.globalCGX, physicalTap.globalCGY)))
          duration: \(String(format: "%.3f", physicalTap.durationSec)) s
          movement: \(String(format: "%.1f", physicalTap.movementPt)) pt

        AX Hit Test
          application: \(appStr)
          pid: \(pidStr)
          role: \(roleStr)
          subrole: \(subroleStr)
          title/value: \(titleValStr)
          supported actions: \(actionsStr)

        Semantic Action
          requested: \(semanticAction.requestedAction)
          AXError: \(semanticAction.axErrorName)
          classification: \(classification.rawValue)
          visible result: \(visibleResult)

        Cursor
          before: (\(String(format: "%.1f, %.1f", cursor.beforeX, cursor.beforeY)))
          after: (\(String(format: "%.1f, %.1f", cursor.afterX, cursor.afterY)))
          delta: \(String(format: "%.2f", cursor.deltaPt)) pt (Invariant Inviolate: \(cursor.invariantSatisfied ? "YES [PASS]" : "NO [FAIL]"))
        ================================================================================
        """
    }
}

public final class AXSemanticEngine {
    public static let shared = AXSemanticEngine()
    
    private let systemWideElement: AXUIElement
    private var recordedEvidence: [SemanticEvidenceRecord] = []
    
    public init() {
        self.systemWideElement = AXUIElementCreateSystemWide()
        let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("semantic_verification_records.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let existing = try? decoder.decode([SemanticEvidenceRecord].self, from: data) {
                self.recordedEvidence = existing
            }
        }
    }
    
    public func getAllEvidence() -> [SemanticEvidenceRecord] {
        return recordedEvidence
    }
    
    public func clearEvidence() {
        recordedEvidence.removeAll()
    }
    
    public func saveEvidenceToFile(at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recordedEvidence)
        try data.write(to: url)
    }
    
    /// Phase 2: Probe-only hit test at CoreGraphics Global coordinates.
    /// Does NOT perform any action.
    public func probeElementAt(globalCG: CGPoint, includeWindow: Bool = false) -> (element: AXUIElement?, snapshot: AXElementSnapshot?, error: AXError) {
        guard AXPermissionManager.shared.isTrusted() else {
            return (nil, nil, .apiDisabled)
        }
        
        var hitElem: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(globalCG.x),
            Float(globalCG.y),
            &hitElem
        )
        
        guard err == .success, let elem = hitElem else {
            return (nil, nil, err)
        }
        
        let snapshot = inspectElement(elem, includeWindow: includeWindow)
        return (elem, snapshot, err)
    }
    
    /// Phase 4: Full semantic tap execution on a physical tap event.
    /// Strictly verifies supported actions, calls AXPress ONLY if explicitly supported,
    /// measures cursor invariant before/after, and returns structured evidence.
    public func performSemanticTap(
        tap: PhysicalTapEvent,
        preResolvedElement: AXUIElement? = nil,
        preResolvedSnapshot: AXElementSnapshot? = nil,
        testCase: String = "Interactive Tap",
        expectedVisibleResult: String? = nil
    ) -> SemanticEvidenceRecord {
        let recordID = "EVD-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
        
        // 1. Permission check
        guard AXPermissionManager.shared.isTrusted() else {
            let record = makeRecord(
                id: recordID,
                testCase: testCase,
                tap: tap,
                snapshot: nil,
                actionName: "AXPress",
                axErr: .apiDisabled,
                executed: false,
                classification: .axPermissionRequired,
                visibleResult: "Accessibility permission unavailable (AXIsProcessTrusted == false)",
                cursorBefore: NSEvent.mouseLocation,
                cursorAfter: NSEvent.mouseLocation
            )
            recordEvidence(record)
            return record
        }
        
        // 2. Resolve AX Element (either pre-resolved from session touch-down or probed fresh)
        let elem: AXUIElement
        let snapshot: AXElementSnapshot
        if let preElem = preResolvedElement, let preSnap = preResolvedSnapshot {
            elem = preElem
            snapshot = preSnap
        } else {
            let (elemOpt, snapshotOpt, hitErr) = probeElementAt(globalCG: tap.calibratedGlobalCG)
            guard hitErr == .success, let e = elemOpt, let s = snapshotOpt else {
                let cursorLoc = NSEvent.mouseLocation
                let record = makeRecord(
                    id: recordID,
                    testCase: testCase,
                    tap: tap,
                    snapshot: snapshotOpt,
                    actionName: "AXPress",
                    axErr: hitErr,
                    executed: false,
                    classification: (hitErr == .noValue || hitErr == .cannotComplete) ? .noActionableElement : .axHitTestFailed,
                    visibleResult: "AX hit test returned error: \(axErrorDescription(hitErr))",
                    cursorBefore: cursorLoc,
                    cursorAfter: cursorLoc
                )
                recordEvidence(record)
                return record
            }
            elem = e
            snapshot = s
        }
        
        // 3. Inspect supported actions for kAXPressAction ("AXPress")
        let supportsPress = snapshot.supportedActions.contains(kAXPressAction as String)
        
        if !supportsPress {
            // Absolute prohibition: Do NOT synthesize mouse events if AXPress is absent.
            let cursorLoc = NSEvent.mouseLocation
            let record = makeRecord(
                id: recordID,
                testCase: testCase,
                tap: tap,
                snapshot: snapshot,
                actionName: "AXPress",
                axErr: .actionUnsupported,
                executed: false,
                classification: .axPressUnsupported,
                visibleResult: "Element does not support kAXPressAction (supported: \(snapshot.supportedActions)). Fallback click prohibited.",
                cursorBefore: cursorLoc,
                cursorAfter: cursorLoc
            )
            recordEvidence(record)
            return record
        }
        
        // 4. Invariant: Record cursor before action
        let cursorBefore = NSEvent.mouseLocation
        
        // 5. Perform semantic press action
        let actionErr = AXUIElementPerformAction(elem, kAXPressAction as CFString)
        
        // 6. Invariant: Record cursor immediately after action
        let cursorAfter = NSEvent.mouseLocation
        
        let classification: SemanticResultClassification
        let visibleResultDesc: String
        
        if actionErr == .success {
            classification = .semanticPressSuccess
            visibleResultDesc = expectedVisibleResult ?? "kAXPressAction dispatched successfully to \(snapshot.role) [\(snapshot.title ?? "")]"
        } else {
            classification = .axActionFailed
            visibleResultDesc = "AXUIElementPerformAction failed with error: \(axErrorDescription(actionErr))"
        }
        
        let record = makeRecord(
            id: recordID,
            testCase: testCase,
            tap: tap,
            snapshot: snapshot,
            actionName: "AXPress",
            axErr: actionErr,
            executed: true,
            classification: classification,
            visibleResult: visibleResultDesc,
            cursorBefore: cursorBefore,
            cursorAfter: cursorAfter
        )
        recordEvidence(record)
        return record
    }
    
    private func recordEvidence(_ record: SemanticEvidenceRecord) {
        recordedEvidence.append(record)
        print(record.formattedOutput())
        fflush(stdout)
    }
    
    private func makeRecord(
        id: String,
        testCase: String,
        tap: PhysicalTapEvent,
        snapshot: AXElementSnapshot?,
        actionName: String,
        axErr: AXError,
        executed: Bool,
        classification: SemanticResultClassification,
        visibleResult: String,
        cursorBefore: NSPoint,
        cursorAfter: NSPoint
    ) -> SemanticEvidenceRecord {
        let dx = cursorAfter.x - cursorBefore.x
        let dy = cursorAfter.y - cursorBefore.y
        let delta = sqrt(Double(dx * dx + dy * dy))
        let invariantPassed = (delta < 0.001)
        
        return SemanticEvidenceRecord(
            id: id,
            timestamp: Date(),
            testCase: testCase,
            physicalTap: SemanticEvidenceRecord.PhysicalTapRecord(
                rawX: tap.rawDownPoint.x,
                rawY: tap.rawDownPoint.y,
                globalCGX: tap.calibratedGlobalCG.x,
                globalCGY: tap.calibratedGlobalCG.y,
                durationSec: tap.durationSec,
                movementPt: tap.movementPt
            ),
            axHitTest: snapshot,
            semanticAction: SemanticEvidenceRecord.SemanticActionRecord(
                requestedAction: actionName,
                axErrorCode: axErr.rawValue,
                axErrorName: axErrorDescription(axErr),
                executed: executed
            ),
            cursor: SemanticEvidenceRecord.CursorRecord(
                beforeX: cursorBefore.x,
                beforeY: cursorBefore.y,
                afterX: cursorAfter.x,
                afterY: cursorAfter.y,
                deltaPt: delta,
                invariantSatisfied: invariantPassed
            ),
            classification: classification,
            visibleResult: visibleResult
        )
    }
    
    public func inspectElement(_ element: AXUIElement, includeWindow: Bool = false) -> AXElementSnapshot {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
        
        let role = getAttributeString(element, kAXRoleAttribute) ?? "UnknownRole"
        let subrole = getAttributeString(element, kAXSubroleAttribute)
        let title = getAttributeString(element, kAXTitleAttribute)
        let desc = getAttributeString(element, kAXDescriptionAttribute)
        let value = getAttributeString(element, kAXValueAttribute)
        
        var isEnabled: Bool? = nil
        var enabledRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let b = enabledRef as? Bool {
            isEnabled = b
        }
        
        var isFocused: Bool? = nil
        var focusedRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedRef) == .success,
           let b = focusedRef as? Bool {
            isFocused = b
        }
        
        var actions: [String] = []
        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let arr = actionsRef as? [AnyObject] {
            actions = arr.map { String(describing: $0) }
        }
        
        // Element Frame if available
        var frameArray: [Double]? = nil
        var posRef: AnyObject?, sizeRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let pv = posRef, let sv = sizeRef {
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
            frameArray = [p.x, p.y, s.width, s.height]
        }
        
        let window: AXWindowSnapshot?
        if includeWindow,
           let rawWindow = copyElementAttribute(element, kAXWindowAttribute as CFString),
           CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
            window = inspectWindow(rawWindow as! AXUIElement)
        } else {
            window = nil
        }

        return AXElementSnapshot(
            pid: pid,
            applicationName: appName,
            role: role,
            subrole: subrole,
            title: title,
            descriptionText: desc,
            value: value,
            isEnabled: isEnabled,
            isFocused: isFocused,
            supportedActions: actions,
            elementFrame: frameArray,
            window: window
        )
    }

    private func inspectWindow(_ element: AXUIElement) -> AXWindowSnapshot {
        func pointAttribute(_ name: String) -> [Double]? {
            guard let raw = copyElementAttribute(element, name as CFString),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let value = raw as! AXValue
            var point = CGPoint.zero
            guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
            return [point.x, point.y]
        }
        func sizeAttribute(_ name: String) -> [Double]? {
            guard let raw = copyElementAttribute(element, name as CFString),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let value = raw as! AXValue
            var size = CGSize.zero
            guard AXValueGetValue(value, .cgSize, &size) else { return nil }
            return [size.width, size.height]
        }
        func boolAttribute(_ name: String) -> Bool? {
            copyElementAttribute(element, name as CFString) as? Bool
        }
        return AXWindowSnapshot(
            role: getAttributeString(element, kAXRoleAttribute),
            subrole: getAttributeString(element, kAXSubroleAttribute),
            title: getAttributeString(element, kAXTitleAttribute),
            position: pointAttribute(kAXPositionAttribute),
            size: sizeAttribute(kAXSizeAttribute),
            isMain: boolAttribute(kAXMainAttribute),
            isFocused: boolAttribute(kAXFocusedAttribute)
        )
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }
    
    private func getAttributeString(_ element: AXUIElement, _ attribute: String) -> String? {
        var val: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &val)
        if err == .success, let v = val {
            let str = String(describing: v)
            return str.isEmpty ? nil : str
        }
        return nil
    }
    
    public func axErrorDescription(_ err: AXError) -> String {
        switch err {
        case .success: return "kAXErrorSuccess (0)"
        case .failure: return "kAXErrorFailure (-25200)"
        case .illegalArgument: return "kAXErrorIllegalArgument (-25201)"
        case .invalidUIElement: return "kAXErrorInvalidUIElement (-25202)"
        case .cannotComplete: return "kAXErrorCannotComplete (-25204)"
        case .notImplemented: return "kAXErrorNotImplemented (-25205)"
        case .actionUnsupported: return "kAXErrorActionUnsupported (-25206)"
        case .attributeUnsupported: return "kAXErrorAttributeUnsupported (-25203)"
        case .noValue: return "kAXErrorNoValue (-25212)"
        case .apiDisabled: return "kAXErrorAPIDisabled (-25211)"
        default: return "AXError(\(err.rawValue))"
        }
    }
}
