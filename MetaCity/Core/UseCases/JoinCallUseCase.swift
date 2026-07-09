import Foundation

/// Ensures a participant can't accidentally join two rooms at once — a rule that belongs in the
/// Domain layer, not scattered across UI code. The use case is stateless; the caller passes in the
/// last known `CallState` so this stays trivially testable without a running CallService.
struct JoinCallUseCase {
    private let callService: CallService

    init(callService: CallService) {
        self.callService = callService
    }

    func execute(roomID: String, currentState: CallState) async throws {
        switch currentState {
        case .connected, .connecting, .outgoing, .incoming:
            throw CallError.alreadyInCall
        case .idle, .ended, .failed:
            try await callService.join(roomID: roomID)
        }
    }
}
