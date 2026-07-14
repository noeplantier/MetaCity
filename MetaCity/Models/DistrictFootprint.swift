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
    /// Balinese compound architecture — warm volcanic stone, low-pitch roofs, open courtyards.
    /// Applies to Canggu, Seminyak, Kuta, Ubud. Visually distinct from Javanese `colonial`.
    case balinese
    /// Traditional Javanese shophouse and palace compound architecture — warm buff stone, old
    /// terracotta roofs darker than Dutch colonial, amber lantern glow at night.
    /// Applies to Malioboro and Kraton in Yogyakarta. Do not conflate with `colonial` (Dutch).
    case javanese
    /// Haussmann-era Parisian limestone building — cream/beige cut stone facade, mansard zinc roof.
    /// The dominant typology of Paris (c. 1853–1927), Bordeaux centre, and other French cities
    /// rebuilt under the Second Empire. Visually unmistakable: pale stone walls, grey zinc attic.
    case haussmannien
    /// Medieval/half-timber urban fabric — Vieux-Rennes pan-de-bois, Breton granite townhouses.
    /// White plaster or granite walls, steep pitched tile roofs in dark brown/dark red.
    case medieval
    /// Bordeaux classical limestone — calcaire à astéries (shelly Gironde limestone), distinctly
    /// warmer amber-gold than Parisian Lutetian cream. Low-pitch (~30°) Provençal canal-tile roof.
    /// The UNESCO Port de la Lune fabric: Place de la Bourse, Cours de l'Intendance, quays.
    case bordelaisClassical
    /// London stock brick — fired yellow-buff clay brick, the dominant Victorian/Georgian material
    /// of the City of London's non-tower fabric. Leadenhall Market, Cornhill, Cheapside terrace rows.
    /// Rougher and warmer than Parisian limestone. Shallow (~25°) pitched slate roof with long ridge.
    /// Height promotion NOT bypassed: City of London glass towers should auto-promote to modernGlass.
    case londonBrick
    /// 19th-century Madrid Ensanche apartment block — limestone/sandstone render in a warm golden-beige
    /// distinctly warmer than Parisian haussmannien cream. The Salamanca grid, Calle Serrano, the
    /// barrios of Argüelles and Chueca. Flat azotea rooftop — NO hip roof cap, no mansard.
    /// Do NOT add madrileño to capStyles.
    case madrileño
    /// Roman tuff/brick and ochre render plaster — the dominant wall surface of Rome's historic core.
    /// Warm sienna-amber finish on tuff-block substrate. Campo de' Fiori, Piazza Navona surrounds,
    /// the Ghetto fabric. Canal-tile roof at 35°.
    /// Do NOT raise B channel above 0.40 — the low blue (B≈0.32) distinguishes Rome ochre from
    /// bordelaisClassical amber and madrileño golden-beige.
    case romanOchre
    /// New York City red-brown fired brick — the defining material of Manhattan's pre-war fabric:
    /// tenements (Lower East Side, Harlem), brownstones (Upper West Side, Brooklyn Heights),
    /// and the 1900–1940s limestone-clad office towers that still frame Midtown's street level.
    /// Wall: warm red-brown (R≈0.50–0.62, G≈0.26–0.34, B≈0.16–0.24) distinctly redder than London
    /// stock brick (yellow-buff) and darker/less saturated than Roman ochre (sienna-amber).
    /// Roof: **flat** dark tar/EPDM membrane — NYC rooftops are almost universally flat, often black
    /// from the orbit camera. **NOT in capStyles**. **IN HEIGHT_PROMOTION_BYPASS** — 20-floor
    /// pre-war limestone office buildings (70m) must stay nycBrick, not auto-promote to modernGlass.
    /// Apply authored overrides for glass supertalls (WTC, modern towers) that should be modernGlass.
    case nycBrick
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
    /// Explicit roof shape from an authored-overrides sidecar (`<district>_authored.json`).
    /// "conical" = octagonal cone (Balinese meru/pavilion), "thatched" = steep hip with dark
    /// straw material, "dome" = hemisphere (mosque/hotel cupola), "hip" = style-default hip,
    /// "flat" = no cap. Nil for all plain OSM buildings (roof decided by `makeRoofCapEntities`).
    let roofType: String?

    func applying(_ override: AuthoredBuildingOverride) -> BuildingFootprint {
        BuildingFootprint(
            name: self.name,
            polygon: self.polygon,
            heightMeters: override.heightMeters ?? self.heightMeters,
            isHeightEstimated: override.heightMeters != nil ? false : self.isHeightEstimated,
            style: override.style ?? self.style,
            osmID: self.osmID,
            roofType: override.roofType ?? self.roofType
        )
    }
}

// MARK: - Authored overrides

struct AuthoredBuildingOverride: Codable {
    let osmID: String?
    let nameMatch: String?
    let roofType: String?
    let heightMeters: Float?
    let style: BuildingStyle?
}

struct DistrictAuthoredOverrides: Codable {
    let districtId: String
    let overrides: [AuthoredBuildingOverride]

    static func load(for resourceName: String) -> DistrictAuthoredOverrides? {
        guard let url = Bundle.main.url(forResource: "\(resourceName)_authored", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DistrictAuthoredOverrides.self, from: data)
    }
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

extension BuildingStyle {
    var displayName: String {
        switch self {
        case .modernGlass:    return "Glass Tower"
        case .modernConcrete: return "Concrete Tower"
        case .colonial:       return "Colonial"
        case .government:     return "Government"
        case .religious:      return "Religious"
        case .balinese:       return "Balinese"
        case .javanese:       return "Javanese"
        case .haussmannien:        return "Haussmannien"
        case .medieval:            return "Médiéval"
        case .bordelaisClassical:  return "Bordelais"
        case .londonBrick:         return "London Brick"
        case .madrileño:           return "Madrileño"
        case .romanOchre:          return "Roman Ochre"
        case .nycBrick:            return "NYC Brick"
        }
    }

    var icon: String {
        switch self {
        case .modernGlass:    return "building.fill"
        case .modernConcrete: return "building.fill"
        case .colonial:       return "house.fill"
        case .government:     return "building.columns.fill"
        case .religious:      return "moon.fill"
        case .balinese:       return "flame.fill"
        case .javanese:       return "archivebox.fill"
        case .haussmannien:       return "building.2.fill"
        case .medieval:           return "house.lodge.fill"
        case .bordelaisClassical: return "building.columns.fill"
        case .londonBrick:        return "house.fill"
        case .madrileño:          return "building.2.fill"
        case .romanOchre:         return "building.columns.circle.fill"
        case .nycBrick:           return "building.2.crop.circle.fill"
        }
    }
}

/// A real park / green space outline.
struct GreenZone: Codable, Identifiable {
    var id: String { osmID }
    let name: String?
    /// OSM land-use kind — written by `fetch_district_data.py` as `"natural=beach"`,
    /// `"landuse=farmland"`, `"leisure=park"`, etc. Nil for JSONs fetched before this field
    /// was added (all non-Canggu districts currently); those fall back to generic park green.
    let kind: String?
    let polygon: [LocalPoint]
    let osmID: String
}

/// A fully real, curated Jakarta district — see `MetaCity/Resources/Districts/*.json` and
/// `tools/fetch_district_data.py` for provenance. This is the data backbone for every 3D/AR
/// rendering path in the app (`DistrictRealityView`, `SimulatedARSceneView`, `ARSceneView`) and
/// for the offline SceneKit→USDZ export step that feeds them (`SharedCityGeometry.makeExportableScene`).
struct District: Codable {
    let name: String
    let anchorLatitude: Double
    let anchorLongitude: Double
    let buildings: [BuildingFootprint]
    let roads: [RoadSegment]
    let greenZones: [GreenZone]
    let sourceAttribution: String

    /// In-memory cache, keyed by resource name — `District` is a value type, so handing back the
    /// same cached instance repeatedly is safe with no shared-mutable-state risk. Added because
    /// `load(named:)` sat on a hot path (`DistrictRealityView.update()` was calling it on every
    /// SwiftUI re-render, see CLAUDE.md's performance notes) and re-reading + re-decoding a
    /// several-hundred-building JSON file from disk on every call was pure waste once that path
    /// could fire dozens of times a second (e.g. dragging the rotation-speed slider).
    private static var cache: [String: District] = [:]

    /// Cache for `boundingBox` — `center` and `extent` both delegate to `boundingBox`, so a
    /// single `district.center; district.extent` pair used to run three separate O(6000) flatMap
    /// passes over all building+road points. The district JSON never changes at runtime.
    private static var bboxCache: [String: (minX: Float, maxX: Float, minZ: Float, maxZ: Float)] = [:]

    /// Loads a bundled district JSON by file name (without extension), e.g. `District.load(named: "KotaTua")`.
    /// Also applies any `<resourceName>_authored.json` sidecar overrides before caching.
    static func load(named resourceName: String) -> District? {
        if let cached = cache[resourceName] { return cached }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(District.self, from: data) else {
            return nil
        }
        let district: District
        if let authored = DistrictAuthoredOverrides.load(for: resourceName) {
            district = decoded.applyingAuthoredOverrides(authored)
        } else {
            district = decoded
        }
        cache[resourceName] = district
        return district
    }

    func applyingAuthoredOverrides(_ authored: DistrictAuthoredOverrides) -> District {
        let patched = buildings.map { building -> BuildingFootprint in
            for ov in authored.overrides {
                if let id = ov.osmID, id == building.osmID { return building.applying(ov) }
                if let match = ov.nameMatch, let name = building.name,
                   name.localizedCaseInsensitiveContains(match) { return building.applying(ov) }
            }
            return building
        }
        return District(name: name, anchorLatitude: anchorLatitude,
                        anchorLongitude: anchorLongitude, buildings: patched,
                        roads: roads, greenZones: greenZones,
                        sourceAttribution: sourceAttribution)
    }

    /// Real spatial extent of everything in the district, in meters from the anchor. Districts
    /// range from Kemang's ~400m strip to Ancol's ~1200m amusement park — camera framing in
    /// `DistrictRealityView`/`SimulatedARSceneView` scales off this instead of a fixed distance
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
        if let cached = District.bboxCache[name] { return cached }
        let points = buildings.flatMap(\.polygon) + roads.flatMap(\.points)
        guard !points.isEmpty else { return (0, 1, 0, 1) }
        let xs = points.map(\.x)
        let zs = points.map(\.z)
        let result = (xs.min()!, xs.max()!, zs.min()!, zs.max()!)
        District.bboxCache[name] = result
        return result
    }

    var center: (x: Float, z: Float) {
        let bounds = boundingBox
        return ((bounds.minX + bounds.maxX) / 2, (bounds.minZ + bounds.maxZ) / 2)
    }

    /// Mean of all building polygon centroids — a more robust camera look-at target than the
    /// bounding-box midpoint for linear or skewed districts (e.g. Dago's 1km boulevard) where
    /// outlier buildings or roads drag the bbox center far from where the building cluster actually
    /// lives. Cached alongside `bboxCache` since district data is immutable post-decode.
    private static var buildingCentroidCache: [String: (x: Float, z: Float)] = [:]

    var buildingCentroid: (x: Float, z: Float) {
        if let cached = District.buildingCentroidCache[name] { return cached }
        guard !buildings.isEmpty else { return center }
        var sumX: Float = 0, sumZ: Float = 0
        for building in buildings {
            let pts = building.polygon
            let n = Float(pts.count)
            sumX += pts.map(\.x).reduce(0, +) / n
            sumZ += pts.map(\.z).reduce(0, +) / n
        }
        let result = (sumX / Float(buildings.count), sumZ / Float(buildings.count))
        District.buildingCentroidCache[name] = result
        return result
    }

    /// The longer side of the bounding box — the single number everything else scales from.
    var extent: Float {
        let bounds = boundingBox
        return max(bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ)
    }

    /// Real building-footprint count across all bundled districts — used by Profile's summary
    /// card so that number can't silently drift from whatever districts are actually shipped.
    static var totalRealBuildingCount: Int {
        CityManifest.shared.allDistricts.compactMap { District.load(named: $0.id)?.buildings.count }.reduce(0, +)
    }

    /// Real road-centerline count across all bundled districts. Unlike building heights (many
    /// `isHeightEstimated`), road geometry has no estimated component — every segment traces a
    /// real OSM `highway` way — so this is safe to present without a caveat.
    static var totalRealRoadCount: Int {
        CityManifest.shared.allDistricts.compactMap { District.load(named: $0.id)?.roads.count }.reduce(0, +)
    }
}
