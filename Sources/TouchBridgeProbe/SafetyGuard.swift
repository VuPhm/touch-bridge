import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - TouchBridge Safety Invariants (P3-01 Section 12)

public enum SafetyInvariants {
    public static let formalStatement = """
    ================================================================================
                        TouchBridge Core Safety Invariants
    ================================================================================
    1. Zero Cursor Warping:
       Never call CGWarpMouseCursorPosition or mutate system cursor position.
    
    2. Zero Mouse Fallback:
       Never synthesize or inject mouse CGEvents (leftMouseDown, mouseMoved, etc.).
       Fallback to mouse synthesis is strictly forbidden.
    
    3. Zero Virtual HID:
       Never instantiate virtual HID devices or drivers.
    
    4. Zero Private APIs:
       Exclusively interact via public macOS AppKit, CoreGraphics, ApplicationServices
       (Accessibility), and IOKit APIs.
    
    5. Strict Pointer Isolation:
       The physical system pointer remains completely isolated and stationary during
       touch interactions on the external display.
    ================================================================================
    """
    
    /// Queries the current system cursor position in CoreGraphics global display coordinates.
    public static func currentCursorPosition() -> CGPoint {
        // Obtains current mouse position using public CGEvent without warping
        if let event = CGEvent(source: nil) {
            return event.location
        }
        return .zero
    }
    
    /// Asserts that the system pointer has not moved across a semantic action.
    /// Returns true if invariant is satisfied, false if pointer moved.
    @discardableResult
    public static func assertPointerIsolation(
        cursorBefore: CGPoint,
        cursorAfter: CGPoint,
        context: String = "Semantic Action",
        fatalOnError: Bool = false
    ) -> (satisfied: Bool, delta: Double) {
        let dx = cursorAfter.x - cursorBefore.x
        let dy = cursorAfter.y - cursorBefore.y
        let delta = sqrt(dx * dx + dy * dy)
        
        let satisfied = (delta <= 0.001)
        if !satisfied {
            TouchBridgeLogger.error(
                .safety,
                "SAFETY INVARIANT VIOLATED during [\(context)]! Cursor moved by \(String(format: "%.3f", delta)) pt (Before: [\(cursorBefore.x), \(cursorBefore.y)], After: [\(cursorAfter.x), \(cursorAfter.y)])"
            )
            if fatalOnError {
                #if DEBUG
                assertionFailure("TouchBridge cursor isolation invariant violated: cursor delta = \(delta) pt")
                #endif
            }
        }
        return (satisfied, delta)
    }
}
