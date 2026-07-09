import SwiftUI

/// Styling for `TextField`/`SecureField`, applied as a modifier rather than a wrapping view.
/// Wrapping `TextField` in a custom container would break `.focused()`/`.submitLabel()`/`.onSubmit()`
/// forwarding (those only attach to the actual focusable control), so this stays a pure visual
/// layer and the call site keeps full, ordinary control over focus and the submit chain.
private struct AppTextFieldStyle: ViewModifier {
    var icon: String?
    var isFocused: Bool

    func body(content: Content) -> some View {
        HStack(spacing: Spacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(Color.metacityTextTertiary)
                    .frame(width: 20)
            }
            content
        }
        .padding(.horizontal, Spacing.lg)
        .frame(minHeight: 50)
        .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(isFocused ? Color.metacityPrimary : Color.metacityBorder, lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(Motion.quick, value: isFocused)
    }
}

extension View {
    func appTextFieldStyle(icon: String? = nil, isFocused: Bool) -> some View {
        modifier(AppTextFieldStyle(icon: icon, isFocused: isFocused))
    }
}
