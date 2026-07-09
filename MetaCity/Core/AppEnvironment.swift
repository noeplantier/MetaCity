import FirebaseCore
import Foundation

/// Simple, explicit dependency container. Every dependency is exposed only as its Domain protocol
/// type so swapping mock for real is a one-line change here and nowhere else.
@MainActor
final class AppEnvironment {
    let authRepository: AuthRepository
    let callService: CallService
    let locationProvider: UserLocationProvider
    let preferencesStore: UserPreferencesStore
    let biometricAuthenticator: BiometricAuthenticator
    let isUsingMockAuth: Bool
    let selectionStore = AppSelectionStore()

    init(
        authRepository: AuthRepository = AppEnvironment.defaultAuthRepository(),
        callService: CallService = MockCallService(),
        locationProvider: UserLocationProvider = CoreLocationProvider(),
        preferencesStore: UserPreferencesStore = UserDefaultsPreferencesStore(),
        biometricAuthenticator: BiometricAuthenticator = LocalAuthenticationBiometricAuthenticator()
    ) {
        self.authRepository = authRepository
        self.callService = callService
        self.locationProvider = locationProvider
        self.preferencesStore = preferencesStore
        self.biometricAuthenticator = biometricAuthenticator
        self.isUsingMockAuth = FirebaseApp.app() == nil
    }

    private nonisolated static func defaultAuthRepository() -> AuthRepository {
        FirebaseApp.app() != nil ? FirebaseAuthRepository() : MockAuthRepository()
    }

    // MARK: - Feature ViewModel factories

    func makeAuthViewModel(session: SessionStore) -> AuthViewModel {
        AuthViewModel(
            authRepository: authRepository,
            loginUseCase: LoginUseCase(authRepository: authRepository),
            session: session,
            isUsingMockAuth: isUsingMockAuth
        )
    }

    func makeDiscoverViewModel() -> DiscoverViewModel {
        DiscoverViewModel()
    }

    func makeCallViewModel() -> CallViewModel {
        CallViewModel(
            callService: callService,
            joinCallUseCase: JoinCallUseCase(callService: callService)
        )
    }

    func makeProfileViewModel(session: SessionStore) -> ProfileViewModel {
        ProfileViewModel(
            authRepository: authRepository,
            session: session,
            preferencesStore: preferencesStore,
            biometricAuthenticator: biometricAuthenticator
        )
    }
}
