import SwiftUI
import UIKit

/// MetaCity's color tokens. Each token is a *dynamic* color with both a light and dark appearance,
/// the way every system color (`.label`, `.systemBackground`, ...) does — but `MetaCityApp` forces
/// `.preferredColorScheme(.dark)` at the root, so in practice only the dark side ever ships: a
/// permanent anthracite-on-white brand look rather than a mode that follows the system setting.
/// The light values are kept (rather than deleted) so SwiftUI previews and any future toggle back
/// to system-following behavior don't need the palette rebuilt from scratch.
///
/// The dark appearance is a soft anthracite (never pure black) for a premium, non-OLED-harsh feel.
/// Accent/success/danger/warning intentionally reuse Apple's own dynamic system color values
/// (systemBlue/Green/Red/Orange) — they're already contrast-vetted by Apple, so there's no reason
/// to reinvent them.
private extension Color {
    init(light: UIColor, dark: UIColor) {
        self = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

extension Color {
    // Surfaces, back to front.
    static let metacityBackground = Color(
        light: UIColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1),
        dark: UIColor(red: 0.051, green: 0.055, blue: 0.063, alpha: 1)
    )
    static let metacitySurface = Color(
        light: UIColor.white,
        dark: UIColor(red: 0.086, green: 0.090, blue: 0.102, alpha: 1)
    )
    static let metacitySurfaceElevated = Color(
        light: UIColor.white,
        dark: UIColor(red: 0.118, green: 0.122, blue: 0.137, alpha: 1)
    )

    // Hairlines.
    static let metacityBorder = Color(
        light: UIColor(red: 0.890, green: 0.890, blue: 0.898, alpha: 1),
        dark: UIColor(red: 0.157, green: 0.157, blue: 0.180, alpha: 1)
    )
    static let metacitySeparator = Color(
        light: UIColor(red: 0.820, green: 0.820, blue: 0.839, alpha: 1),
        dark: UIColor(red: 0.161, green: 0.161, blue: 0.173, alpha: 1)
    )

    // Text, in descending emphasis.
    static let metacityTextPrimary = Color(
        light: UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1),
        dark: UIColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1)
    )
    static let metacityTextSecondary = Color(
        light: UIColor(red: 0.431, green: 0.431, blue: 0.451, alpha: 1),
        dark: UIColor(red: 0.631, green: 0.631, blue: 0.651, alpha: 1)
    )
    static let metacityTextTertiary = Color(
        light: UIColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1),
        dark: UIColor(red: 0.431, green: 0.431, blue: 0.451, alpha: 1)
    )

    // Brand/system accents — same dynamic pairs Apple uses for systemBlue/Green/Red/Orange.
    static let metacityPrimary = Color(
        light: UIColor(red: 0.000, green: 0.478, blue: 1.000, alpha: 1),
        dark: UIColor(red: 0.039, green: 0.518, blue: 1.000, alpha: 1)
    )
    static let metacitySecondary = Color(
        light: UIColor(red: 0.345, green: 0.337, blue: 0.839, alpha: 1),
        dark: UIColor(red: 0.478, green: 0.467, blue: 1.000, alpha: 1)
    )
    static let metacitySuccess = Color(
        light: UIColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1),
        dark: UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)
    )
    static let metacityDanger = Color(
        light: UIColor(red: 1.000, green: 0.231, blue: 0.188, alpha: 1),
        dark: UIColor(red: 1.000, green: 0.271, blue: 0.227, alpha: 1)
    )
    static let metacityWarning = Color(
        light: UIColor(red: 1.000, green: 0.584, blue: 0.000, alpha: 1),
        dark: UIColor(red: 1.000, green: 0.624, blue: 0.039, alpha: 1)
    )
}
