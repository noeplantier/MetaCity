import Foundation

/// A 2D point in a district's local coordinate space — meters from the district's anchor point
/// (its main square or landmark), not raw latitude/longitude. Projection happens once, offline,
/// in `tools/fetch_district_data.py`; nothing at runtime ever has to think about map projection.
struct LocalPoint: Codable, Hashable {
    let x: Float
    let z: Float
}

/// Consistent, deliberate per-building material treatment — every building of the same style
/// renders with the exact same color/finish everywhere, so a district reads as a coherent real
/// place rather than procedurally-colored noise.
enum BuildingStyle: String, Codable {
    /// Modern glass-curtain-wall office/residential tower (Sudirman-Thamrin, Kemang's apartment towers).
    case modernGlass
    /// Mid-rise concrete/precast tower.
    case modernConcrete
    /// Dutch colonial-era stucco building (most of Kota Tua and Menteng's unlabeled OSM footprints).
    case colonial
    /// Stone/stucco civic building (Kota Tua's government offices and museums).
    case government
    /// Mosque — white/cream walls, modest night lighting, distinct from the civic `government` tone.
    case religious
}

/// A real OpenStreetMap building footprint, simplified and classified by
/// `tools/fetch_district_data.py` — `polygon` is the building's actual real-world outline, not a
/// hand-placed rectangle.
struct BuildingFootprint: Codable, Identifiable {
    var id: String { osmID }
    let name: String?
    let polygon: [LocalPoint]
    let heightMeters: Float
    /// True when no real height/levels source existed and the value was estimated by style — see
    /// the curation script's `estimate_height`. Kept so the app never silently presents a guess as
    /// fact; a future UI affordance (e.g. a small marker) could surface this if useful.
    let isHeightEstimated: Bool
    let style: BuildingStyle
    let osmID: String
}

/// A real road or path centerline.
struct RoadSegment: Codable, Identifiable {
    var id: String { osmID }
    let name: String?
    let points: [LocalPoint]
    /// OSM `highway` tag value (`secondary`, `pedestrian`, `footway`, ...) — drives rendered width.
    let kind: String?
    let osmID: String
}

/// A real park / green space outline.
struct GreenZone: Codable, Identifiable {
    var id: String { osmID }
    let name: String?
    let polygon: [LocalPoint]
    let osmID: String
}

/// A fully real, curated Jakarta district — see `MetaCity/Resources/Districts/*.json` and
/// `tools/fetch_district_data.py` for provenance. This is the data backbone for every 3D/AR
/// rendering path in the app (`DistrictScene3DView`, `SimulatedARSceneView`, `ARSceneView`).
struct District: Codable {
    let name: String
    let anchorLatitude: Double
    let anchorLongitude: Double
    let buildings: [BuildingFootprint]
    let roads: [RoadSegment]
    let greenZones: [GreenZone]
    let sourceAttribution: String

    /// Loads a bundled district JSON by file name (without extension), e.g. `District.load(named: "KotaTua")`.
    static func load(named resourceName: String) -> District? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(District.self, from: data)
    }

    /// Real spatial extent of everything in the district, in meters from the anchor. Districts
    /// range from Kemang's ~400m strip to Ancol's ~1200m amusement park — camera framing in
    /// `DistrictScene3DView`/`SimulatedARSceneView` scales off this instead of a fixed distance
    /// tuned for one district's size, so a new district frames itself reasonably with zero
    /// per-district camera tuning.
    ///
    /// Deliberately excludes `greenZones`: OSM tags a park's *administrative boundary* as a single
    /// `leisure=park` way, which for somewhere like Ancol (Jakarta's ~5km² Dunia Fantasi complex)
    /// can be several times larger than the actual building/road cluster the fetch bbox targeted —
    /// including it skewed the centroid ~1.3km off-target and bloated the extent ~3x, pointing the
    /// camera at empty space. Buildings + roads are what's actually explorable; green zones are
    /// still rendered, just not load-bearing for where the camera looks.
    var boundingBox: (minX: Float, maxX: Float, minZ: Float, maxZ: Float) {
        let points = buildings.flatMap(\.polygon) + roads.flatMap(\.points)
        guard !points.isEmpty else { return (0, 1, 0, 1) }
        let xs = points.map(\.x)
        let zs = points.map(\.z)
        return (xs.min()!, xs.max()!, zs.min()!, zs.max()!)
    }

    var center: (x: Float, z: Float) {
        let bounds = boundingBox
        return ((bounds.minX + bounds.maxX) / 2, (bounds.minZ + bounds.maxZ) / 2)
    }

    /// The longer side of the bounding box — the single number everything else scales from.
    var extent: Float {
        let bounds = boundingBox
        return max(bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ)
    }

    /// Real building-footprint count across all 5 bundled districts — used by Profile's summary
    /// card so that number can't silently drift from whatever districts are actually shipped.
    static var totalRealBuildingCount: Int {
        ARLocation.allCases.compactMap { District.load(named: $0.jsonResourceName)?.buildings.count }.reduce(0, +)
    }

    /// Real road-centerline count across all 5 bundled districts. Unlike building heights (many
    /// `isHeightEstimated`), road geometry has no estimated component — every segment traces a
    /// real OSM `highway` way — so this is safe to present without a caveat.
    static var totalRealRoadCount: Int {
        ARLocation.allCases.compactMap { District.load(named: $0.jsonResourceName)?.roads.count }.reduce(0, +)
    }
}
