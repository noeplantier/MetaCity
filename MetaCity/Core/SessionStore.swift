import Foundation

/// App-wide source of truth for "who is signed in". `RootView` observes this to decide between
/// `AuthView` and `HomeTabView`; `AuthViewModel` updates it on successful login/signup and
/// `ProfileViewModel` clears it on logout. Centralizing this means no feature screen needs its own auth check.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var currentUser: User?

    private let authRepository: AuthRepository

    init(authRepository: AuthRepository) {
        self.authRepository = authRepository
    }

    func restoreExistingSession() async {
        guard currentUser == nil else { return }  // already signed in (e.g., UITEST_SKIP_AUTH flag)
        currentUser = await authRepository.currentUser()
    }

    func handleSignedIn(_ user: User) {
        currentUser = user
    }

    func handleSignedOut() {
        currentUser = nil
    }
}
