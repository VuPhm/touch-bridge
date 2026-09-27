import Foundation
import CoreGraphics

/// Output of gesture arbitration. Intents describe what happened without
/// selecting an operating-system delivery mechanism.
public enum InteractionIntent {
    case tap(InteractionSession)
    case cancelledOneFingerMovement(InteractionSession, reason: String)
    case directPanStarted(InteractionSession)
    case directPanUpdated(InteractionSession, deltaPixels: CGVector)
    case directPanAXValueUpdated(InteractionSession, targetValue: Double)
    case directPanEnded(InteractionSession)
    case momentumStarted(InteractionSession, initialVelocity: CGVector)
    case momentumInterrupted(InteractionSession)
    case unsupportedPan(InteractionSession)
    case cancelled(InteractionSession, reason: String)
}

public enum TapBackendMode: String, CaseIterable {
    case semantic
    case transientPointer = "transient-pointer"

    public static let pointerPrimary = TapBackendMode.transientPointer

    public var diagnosticName: String {
        switch self {
        case .semantic: return "DIAGNOSTIC_SEMANTIC_ONLY"
        case .transientPointer: return "POINTER_PRIMARY"
        }
    }

    public static func parseCLI(_ value: String) -> TapBackendMode? {
        switch value {
        case "semantic", "semantic-only": return .semantic
        case "transient-pointer", "pointer-primary": return .transientPointer
        default: return nil
        }
    }
}

public enum TapDeliveryMechanism: String, Equatable {
    case transientPointer = "TRANSIENT_POINTER"
    case diagnosticSemantic = "DIAGNOSTIC_SEMANTIC"
}

/// Pure policy decision, deliberately independent of AX hit-test results.
public enum InteractionDeliveryPolicy {
    public static func tapMechanism(mode: TapBackendMode) -> TapDeliveryMechanism {
        mode == .semantic ? .diagnosticSemantic : .transientPointer
    }

    public static func selectsDiagnosticSemanticDelivery(mode: TapBackendMode) -> Bool {
        tapMechanism(mode: mode) == .diagnosticSemantic
    }
}
