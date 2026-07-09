import CoreLocation
import Foundation

// MARK: - Root manifest

/// Data-driven city catalog: the single source of truth for every city/district in the app.
/// Adding a city = one JSON entry + one `fetch_district_data.py` run. Zero Swift changes.
struct CityManifest: Codable {
    let version: String
    let islands: [IslandEntry]

    static let shared: CityManifest = {
        guard let url = Bundle.main.url(forResource: "CityManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(CityManifest.self, from: data)
        else { return .fallback }
        return manifest
    }()

    var allCities: [CityEntry] { islands.flatMap(\.cities) }
    var allDistricts: [DistrictEntry] { allCities.flatMap(\.districts) }

    func city(id: String) -> CityEntry? { allCities.first { $0.id == id } }
    func district(id: String) -> DistrictEntry? { allDistricts.first { $0.id == id } }
}

// MARK: - Hierarchy

struct IslandEntry: Codable, Identifiable {
    let id: String
    let displayName: String
    let cities: [CityEntry]
}

struct CityEntry: Codable, Identifiable {
    let id: String
    let displayName: String
    let shortName: String
    let anchor: GeoCoord
    let mapZoomRadius: Double
    let markerColor: String
    let markerHeight: Float
    let districts: [DistrictEntry]
}

/// Replaces the old `ARLocation` enum. Every field that was hard-coded in that enum now lives here
/// as JSON data — adding district #6 (or a second city) requires no Swift changes.
struct DistrictEntry: Codable, Identifiable, Equatable {
    /// Maps to the bundled `Districts/<id>.json` resource name.
    let id: String
    let displayName: String
    let anchor: GeoCoord
    let boundingBox: GeoBBox
    let focusBuildingName: String?
    /// Matches a `DistrictRealityScene.Mood` case name — converted via `DistrictEntry.mood`.
    let moodKey: String
    let dataBundled: Bool
    let dataPath: String
    /// True for the three hand-curated AR showcase districts: SudirmanThamrin, Braga, Canggu.
    let supportsAR: Bool

    // Custom decode so `supportsAR` is optional in JSON — Swift's synthesized Codable
    // requires all non-Optional properties to have a key, even when a default value is set.
    init(id: String, displayName: String, anchor: GeoCoord, boundingBox: GeoBBox,
         focusBuildingName: String?, moodKey: String, dataBundled: Bool, dataPath: String,
         supportsAR: Bool = false) {
        self.id = id; self.displayName = displayName; self.anchor = anchor
        self.boundingBox = boundingBox; self.focusBuildingName = focusBuildingName
        self.moodKey = moodKey; self.dataBundled = dataBundled; self.dataPath = dataPath
        self.supportsAR = supportsAR
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(String.self,   forKey: .id)
        displayName     = try c.decode(String.self,   forKey: .displayName)
        anchor          = try c.decode(GeoCoord.self, forKey: .anchor)
        boundingBox     = try c.decode(GeoBBox.self,  forKey: .boundingBox)
        focusBuildingName = try c.decodeIfPresent(String.self, forKey: .focusBuildingName)
        moodKey         = try c.decode(String.self,   forKey: .moodKey)
        dataBundled     = try c.decode(Bool.self,     forKey: .dataBundled)
        dataPath        = try c.decode(String.self,   forKey: .dataPath)
        supportsAR      = (try? c.decodeIfPresent(Bool.self, forKey: .supportsAR)) ?? false
    }
}

// MARK: - Geography

struct GeoCoord: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    /// Flat equirectangular projection to local scene space (meters from anchor).
    /// Error < 0.1% within 100 km — safe for district scale.
    func sceneOffset(from anchor: GeoCoord) -> SIMD3<Float> {
        let metersPerLat: Float = 111_320
        let metersPerLon = metersPerLat * cos(Float(anchor.latitude) * .pi / 180)
        return SIMD3(
            Float(longitude - anchor.longitude) * metersPerLon,
            0,
            -Float(latitude - anchor.latitude) * metersPerLat
        )
    }
}

struct GeoBBox: Codable, Equatable {
    let south, west, north, east: Double
}

extension GeoCoord {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Fallback (mirrors CityManifest.json exactly, for bundle-read robustness)

private extension CityManifest {
    static var fallback: CityManifest {
        let d = CityManifest.jakartaDistricts
        let jakarta = CityEntry(id: "jakarta", displayName: "Jakarta", shortName: "Jakarta",
                                anchor: GeoCoord(latitude: -6.2088, longitude: 106.8456),
                                mapZoomRadius: 8000, markerColor: "#E8B86D", markerHeight: 1.6,
                                districts: d)
        return CityManifest(version: "1.0", islands: [IslandEntry(id: "java", displayName: "Jawa", cities: [jakarta])])
    }

    static var jakartaDistricts: [DistrictEntry] { [
        DistrictEntry(id: "SudirmanThamrin", displayName: "Bundaran HI",
                      anchor: GeoCoord(latitude: -6.2000, longitude: 106.8229),
                      boundingBox: GeoBBox(south: -6.215, west: 106.812, north: -6.185, east: 106.833),
                      focusBuildingName: "Menara BCA", moodKey: "skyscraperCorridor",
                      dataBundled: true, dataPath: "Districts/SudirmanThamrin.json"),
        DistrictEntry(id: "KotaTua", displayName: "Kota Tua",
                      anchor: GeoCoord(latitude: -6.1352, longitude: 106.8133),
                      boundingBox: GeoBBox(south: -6.142, west: 106.808, north: -6.130, east: 106.820),
                      focusBuildingName: "Museum Sejarah Jakarta", moodKey: "colonialSquare",
                      dataBundled: true, dataPath: "Districts/KotaTua.json"),
        DistrictEntry(id: "Kemang", displayName: "Jalan Kemang Raya",
                      anchor: GeoCoord(latitude: -6.2611, longitude: 106.8145),
                      boundingBox: GeoBBox(south: -6.275, west: 106.805, north: -6.250, east: 106.825),
                      focusBuildingName: "The Tiffany", moodKey: "residentialDusk",
                      dataBundled: true, dataPath: "Districts/Kemang.json"),
        DistrictEntry(id: "Menteng", displayName: "Taman Suropati",
                      anchor: GeoCoord(latitude: -6.2058, longitude: 106.8371),
                      boundingBox: GeoBBox(south: -6.215, west: 106.828, north: -6.195, east: 106.847),
                      focusBuildingName: "Gereja Kristen Indonesia Barat", moodKey: "parkDaylight",
                      dataBundled: true, dataPath: "Districts/Menteng.json"),
        DistrictEntry(id: "Ancol", displayName: "Taman Impian Jaya Ancol",
                      anchor: GeoCoord(latitude: -6.1258, longitude: 106.8346),
                      boundingBox: GeoBBox(south: -6.135, west: 106.825, north: -6.115, east: 106.845),
                      focusBuildingName: "Istana Boneka", moodKey: "coastalPark",
                      dataBundled: true, dataPath: "Districts/Ancol.json"),
    ] }
}
