import SwiftUI

/// A full-area, premium loading placeholder — centered, generously spaced, optionally captioned.
/// Use this instead of a bare `ProgressView()` wherever a screen needs to communicate "working on
/// it" rather than just "something is technically loading".
struct LoadingStateView: View {
    var message: String? = nil

    var body: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.metacityTextSecondary)
            if let message {
                Text(message)
                    .font(.metacitySubheadline)
                    .foregroundStyle(Color.metacityTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    LoadingStateView(message: "Connecting…")
        .background(Color.metacityBackground)
}
