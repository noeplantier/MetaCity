import Foundation

/// Abstraction over "who is signed in". Swap `MockAuthRepository` for a Firebase/Auth0/Cognito
/// backed implementation later without touching any ViewModel or View — see Data/Auth.
protocol AuthRepository: AnyObject {
    func login(email: String, password: String) async throws -> User
    func signUp(email: String, password: String) async throws -> User

    /// Deliberately takes no credentials — real "Sign in with Google" is an OAuth handoff
    /// (the `GoogleSignIn-iOS` SDK presents Google's own consent screen and hands back an ID
    /// token; the user's Google password never passes through this app). The real implementation
    /// would take that token and exchange it with your backend; see `MockAuthRepository` for the
    /// exact spot that swap happens.
    func signInWithGoogle() async throws -> User

    func logout() async
    func currentUser() async -> User?
}
