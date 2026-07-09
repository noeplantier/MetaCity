import Foundation

/// MetaCity is Jakarta-only for now (Surabaya/Bandung and the old per-city artistic skyline were
/// removed — see CLAUDE.md). Trimmed to exactly what's used: `displayName`/`tagline` and the
/// `CaseIterable`/`Codable`/`Identifiable`/`Hashable` conformances were all dead weight (zero call
/// sites anywhere in the app, confirmed before removing them) now that nothing iterates, encodes,
/// or displays a city list — there's only ever one. Kept as a type at all, rather than inlining
/// the coordinate as a constant, only because `.centerCoordinate` is genuinely reused and a named
/// seam is one line to extend if another city is ever added back.
enum IndonesianCity {
    case jakarta

    /// Default Map camera center — the centroid of the curated landmark cluster, not Jakarta's
    /// literal geographic center, so the Map tab opens with several real pins already on screen.
    var centerCoordinate: Coordinate {
        switch self {
        case .jakarta: Coordinate(latitude: -6.1747, longitude: 106.8254)
        }
    }
}
