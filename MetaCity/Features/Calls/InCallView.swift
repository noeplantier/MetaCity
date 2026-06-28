import SwiftUI

/// Deliberately stays a fixed black/white "immersive" surface regardless of the system's light/dark
/// setting — the same choice every real calling app (FaceTime, Zoom, Meet) makes, since video tiles
/// need a neutral dark surround to read correctly. Everything here is hand-tuned white-on-black on
/// purpose; it does not use the dynamic `metacity*` color tokens the rest of the app uses.
struct InCallView: View {
    @ObservedObject var viewModel: CallViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.callState {
            case .outgoing(let contact, let mode):
                RingingView(contact: contact, mode: mode, role: .outgoing) {
                    Task { await viewModel.cancelOutgoingCall() }
                }
            case .incoming(let contact, let mode):
                RingingView(contact: contact, mode: mode, role: .incoming) {
                    Task { await viewModel.declineIncomingCall() }
                } onAccept: {
                    Task { await viewModel.acceptIncomingCall() }
                }
            case .connecting, .connected:
                connectedLayout
            case .idle, .ended, .failed:
                // `CallLobbyView.isInCallBinding` only presents this screen for the cases above —
                // reachable only mid-dismissal animation, never as a state a user actually sees.
                EmptyView()
            }
        }
    }

    private var connectedLayout: some View {
        ZStack {
            remoteVideoArea

            VStack {
                HStack {
                    statusBadge
                    Spacer()
                    if case .connected = viewModel.callState {
                        timerBadge
                    }
                }
                .padding()

                Spacer()

                HStack {
                    Spacer()
                    localVideoPreview
                        .padding()
                }

                controlBar
            }
        }
    }

    @ViewBuilder
    private var remoteVideoArea: some View {
        if case .connected(_, let participants) = viewModel.callState {
            let remoteParticipants = participants.filter { !$0.isLocal }
            if let remote = remoteParticipants.first {
                VideoPlaceholderView(participant: remote, isProminent: true)
            } else {
                waitingForOthersView
            }
        } else if case .connecting = viewModel.callState {
            VStack(spacing: Spacing.md) {
                ProgressView().tint(.white)
                Text("Connecting…").foregroundStyle(.white)
            }
        }
    }

    private var waitingForOthersView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))
            Text("Waiting for others to join…")
                .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var localVideoPreview: some View {
        if case .connected(_, let participants) = viewModel.callState, let local = participants.first(where: \.isLocal) {
            VideoPlaceholderView(participant: local, isProminent: false, isMirrored: viewModel.isFrontCamera)
                .frame(width: 100, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .stroke(.white.opacity(0.3), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if case .connected(let room, _) = viewModel.callState {
            Text(room.name)
                .font(.metacityCaption)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Capsule().fill(.black.opacity(0.4)))
                .foregroundStyle(.white)
        }
    }

    private var timerBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.red)
            Text(formattedDuration)
                .font(.metacityCaption.monospacedDigit())
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Capsule().fill(.black.opacity(0.4)))
        .foregroundStyle(.white)
    }

    private var formattedDuration: String {
        let minutes = viewModel.elapsedSeconds / 60
        let seconds = viewModel.elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var controlBar: some View {
        HStack(spacing: Spacing.lg) {
            CallControlButton(
                systemImage: isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                accessibilityLabel: isMicrophoneMuted ? "Unmute microphone" : "Mute microphone",
                isActive: !isMicrophoneMuted,
                size: 54
            ) {
                Task { await viewModel.toggleMicrophone() }
            }

            CallControlButton(
                systemImage: viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                accessibilityLabel: viewModel.isSpeakerOn ? "Turn off speaker" : "Turn on speaker",
                isActive: viewModel.isSpeakerOn,
                size: 54
            ) {
                viewModel.toggleSpeaker()
            }

            CallControlButton(
                systemImage: isCameraEnabled ? "video.fill" : "video.slash.fill",
                accessibilityLabel: isCameraEnabled ? "Turn off camera" : "Turn on camera",
                isActive: isCameraEnabled,
                size: 54
            ) {
                Task { await viewModel.toggleCamera() }
            }

            if isCameraEnabled {
                CallControlButton(
                    systemImage: "arrow.triangle.2.circlepath.camera.fill",
                    accessibilityLabel: "Flip camera",
                    size: 54
                ) {
                    viewModel.flipCamera()
                }
            }

            CallControlButton(systemImage: "phone.down.fill", accessibilityLabel: "End call", tint: .metacityDanger, size: 54) {
                Task { await viewModel.leaveCall() }
            }
        }
        .padding(.vertical, Spacing.xl)
        .animation(.snappy, value: isCameraEnabled)
    }

    private var isMicrophoneMuted: Bool {
        guard case .connected(_, let participants) = viewModel.callState else { return false }
        return participants.first(where: \.isLocal)?.isMicrophoneMuted ?? false
    }

    private var isCameraEnabled: Bool {
        guard case .connected(_, let participants) = viewModel.callState else { return true }
        return participants.first(where: \.isLocal)?.isCameraEnabled ?? true
    }
}

/// Full-screen ring state — either you're calling someone (`.outgoing`, shows "Cancel") or someone
/// is calling you (`.incoming`, shows "Decline"/"Accept"). A pulsing ring behind the avatar is the
/// only thing standing in for a real ringtone/vibration, which a Simulator can't demonstrate anyway.
private struct RingingView: View {
    enum Role { case outgoing, incoming }

    let contact: CallContact
    let mode: CallMode
    let role: Role
    let onDecline: () -> Void
    var onAccept: (() -> Void)?

    @State private var isPulsing = false

    init(contact: CallContact, mode: CallMode, role: Role, onDecline: @escaping () -> Void, onAccept: (() -> Void)? = nil) {
        self.contact = contact
        self.mode = mode
        self.role = role
        self.onDecline = onDecline
        self.onAccept = onAccept
    }

    var body: some View {
        VStack(spacing: Spacing.xxxl) {
            Spacer()

            VStack(spacing: Spacing.lg) {
                ZStack {
                    Circle()
                        .stroke(Color.metacityPrimary.opacity(0.4), lineWidth: 2)
                        .frame(width: isPulsing ? 168 : 112, height: isPulsing ? 168 : 112)
                        .opacity(isPulsing ? 0 : 1)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: isPulsing)

                    Avatar(
                        name: contact.name,
                        size: 112,
                        backgroundColor: contact.isBot ? Color.metacitySuccess.opacity(0.3) : .metacitySurfaceElevated,
                        systemImage: contact.isBot ? "sparkles" : nil
                    )
                }
                .onAppear { isPulsing = true }

                Text(contact.name)
                    .font(.metacityLargeTitle)
                    .foregroundStyle(.white)

                Text(statusText)
                    .font(.metacityBody)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            actions
                .padding(.bottom, Spacing.xxxl)
        }
    }

    private var statusText: String {
        let modeText = mode == .video ? "video call" : "audio call"
        switch role {
        case .outgoing: return "Calling… (\(modeText))"
        case .incoming: return "Incoming \(modeText)"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch role {
        case .outgoing:
            CallControlButton(systemImage: "phone.down.fill", accessibilityLabel: "Cancel call", tint: .metacityDanger, size: 64, action: onDecline)
        case .incoming:
            HStack(spacing: Spacing.xxxl) {
                CallControlButton(systemImage: "phone.down.fill", accessibilityLabel: "Decline call", tint: .metacityDanger, size: 64, action: onDecline)
                CallControlButton(systemImage: "phone.fill", accessibilityLabel: "Accept call", tint: .metacitySuccess, size: 64) {
                    onAccept?()
                }
            }
        }
    }
}

/// Stand-in for a real video frame. In production this is where you'd mount Twilio's `VideoView`,
/// Agora's `AgoraRtcVideoCanvas`, or a WebRTC `RTCMTLVideoView` via `UIViewRepresentable` — see the
/// architecture notes for how `CallService` makes that swap contained to the Data layer.
private struct VideoPlaceholderView: View {
    let participant: CallParticipant
    let isProminent: Bool
    var isMirrored: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.metacityPrimary.opacity(0.6), .black], startPoint: .top, endPoint: .bottom)

            if participant.isCameraEnabled {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: isProminent ? 70 : 36))
                        .foregroundStyle(.white.opacity(0.9))
                        .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
                    if isProminent {
                        Text(participant.displayName)
                            .font(.metacityBody)
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: isProminent ? 40 : 22))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if participant.isMicrophoneMuted {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "mic.slash.fill")
                            .font(.caption)
                            .padding(6)
                            .background(Circle().fill(.black.opacity(0.5)))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [participant.isLocal ? "You" : participant.displayName]
        parts.append(participant.isCameraEnabled ? "camera on" : "camera off")
        if participant.isMicrophoneMuted { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

private struct CallControlButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isActive: Bool = true
    var tint: Color = .white
    var size: CGFloat = 60
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.37, weight: .semibold))
                .foregroundStyle(backgroundFill == .white ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background(backgroundFill, in: Circle())
        }
        .buttonStyle(PressableScaleStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var backgroundFill: Color {
        if tint == .metacityDanger { return .metacityDanger }
        if tint == .metacitySuccess { return .metacitySuccess }
        return isActive ? Color.white.opacity(0.25) : .white
    }
}

#Preview {
    let service = MockCallService()
    InCallView(viewModel: CallViewModel(callService: service, joinCallUseCase: JoinCallUseCase(callService: service)))
}
