import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class MapViewModel: ObservableObject {
    @Published var cameraPosition: MapCameraPosition
    @Published var places: [PlaceAnnotationItem] = []
    @Published var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published var is3DEnabled = false
    @Published var presentedError: IdentifiableError?
    /// The place the user tapped on the map — drives the bottom callout card (title/subtitle +
    /// "View in AR"). `nil` when no pin is focused.
    @Published var selectedPlace: PlaceAnnotationItem?

    private let mapRepository: MapRepository
    private let locationProvider: UserLocationProvider
    private let selectionStore: AppSelectionStore
    /// Tracks whatever the camera is currently centered on (the Jakarta cluster, a selected
    /// place, or the user's real location) so `toggle3DPerspective` re-pitches *that* view
    /// instead of re-deriving a coordinate from scratch and potentially jumping somewhere else.
    private var currentCenterCoordinate: Coordinate

    /// MetaCity's whole premise is Indonesian cities, so the map opens on the curated Jakarta
    /// landmark cluster (Monas/Istiqlal/Bundaran HI/Menteng) and *stays there* — it deliberately
    /// does not auto-jump to the device's real/simulated GPS location on launch the way a generic
    /// maps app would, since that location could be anywhere on Earth and has nothing to do with
    /// what this app is for. "Center on me" (`recenterOnUser`) remains available as an explicit,
    /// user-initiated action for whoever actually wants their real position.
    private let fallbackCoordinate = IndonesianCity.jakarta.centerCoordinate

    init(mapRepository: MapRepository, locationProvider: UserLocationProvider, selectionStore: AppSelectionStore) {
        self.mapRepository = mapRepository
        self.locationProvider = locationProvider
        self.selectionStore = selectionStore
        self.currentCenterCoordinate = fallbackCoordinate
        self.cameraPosition = .camera(
            // Wide enough to show several real landmarks on first open, not just one.
            MapCamera(centerCoordinate: fallbackCoordinate.clLocationCoordinate, distance: 5500, heading: 0, pitch: 0)
        )
    }

    func onAppear() {
        locationProvider.requestWhenInUseAuthorization()
        locationProvider.startUpdatingLocation()
        Task { await loadPlaces(around: fallbackCoordinate) }
    }

    private func loadPlaces(around coordinate: Coordinate) async {
        do {
            places = try await mapRepository.fetchNearbyPlaces(around: coordinate, radiusMeters: 1500)
            if let firstPlace = places.first {
                let route = try await mapRepository.fetchRoute(from: coordinate, to: firstPlace.coordinate)
                routeCoordinates = route.map(\.clLocationCoordinate)
            }
        } catch {
            presentedError = IdentifiableError(underlyingError: error)
        }
    }

    func recenterOnUser() {
        guard let coordinate = locationProvider.currentCoordinate else { return }
        selectedPlace = nil
        centerCamera(on: coordinate)
    }

    /// Tapping a pin selects it (shows the callout card) and recenters precisely on it — a much
    /// tighter, landmark-appropriate zoom than the generic "near the user" distance, with the same
    /// pitch/heading the 3D toggle already uses so the camera stays visually consistent.
    func select(_ place: PlaceAnnotationItem) {
        selectedPlace = place
        currentCenterCoordinate = place.coordinate
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: place.coordinate.clLocationCoordinate,
                    distance: is3DEnabled ? 350 : 600,
                    heading: is3DEnabled ? 45 : 0,
                    pitch: is3DEnabled ? 60 : 0
                )
            )
        }
    }

    func clearSelection() {
        selectedPlace = nil
    }

    /// "View in AR": tells the shared selection store which place to focus and requests the AR
    /// tab — `ARViewModel` picks up `selectedPlace` and resolves it to the right `ARLocation`.
    func viewSelectedPlaceInAR() {
        guard let selectedPlace else { return }
        selectionStore.focus(on: selectedPlace, andSwitchTo: .ar)
    }

    /// Toggles between a flat top-down view and a pitched "3D" perspective by animating the
    /// camera's pitch/heading/distance together — this is what gives the illusion of a 3D map.
    /// Re-pitches whatever the camera is *already* centered on, rather than recomputing a
    /// coordinate from scratch (which previously could silently jump the view to the device's
    /// real/simulated GPS location instead of staying wherever the user actually was looking).
    func toggle3DPerspective() {
        is3DEnabled.toggle()
        centerCamera(on: currentCenterCoordinate)
    }

    private func centerCamera(on coordinate: Coordinate) {
        currentCenterCoordinate = coordinate
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: coordinate.clLocationCoordinate,
                    distance: is3DEnabled ? 600 : 1200,
                    heading: is3DEnabled ? 45 : 0,
                    pitch: is3DEnabled ? 60 : 0
                )
            )
        }
    }
}

extension Coordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
