import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - TouchBridge Safety Invariants (P3-01 Section 12)

public enum SafetyInvariants {
    public static let formalStatement = """
    ================================================================================
                        TouchBridge Core Safety Invariants
    ================================================================================
    1. Direct-Touch Cursor Safety:
       The default product path does not warp the cursor and suppresses unresolved
       taps instead of injecting a cursor-moving mouse fallback. The explicit
       CG_CURSOR_RESTORE_EXPERIMENT mode is separate, opt-in, and not pointer isolation.

    2. Cursor-Moving Compatibility Fallback:
       CG primary click is available only when explicitly enabled. It may move the
       real cursor and is always reported as CG_PRIMARY_CLICK_CURSOR_MOVING.
    
    3. Zero Virtual HID:
       Never instantiate virtual HID devices or drivers.
    
    4. Zero Private APIs:
       Exclusively interact via public macOS AppKit, CoreGraphics, ApplicationServices
       (Accessibility), and IOKit APIs.
    
    5. Pointer Isolation Scope:
       AX semantic actions and direct scrolling are measured for cursor movement.
       Cursor-moving CG compatibility clicks and cursor-restore experiments are
       excluded from any pointer-isolation claim.
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
