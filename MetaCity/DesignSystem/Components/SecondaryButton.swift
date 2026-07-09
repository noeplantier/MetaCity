import SwiftUI

/// A quieter alternative to `PrimaryButton` for actions that shouldn't compete with the screen's
/// main CTA (e.g. "Cycle color", "Reset camera", "Continue with Google"). Outlined rather than
/// filled, so it stays in the app's neutral palette instead of adding another loud color — this
/// also happens to match Google's own "light" sign-in button guidelines, which is why the Google
/// button in `AuthView` reuses this instead of a one-off view.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isFullWidth: Bool = false
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if isLoading {
                    ProgressView()
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.metacityHeadline)
            }
            .frame(maxWidth: isFullWidth ? .infinity : nil, minHeight: 44)
            .padding(.horizontal, Spacing.lg)
            .foregroundStyle(Color.metacityTextPrimary.opacity(isEnabled ? 1 : 0.4))
            .background(Color.metacitySurfaceElevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.metacityBorder, lineWidth: 1)
            )
        }
        .buttonStyle(PressableScaleStyle())
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(title)
    }
}

#Preview {
    VStack(spacing: Spacing.md) {
        SecondaryButton(title: "Reset camera", systemImage: "arrow.counterclockwise", action: {})
        SecondaryButton(title: "Continue with Google", systemImage: "g.circle.fill", isFullWidth: true, action: {})
        SecondaryButton(title: "Continue with Google", isFullWidth: true, isLoading: true, action: {})
    }
    .padding()
    .background(Color.metacityBackground)
}
