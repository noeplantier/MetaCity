import Foundation

/// MetaCity is Jakarta-only for now (Surabaya/Bandung and the old per-city artistic skyline were
/// removed — see CLAUDE.md) — kept as a single-case type rather than deleted outright so the
/// `city`/`centerCoordinate` call sites don't need to change if another city is added later.
enum IndonesianCity: String, CaseIterable, Codable, Identifiable, Hashable {
    case jakarta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jakarta: "Jakarta"
        }
    }

    /// Short, factual hook shown under the city name — not marketing copy.
    var tagline: String {
        switch self {
        case .jakarta: "Indonesia's capital — a dense, high-rise megacity"
        }
    }

    /// Default Map camera center — the centroid of the curated landmark cluster, not Jakarta's
    /// literal geographic center, so the Map tab opens with several real pins already on screen.
    var centerCoordinate: Coordinate {
        switch self {
        case .jakarta: Coordinate(latitude: -6.1747, longitude: 106.8254)
        }
    }
}
