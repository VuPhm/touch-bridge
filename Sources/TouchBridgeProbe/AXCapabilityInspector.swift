import Foundation
import Cocoa
import ApplicationServices

public struct AXNodeCapability: Codable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let descriptionText: String?
    public let value: String?
    public let minValue: Double?
    public let maxValue: Double?
    public let valueIncrement: Double?
    public let isEnabled: Bool?
    public let isFocused: Bool?
    public let isSelected: Bool?
    public let position: [Double]?
    public let size: [Double]?
    public let parentRole: String?
    public let supportedActions: [String]
    public let attributeNames: [String]
    public let parameterizedAttributeNames: [String]
    public let settableAttributes: [String]
    
    public var isValueSettable: Bool { settableAttributes.contains(kAXValueAttribute as String) }
    public var isFocusSettable: Bool { settableAttributes.contains(kAXFocusedAttribute as String) }
    public var isSelectedSettable: Bool { settableAttributes.contains(kAXSelectedAttribute as String) }

    func replacingSupportedActions(_ actions: [String]) -> AXNodeCapability {
        AXNodeCapability(
            role: role, subrole: subrole, title: title, descriptionText: descriptionText,
            value: value, minValue: minValue, maxValue: maxValue, valueIncrement: valueIncrement,
            isEnabled: isEnabled, isFocused: isFocused, isSelected: isSelected,
            position: position, size: size, parentRole: parentRole,
            supportedActions: actions, attributeNames: attributeNames,
            parameterizedAttributeNames: parameterizedAttributeNames, settableAttributes: settableAttributes
        )
    }
    
    public func toSnapshot(pid: Int32, appName: String) -> AXElementSnapshot {
        var frame: [Double]? = nil
        if let p = position, let s = size, p.count > 1, s.count > 1 {
            frame = [p[0], p[1], s[0], s[1]]
        }
        return AXElementSnapshot(
            pid: pid,
            applicationName: appName,
            role: role,
            subrole: subrole,
            title: title,
            descriptionText: descriptionText,
            value: value,
            isEnabled: isEnabled,
            isFocused: isFocused,
            supportedActions: supportedActions,
            elementFrame: frame
        )
    }
}

public struct AXScrollCapability: Codable {
    public let hasScrollArea: Bool
    public let scrollAreaRole: String?
    public let verticalScrollBarAvailable: Bool
    public let isVerticalValueSettable: Bool
    public let verticalValue: Double?
    public let verticalMin: Double?
    public let verticalMax: Double?
    public let verticalActions: [String]
    public let scrollAreaActions: [String]
    public let mechanism: String // "DIRECT_VALUE", "INCREMENTAL_ACTION", "SEMANTIC_OTHER", "UNSUPPORTED"
}

public struct AXCapabilityInspectionResult: Codable {
    public let pid: Int32
    public let applicationName: String
    public let hitNode: AXNodeCapability
    public let ancestorChain: [AXNodeCapability] // Bounded ancestry (up to 4 levels)
    public let scrollCapability: AXScrollCapability
}

/// Direct interaction context holding live AXUIElement references for session lifetime.
public struct AXInteractionContext {
    public let pid: Int32
    public let applicationName: String
    public let hitElement: AXUIElement
    public let hitNode: AXNodeCapability
    public let ancestorChain: [AXNodeCapability]
    public let scrollAreaElement: AXUIElement?
    public let scrollBarElement: AXUIElement?
    public let scrollCapability: AXScrollCapability
    public let scrollAreaHeight: Double
}

public final class AXCapabilityInspector {
    public static let shared = AXCapabilityInspector()
    
    private init() {}
    
    public func discoverContext(element: AXUIElement, maxAncestors: Int = 4) -> AXInteractionContext {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
        
        let hitNode = inspectNode(element)
        
        // Inspect bounded ancestor chain
        var ancestors: [AXNodeCapability] = []
        var currentElem = element
        var foundScrollAreaElem: AXUIElement? = nil
        var foundScrollBarElem: AXUIElement? = nil
        
        if hitNode.role == "AXScrollBar" {
            foundScrollBarElem = element
        } else if hitNode.role == "AXScrollArea" {
            foundScrollAreaElem = element
        }
        
        for _ in 0..<maxAncestors {
            var parentRef: AnyObject?
            let err = AXUIElementCopyAttributeValue(currentElem, kAXParentAttribute as CFString, &parentRef)
            guard err == .success, let p = parentRef else { break }
            let pElem = p as! AXUIElement
            let pNode = inspectNode(pElem)
            ancestors.append(pNode)
            
            if foundScrollAreaElem == nil && pNode.role == "AXScrollArea" {
                foundScrollAreaElem = pElem
            }
            if foundScrollBarElem == nil && pNode.role == "AXScrollBar" {
                foundScrollBarElem = pElem
            }
            
            currentElem = pElem
            if pNode.role == "AXWindow" || pNode.role == "AXApplication" {
                break
            }
        }
        
        if foundScrollAreaElem != nil && foundScrollBarElem == nil {
            var vsbRef: AnyObject?
            if AXUIElementCopyAttributeValue(foundScrollAreaElem!, "AXVerticalScrollBar" as CFString, &vsbRef) == .success, let b = vsbRef {
                foundScrollBarElem = (b as! AXUIElement)
            }
        }
        
        let scrollCap = evaluateScrollCapability(
            hitElement: element,
            scrollAreaElem: foundScrollAreaElem,
            directScrollBarElem: foundScrollBarElem
        )
        
        var sHeight: Double = 400.0
        if let sa = foundScrollAreaElem, let sz = getSizeAttr(sa, kAXSizeAttribute), sz.count > 1 {
            sHeight = sz[1]
        } else if let sz = hitNode.size, sz.count > 1 {
            sHeight = sz[1]
        }
        
        return AXInteractionContext(
            pid: pid,
            applicationName: appName,
            hitElement: element,
            hitNode: hitNode,
            ancestorChain: ancestors,
            scrollAreaElement: foundScrollAreaElem,
            scrollBarElement: foundScrollBarElem,
            scrollCapability: scrollCap,
            scrollAreaHeight: max(100.0, sHeight)
        )
    }
    
    public func inspect(element: AXUIElement, maxAncestors: Int = 4) -> AXCapabilityInspectionResult {
        let ctx = discoverContext(element: element, maxAncestors: maxAncestors)
        return AXCapabilityInspectionResult(
            pid: ctx.pid,
            applicationName: ctx.applicationName,
            hitNode: ctx.hitNode,
            ancestorChain: ctx.ancestorChain,
            scrollCapability: ctx.scrollCapability
        )
    }
    
    public func inspectNode(_ element: AXUIElement) -> AXNodeCapability {
        let role = getStringAttr(element, kAXRoleAttribute) ?? "UnknownRole"
        let subrole = getStringAttr(element, kAXSubroleAttribute)
        let title = getStringAttr(element, kAXTitleAttribute)
        let desc = getStringAttr(element, kAXDescriptionAttribute)
        let valStr = getStringAttr(element, kAXValueAttribute)
        
        let minVal = getDoubleAttr(element, kAXMinValueAttribute)
        let maxVal = getDoubleAttr(element, kAXMaxValueAttribute)
        let valInc = getDoubleAttr(element, kAXValueIncrementAttribute)
        
        let enabled = getBoolAttr(element, kAXEnabledAttribute)
        let focused = getBoolAttr(element, kAXFocusedAttribute)
        let selected = getBoolAttr(element, kAXSelectedAttribute)
        
        let pos = getPointAttr(element, kAXPositionAttribute)
        let size = getSizeAttr(element, kAXSizeAttribute)
        
        var parentRole: String? = nil
        var parentRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success, let p = parentRef {
            parentRole = getStringAttr(p as! AXUIElement, kAXRoleAttribute)
        }
        
        // Actions
        var actions: [String] = []
        var actsRef: CFArray?
        if AXUIElementCopyActionNames(element, &actsRef) == .success, let arr = actsRef as? [AnyObject] {
            actions = arr.map { String(describing: $0) }
        }
        
        // Attribute names
        var attrNames: [String] = []
        var namesRef: CFArray?
        if AXUIElementCopyAttributeNames(element, &namesRef) == .success, let arr = namesRef as? [AnyObject] {
            attrNames = arr.map { String(describing: $0) }
        }
        
        // Parameterized attribute names
        var paramNames: [String] = []
        var pNamesRef: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &pNamesRef) == .success, let arr = pNamesRef as? [AnyObject] {
            paramNames = arr.map { String(describing: $0) }
        }
        
        // Check settability of relevant attributes
        var settableAttrs: [String] = []
        let testList = [
            kAXValueAttribute as String,
            kAXFocusedAttribute as String,
            kAXSelectedAttribute as String,
            "AXSelectedRows",
            "AXSelectedChildren"
        ]
        for attr in testList {
            if attrNames.contains(attr) {
                var isSettable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(element, attr as CFString, &isSettable) == .success, isSettable.boolValue {
                    settableAttrs.append(attr)
                }
            }
        }
        
        return AXNodeCapability(
            role: role,
            subrole: subrole,
            title: title,
            descriptionText: desc,
            value: valStr,
            minValue: minVal,
            maxValue: maxVal,
            valueIncrement: valInc,
            isEnabled: enabled,
            isFocused: focused,
            isSelected: selected,
            position: pos,
            size: size,
            parentRole: parentRole,
            supportedActions: actions,
            attributeNames: attrNames,
            parameterizedAttributeNames: paramNames,
            settableAttributes: settableAttrs
        )
    }
    
    private func evaluateScrollCapability(
        hitElement: AXUIElement,
        scrollAreaElem: AXUIElement?,
        directScrollBarElem: AXUIElement?
    ) -> AXScrollCapability {
        var vBarElem: AXUIElement? = directScrollBarElem
        let sAreaElem: AXUIElement? = scrollAreaElem
        
        // If scroll area was found, check if it has an AXVerticalScrollBar attribute
        if let sa = sAreaElem {
            if vBarElem == nil {
                var vsbRef: AnyObject?
                if AXUIElementCopyAttributeValue(sa, "AXVerticalScrollBar" as CFString, &vsbRef) == .success, let b = vsbRef {
                    vBarElem = (b as! AXUIElement)
                }
            }
        }
        
        // If neither was in ancestor chain, check if hitElement itself is inside a WebArea with AXScrollToVisible
        let hitNode = inspectNode(hitElement)
        
        var vBarAvailable = false
        var isValSettable = false
        var vVal: Double? = nil
        var vMin: Double? = nil
        var vMax: Double? = nil
        var vActions: [String] = []
        var saActions: [String] = []
        
        if let sa = sAreaElem {
            let saNode = inspectNode(sa)
            saActions = saNode.supportedActions
        }
        
        if let vb = vBarElem {
            vBarAvailable = true
            let vbNode = inspectNode(vb)
            isValSettable = vbNode.isValueSettable
            vVal = getDoubleAttr(vb, kAXValueAttribute)
            vMin = vbNode.minValue ?? 0.0
            vMax = vbNode.maxValue ?? 1.0
            vActions = vbNode.supportedActions
        }
        
        let mechanism: String
        if vBarAvailable && isValSettable {
            mechanism = "DIRECT_VALUE"
        } else if vActions.contains("AXIncrement") || vActions.contains("AXDecrement") {
            mechanism = "INCREMENTAL_ACTION"
        } else if saActions.contains("AXScrollDownByPage") || hitNode.supportedActions.contains("AXScrollToVisible") {
            mechanism = "SEMANTIC_OTHER"
        } else {
            mechanism = "UNSUPPORTED"
        }
        
        return AXScrollCapability(
            hasScrollArea: (sAreaElem != nil),
            scrollAreaRole: sAreaElem != nil ? "AXScrollArea" : nil,
            verticalScrollBarAvailable: vBarAvailable,
            isVerticalValueSettable: isValSettable,
            verticalValue: vVal,
            verticalMin: vMin,
            verticalMax: vMax,
            verticalActions: vActions,
            scrollAreaActions: saActions,
            mechanism: mechanism
        )
    }
    
    // Helpers
    private func getStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let val = ref {
            let str = String(describing: val)
            return str.isEmpty ? nil : str
        }
        return nil
    }
    
    private func getDoubleAttr(_ element: AXUIElement, _ attr: String) -> Double? {
        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let val = ref {
            if let n = val as? NSNumber { return n.doubleValue }
            if let d = Double(String(describing: val)) { return d }
        }
        return nil
    }
    
    private func getBoolAttr(_ element: AXUIElement, _ attr: String) -> Bool? {
        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let val = ref {
            if let b = val as? Bool { return b }
            if let n = val as? NSNumber { return n.boolValue }
        }
        return nil
    }
    
    private func getPointAttr(_ element: AXUIElement, _ attr: String) -> [Double]? {
        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let val = ref {
            var pt = CGPoint.zero
            if AXValueGetValue(val as! AXValue, .cgPoint, &pt) {
                return [pt.x, pt.y]
            }
        }
        return nil
    }
    
    private func getSizeAttr(_ element: AXUIElement, _ attr: String) -> [Double]? {
        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let val = ref {
            var sz = CGSize.zero
            if AXValueGetValue(val as! AXValue, .cgSize, &sz) {
                return [sz.width, sz.height]
            }
        }
        return nil
    }
}
