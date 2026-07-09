import MapKit
import UIKit

/// Generates and caches `MKMapSnapshotter` satellite thumbnails for city callout cards.
/// Each city gets one snapshot (hybrid satellite + road labels, pitch-0 overhead) sized at
/// 340 × 108 pt, loaded lazily on first request and never re-generated within an app session.
actor CityThumbnailCache {
    static let shared = CityThumbnailCache()
    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func thumbnail(for city: CityEntry) async -> UIImage? {
        if let hit = cache[city.id] { return hit }
        // Coalesce concurrent callers behind a single in-flight task.
        if let task = inFlight[city.id] { return await task.value }

        let task = Task<UIImage?, Never> {
            await generateSnapshot(for: city)
        }
        inFlight[city.id] = task
        let result = await task.value
        inFlight.removeValue(forKey: city.id)
        if let result { cache[city.id] = result }
        return result
    }

    private func generateSnapshot(for city: CityEntry) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.camera = MKMapCamera(
            lookingAtCenter: city.anchor.clLocationCoordinate,
            fromDistance: city.mapZoomRadius * 1.8,
            pitch: 0,
            heading: 0
        )
        options.size = CGSize(width: 340, height: 108)
        options.mapType = .hybrid
        options.showsBuildings = true

        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start { snapshot, _ in
                continuation.resume(returning: snapshot?.image)
            }
        }
    }
}
