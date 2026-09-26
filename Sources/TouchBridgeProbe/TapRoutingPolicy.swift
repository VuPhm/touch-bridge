import Foundation
import ApplicationServices

enum TapBackend: String, Equatable {
    case press = "AX_PRESS"
    case selection = "AX_SELECTION"
    case focus = "AX_FOCUS"
    case cursorMovingCGClick = "CG_PRIMARY_CLICK_CURSOR_MOVING"
}

enum TapBackendOutcome {
    case focusReadback(isFocused: Bool)
    case selection(setSucceeded: Bool, isSelected: Bool)
    case axPressSucceeded(Bool)
}

enum UnresolvedTapHandling: String, Equatable {
    case semanticUnresolved = "SEMANTIC_UNRESOLVED"
    case cursorMovingCGClick = "CG_PRIMARY_CLICK_CURSOR_MOVING"
    case cursorRestoreExperiment = "CG_CURSOR_RESTORE_EXPERIMENT"
}

enum TapExecutionClassification: String, Equatable {
    case cursorMovingCGClick = "CG_PRIMARY_CLICK_CURSOR_MOVING"
    case cursorRestoreExperiment = "CG_CURSOR_RESTORE_EXPERIMENT"
}

enum TapRoutingPolicy {
    private static let textEntryRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField"
    ]
    private static let selectionRoles: Set<String> = [
        "AXRow", "AXCell", "AXListItem", "AXOutlineRow"
    ]

    static func isPrimaryActionable(role: String, supportedActions: Set<String>, settableAttributes: Set<String>) -> Bool {
        supportedActions.contains(kAXPressAction as String) ||
            (selectionRoles.contains(role) && settableAttributes.contains(kAXSelectedAttribute as String)) ||
            (textEntryRoles.contains(role) && settableAttributes.contains(kAXFocusedAttribute as String))
    }

    static func backends(role: String, supportedActions: Set<String>, settableAttributes: Set<String>) -> [TapBackend] {
        var result: [TapBackend] = []
        if supportedActions.contains(kAXPressAction as String) {
            result.append(.press)
        }
        if selectionRoles.contains(role), settableAttributes.contains(kAXSelectedAttribute as String) {
            result.append(.selection)
        }
        if textEntryRoles.contains(role), settableAttributes.contains(kAXFocusedAttribute as String) {
            result.append(.focus)
        }
        result.append(.cursorMovingCGClick)
        return result
    }

    static func unresolvedHandling(allowCursorMovingFallback: Bool, enableCursorRestoreExperiment: Bool) -> UnresolvedTapHandling {
        if enableCursorRestoreExperiment { return .cursorRestoreExperiment }
        if allowCursorMovingFallback { return .cursorMovingCGClick }
        return .semanticUnresolved
    }

    static func succeeded(_ outcome: TapBackendOutcome) -> Bool {
        switch outcome {
        case .focusReadback(let isFocused):
            return isFocused
        case .selection(let setSucceeded, let isSelected):
            return setSucceeded && isSelected
        case .axPressSucceeded(let succeeded):
            return succeeded
        }
    }
}
