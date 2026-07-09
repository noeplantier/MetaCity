import CoreLocation
import Foundation

/// Concrete CoreLocation-backed implementation of `UserLocationProvider`. This is the only file in
/// the app that imports CoreLocation directly — everything else talks to the `Coordinate` domain type.
final class CoreLocationProvider: NSObject, UserLocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let continuation: AsyncStream<Coordinate>.Continuation
    let locationUpdates: AsyncStream<Coordinate>

    private(set) var currentCoordinate: Coordinate?

    override init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Coordinate.self)
        self.locationUpdates = stream
        self.continuation = continuation
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdatingLocation() {
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        currentCoordinate = coordinate
        continuation.yield(coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Production: surface this through a dedicated error stream. The mock map data keeps the
        // UI usable even if location permission is denied, so we swallow the error here.
    }
}
