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

<<<<<<< HEAD
/// 2-preset camera view selector — OVERVIEW is the default bird's-eye orbit;
/// POI activates the points-of-interest panel in the mini-map widget.
/// (SURVOL / `.ciel` removed 2026-07-21 — its overhead framing is now .overview's default position
/// and the magenta-pink shibuyaNeon sky it exposed has been replaced with a day-blue gradient.)
enum ViewPreset: String, CaseIterable {
    case overview // OVERVIEW — bird's-eye at ~61°, districtDistance×0.60
    case focus    // POI — reveals the district's landmark list; camera stays at overview

    var label: String {
        switch self {
        case .overview: return "OVERVIEW"
        case .focus:    return "POI"
=======
/// 3-preset camera view selector — controls which camera mode the district 3D inspector is in.
/// OVERVIEW is the default bird's-eye; CLOSE DISTRICT is a tighter framing of the district;
/// POI is entered via POI tap and frames the selected point of interest.
enum ViewPreset: String, CaseIterable {
    case overview     // OVERVIEW — bird's-eye at ~61°, districtDistance×0.60
    case closeDistrict // CLOSE DISTRICT — tighter district framing, districtExtent×0.50 horiz, ×0.90 height
    case poi          // POI — frames selected POI with context

    var label: String {
        switch self {
        case .overview:      return "OVERVIEW"
        case .closeDistrict: return "QUARTIER"
        case .poi:           return "POI"
>>>>>>> origin/main
        }
    }

    var icon: String {
        switch self {
<<<<<<< HEAD
        case .overview: return "viewfinder"
        case .focus:    return "mappin.and.ellipse"
=======
        case .overview:      return "viewfinder"
        case .closeDistrict: return "map.fill"
        case .poi:           return "mappin.circle.fill"
>>>>>>> origin/main
        }
    }
}

/// Data surfaced on the first-entry district reveal overlay (auto-dismissed after 3s).
struct DistrictRevealContext {
    let city: CityEntry
    let district: DistrictEntry
    let buildingCount: Int
    let roadCount: Int
    let activityCount: Int
}

/// A world-city autocomplete suggestion from MKLocalSearchCompleter.
struct WorldCitySuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    /// True if this suggestion matches one of the 5 vitrine cities with bundled 3D data.
    let isVitrine: Bool
    /// Non-nil only when `isVitrine` is true and the city is in CityManifest.
    let matchedCity: CityEntry?
}

/// Delegate bridge so MKLocalSearchCompleter (NSObjectProtocol) can be owned by a @MainActor class.
private final class SearchCompleterBridge: NSObject, MKLocalSearchCompleterDelegate {
    var onResults: ([MKLocalSearchCompletion]) -> Void = { _ in }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onResults(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

/// A result from the global map search (cities, districts, buildings, POIs across all data).
struct GlobalSearchResult: Identifiable {
    enum Kind {
        case city(CityEntry)
        case district(DistrictEntry, CityEntry)
        case building(BuildingFootprint, DistrictEntry, CityEntry)
        case poi(CangguPOI, DistrictEntry, CityEntry)
    }
    let id: String
    let name: String
    let subtitle: String
    let icon: String
    let kind: Kind
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
    @Published var activeViewPreset: ViewPreset = .overview
    @Published var isAutoRotating = false
    @Published var rotationSpeed: Double = 1.0
    /// Bumped by `resetCamera()`. `DistrictRealityView` observes changes and flies the
    /// camera back to the default orbit position without requiring a gesture.
    @Published private(set) var cameraResetToken: Int = 0
    /// Bumped by `setViewPreset(.poi)` when a POI is already selected.
    /// Signals the coordinator to re-trigger `flyToVenue` for the current POI.
    @Published private(set) var poiFocusToken: Int = 0
    /// Bumped by `startBuildingOrbit()`. Signals the 3D coordinator to begin a smooth
    /// 360° orbit around the currently inspected building.
    @Published private(set) var buildingOrbitToken: Int = 0
    /// The building the user last tapped — drives the building info card overlay when no POI matches.
    @Published private(set) var selectedBuilding: BuildingFootprint? = nil
    /// The POI the user last selected — drives the VenueCard overlay and triggers flyTo.
    @Published private(set) var selectedVenuePOI: CangguPOI? = nil
    /// POI id to fly the camera to. Setting this to a non-nil value signals the coordinator
    /// to compute the approach position from the POI's lat/lon + approachBearing and call flyCamera.
    /// Set back to nil when the venue is dismissed — coordinator returns to orbit.
    @Published private(set) var venueTargetPOIId: String? = nil
    // MARK: - First-entry district reveal
    /// Non-nil only during the 3s wow-moment window after a district is opened for the first time.
    /// Keyed by `reveal_<districtId>` in UserDefaults so it only shows once per install.
    @Published private(set) var districtRevealContext: DistrictRevealContext? = nil
    // MARK: - District search bar
    /// Live query text from the search bar overlay. Two characters minimum before results appear.
    @Published var districtSearchQuery: String = ""
    /// Incremented on each `selectSearchResult(_:)` call so `DistrictRealityView` detects a
    /// new fly-to request even when the target centroid coordinates are unchanged.
    @Published private(set) var searchFlyToken: Int = 0
    /// Last selected search result's model-local centroid (metres from district anchor).
    @Published private(set) var searchFlyCentroid: SIMD3<Float> = .zero

    // MARK: - Global map search bar
    @Published var globalSearchQuery: String = ""
    @Published var isGlobalSearchActive: Bool = false
    /// True while the speech recogniser is listening for voice input.
    @Published var isListening: Bool = false
    /// World-city autocomplete suggestions from MKLocalSearchCompleter.
    @Published private(set) var worldCitySuggestions: [WorldCitySuggestion] = []

    /// Cities with bundled 3D data that match `globalSearchQuery` from the very first character.
    /// Purely local — zero network, zero debounce. Used as the top "VILLES 3D" section of
    /// GlobalSearchDropdown so existing cities surface before MKLocalSearchCompleter fires.
    var instantCityResults: [GlobalSearchResult] {
        let q = globalSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return visibleCities
            .filter { city in
                city.displayName.lowercased().contains(q) &&
                city.districts.contains(where: \.dataBundled)
            }
            .sorted { a, b in
                let aP = a.displayName.lowercased().hasPrefix(q)
                let bP = b.displayName.lowercased().hasPrefix(q)
                if aP != bP { return aP }
                return a.displayName < b.displayName
            }
            .map { city in
                let count = city.districts.filter(\.dataBundled).count
                let regionName = manifest.islands
                    .first(where: { $0.cities.contains(where: { $0.id == city.id }) })?
                    .displayName ?? ""
                return GlobalSearchResult(
                    id: "city_\(city.id)",
                    name: city.displayName,
                    subtitle: "\(regionName) · \(count) quartier\(count > 1 ? "s" : "") 3D",
                    icon: "building.2.fill",
                    kind: .city(city)
                )
            }
    }

    let manifest: CityManifest

    // Europe overview: 47°N/7°E at 3 200 km — Paris/London/Madrid/Rome all visible at a glance.
    private static let defaultCamera = MapCamera(
        centerCoordinate: CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0),
        distance: 3_200_000,
        heading: 0,
        pitch: 0
    )

    private let searchCompleter = MKLocalSearchCompleter()
    private let searchCompleterBridge = SearchCompleterBridge()
    private var cancellables = Set<AnyCancellable>()

    /// All city IDs shown in the UI — Europe + Tokyo + North America + Indonesia (Phase 6 re-integration).
    static let visibleCityIds: Set<String> = [
        "paris", "bordeaux", "london", "madrid", "rome",
        "tokyo", "newyork", "losangeles", "vancouver", "sanfrancisco",
        "jakarta", "bandung", "denpasar", "yogyakarta"
    ]

    /// Kept for any call-sites that haven't been renamed yet — aliases visibleCityIds.
    static var europeFocusCityIds: Set<String> { visibleCityIds }

    /// Display names of vitrine showcase cities — used for the "Vitrine disponible" badge.
    static let vitrineCityNames: Set<String> = ["Paris", "Londres", "Tokyo", "New York", "Madrid", "Rome", "Vancouver", "Jakarta", "Bali"]

    /// All cities visible in the Discover UI (map, globe, search).
    var visibleCities: [CityEntry] {
        manifest.allCities.filter { Self.visibleCityIds.contains($0.id) }
    }

    init(manifest: CityManifest = .shared) {
        self.manifest = manifest
        self.cameraPosition = .camera(DiscoverViewModel.defaultCamera)
        setupSearchCompleter(manifest: manifest)
        applyUITestOverrides(manifest: manifest)
    }

    private func setupSearchCompleter(manifest: CityManifest) {
        searchCompleter.delegate = searchCompleterBridge
        searchCompleter.resultTypes = .address
        searchCompleterBridge.onResults = { [weak self] results in
            guard let self else { return }
            let allCities = manifest.allCities
            self.worldCitySuggestions = results.prefix(6).compactMap { completion in
                let title = completion.title
                let subtitle = completion.subtitle
                let matched = allCities.first {
                    title.localizedCaseInsensitiveContains($0.displayName)
                }
                let isVitrine = Self.vitrineCityNames.contains(where: {
                    title.localizedCaseInsensitiveContains($0)
                }) || matched != nil
                return WorldCitySuggestion(
                    id: title + subtitle,
                    title: title,
                    subtitle: subtitle,
                    isVitrine: isVitrine,
                    matchedCity: matched
                )
            }
        }
        $globalSearchQuery
            .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
            .sink { [weak self] query in
                guard let self else { return }
                if query.count >= 2 {
                    self.searchCompleter.queryFragment = query
                } else {
                    self.worldCitySuggestions = []
                }
            }
            .store(in: &cancellables)
    }

    /// Launch-flag overrides for `simctl launch` + `simctl io screenshot` visual verification
    /// without tap simulation. Three variants:
    /// - `UITEST_OPEN_CITY=<cityId>` → jumps to `cityFocused` (zooms map to city, shows district callout)
    /// - `UITEST_OPEN_DISTRICT=<districtId>` → jumps to `districtExplore` (shows full mesh)
    /// - `UITEST_NIGHT_MODE=1` → enables night mode immediately (avoids Toggle tap automation,
    ///   which is unreliable on this Simulator build — see CLAUDE.md / iOS Simulator quirks memory)
    private func applyUITestOverrides(manifest: CityManifest) {
        let env = ProcessInfo.processInfo.environment
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
        // Default: open Paris on every cold launch — Europe is the primary focus.
        if let paris = manifest.allCities.first(where: { $0.id == "paris" }) {
            state = .cityFocused(paris)
            cameraPosition = .camera(MapCamera(
                centerCoordinate: paris.anchor.clLocationCoordinate,
                distance: paris.mapZoomRadius, heading: 0, pitch: 15))
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
        activeViewPreset = .overview
        isAutoRotating = false
        cameraResetToken += 1
    }

<<<<<<< HEAD
    /// Applies a named camera preset. OVERVIEW = bird's-eye ~61°; POI = reveals the landmark list
    /// in the mini-map widget and, if a building is already selected, flies the camera to it.
=======
    /// Applies a named camera preset. OVERVIEW = bird's-eye ~61°;
    /// CLOSE DISTRICT = tighter district framing; POI = fly to selected POI.
>>>>>>> origin/main
    func setViewPreset(_ preset: ViewPreset) {
        activeViewPreset = preset
        switch preset {
        case .overview:
            isAutoRotating = false
            cameraResetToken += 1
<<<<<<< HEAD
        case .focus:
            isAutoRotating = false
            if selectedBuilding != nil {
                viewFocusToken += 1
            }
            // No cameraResetToken — camera holds its current position in POI mode.
=======
        case .closeDistrict:
            isAutoRotating = false
            cameraResetToken += 1
        case .poi:
            guard selectedVenuePOI != nil else {
                activeViewPreset = .overview
                isAutoRotating = false
                cameraResetToken += 1
                return
            }
            poiFocusToken += 1
>>>>>>> origin/main
        }
    }

    /// Starts a 360° auto-orbit around the currently selected building. Enables
    /// auto-rotation and signals the 3D coordinator via a token change.
    func startBuildingOrbit() {
        isAutoRotating = true
        buildingOrbitToken += 1
    }

    func selectBuilding(_ building: BuildingFootprint) {
        selectedBuilding = building
        selectedVenuePOI = nil
        venueTargetPOIId = nil
    }

    func clearSelectedBuilding() {
        selectedBuilding = nil
        activeViewPreset = .overview
        cameraResetToken += 1
    }

    func selectPOIById(_ poiId: String, districtId: String) {
        guard let collection = CangguPOICollection.load(for: districtId) else { return }
        selectedVenuePOI = collection.pois.first { $0.id == poiId }
        selectedBuilding = nil
        venueTargetPOIId = poiId
        // Auto-switch to POI preset when a POI is selected
        if selectedVenuePOI != nil {
            activeViewPreset = .poi
            poiFocusToken += 1
        }
    }

    func dismissVenue() {
        selectedVenuePOI = nil
        venueTargetPOIId = nil
    }

    // MARK: - Search

    /// District-only results from the first character typed — up to 5 matches across all cities.
    var globalDistrictResults: [GlobalSearchResult] {
        let q = globalSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var results: [GlobalSearchResult] = []
        outer: for island in manifest.islands {
            for city in island.cities {
                for district in city.districts {
                    guard results.count < 5 else { break outer }
                    if district.displayName.lowercased().contains(q) {
                        results.append(GlobalSearchResult(
                            id: "dist_\(district.id)", name: district.displayName,
                            subtitle: city.displayName, icon: "map.fill",
                            kind: .district(district, city)
                        ))
                    }
                }
            }
        }
        return results
    }

    /// Building + POI results — requires 2 characters, up to 8 matches across bundled districts.
    var globalPlaceResults: [GlobalSearchResult] {
        let q = globalSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var results: [GlobalSearchResult] = []
        outer: for island in manifest.islands {
            for city in island.cities {
                for district in city.districts {
                    guard results.count < 8 else { break outer }
                    guard district.dataBundled else { continue }
                    if let data = District.load(named: district.id) {
                        for building in data.buildings {
                            guard results.count < 8 else { break }
                            guard let name = building.name,
                                  name.lowercased().contains(q) else { continue }
                            results.append(GlobalSearchResult(
                                id: "b_\(building.osmID ?? name)_\(district.id)",
                                name: name,
                                subtitle: "\(district.displayName), \(city.displayName)",
                                icon: "building.fill",
                                kind: .building(building, district, city)
                            ))
                        }
                    }
                    if let col = CangguPOICollection.load(for: district.id) {
                        for poi in col.pois {
                            guard results.count < 8 else { break }
                            guard poi.name.lowercased().contains(q) else { continue }
                            results.append(GlobalSearchResult(
                                id: "poi_\(poi.id)", name: poi.name,
                                subtitle: "\(district.displayName), \(city.displayName)",
                                icon: "mappin.fill",
                                kind: .poi(poi, district, city)
                            ))
                        }
                    }
                }
            }
        }
        return results
    }

    /// Flat combined list for the submit-on-enter handler — first 10 across districts + places.
    func globalSearchResults() -> [GlobalSearchResult] {
        Array((globalDistrictResults + globalPlaceResults).prefix(10))
    }

    /// Called when the user taps a `WorldCitySuggestion` row.
    /// Navigates to the matched city if it's in the manifest; clears search state regardless.
    func selectWorldCitySuggestion(_ suggestion: WorldCitySuggestion) {
        globalSearchQuery = ""
        isGlobalSearchActive = false
        worldCitySuggestions = []
        if let city = suggestion.matchedCity {
            selectCity(city)
        }
    }

    func selectGlobalSearchResult(_ result: GlobalSearchResult) {
        globalSearchQuery = ""
        isGlobalSearchActive = false
        switch result.kind {
        case .city(let city):
            // Jump to the first bundled district at OVERVIEW bird's-eye
            if let firstDistrict = city.districts.first(where: \.dataBundled) {
                selectDistrict(firstDistrict, in: city)
                setViewPreset(.overview)
            } else {
                selectCity(city)
            }
        case .district(let district, let city):
            selectDistrict(district, in: city)
        case .building(let building, let district, let city):
            // Navigate to district, then fly to the building in wide-framing BÂTIMENT view.
            selectDistrict(district, in: city)
            selectBuilding(building)
            setViewPreset(.overview)
        case .poi(let poi, let district, let city):
            selectVenuePOI(poi, in: district, city: city)
            setViewPreset(.poi)
        }
    }

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
        // Reset inspector controls to defaults on each new district open.
        isAutoRotating = false  // manual orbit — user pans to rotate
        rotationSpeed = 1.0
        selectedBuilding = nil
        selectedVenuePOI = nil
        venueTargetPOIId = nil
        withAnimation(.easeInOut(duration: 0.35)) {
            state = .districtExplore(city, district)
        }
        // First-entry reveal: show once per district install-lifetime.
        let key = "reveal_\(district.id)"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            let d = District.load(named: district.id)
            // Activity count: try district-level file first (Bali); fall back to city-level.
            let distActs = CityActivities.load(for: district.id.lowercased())
            let cityActs = distActs.isEmpty ? CityActivities.load(for: city.id) : []
            let ctx = DistrictRevealContext(
                city: city, district: district,
                buildingCount: d?.buildings.count ?? 0,
                roadCount: d?.roads.count ?? 0,
                activityCount: distActs.count + cityActs.count
            )
            // 0.7s delay so the 3D scene finishes its cinematic entry before the card appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    self?.districtRevealContext = ctx
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    withAnimation(.easeOut(duration: 0.35)) { self?.districtRevealContext = nil }
                }
            }
        }
    }

    func dismissDistrictReveal() {
        withAnimation(.easeOut(duration: 0.25)) { districtRevealContext = nil }
    }

    /// Transitions directly from the world map to a district's 3D view with the camera already
    /// flying to the given venue POI. Used when the user taps a `VenueMapPin` on the city map.
    func selectVenuePOI(_ poi: CangguPOI, in district: DistrictEntry, city: CityEntry) {
        isAutoRotating = false
        rotationSpeed = 1.0
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
                cameraPosition = .camera(DiscoverViewModel.defaultCamera)
            }
        case .worldMap:
            break
        }
    }

    func resetToWorldMap() {
        withAnimation(.easeInOut(duration: 0.5)) {
            state = .worldMap
            cameraPosition = .camera(DiscoverViewModel.defaultCamera)
        }
    }
}
