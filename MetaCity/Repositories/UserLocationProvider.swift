import Foundation

/// Wraps CoreLocation behind a Domain-friendly interface so MapViewModel never imports CoreLocation
/// directly — keeps the Presentation/Domain layers testable without a real location manager.
protocol UserLocationProvider: AnyObject {
    var currentCoordinate: Coordinate? { get }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    var locationUpdates: AsyncStream<Coordinate> { get }
}
