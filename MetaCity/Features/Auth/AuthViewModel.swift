import Foundation

enum AuthMode: Equatable {
    case login
    case signUp

    var toggleTitle: String {
        switch self {
        case .login: return "Need an account? Sign up"
        case .signUp: return "Already have an account? Log in"
        }
    }

    var submitTitle: String {
        switch self {
        case .login: return "Log In"
        case .signUp: return "Sign Up"
        }
    }
}

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var mode: AuthMode = .login
    @Published var isLoading = false
    /// Separate from `isLoading` on purpose — the email form and the Google button are
    /// independent actions, and conflating them would make one show a spinner for the other's request.
    @Published var isGoogleSignInLoading = false
    @Published var presentedError: IdentifiableError?

    let isUsingMockAuth: Bool

    private let authRepository: AuthRepository
    private let loginUseCase: LoginUseCase
    private let session: SessionStore

    init(authRepository: AuthRepository, loginUseCase: LoginUseCase, session: SessionStore, isUsingMockAuth: Bool = true) {
        self.authRepository = authRepository
        self.loginUseCase = loginUseCase
        self.session = session
        self.isUsingMockAuth = isUsingMockAuth
    }

    var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && !isLoading && !isGoogleSignInLoading
    }

    var canUseGoogleSignIn: Bool {
        !isLoading && !isGoogleSignInLoading
    }

    func toggleMode() {
        mode = (mode == .login) ? .signUp : .login
        presentedError = nil
    }

    /// Login goes through `LoginUseCase` for basic validation; sign-up calls the repository
    /// directly since the mock backend already enforces its own rule (`AuthError.weakPassword`).
    func submit() async {
        guard canSubmit else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let user: User
            switch mode {
            case .login:
                user = try await loginUseCase.execute(email: email, password: password)
            case .signUp:
                user = try await authRepository.signUp(email: email, password: password)
            }
            session.handleSignedIn(user)
        } catch {
            presentedError = IdentifiableError(underlyingError: error)
        }
    }

    func continueWithGoogle() async {
        guard canUseGoogleSignIn else { return }
        isGoogleSignInLoading = true
        defer { isGoogleSignInLoading = false }
        do {
            let user = try await authRepository.signInWithGoogle()
            session.handleSignedIn(user)
        } catch {
            presentedError = IdentifiableError(underlyingError: error)
        }
    }
}
