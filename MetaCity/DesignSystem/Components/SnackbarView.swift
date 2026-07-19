import SwiftUI

/// Lightweight, auto-dismissing banner for non-blocking notices (e.g. "Call disconnected"), used
/// as an alternative to the blocking `.errorAlert` when the user shouldn't be interrupted.
struct SnackbarView: View {
    let message: String
    var style: Style = .error

    enum Style {
        case error, success, info

        var color: Color {
            switch self {
            case .error: return .metacityDanger
            case .success: return .metacitySuccess
            case .info: return .metacityPrimary
            }
        }

        var systemImage: String {
            switch self {
            case .error: return "exclamationmark.triangle.fill"
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: style.systemImage)
            Text(message)
                .font(.metacitySubheadline)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .background(style.color, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .foregroundStyle(.white)
        .elevation(.raised)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

struct SnackbarMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let style: SnackbarView.Style

    static func == (lhs: SnackbarMessage, rhs: SnackbarMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// Attaches a snackbar that fades in/out at the bottom of the view whenever `message` is non-nil,
/// auto-dismissing after `duration` seconds.
private struct SnackbarModifier: ViewModifier {
    @Binding var message: SnackbarMessage?
    var duration: TimeInterval = 2.5

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                SnackbarView(message: message.text, style: message.style)
                    .padding(.bottom, Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message.id) {
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        self.message = nil
                    }
            }
        }
        .animation(Motion.spring, value: message?.id)
    }
}

extension View {
    func snackbar(_ message: Binding<SnackbarMessage?>, duration: TimeInterval = 2.5) -> some View {
        modifier(SnackbarModifier(message: message, duration: duration))
    }
}
