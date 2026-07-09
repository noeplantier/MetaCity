import Foundation

/// Abstraction over "where are interesting places, and how do I get there". Swap the mock for a
/// real places/directions backend (your own API, Mapbox, Google Places, ...) later — see Data/Map.
protocol MapRepository {
    func fetchNearbyPlaces(around coordinate: Coordinate, radiusMeters: Double) async throws -> [PlaceAnnotationItem]
    func fetchRoute(from start: Coordinate, to end: Coordinate) async throws -> [Coordinate]
}
