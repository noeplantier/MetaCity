import LocalAuthentication

/// Real `LocalAuthentication` integration — not mocked, this genuinely prompts Face ID/Touch ID on
/// a real device. The Simulator can still exercise it via Features > Face ID > Enrolled +
/// Matching/Non-matching Face in the Simulator menu, same as any other app.
final class LocalAuthenticationBiometricAuthenticator: BiometricAuthenticator {
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var biometryDisplayName: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return "Biometric authentication"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometric authentication"
        }
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
