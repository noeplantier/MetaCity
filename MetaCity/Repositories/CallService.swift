import Foundation

/// Abstraction over a calling backend (WebRTC/Twilio/Agora/...). `MockCallService` simulates it
/// in-memory so the UI is fully functional before a real SDK is wired in — see Data/Call.
protocol CallService: AnyObject {
    /// Long-lived stream of call state changes. ViewModels subscribe once (in `init`) and react to every update.
    var callStateStream: AsyncStream<CallState> { get }

    func fetchAvailableRooms() async throws -> [CallRoom]
    func createRoom(named name: String) async throws -> CallRoom
    func join(roomID: String) async throws
    func leaveCurrentRoom() async
    func setMicrophoneEnabled(_ isEnabled: Bool) async
    func setCameraEnabled(_ isEnabled: Bool) async

    /// Directly-callable contacts (e.g. the bot assistant), shown separately from joinable rooms.
    func fetchContacts() async throws -> [CallContact]
    /// You call `contact` — moves to `.outgoing`, then to `.connected` once they "pick up". A bot
    /// contact answers itself after a short, realistic ring delay.
    func call(_ contact: CallContact, mode: CallMode) async throws
    /// Test-only: simulates `contact` calling *you* instead, for exercising the `.incoming`
    /// accept/decline UI without a second device.
    func simulateIncomingCall(from contact: CallContact, mode: CallMode) async
    func acceptIncomingCall() async throws
    /// Ends a call that hasn't connected yet — covers both declining an `.incoming` ring and
    /// canceling your own `.outgoing` one.
    func endRingingCall() async
}
