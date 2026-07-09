import SwiftUI

/// Animation curves used across the app. Centralizing these means "make it feel less bouncy"
/// is a one-file change, and it keeps every screen feeling like the same product.
/// Apple's HIG asks for motion that's fluid but not attention-seeking — short durations, gentle
/// easing, minimal bounce.
enum Motion {
    /// Micro-interactions: press states, toggles.
    static let quick = Animation.easeOut(duration: 0.18)
    /// Layout/content changes: showing an error, swapping an empty state for content.
    static let standard = Animation.easeInOut(duration: 0.28)
    /// Larger transitions: camera moves, sheet-like presentations.
    static let spring = Animation.spring(duration: 0.45, bounce: 0.15)
}

/// Shared press feedback for every tappable control (buttons, icon buttons). Scaling + fading the
/// label on press is cheap (no extra @State/@GestureState, SwiftUI gives us `isPressed` for free)
/// and reads as "premium" without being showy.
struct PressableScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}
