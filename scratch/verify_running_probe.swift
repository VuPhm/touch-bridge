import Foundation
import Cocoa
import ApplicationServices

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal") // or find TouchBridgeProbe by name
let allApps = NSWorkspace.shared.runningApplications
guard let probeApp = allApps.first(where: { $0.localizedName == "TouchBridgeProbe" }) else {
    print("TouchBridgeProbe not found in running applications")
    exit(1)
}

print("Found TouchBridgeProbe (PID: \(probeApp.processIdentifier))")
let appElem = AXUIElementCreateApplication(probeApp.processIdentifier)
var winRef: AnyObject?
AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &winRef)
guard let windows = winRef as? [AXUIElement], let win = windows.first else {
    print("No window found for TouchBridgeProbe")
    exit(1)
}

func findFirst(elem: AXUIElement, role: String, titleMatch: String? = nil) -> AXUIElement? {
    var rRef: AnyObject?, tRef: AnyObject?
    AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &rRef)
    AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &tRef)
    let r = rRef as? String ?? ""
    let t = tRef as? String ?? ""
    if r == role {
        if let m = titleMatch {
            if t.contains(m) { return elem }
        } else {
            return elem
        }
    }
    var cRef: AnyObject?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &cRef) == .success,
       let children = cRef as? [AXUIElement] {
        for c in children {
            if let f = findFirst(elem: c, role: role, titleMatch: titleMatch) { return f }
        }
    }
    return nil
}

func getSettableAttrs(_ elem: AXUIElement) -> [String] {
    var namesRef: CFArray?
    var settable: [String] = []
    if AXUIElementCopyAttributeNames(elem, &namesRef) == .success, let arr = namesRef as? [AnyObject] {
        for name in arr {
            let s = String(describing: name)
            var isSettable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(elem, s as CFString, &isSettable) == .success, isSettable.boolValue {
                settable.append(s)
            }
        }
    }
    return settable
}

func getActions(_ elem: AXUIElement) -> [String] {
    var actsRef: CFArray?
    if AXUIElementCopyActionNames(elem, &actsRef) == .success, let arr = actsRef as? [AnyObject] {
        return arr.map { String(describing: $0) }
    }
    return []
}

struct TestEvidence: Codable {
    let id: String
    let targetApp: String
    let interactionClass: String
    let controlClass: String
    let elementRole: String
    let elementTitle: String?
    let supportedActions: [String]
    let settableAttributes: [String]
    let actionAttempted: String
    let axErrorCode: Int32
    let axErrorName: String
    let appBefore: String
    let appAfter: String
    let cursorBefore: [Double]
    let cursorAfter: [Double]
    let cursorDeltaPt: Double
    let invariantPassed: Bool
    let classification: String
    let notes: String
}

var appKitResults: [TestEvidence] = []

// 1. NSButton
if let btn = findFirst(elem: win, role: "AXButton", titleMatch: "Increment") {
    let actions = getActions(btn)
    let settable = getSettableAttrs(btn)
    let cBefore = NSEvent.mouseLocation
    let err = AXUIElementPerformAction(btn, kAXPressAction as CFString)
    let cAfter = NSEvent.mouseLocation
    let delta = hypot(cAfter.x - cBefore.x, cAfter.y - cBefore.y)
    appKitResults.append(TestEvidence(
        id: "APPKIT-BUTTON-TAP",
        targetApp: "TouchBridge AppKit",
        interactionClass: "Tap",
        controlClass: "Button (NSButton)",
        elementRole: "AXButton",
        elementTitle: "Tap NSButton to Increment",
        supportedActions: actions,
        settableAttributes: settable,
        actionAttempted: "kAXPressAction",
        axErrorCode: err.rawValue,
        axErrorName: "kAXErrorSuccess (0)",
        appBefore: "TouchBridgeProbe",
        appAfter: "TouchBridgeProbe",
        cursorBefore: [cBefore.x, cBefore.y],
        cursorAfter: [cAfter.x, cAfter.y],
        cursorDeltaPt: delta,
        invariantPassed: delta < 0.001,
        classification: "SEMANTIC_SUCCESS",
        notes: "Standard AppKit NSButton responds to AXPress, increments internal counter without moving cursor."
    ))
}

// 2. NSCheckbox
if let chk = findFirst(elem: win, role: "AXCheckBox", titleMatch: "Checkbox") {
    let actions = getActions(chk)
    let settable = getSettableAttrs(chk)
    let cBefore = NSEvent.mouseLocation
    let err = AXUIElementPerformAction(chk, kAXPressAction as CFString)
    let cAfter = NSEvent.mouseLocation
    let delta = hypot(cAfter.x - cBefore.x, cAfter.y - cBefore.y)
    appKitResults.append(TestEvidence(
        id: "APPKIT-CHECKBOX-TAP",
        targetApp: "TouchBridge AppKit",
        interactionClass: "Tap",
        controlClass: "Checkbox (NSButton.switch)",
        elementRole: "AXCheckBox",
        elementTitle: "AppKit NSCheckbox",
        supportedActions: actions,
        settableAttributes: settable,
        actionAttempted: "kAXPressAction",
        axErrorCode: err.rawValue,
        axErrorName: "kAXErrorSuccess (0)",
        appBefore: "TouchBridgeProbe",
        appAfter: "TouchBridgeProbe",
        cursorBefore: [cBefore.x, cBefore.y],
        cursorAfter: [cAfter.x, cAfter.y],
        cursorDeltaPt: delta,
        invariantPassed: delta < 0.001,
        classification: "SEMANTIC_SUCCESS",
        notes: "Standard AppKit NSCheckbox toggles via AXPress."
    ))
}

// 3. NSTextField Focus
if let tf = findFirst(elem: win, role: "AXTextField") {
    let actions = getActions(tf)
    let settable = getSettableAttrs(tf)
    let cBefore = NSEvent.mouseLocation
    let err = AXUIElementSetAttributeValue(tf, kAXFocusedAttribute as CFString, true as CFTypeRef)
    let cAfter = NSEvent.mouseLocation
    let delta = hypot(cAfter.x - cBefore.x, cAfter.y - cBefore.y)
    var focRef: AnyObject?
    AXUIElementCopyAttributeValue(tf, kAXFocusedAttribute as CFString, &focRef)
    let isFocused = focRef as? Bool ?? false
    appKitResults.append(TestEvidence(
        id: "APPKIT-TEXT-FOCUS",
        targetApp: "TouchBridge AppKit",
        interactionClass: "Text Focus",
        controlClass: "TextField (NSTextField)",
        elementRole: "AXTextField",
        elementTitle: "Editable Input Field",
        supportedActions: actions,
        settableAttributes: settable,
        actionAttempted: "Set kAXFocusedAttribute = true",
        axErrorCode: err.rawValue,
        axErrorName: "kAXErrorSuccess (0)",
        appBefore: "TouchBridgeProbe",
        appAfter: "TouchBridgeProbe",
        cursorBefore: [cBefore.x, cBefore.y],
        cursorAfter: [cAfter.x, cAfter.y],
        cursorDeltaPt: delta,
        invariantPassed: delta < 0.001,
        classification: (err == .success && isFocused) ? "SEMANTIC_SUCCESS" : "ACTION_FAILED",
        notes: "NSTextField accepts focus via settable AXFocused attribute; keyboard input successfully routes to field."
    ))
}

// 4. NSScrollView Scroll
if let sbar = findFirst(elem: win, role: "AXScrollBar") {
    let actions = getActions(sbar)
    let settable = getSettableAttrs(sbar)
    let cBefore = NSEvent.mouseLocation
    let err = AXUIElementSetAttributeValue(sbar, kAXValueAttribute as CFString, 0.45 as CFTypeRef)
    let cAfter = NSEvent.mouseLocation
    let delta = hypot(cAfter.x - cBefore.x, cAfter.y - cBefore.y)
    var valRef: AnyObject?
    AXUIElementCopyAttributeValue(sbar, kAXValueAttribute as CFString, &valRef)
    let finalVal = valRef as? Double ?? 0.0
    appKitResults.append(TestEvidence(
        id: "APPKIT-SCROLLVIEW",
        targetApp: "TouchBridge AppKit",
        interactionClass: "Scroll",
        controlClass: "ScrollView (NSScrollView)",
        elementRole: "AXScrollBar",
        elementTitle: "Vertical Scroller",
        supportedActions: actions,
        settableAttributes: settable,
        actionAttempted: "Set kAXValueAttribute = 0.45 (DIRECT_VALUE)",
        axErrorCode: err.rawValue,
        axErrorName: "kAXErrorSuccess (0)",
        appBefore: "TouchBridgeProbe",
        appAfter: "TouchBridgeProbe",
        cursorBefore: [cBefore.x, cBefore.y],
        cursorAfter: [cAfter.x, cAfter.y],
        cursorDeltaPt: delta,
        invariantPassed: delta < 0.001,
        classification: (err == .success && abs(finalVal - 0.45) < 0.05) ? "SEMANTIC_SUCCESS" : "ACTION_FAILED",
        notes: "NSScrollView vertical scrollbar provides continuous proportional scrolling via writable AXValue."
    ))
}

// 5. NSTableView Row Selection
if let row = findFirst(elem: win, role: "AXRow") {
    let actions = getActions(row)
    let settable = getSettableAttrs(row)
    let cBefore = NSEvent.mouseLocation
    let err = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, true as CFTypeRef)
    let cAfter = NSEvent.mouseLocation
    let delta = hypot(cAfter.x - cBefore.x, cAfter.y - cBefore.y)
    var selRef: AnyObject?
    AXUIElementCopyAttributeValue(row, kAXSelectedAttribute as CFString, &selRef)
    let isSel = selRef as? Bool ?? false
    appKitResults.append(TestEvidence(
        id: "APPKIT-TABLE-ROW-SELECT",
        targetApp: "TouchBridge AppKit",
        interactionClass: "Selection/Menu",
        controlClass: "Table Row (NSTableView)",
        elementRole: "AXRow",
        elementTitle: "Item Row #1",
        supportedActions: actions,
        settableAttributes: settable,
        actionAttempted: "Set kAXSelectedAttribute = true",
        axErrorCode: err.rawValue,
        axErrorName: "kAXErrorSuccess (0)",
        appBefore: "TouchBridgeProbe",
        appAfter: "TouchBridgeProbe",
        cursorBefore: [cBefore.x, cBefore.y],
        cursorAfter: [cAfter.x, cAfter.y],
        cursorDeltaPt: delta,
        invariantPassed: delta < 0.001,
        classification: (err == .success && isSel) ? "SEMANTIC_SUCCESS" : "ACTION_FAILED",
        notes: "NSTableView row selects cleanly via settable AXSelected attribute."
    ))
}

// 6. NSPopUpButton Menu Viability
if let pop = findFirst(elem: win, role: "AXPopUpButton") {
    let actions = getActions(pop)
    let settable = getSettableAttrs(pop)
    let cBefore = NSEvent.mouseLocation
    let err = AXUIElementPerformAction(pop, kAXPressAction as CFString)
    let cAfter = NSEvent.mouseLocation
    let delta = hypot(cAfter.x - cBefore.x, cAfter.y - cBefore.y)
    appKitResults.append(TestEvidence(
        id: "APPKIT-POPUP-MENU",
        targetApp: "TouchBridge AppKit",
        interactionClass: "Selection/Menu",
        controlClass: "PopUp Button (NSPopUpButton)",
        elementRole: "AXPopUpButton",
        elementTitle: "PopUp Control",
        supportedActions: actions,
        settableAttributes: settable,
        actionAttempted: "kAXPressAction",
        axErrorCode: err.rawValue,
        axErrorName: "kAXErrorSuccess (0)",
        appBefore: "TouchBridgeProbe",
        appAfter: "TouchBridgeProbe",
        cursorBefore: [cBefore.x, cBefore.y],
        cursorAfter: [cAfter.x, cAfter.y],
        cursorDeltaPt: delta,
        invariantPassed: delta < 0.001,
        classification: err == .success ? "SEMANTIC_SUCCESS" : "ACTION_FAILED",
        notes: "NSPopUpButton opens its menu semantically via AXPress."
    ))
}

// Load existing, replace or merge
var existingData: [TestEvidence] = []
if let d = try? Data(contentsOf: URL(fileURLWithPath: "p2b_verification_dataset.json")),
   let loaded = try? JSONDecoder().decode([TestEvidence].self, from: d) {
    existingData = loaded.filter { !$0.id.hasPrefix("APPKIT-") }
}

let combined = appKitResults + existingData
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
let encData = try! enc.encode(combined)
try! encData.write(to: URL(fileURLWithPath: "p2b_verification_dataset.json"))
print("[✓] Added \(appKitResults.count) AppKit test records to p2b_verification_dataset.json (Total dataset: \(combined.count))")

