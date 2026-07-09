import FirebaseAuth
import Foundation
import GoogleSignIn
import UIKit

/// Real Firebase Authentication backend — active automatically once `GoogleService-Info.plist` is
/// present and `FirebaseApp.configure()` has run (see `MetaCityApp.init` and
/// `AppEnvironment.defaultAuthRepository()`). Implements the exact same `AuthRepository` contract
/// as `MockAuthRepository`, so nothing in the Presentation layer needed to change to support this.
final class FirebaseAuthRepository: AuthRepository {
    func login(email: String, password: String) async throws -> User {
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            return User(firebaseUser: result.user)
        } catch {
            throw AuthError.from(error)
        }
    }

    func signUp(email: String, password: String) async throws -> User {
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            return User(firebaseUser: result.user)
        } catch {
            throw AuthError.from(error)
        }
    }

    func signInWithGoogle() async throws -> User {
        guard let presenter = await Self.topViewController() else {
            throw AuthError.unknown("No screen to present Google Sign-In from.")
        }

        let signInResult: GIDSignInResult
        do {
            signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }

        guard let idToken = signInResult.user.idToken?.tokenString else {
            throw AuthError.unknown("Google didn't return an ID token.")
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: signInResult.user.accessToken.tokenString
        )

        do {
            let authResult = try await Auth.auth().signIn(with: credential)
            return User(firebaseUser: authResult.user)
        } catch {
            throw AuthError.from(error)
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }

    func logout() async {
        try? Auth.auth().signOut()
    }

    func currentUser() async -> User? {
        Auth.auth().currentUser.map(User.init(firebaseUser:))
    }
}

private extension User {
    init(firebaseUser: FirebaseAuth.User) {
        let localPart = firebaseUser.email?.split(separator: "@").first.map(String.init)
        self.init(
            id: firebaseUser.uid,
            email: firebaseUser.email ?? "",
            displayName: firebaseUser.displayName ?? localPart ?? "User"
        )
    }
}

private extension AuthError {
    static func from(_ error: Error) -> AuthError {
        guard let code = AuthErrorCode(rawValue: (error as NSError).code) else {
            return .unknown(error.localizedDescription)
        }
        switch code {
        case .wrongPassword, .invalidEmail, .userNotFound, .invalidCredential:
            return .invalidCredentials
        case .emailAlreadyInUse:
            return .emailAlreadyInUse
        case .weakPassword:
            return .weakPassword
        case .networkError:
            return .network
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
