import Foundation

/// Domain-level coordinate. The Domain layer deliberately avoids importing CoreLocation/MapKit so
/// it stays framework-agnostic; Presentation and Data convert to/from CLLocationCoordinate2D at the edges.
struct Coordinate: Equatable, Hashable, Codable {
    let latitude: Double
    let longitude: Double
}
