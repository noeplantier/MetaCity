import SwiftUI

/// The app's single circular icon-only button, used for every floating control (map recenter/3D
/// toggle, call mute/camera/end). Consolidating what used to be `MapControlButton` and
/// `CallControlButton` — two near-identical, hand-rolled views — into one component means a future
/// visual tweak happens once, and `accessibilityLabel` is a required parameter so an icon-only
/// button can never accidentally ship without one (VoiceOver would otherwise just read "Button").
struct IconButton: View {
    enum Style {
        case subtle
        case prominent
        case danger
    }

    let systemImage: String
    let accessibilityLabel: String
    var style: Style = .subtle
    /// 44pt is the HIG minimum comfortable touch target; `@ScaledMetric` lets it grow gently with
    /// Dynamic Type instead of staying a fixed pixel size for low-vision users.
    @ScaledMetric var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background, in: Circle())
                .overlay(
                    Circle().strokeBorder(Color.metacityBorder, lineWidth: style == .subtle ? 1 : 0)
                )
        }
        .buttonStyle(PressableScaleStyle())
        .elevation(.soft)
        .accessibilityLabel(accessibilityLabel)
    }

    private var background: Color {
        switch style {
        case .subtle: return .metacitySurfaceElevated
        case .prominent: return .metacityPrimary
        case .danger: return .metacityDanger
        }
    }

    private var foreground: Color {
        switch style {
        case .subtle: return .metacityTextPrimary
        case .prominent, .danger: return .white
        }
    }
}

#Preview {
    HStack(spacing: Spacing.lg) {
        IconButton(systemImage: "location.fill", accessibilityLabel: "Recenter", action: {})
        IconButton(systemImage: "mic.fill", accessibilityLabel: "Mute", style: .prominent, action: {})
        IconButton(systemImage: "phone.down.fill", accessibilityLabel: "End call", style: .danger, action: {})
    }
    .padding()
    .background(Color.metacityBackground)
}
