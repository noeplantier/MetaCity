import Foundation

/// Orchestrates login with validation that belongs to business rules, not the repository or the view.
/// Keeping this as its own type (rather than logic inline in the ViewModel) is what makes it unit-testable in isolation.
struct LoginUseCase {
    private let authRepository: AuthRepository

    init(authRepository: AuthRepository) {
        self.authRepository = authRepository
    }

    func execute(email: String, password: String) async throws -> User {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            throw AuthError.invalidCredentials
        }
        guard !password.isEmpty else {
            throw AuthError.invalidCredentials
        }
        return try await authRepository.login(email: trimmedEmail, password: password)
    }
}
