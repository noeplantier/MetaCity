import SwiftUI

/// A premium empty state: icon, title, supporting copy, and an optional single action — generous
/// padding so it reads as a deliberate design moment rather than "we forgot to handle this case".
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.metacityTextTertiary)
                .padding(.bottom, Spacing.xs)
                .accessibilityHidden(true)

            Text(title)
                .font(.metacityHeadline)
                .foregroundStyle(Color.metacityTextPrimary)

            Text(message)
                .font(.metacitySubheadline)
                .foregroundStyle(Color.metacityTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                SecondaryButton(title: actionTitle, action: action)
                    .padding(.top, Spacing.md)
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    EmptyStateView(
        systemImage: "phone.down.circle",
        title: "No rooms yet",
        message: "Start a call above to create the first room.",
        actionTitle: nil,
        action: nil
    )
    .background(Color.metacityBackground)
}
