import Foundation

/// Feature gate that prevents self-executing or irreversible operations from running automatically.
/// Off by default (safe). Enable only in CI, TestFlight, or explicit debug sessions.
///
/// Set via Xcode scheme environment variable or simctl launch env:
///   SIMCTL_CHILD_SAFE_RUN=1 xcrun simctl launch <UDID> com.metacity.app
///
/// Usage:
///   guard SafeRun.isEnabled else { return }
///   // ... risky/irreversible operation ...
enum SafeRun {
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["SAFE_RUN"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "SafeRun.enabled")
    }

    static func enable()  { UserDefaults.standard.set(true,  forKey: "SafeRun.enabled") }
    static func disable() { UserDefaults.standard.set(false, forKey: "SafeRun.enabled") }
}
