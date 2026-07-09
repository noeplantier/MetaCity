import Foundation

/// In-memory stand-in for a real auth backend. Swap this for `FirebaseAuthRepository` /
/// `Auth0Repository` etc. later — nothing outside this file needs to change because every
/// caller depends only on the `AuthRepository` protocol.
///
/// Demo credentials: demo@metacity.app / password123
actor MockAuthRepository: AuthRepository {
    private struct StoredAccount {
        let user: User
        var password: String
    }

    private var accountsByEmail: [String: StoredAccount]
    /// Not in `accountsByEmail` on purpose: a Google-sign-in identity has no local password to
    /// check, so it doesn't belong in a dictionary keyed for password verification.
    private let googleUser: User
    private var signedInUser: User?

    init() {
        let demoUser = User(id: UUID().uuidString, email: "demo@metacity.app", displayName: "Demo User")
        accountsByEmail = [demoUser.email: StoredAccount(user: demoUser, password: "password123")]
        googleUser = User(id: UUID().uuidString, email: "plantiernoe50@gmail.com", displayName: "Noé Plantier")
        signedInUser = nil
    }

    func login(email: String, password: String) async throws -> User {
        try await simulateNetworkLatency()
        let normalizedEmail = email.lowercased()
        guard let account = accountsByEmail[normalizedEmail], account.password == password else {
            throw AuthError.invalidCredentials
        }
        signedInUser = account.user
        return account.user
    }

    func signUp(email: String, password: String) async throws -> User {
        try await simulateNetworkLatency()
        let normalizedEmail = email.lowercased()
        guard accountsByEmail[normalizedEmail] == nil else {
            throw AuthError.emailAlreadyInUse
        }
        guard password.count >= 6 else {
            throw AuthError.weakPassword
        }
        let localPart = normalizedEmail.split(separator: "@").first.map(String.init) ?? "New User"
        let newUser = User(id: UUID().uuidString, email: normalizedEmail, displayName: localPart)
        accountsByEmail[normalizedEmail] = StoredAccount(user: newUser, password: password)
        signedInUser = newUser
        return newUser
    }

    func signInWithGoogle() async throws -> User {
        try await simulateNetworkLatency()
        // Real implementation: call `GIDSignIn.sharedInstance.signIn(...)`, take the resulting
        // `idToken`, and send it to your backend to mint a session — nothing else in the app
        // changes, since every caller only ever sees the `AuthRepository` protocol.
        signedInUser = googleUser
        return googleUser
    }

    func logout() async {
        signedInUser = nil
    }

    func currentUser() async -> User? {
        signedInUser
    }

    private func simulateNetworkLatency() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }
}
