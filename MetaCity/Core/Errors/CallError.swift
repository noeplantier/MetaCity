import Foundation

enum CallError: Error, Equatable, LocalizedError {
    case roomNotFound
    case joinFailed
    case microphonePermissionDenied
    case cameraPermissionDenied
    case alreadyInCall
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .roomNotFound: return "That room no longer exists."
        case .joinFailed: return "Couldn't join the call. Please try again."
        case .microphonePermissionDenied: return "Microphone access is required to join a call."
        case .cameraPermissionDenied: return "Camera access is required to turn on video."
        case .alreadyInCall: return "You're already in a call. Leave it before joining another."
        case .unknown(let message): return message
        }
    }
}
