import Foundation

/// Abstraction over Face ID/Touch ID so `ProfileViewModel` doesn't depend on `LocalAuthentication`
/// directly — keeps the same Domain-protocol-first pattern as Auth/Map/Call.
protocol BiometricAuthenticator {
    /// Whether this device has biometrics enrolled and available right now.
    var isAvailable: Bool { get }
    /// "Face ID" or "Touch ID" — whichever this device actually has, for accurate copy in the UI.
    var biometryDisplayName: String { get }
    func authenticate(reason: String) async -> Bool
}
