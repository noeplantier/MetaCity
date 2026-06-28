import SwiftUI

struct CallLobbyView: View {
    @ObservedObject var viewModel: CallViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    contactsContent
                } header: {
                    SectionHeader(title: "Contacts")
                }
                .textCase(nil)
                .listRowBackground(Color.metacitySurface)

                Section {
                    newRoomRow
                } header: {
                    SectionHeader(title: "Start a new call")
                }
                .textCase(nil)
                .listRowBackground(Color.metacitySurface)

                Section {
                    roomsContent
                } header: {
                    SectionHeader(title: "Join a room")
                }
                .textCase(nil)
                .listRowBackground(Color.metacitySurface)

                Section {
                    testingRow
                } header: {
                    SectionHeader(title: "Internal testing")
                }
                .textCase(nil)
                .listRowBackground(Color.metacitySurface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.metacityBackground)
            .navigationTitle("Calls")
            .task {
                await viewModel.loadRooms()
                await viewModel.loadContacts()
            }
            .refreshable { await viewModel.loadRooms() }
            .snackbar($viewModel.presentedSnackbar)
            .fullScreenCover(isPresented: isInCallBinding) {
                InCallView(viewModel: viewModel)
            }
        }
    }

    @ViewBuilder
    private var contactsContent: some View {
        if viewModel.contacts.isEmpty {
            LoadingStateView()
                .frame(height: 80)
                .listRowInsets(EdgeInsets())
        } else {
            ForEach(viewModel.contacts) { contact in
                ContactRow(contact: contact) { mode in
                    Task { await viewModel.call(contact, mode: mode) }
                }
            }
        }
    }

    /// Lets the bot ring *you* instead, exercising the full incoming-call accept/decline UI —
    /// without it, that state would only ever be reachable with a second device or person.
    private var testingRow: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Simulate the assistant calling you, to test the incoming-call screen.")
                .font(.metacityCaption)
                .foregroundStyle(Color.metacityTextSecondary)
            HStack(spacing: Spacing.lg) {
                Button {
                    Task { await viewModel.simulateIncomingCall(mode: .audio) }
                } label: {
                    Label("Audio", systemImage: "phone.arrow.down.left.fill")
                }
                Button {
                    Task { await viewModel.simulateIncomingCall(mode: .video) }
                } label: {
                    Label("Video", systemImage: "video.fill")
                }
            }
            .font(.metacitySubheadline)
            .foregroundStyle(Color.metacityPrimary)
            .frame(minHeight: 44)
        }
        .padding(.vertical, Spacing.xs)
    }

    private var newRoomRow: some View {
        HStack(spacing: Spacing.sm) {
            TextField("New room name", text: $viewModel.newRoomName)
                .font(.metacityBody)
            Button("Start") {
                Task { await viewModel.createAndJoinRoom() }
            }
            .font(.metacityHeadline)
            .foregroundStyle(Color.metacityPrimary)
            .frame(minHeight: 44)
            .disabled(viewModel.newRoomName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private var roomsContent: some View {
        if viewModel.isLoadingRooms {
            LoadingStateView()
                .frame(height: 120)
                .listRowInsets(EdgeInsets())
        } else if viewModel.rooms.isEmpty {
            EmptyStateView(
                systemImage: "phone.down.circle",
                title: "No rooms yet",
                message: "Start a call above to create the first room."
            )
            .listRowInsets(EdgeInsets())
        } else {
            ForEach(viewModel.rooms) { room in
                RoomRow(room: room) {
                    Task { await viewModel.join(roomID: room.id) }
                }
            }
        }
    }

    /// Drives the in-call presentation purely off `CallState` so there's exactly one source of truth
    /// for "are we in a call" — no separate `@State isShowingCall` flag to fall out of sync.
    private var isInCallBinding: Binding<Bool> {
        Binding(
            get: {
                switch viewModel.callState {
                case .connecting, .connected, .outgoing, .incoming: return true
                case .idle, .ended, .failed: return false
                }
            },
            set: { isPresented in
                if !isPresented {
                    Task { await viewModel.leaveCall() }
                }
            }
        )
    }
}

private struct ContactRow: View {
    let contact: CallContact
    let onCall: (CallMode) -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Avatar(
                name: contact.name,
                size: 44,
                backgroundColor: contact.isBot ? Color.metacitySuccess.opacity(0.22) : .metacitySurfaceElevated,
                systemImage: contact.isBot ? "sparkles" : nil
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(contact.name)
                        .font(.metacityHeadline)
                        .foregroundStyle(Color.metacityTextPrimary)
                    if contact.isBot {
                        Text("TEST BOT")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.metacitySuccess.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.metacitySuccess)
                    }
                }
                Text(contact.isBot ? "Always available — answers in a couple seconds" : "Contact")
                    .font(.metacityCaption)
                    .foregroundStyle(Color.metacityTextSecondary)
            }

            Spacer(minLength: Spacing.sm)

            HStack(spacing: Spacing.sm) {
                IconButton(systemImage: "phone.fill", accessibilityLabel: "Audio call \(contact.name)") {
                    onCall(.audio)
                }
                IconButton(systemImage: "video.fill", accessibilityLabel: "Video call \(contact.name)", style: .prominent) {
                    onCall(.video)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

private struct RoomRow: View {
    let room: CallRoom
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Avatar(name: room.name, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.metacityHeadline)
                    .foregroundStyle(Color.metacityTextPrimary)
                Text(room.participantCount == 0 ? "Empty" : "\(room.participantCount) already in the room")
                    .font(.metacityCaption)
                    .foregroundStyle(Color.metacityTextSecondary)
            }

            Spacer()

            Button("Join", action: onJoin)
                .font(.metacitySubheadline)
                .foregroundStyle(Color.metacityPrimary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.vertical, Spacing.xs)
    }
}

#Preview {
    let service = MockCallService()
    CallLobbyView(viewModel: CallViewModel(callService: service, joinCallUseCase: JoinCallUseCase(callService: service)))
}
