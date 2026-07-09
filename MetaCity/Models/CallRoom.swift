import Foundation

struct CallRoom: Identifiable, Equatable {
    let id: String
    let name: String
    let participantCount: Int
}

struct CallParticipant: Identifiable, Equatable {
    let id: String
    let displayName: String
    let isLocal: Bool
    var isMicrophoneMuted: Bool
    var isCameraEnabled: Bool
}

/// A directly-callable contact, distinct from a `CallRoom` you join — shown in its own section in
/// `CallLobbyView`. `isBot` marks contacts that are always reachable and answer automatically,
/// which is what makes `MockCallService.assistantContact` usable as a one-tap internal test call
/// without needing a second device or person.
struct CallContact: Identifiable, Equatable {
    let id: String
    let name: String
    let isBot: Bool
}

/// Audio-only vs. video — chosen when starting a call with a contact, mirrored in the local
/// participant's initial `isCameraEnabled` so the in-call UI opens already in the right mode.
enum CallMode: Equatable {
    case audio
    case video
}

/// Snapshot of an in-progress call, streamed by `CallService` to anyone observing it.
/// Modeling this as an enum (rather than several optional flags) makes illegal states unrepresentable.
enum CallState: Equatable {
    case idle
    /// You called a contact and are waiting for them to pick up — shows a "Cancel" action.
    case outgoing(contact: CallContact, mode: CallMode)
    /// A contact is calling you — shows "Accept"/"Decline". Reached either by the bot auto-ringing
    /// back, or via the lobby's "Simulate incoming call" test action.
    case incoming(contact: CallContact, mode: CallMode)
    case connecting(roomID: String)
    case connected(room: CallRoom, participants: [CallParticipant])
    case ended
    case failed(CallError)
}
