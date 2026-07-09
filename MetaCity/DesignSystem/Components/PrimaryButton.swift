import SwiftUI

/// The app's single call-to-action button. Same public API as before a deliberate choice — every
/// screen that already uses `PrimaryButton` gets the new look for free, no call-site changes.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.metacityHeadline)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(
                isEnabled ? Color.metacityPrimary : Color.metacityPrimary.opacity(0.35),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
        }
        .buttonStyle(PressableScaleStyle())
        .disabled(!isEnabled || isLoading)
        .animation(Motion.quick, value: isEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(isLoading ? "Loading" : "")
    }
}

#Preview {
    VStack(spacing: Spacing.lg) {
        PrimaryButton(title: "Continue", action: {})
        PrimaryButton(title: "Joining…", isLoading: true, action: {})
        PrimaryButton(title: "Disabled", isEnabled: false, action: {})
    }
    .padding()
    .background(Color.metacityBackground)
}
