import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published private(set) var currentUser: User?
    @Published var presentedError: IdentifiableError?
    @Published var preferences: UserPreferences
    /// Whether the Profile tab's content is currently hidden behind a biometric prompt. Starts
    /// `true` whenever the lock setting is on, so a fresh launch (or a fresh `ProfileViewModel`)
    /// never shows private details before the device owner has actually proven who they are.
    @Published private(set) var isLocked: Bool

    let biometryDisplayName: String
    let isBiometricAvailable: Bool

    private let authRepository: AuthRepository
    private let session: SessionStore
    private let preferencesStore: UserPreferencesStore
    private let biometricAuthenticator: BiometricAuthenticator

    init(
        authRepository: AuthRepository,
        session: SessionStore,
        preferencesStore: UserPreferencesStore,
        biometricAuthenticator: BiometricAuthenticator
    ) {
        self.authRepository = authRepository
        self.session = session
        self.preferencesStore = preferencesStore
        self.biometricAuthenticator = biometricAuthenticator
        self.currentUser = session.currentUser
        self.biometryDisplayName = biometricAuthenticator.biometryDisplayName
        self.isBiometricAvailable = biometricAuthenticator.isAvailable

        let loaded = session.currentUser.map { preferencesStore.load(for: $0.id) } ?? .default
        self.preferences = loaded
        self.isLocked = loaded.isBiometricLockEnabled
    }

    func logout() async {
        await authRepository.logout()
        session.handleSignedOut()
    }

    /// Every preference write goes through here so a save to disk is never forgotten on a new field.
    func updatePreferences(_ mutate: (inout UserPreferences) -> Void) {
        mutate(&preferences)
        guard let userID = currentUser?.id else { return }
        preferencesStore.save(preferences, for: userID)
    }

    func unlock() async {
        guard isLocked else { return }
        guard await biometricAuthenticator.authenticate(reason: "Unlock your MetaCity profile") else { return }
        isLocked = false
    }

    /// Called when the app backgrounds (see `ProfileView`'s `scenePhase` observation) — re-arms
    /// the lock so leaving and returning to the app re-prompts, not just the very first open.
    func lockIfEnabled() {
        guard preferences.isBiometricLockEnabled else { return }
        isLocked = true
    }
}
