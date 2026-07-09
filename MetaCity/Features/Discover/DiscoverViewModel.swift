import Combine
import CoreLocation
import MapKit
import SwiftUI

/// Identifiable tuple used by `ForEach` to render one `VenueMapPin` per featured POI
/// when the user has a city focused on the world map.
struct VenuePOIPin: Identifiable {
    let poi: CangguPOI
    let district: DistrictEntry
    let city: CityEntry
    var id: String { poi.id }
}

/// A single result from the in-scene district search bar — either a named building or a POI.
struct DistrictSearchResult: Identifiable {
    enum Kind { case building(BuildingFootprint), poi(CangguPOI) }
    let id: String
    let name: String
    let subtitle: String?
    let kind: Kind
    /// Model-local position in metres from the district anchor — used to fly the camera.
    let localCentroid: SIMD3<Float>
}

@MainActor
final class DiscoverViewModel: ObservableObject {

    // MARK: - State machine

    enum ExploreState: Equatable {
        case worldMap
        case cityFocused(CityEntry)
        case districtExplore(CityEntry, DistrictEntry)

        static func == (lhs: ExploreState, rhs: ExploreState) -> Bool {
            switch (lhs, rhs) {
            case (.worldMap, .worldMap): return true
            case (.cityFocused(let a), .cityFocused(let b)): return a.id == b.id
            case (.districtExplore(let a, let d), .districtExplore(let b, let e)):
                return a.id == b.id && d.id == e.id
            default: return false
            }
        }
    }

    @Published private(set) var state: ExploreState = .worldMap
    @Published var cameraPosition: MapCameraPosition

    // District 3D inspector controls — owned here so the values survive
    // back-and-forth navigation without resetting every time.
    @Published var isNightMode = false
    // Auto-rotation is off by default. Users orbit manually with a pan gesture.
    @Published var isAutoRotating = false
    @Published var rotationSpeed: Double = 1.0
    /// When true the orbit camera pulls back to 2.2× default distance for a wider
    /// city-overview framing. Toggle via the Overview button in DistrictControlsPanel.
    @Published var isElevated: Bool = false
    /// Bumped by `resetCamera()`. `DistrictRealityView` observes changes and flies the
    /// camera back to the default orbit position without requiring a gesture.
    @Published private(set) var cameraResetToken: Int = 0
    /// The building the user last tapped — drives the building info card overlay when no POI matches.
    @Published private(set) var selectedBuilding: BuildingFootprint? = nil
    /// The POI the user last selected — drives the VenueCard overlay and triggers flyTo.
    @Published private(set) var selectedVenuePOI: CangguPOI? = nil
    /// POI id to fly the camera to. Setting this to a non-nil value signals the coordinator
    /// to compute the approach position from the POI's lat/lon + approachBearing and call flyCamera.
    /// Set back to nil when the venue is dismissed — coordinator returns to orbit.
    @Published private(set) var venueTargetPOIId: String? = nil
    // MARK: - District search bar
    /// Live query text from the search bar overlay. Two characters minimum before results appear.
    @Published var districtSearchQuery: String = ""
    /// Incremented on each `selectSearchResult(_:)` call so `DistrictRealityView` detects a
    /// new fly-to request even when the target centroid coordinates are unchanged.
    @Published private(set) var searchFlyToken: Int = 0
    /// Last selected search result's model-local centroid (metres from district anchor).
    @Published private(set) var searchFlyCentroid: SIMD3<Float> = .zero

    let manifest: CityManifest

    // Geographic center of all 10 city pins (lon 98.67–119.43, lat -8.67 to +3.60).
    // Midpoint: ~(-2.5, 109.0). Distance 4.8M keeps Medan top-left and Makassar right
    // both in frame while Java (Jakarta at bottom-left) stays visible.
    private static let indonesiaCamera = MapCamera(
        centerCoordinate: CLLocationCoordinate2D(latitude: -2.5, longitude: 109.0),
        distance: 4_800_000,
        heading: 0,
        pitch: 0
    )

    init(manifest: CityManifest = .shared) {
        self.manifest = manifest
        self.cameraPosition = .camera(DiscoverViewModel.indonesiaCamera)
        applyUITestOverrides(manifest: manifest)
    }

    /// Launch-flag overrides for `simctl launch` + `simctl io screenshot` visual verification
    /// without tap simulation. Three variants:
    /// - `UITEST_OPEN_CITY=<cityId>` → jumps to `cityFocused` (zooms map to city, shows district callout)
    /// - `UITEST_OPEN_DISTRICT=<districtId>` → jumps to `districtExplore` (shows full mesh)
    /// - `UITEST_NIGHT_MODE=1` → enables night mode immediately (avoids Toggle tap automation,
    ///   which is unreliable on this Simulator build — see CLAUDE.md / iOS Simulator quirks memory)
    private func applyUITestOverrides(manifest: CityManifest) {
        let env = ProcessInfo.processInfo.environment
        if env["UITEST_NIGHT_MODE"] == "1" { isNightMode = true }
        if let cityID = env["UITEST_OPEN_CITY"],
           let city = manifest.allCities.first(where: { $0.id == cityID }) {
            state = .cityFocused(city)
            cameraPosition = .camera(MapCamera(
                centerCoordinate: city.anchor.clLocationCoordinate,
                distance: city.mapZoomRadius, heading: 0, pitch: 15))
            return
        }
        if let districtID = env["UITEST_OPEN_DISTRICT"],
           let district = manifest.allDistricts.first(where: { $0.id == districtID }),
           let city = manifest.allCities.first(where: { $0.districts.contains(where: { $0.id == district.id }) }) {
            state = .districtExplore(city, district)
            return
        }
        // Default: open Bali on every cold launch (no UITEST override active)
        if let bali = manifest.allCities.first(where: { $0.id == "denpasar" }) {
            state = .cityFocused(bali)
            cameraPosition = .camera(MapCamera(
                centerCoordinate: bali.anchor.clLocationCoordinate,
                distance: bali.mapZoomRadius, heading: 0, pitch: 15))
        }
    }

    // MARK: - Derived

    var showingMap: Bool {
        switch state {
        case .worldMap, .cityFocused: return true
        case .districtExplore: return false
        }
    }

    var focusedCity: CityEntry? {
        switch state {
        case .cityFocused(let c), .districtExplore(let c, _): return c
        default: return nil
        }
    }

    var selectedDistrict: DistrictEntry? {
        if case .districtExplore(_, let d) = state { return d }
        return nil
    }

    /// Featured POI pins for the map layer — only populated in `cityFocused` state so the
    /// city map is zoomed in enough for pins to be tappable and legible.
    var featuredPOIsForMap: [VenuePOIPin] {
        guard case .cityFocused(let city) = state else { return [] }
        return city.districts.flatMap { district -> [VenuePOIPin] in
            guard district.dataBundled,
                  let collection = CangguPOICollection.load(for: district.id)
            else { return [] }
            return collection.pois
                .filter { $0.isFeatured }
                .map { VenuePOIPin(poi: $0, district: district, city: city) }
        }
    }

    // MARK: - Navigation

    func selectCity(_ city: CityEntry) {
        // Clear all sub-selection so a new city starts with a clean slate
        selectedBuilding = nil
        selectedVenuePOI = nil
        venueTargetPOIId = nil
        districtSearchQuery = ""
        state = .cityFocused(city)
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: city.anchor.clLocationCoordinate,
                distance: city.mapZoomRadius,
                heading: 0,
                pitch: 15
            ))
        }
    }

    /// No longer transitions to a separate cityExplore page — districts are directly visible
    /// on the map via `districtPins` annotations. Zooms the map tighter to the city so district
    /// pins are legible and tappable, then dismisses the city callout.
    func enterCity(_ city: CityEntry) {
        withAnimation(.easeInOut(duration: 0.5)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: city.anchor.clLocationCoordinate,
                distance: city.mapZoomRadius * 0.5,
                heading: 0,
                pitch: 20
            ))
            state = .worldMap
        }
    }

    func resetCamera() {
        cameraResetToken += 1
    }

    func selectBuilding(_ building: BuildingFootprint) {
        selectedBuilding = building
        selectedVenuePOI = nil
        venueTargetPOIId = nil
    }

    func clearSelectedBuilding() {
        selectedBuilding = nil
        cameraResetToken += 1
    }

    func selectPOIById(_ poiId: String, districtId: String) {
        guard let collection = CangguPOICollection.load(for: districtId) else { return }
        selectedVenuePOI = collection.pois.first { $0.id == poiId }
        selectedBuilding = nil
        venueTargetPOIId = poiId
    }

    func dismissVenue() {
        selectedVenuePOI = nil
        venueTargetPOIId = nil
    }

    // MARK: - Search

    /// Returns up to 8 named buildings + POIs in `district` whose name contains `districtSearchQuery`.
    func searchResults(in district: DistrictEntry) -> [DistrictSearchResult] {
        let q = districtSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var results: [DistrictSearchResult] = []

        if let data = District.load(named: district.id) {
            let buildings: [DistrictSearchResult] = data.buildings.compactMap { b in
                guard let name = b.name, name.lowercased().contains(q), !b.polygon.isEmpty else { return nil }
                let cx = b.polygon.map(\.x).reduce(0, +) / Float(b.polygon.count)
                let cz = b.polygon.map(\.z).reduce(0, +) / Float(b.polygon.count)
                return DistrictSearchResult(
                    id: "b_\(b.osmID ?? name)",
                    name: name,
                    subtitle: b.style.displayName,
                    kind: .building(b),
                    localCentroid: SIMD3(cx, max(b.heightMeters * 0.5, 8), cz)
                )
            }
            results.append(contentsOf: buildings)
        }
        if let col = CangguPOICollection.load(for: district.id),
           let entry = CityManifest.shared.district(id: district.id) {
            let pois: [DistrictSearchResult] = col.pois.compactMap { poi -> DistrictSearchResult? in
                guard poi.name.lowercased().contains(q) else { return nil }
                let offset = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                    .sceneOffset(from: entry.anchor)
                return DistrictSearchResult(
                    id: "p_\(poi.id)",
                    name: poi.name,
                    subtitle: poi.category.rawValue,
                    kind: .poi(poi),
                    localCentroid: SIMD3(offset.x, 5, offset.z)
                )
            }
            results.append(contentsOf: pois)
        }
        return Array(results.prefix(8))
    }

    /// Flies the district 3D camera to `result` and clears the search query.
    func selectSearchResult(_ result: DistrictSearchResult) {
        searchFlyCentroid = result.localCentroid
        searchFlyToken += 1
        districtSearchQuery = ""
    }

    func selectDistrict(_ district: DistrictEntry, in city: CityEntry) {
        // Reset inspector controls to defaults on each new district open so the
        // night/mode state from a previous visit doesn't persist confusingly.
        isNightMode = false
        isAutoRotating = false  // manual orbit — user pans to rotate
        rotationSpeed = 1.0
        isElevated = false
        selectedBuilding = nil
        selectedVenuePOI = nil
        venueTargetPOIId = nil
        withAnimation(.easeInOut(duration: 0.35)) {
            state = .districtExplore(city, district)
        }
    }

    /// Transitions directly from the world map to a district's 3D view with the camera already
    /// flying to the given venue POI. Used when the user taps a `VenueMapPin` on the city map.
    func selectVenuePOI(_ poi: CangguPOI, in district: DistrictEntry, city: CityEntry) {
        isNightMode = false
        isAutoRotating = false
        rotationSpeed = 1.0
        isElevated = false
        selectedBuilding = nil
        selectedVenuePOI = poi
        venueTargetPOIId = poi.id
        withAnimation(.easeInOut(duration: 0.35)) {
            state = .districtExplore(city, district)
        }
    }

    func back() {
        switch state {
        case .districtExplore(let c, _):
            withAnimation(.easeInOut(duration: 0.35)) { state = .cityFocused(c) }
            withAnimation(.easeInOut(duration: 0.5)) {
                cameraPosition = .camera(MapCamera(
                    centerCoordinate: c.anchor.clLocationCoordinate,
                    distance: c.mapZoomRadius,
                    heading: 0,
                    pitch: 15
                ))
            }
        case .cityFocused:
            withAnimation(.easeInOut(duration: 0.5)) {
                state = .worldMap
                cameraPosition = .camera(DiscoverViewModel.indonesiaCamera)
            }
        case .worldMap:
            break
        }
    }
}
