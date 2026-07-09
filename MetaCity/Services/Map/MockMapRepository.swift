import Foundation

/// Serves exactly the 5 Jakarta districts MetaCity actually has real, OpenStreetMap-derived 3D
/// coverage for (see `MetaCity/Resources/Districts/*.json`) — real coordinates, real history,
/// each one routable straight into its `DistrictRealityView`/AR experience via `districtName`.
/// `coordinate`/`radiusMeters` are accepted (required by `MapRepository`) but intentionally
/// unused: the app is Jakarta-only for now, so there's nothing to filter by proximity yet. Swap
/// for a real places API later behind the same protocol — see the architecture notes for swap points.
final class MockMapRepository: MapRepository {
    private static let landmarks: [PlaceAnnotationItem] = [
        PlaceAnnotationItem(
            id: "jakarta-bundaran-hi",
            title: "Bundaran HI",
            subtitle: "Jakarta's landmark roundabout, gateway to the Sudirman-Thamrin tower corridor",
            coordinate: Coordinate(latitude: -6.1954, longitude: 106.8230),
            category: .monument
        ),
        PlaceAnnotationItem(
            id: "jakarta-kota-tua",
            title: "Kota Tua",
            subtitle: "Dutch colonial-era old town square, museums lining the historic harbor",
            coordinate: Coordinate(latitude: -6.1352, longitude: 106.8133),
            category: .museum
        ),
        PlaceAnnotationItem(
            id: "jakarta-kemang",
            title: "Jalan Kemang Raya",
            subtitle: "South Jakarta's expat-popular dining and nightlife strip",
            coordinate: Coordinate(latitude: -6.2605, longitude: 106.8134),
            category: .monument
        ),
        PlaceAnnotationItem(
            id: "jakarta-menteng",
            title: "Taman Suropati",
            subtitle: "Menteng's leafy diplomatic quarter — embassies and tree-lined Dutch garden-city streets",
            coordinate: Coordinate(latitude: -6.1975, longitude: 106.8326),
            category: .nature
        ),
        PlaceAnnotationItem(
            id: "jakarta-ancol",
            title: "Taman Impian Jaya Ancol",
            subtitle: "Jakarta Bay's beachfront recreation park, home to Dunia Fantasi",
            coordinate: Coordinate(latitude: -6.1225, longitude: 106.8340),
            category: .nature
        )
    ]

    func fetchNearbyPlaces(around coordinate: Coordinate, radiusMeters: Double) async throws -> [PlaceAnnotationItem] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return Self.landmarks
    }

    func fetchRoute(from start: Coordinate, to end: Coordinate) async throws -> [Coordinate] {
        try await Task.sleep(nanoseconds: 200_000_000)
        let steps = 12
        return (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            // A gentle sine curve rather than a straight line, just to demonstrate a non-trivial polyline overlay.
            let curveOffset = sin(fraction * .pi) * 0.0015
            return Coordinate(
                latitude: start.latitude + (end.latitude - start.latitude) * fraction + curveOffset,
                longitude: start.longitude + (end.longitude - start.longitude) * fraction
            )
        }
    }
}
