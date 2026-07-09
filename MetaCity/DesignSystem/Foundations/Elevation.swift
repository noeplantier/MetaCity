import SwiftUI

/// Apple-style elevation is *very* subtle — low opacity, generous blur, almost no offset. Two
/// levels are enough for this app: `soft` for resting cards, `raised` for anything that should
/// feel like it's floating above the surface (the in-call status badge, a future sheet/modal).
enum Elevation {
    case soft
    case raised

    fileprivate var opacity: Double {
        switch self {
        case .soft: return 0.06
        case .raised: return 0.14
        }
    }

    fileprivate var radius: CGFloat {
        switch self {
        case .soft: return 10
        case .raised: return 20
        }
    }

    fileprivate var y: CGFloat {
        switch self {
        case .soft: return 2
        case .raised: return 8
        }
    }
}

extension View {
    /// Dark mode already has enough depth from the background/surface tokens alone, so the shadow
    /// only renders in light mode — a dark shadow on a near-black background is invisible anyway,
    /// and skipping it there is one less layer for SwiftUI to composite.
    func elevation(_ level: Elevation) -> some View {
        modifier(ElevationModifier(level: level))
    }
}

private struct ElevationModifier: ViewModifier {
    let level: Elevation
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.shadow(
            color: .black.opacity(colorScheme == .dark ? 0 : level.opacity),
            radius: level.radius,
            x: 0,
            y: level.y
        )
    }
}
