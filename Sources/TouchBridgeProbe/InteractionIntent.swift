import Foundation
import CoreGraphics

/// Explicit recognizer-to-router gesture outcomes.
public enum InteractionIntent {
    case tap(InteractionSession)
    case pairedSecondTap(InteractionSession)
    case contextMenu(InteractionSession)
    case dragStarted(InteractionSession)
    case dragUpdated(InteractionSession, currentPoint: CGPoint, deltaPixels: CGVector)
    case dragEnded(InteractionSession, endPoint: CGPoint)
    case directPanStarted(InteractionSession)
    case directPanAXValueUpdated(InteractionSession, targetValue: Double)
    case directPanUpdated(InteractionSession, deltaPixels: CGVector)
    case directPanEnded(InteractionSession)
    case momentumStarted(InteractionSession, initialVelocity: CGVector)
    case momentumInterrupted(InteractionSession)
    case magnifyUpdated(InteractionSession, phase: Int64, magnification: Double)
    case rotateUpdated(InteractionSession, phase: Int64, rotationDegrees: Double)
    case unsupportedPan(InteractionSession)
    case cancelledOneFingerMovement(InteractionSession, reason: String)
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
