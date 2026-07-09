import Foundation

enum AuthError: Error, Equatable, LocalizedError {
    case invalidCredentials
    case emailAlreadyInUse
    case weakPassword
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "That email or password doesn't look right."
        case .emailAlreadyInUse: return "An account with that email already exists."
        case .weakPassword: return "Password must be at least 8 characters."
        case .network: return "Couldn't reach the server. Check your connection."
        case .unknown(let message): return message
        }
    }
}
