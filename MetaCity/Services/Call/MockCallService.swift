import Foundation

/// Simulates a WebRTC/Twilio/Agora-style backend entirely in memory. Replace with a real adapter
/// (e.g. `TwilioCallService`, `AgoraCallService`) later — every screen in Presentation/Call only
/// ever talks to the `CallService` protocol, so the swap is contained to this one file.
final class MockCallService: CallService {
    /// Always-reachable test contact — answers automatically a couple seconds after you call it,
    /// so the full call flow is exercisable without a second device or person.
    static let assistantContact = CallContact(id: "bot-assistant", name: "MetaCity Assistant", isBot: true)

    let callStateStream: AsyncStream<CallState>
    private let continuation: AsyncStream<CallState>.Continuation

    private var rooms: [CallRoom]
    private var isMicrophoneEnabled = true
    private var isCameraEnabled = true
    /// Cancels a bot's pending auto-answer if the call is ended/declined before it "picks up".
    private var pendingRingTask: Task<Void, Never>?
    /// `CallService` is push-only (`AsyncStream`), with no synchronous "current state" getter.
    /// `acceptIncomingCall` needs to know *which* contact/mode is currently ringing, so every
    /// state change is mirrored here through `emit(_:)` rather than threading it through
    /// call-site parameters.
    private var lastEmittedState: CallState = .idle

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: CallState.self)
        self.callStateStream = stream
        self.continuation = continuation
        self.rooms = [
            CallRoom(id: "room-design", name: "Design Sync", participantCount: 2),
            CallRoom(id: "room-standup", name: "Daily Standup", participantCount: 4),
            CallRoom(id: "room-investor", name: "Investor Update", participantCount: 1)
        ]
        emit(.idle)
    }

    func fetchAvailableRooms() async throws -> [CallRoom] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return rooms
    }

    func fetchContacts() async throws -> [CallContact] {
        try await Task.sleep(nanoseconds: 200_000_000)
        return [Self.assistantContact]
    }

    func createRoom(named name: String) async throws -> CallRoom {
        try await Task.sleep(nanoseconds: 250_000_000)
        let room = CallRoom(id: UUID().uuidString, name: name, participantCount: 0)
        rooms.append(room)
        return room
    }

    func join(roomID: String) async throws {
        guard let room = rooms.first(where: { $0.id == roomID }) else {
            emit(.failed(.roomNotFound))
            throw CallError.roomNotFound
        }
        emit(.connecting(roomID: roomID))
        try await Task.sleep(nanoseconds: 800_000_000) // simulated signaling/ICE negotiation delay

        let remoteParticipants = (0..<room.participantCount).map { index in
            CallParticipant(
                id: "remote-\(index)",
                displayName: "Teammate \(index + 1)",
                isLocal: false,
                isMicrophoneMuted: false,
                isCameraEnabled: true
            )
        }
        emit(.connected(room: room, participants: [makeLocalParticipant()] + remoteParticipants))
    }

    func call(_ contact: CallContact, mode: CallMode) async throws {
        isCameraEnabled = mode == .video
        emit(.outgoing(contact: contact, mode: mode))

        guard contact.isBot else {
            try await Task.sleep(nanoseconds: 1_200_000_000)
            emit(.failed(.unknown("\(contact.name) isn't reachable yet — only the assistant bot answers in this build.")))
            return
        }

        pendingRingTask?.cancel()
        pendingRingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000) // realistic ring duration
            guard let self, !Task.isCancelled else { return }
            self.connectBotCall(contact: contact, mode: mode)
        }
    }

    func simulateIncomingCall(from contact: CallContact, mode: CallMode) async {
        emit(.incoming(contact: contact, mode: mode))
    }

    func acceptIncomingCall() async throws {
        guard case .incoming(let contact, let mode) = lastEmittedState else {
            throw CallError.joinFailed
        }
        isCameraEnabled = mode == .video
        try await Task.sleep(nanoseconds: 500_000_000) // brief, realistic connect delay
        connectBotCall(contact: contact, mode: mode)
    }

    func endRingingCall() async {
        pendingRingTask?.cancel()
        pendingRingTask = nil
        emit(.ended)
        try? await Task.sleep(nanoseconds: 150_000_000)
        emit(.idle)
    }

    func leaveCurrentRoom() async {
        pendingRingTask?.cancel()
        pendingRingTask = nil
        emit(.ended)
        try? await Task.sleep(nanoseconds: 150_000_000)
        emit(.idle)
    }

    func setMicrophoneEnabled(_ isEnabled: Bool) async {
        isMicrophoneEnabled = isEnabled
    }

    func setCameraEnabled(_ isEnabled: Bool) async {
        isCameraEnabled = isEnabled
    }

    private func connectBotCall(contact: CallContact, mode: CallMode) {
        let room = CallRoom(id: "contact-\(contact.id)", name: contact.name, participantCount: 1)
        let botParticipant = CallParticipant(
            id: contact.id,
            displayName: contact.name,
            isLocal: false,
            isMicrophoneMuted: false,
            isCameraEnabled: mode == .video
        )
        emit(.connected(room: room, participants: [makeLocalParticipant(), botParticipant]))
    }

    private func makeLocalParticipant() -> CallParticipant {
        CallParticipant(
            id: "local",
            displayName: "You",
            isLocal: true,
            isMicrophoneMuted: !isMicrophoneEnabled,
            isCameraEnabled: isCameraEnabled
        )
    }

    private func emit(_ state: CallState) {
        lastEmittedState = state
        continuation.yield(state)
    }
}
