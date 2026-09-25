import Foundation
import ApplicationServices

public enum AXPermissionStatus: String, Codable {
    case granted = "PERMISSION_GRANTED"
    case unavailable = "PERMISSION_UNAVAILABLE"
}

public final class AXPermissionManager {
    public static let shared = AXPermissionManager()
    
    private var hasPromptedUser: Bool = false
    
    private init() {}
    
    /// Checks whether the current process is trusted for Accessibility.
    /// Does not trigger system prompt.
    public func isTrusted() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Checks trust status and optionally requests prompt from macOS if not trusted.
    /// Strictly guarantees no continuous prompt spamming.
    public func checkPermission(requestPromptIfNeeded: Bool = false) -> AXPermissionStatus {
        if isTrusted() {
            return .granted
        }
        
        if requestPromptIfNeeded && !hasPromptedUser {
            hasPromptedUser = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            return trusted ? .granted : .unavailable
        }
        
        return .unavailable
    }
    
    public func printStatusBanner() {
        let status = checkPermission()
        print("--------------------------------------------------------------------------------")
        print("Accessibility Permission (macOS AX API):")
        if status == .granted {
            print("  Status: [✓] GRANTED (AXIsProcessTrusted == true)")
        } else {
            print("  Status: [!] UNAVAILABLE (AXIsProcessTrusted == false)")
            print("  Required Action: Grant Accessibility permissions in:")
            print("    System Settings -> Privacy & Security -> Accessibility")
            print("    for the active terminal or host application.")
        }
        print("--------------------------------------------------------------------------------")
    }
}
