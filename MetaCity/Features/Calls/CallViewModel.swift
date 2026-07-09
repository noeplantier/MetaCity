import Foundation

@MainActor
final class CallViewModel: ObservableObject {
    @Published var rooms: [CallRoom] = []
    @Published var contacts: [CallContact] = []
    @Published private(set) var tourismContacts: [TourismContact] = []
    @Published var callState: CallState = .idle
    @Published var newRoomName: String = ""
    @Published var presentedSnackbar: SnackbarMessage?
    @Published var isLoadingRooms = false
    /// Local-only UI state — there's no real audio session or camera capture behind this mock, so
    /// these don't round-trip through `CallService` the way mic/camera do (those have a plausible
    /// real-SDK equivalent to forward to; "speaker" and "front/back" don't until real AVFoundation
    /// capture exists).
    @Published var isSpeakerOn = false
    @Published var isFrontCamera = true
    /// When the current call first reached `.connected` — `nil` whenever not on a connected call.
    /// `InCallView`'s timer reads this once and ticks its own display via `TimelineView`, rather
    /// than this ViewModel publishing a new value every second: a per-second `@Published` was
    /// re-evaluating the *entire* `InCallView` body every tick (remote video, control bar, all of
    /// it) for a one-line label, the exact "broad `@Published` update for one subview" pattern
    /// worth avoiding — see CLAUDE.md's performance notes.
    @Published private(set) var callStartDate: Date?

    private let callService: CallService
    private let joinCallUseCase: JoinCallUseCase

    init(callService: CallService, joinCallUseCase: JoinCallUseCase) {
        self.callService = callService
        self.joinCallUseCase = joinCallUseCase
        observeCallState()
    }

    /// Subscribes once for the lifetime of this ViewModel — the long-lived `callStateStream` is the
    /// single source of truth for call state, so the UI and the (eventual) real SDK never disagree.
    private func observeCallState() {
        Task { [weak self] in
            guard let self else { return }
            for await state in self.callService.callStateStream {
                let wasConnected = self.callState.isConnected
                self.callState = state
                if case .failed(let error) = state {
                    self.presentedSnackbar = SnackbarMessage(text: error.localizedDescription, style: .error)
                }
                if state.isConnected && !wasConnected {
                    self.callStartDate = Date()
                } else if !state.isConnected && wasConnected {
                    self.callStartDate = nil
                }
            }
        }
    }

    func loadRooms() async {
        isLoadingRooms = true
        defer { isLoadingRooms = false }
        do {
            rooms = try await callService.fetchAvailableRooms()
        } catch {
            presentedSnackbar = SnackbarMessage(text: "Couldn't load rooms.", style: .error)
        }
    }

    func loadContacts() async {
        do {
            contacts = try await callService.fetchContacts()
        } catch {
            presentedSnackbar = SnackbarMessage(text: "Couldn't load contacts.", style: .error)
        }
    }

    /// Loads real tourism contacts from `contacts_<cityId>.json` in the bundle.
    /// Defaults to Jakarta if no city is focused in the Discover tab.
    func loadTourismContacts(for cityId: String = "jakarta") {
        tourismContacts = TourismContact.load(for: cityId)
    }

    func createAndJoinRoom() async {
        let name = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let room = try await callService.createRoom(named: name)
            newRoomName = ""
            await join(roomID: room.id)
        } catch {
            presentedSnackbar = SnackbarMessage(text: "Couldn't create the room.", style: .error)
        }
    }

    func join(roomID: String) async {
        do {
            try await joinCallUseCase.execute(roomID: roomID, currentState: callState)
        } catch let error as CallError {
            presentedSnackbar = SnackbarMessage(text: error.errorDescription ?? "Couldn't join the call.", style: .error)
        } catch {
            presentedSnackbar = SnackbarMessage(text: "Couldn't join the call.", style: .error)
        }
    }

    /// Calls `contact` directly — the bot assistant answers itself after a short ring.
    func call(_ contact: CallContact, mode: CallMode) async {
        guard callState.isIdleOrEnded else {
            presentedSnackbar = SnackbarMessage(text: "You're already in a call. Leave it before starting another.", style: .error)
            return
        }
        isFrontCamera = true
        isSpeakerOn = mode == .video // video calls default to speaker, like every real calling app
        do {
            try await callService.call(contact, mode: mode)
        } catch {
            presentedSnackbar = SnackbarMessage(text: "Couldn't start the call.", style: .error)
        }
    }

    /// Test-only entry point (see `CallLobbyView`'s "Simulate incoming call" action) — exercises
    /// the `.incoming` accept/decline UI without needing a second device or person.
    func simulateIncomingCall(mode: CallMode) async {
        guard callState.isIdleOrEnded else { return }
        await callService.simulateIncomingCall(from: MockCallService.assistantContact, mode: mode)
    }

    func acceptIncomingCall() async {
        do {
            try await callService.acceptIncomingCall()
        } catch {
            presentedSnackbar = SnackbarMessage(text: "Couldn't connect the call.", style: .error)
        }
    }

    func declineIncomingCall() async {
        await callService.endRingingCall()
    }

    func cancelOutgoingCall() async {
        await callService.endRingingCall()
    }

    func leaveCall() async {
        await callService.leaveCurrentRoom()
    }

    /// Applied optimistically to the local participant for instant UI feedback, then forwarded to
    /// the service. A real SDK would also broadcast this change to remote participants.
    func toggleMicrophone() async {
        guard case .connected(let room, var participants) = callState,
              let localIndex = participants.firstIndex(where: { $0.isLocal }) else { return }
        participants[localIndex].isMicrophoneMuted.toggle()
        callState = .connected(room: room, participants: participants)
        await callService.setMicrophoneEnabled(!participants[localIndex].isMicrophoneMuted)
    }

    func toggleCamera() async {
        guard case .connected(let room, var participants) = callState,
              let localIndex = participants.firstIndex(where: { $0.isLocal }) else { return }
        participants[localIndex].isCameraEnabled.toggle()
        callState = .connected(room: room, participants: participants)
        await callService.setCameraEnabled(participants[localIndex].isCameraEnabled)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
    }

    /// No real capture session to flip yet (see the property's doc comment) — toggles the local
    /// flag the preview reads to mirror itself, so the control is visibly live rather than dead.
    func flipCamera() {
        isFrontCamera.toggle()
    }
}

private extension CallState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isIdleOrEnded: Bool {
        switch self {
        case .idle, .ended, .failed: return true
        case .outgoing, .incoming, .connecting, .connected: return false
        }
    }
}
