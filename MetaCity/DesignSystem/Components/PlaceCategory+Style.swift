import SwiftUI

/// Presentation-only styling for `PlaceCategory`, kept out of `Models` so that layer stays
/// framework-agnostic. Both the Map markers and Explore's landmark rows share this mapping —
/// previously duplicated in each view, now defined once.
extension PlaceCategory {
    var systemImage: String {
        switch self {
        case .monument: return "building.columns.fill"
        case .religious: return "building.2.crop.circle.fill"
        case .museum: return "building.fill"
        case .bridge: return "road.lanes"
        case .nature: return "mountain.2.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .monument: return .metacityPrimary
        case .religious: return .metacitySecondary
        case .museum: return .metacityWarning
        case .bridge: return .metacityDanger
        case .nature: return .metacitySuccess
        }
    }
}
