import Foundation
import Cocoa
import Darwin

/// Manages the native macOS Accessibility Virtual Keyboard on macOS 14+ (Sonoma).
/// Uses the official UniversalAccessCore framework C APIs (`UAVirtualKeyboardIsEnabled`, `UAVirtualKeyboardSetEnabled`)
/// to toggle the on-screen keyboard without opening System Settings, stealing application key focus,
/// or relying on fragile internal application paths.
public final class SystemVirtualKeyboardManager {
    public static let shared = SystemVirtualKeyboardManager()

    private typealias IsEnabledFunc = @convention(c) () -> Bool
    private typealias SetEnabledFunc = @convention(c) (Bool) -> Void

    private var isEnabledFn: IsEnabledFunc?
    private var setEnabledFn: SetEnabledFunc?

    private init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Frameworks/UniversalAccessCore.framework/Versions/A/UniversalAccessCore", RTLD_NOW) {
            if let isSym = dlsym(handle, "UAVirtualKeyboardIsEnabled"),
               let setSym = dlsym(handle, "UAVirtualKeyboardSetEnabled") {
                self.isEnabledFn = unsafeBitCast(isSym, to: IsEnabledFunc.self)
                self.setEnabledFn = unsafeBitCast(setSym, to: SetEnabledFunc.self)
            }
        }
    }

    /// Whether the virtual keyboard is currently visible on screen.
    public var isVisible: Bool {
        if let fn = isEnabledFn {
            return fn()
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.inputmethod.AssistiveControl")
        return running.contains(where: { !$0.isTerminated })
    }

    /// Shows or hides the native macOS Accessibility Virtual Keyboard.
    /// Does not steal focus from the currently active application.
    @discardableResult
    public func setVisible(_ visible: Bool) -> Bool {
        if let fn = setEnabledFn {
            fn(visible)
            TouchBridgeLogger.info(.lifecycle, "System Virtual Keyboard visibility set to \(visible)")
            return true
        }
        // Fallback: terminate running instance when hiding
        if !visible {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.inputmethod.AssistiveControl")
            for app in running where !app.isTerminated {
                app.terminate()
            }
            return true
        }
        return false
    }

    /// Toggles the virtual keyboard on/off.
    @discardableResult
    public func toggle() -> Bool {
        let target = !isVisible
        return setVisible(target)
    }
}
