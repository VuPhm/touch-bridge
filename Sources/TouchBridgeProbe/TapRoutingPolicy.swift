import Foundation
import ApplicationServices

/// Capability and role based ordering for a physical tap. A backend is only
/// considered to have consumed the tap after its live operation is verified.
enum TapBackend: String, Equatable {
    case focus = "AX_FOCUS"
    case selection = "AX_SELECTION"
    case press = "AX_PRESS"
    case showMenu = "AX_SHOW_MENU"
    case pick = "AX_PICK"
    case coreGraphicsPrimaryClick = "CG_PRIMARY_CLICK"
}

enum TapBackendOutcome {
    case focusReadback(isFocused: Bool)
    case selection(setSucceeded: Bool, isSelected: Bool)
    case axActionSucceeded(Bool)
}

enum TapRoutingPolicy {
    private static let textEntryRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField"
    ]
    private static let selectionRoles: Set<String> = [
        "AXRow", "AXCell", "AXListItem", "AXOutlineRow"
    ]

    static func backends(
        role: String,
        supportedActions: Set<String>,
        settableAttributes: Set<String>
    ) -> [TapBackend] {
        var result: [TapBackend] = []

        if textEntryRoles.contains(role), settableAttributes.contains(kAXFocusedAttribute as String) {
            result.append(.focus)
        }
        if selectionRoles.contains(role), settableAttributes.contains(kAXSelectedAttribute as String) {
            result.append(.selection)
        }
        if supportedActions.contains(kAXPressAction as String) {
            result.append(.press)
        }
        if supportedActions.contains(kAXShowMenuAction as String) {
            result.append(.showMenu)
        }
        if supportedActions.contains("AXPick") {
            result.append(.pick)
        }

        result.append(.coreGraphicsPrimaryClick)
        return result
    }

    static func succeeded(_ outcome: TapBackendOutcome) -> Bool {
        switch outcome {
        case .focusReadback(let isFocused):
            return isFocused
        case .selection(let setSucceeded, let isSelected):
            return setSucceeded && isSelected
        case .axActionSucceeded(let succeeded):
            return succeeded
        }
    }
}
