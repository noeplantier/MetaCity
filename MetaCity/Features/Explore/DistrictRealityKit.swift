import RealityKit
import UIKit

/// Runtime geometry generation for district 3D scenes. Replaces the SceneKit→USDZ→RealityKit
/// pipeline with direct `MeshDescriptor` construction from the same bundled JSON data:
///
/// - **Why this change**: The USDZ pipeline required an offline export step, shipped 7MB of
///   binary files, and hit the same bottleneck on every first-visit — parsing a USDZ and
///   walking its full entity tree to re-style buildings. The new path reads the JSON (already
///   cached by `District.load`), builds `MeshDescriptor`s, and hands them to
///   `MeshResource.generate(from:)` — no file I/O beyond the JSON, no USD tree walk, no
///   offline export step.
///
/// - **Draw call reduction**: All buildings of the same `BuildingStyle` share one `ModelEntity`
///   (one merged `MeshDescriptor`). All road quads of the same `kind` share one `ModelEntity`.
///   Result: ~5 building entities + ~4 road entities + 1 ground + 1 green = ~11 draw calls per
///   district, versus ~2891 in the USDZ pipeline (2464 road + 427 building).
///
/// - **`@MainActor` constraint still applies**: `ModelEntity(mesh:materials:)` and
///   `entity.addChild` require the main actor (RealityFoundation hard constraint — see CLAUDE.md).
///   `MeshResource.generate(from:)` is NOT `@MainActor`, but since `loadDistrictEntity` runs on
///   the main actor anyway, the full build runs there. The async wrapper still defers the hitch to
///   a subsequent main-actor turn so the scene scaffold renders before the geometry pops in.
enum DistrictRealityKit {

    enum LoadError: Error { case districtNotFound(String) }

    /// Keyed by `"<name>_<isNight>"`. The full mesh build (polygon extrusion + MeshResource
    /// upload) is real cost; the cache ensures it only happens once per (district, mode).
    @MainActor private static var entityCache: [String: Entity] = [:]

    /// 50 material instances max: 10 variation buckets × 5 styles × 2 modes.
    @MainActor private static var materialPool: [String: PhysicallyBasedMaterial] = [:]

    @MainActor private static var windowTextureCache: [String: TextureResource] = [:]
    @MainActor private static var pavementTextureCache: TextureResource? = nil
    /// Mood-tinted flat ground tiles — cached by mood key (not per-district).
    @MainActor private static var groundColorCache: [String: TextureResource] = [:]

    /// Palm tree positions keyed by district name. District data is immutable post-decode so
    /// this cache is valid for the lifetime of the app process (same guarantee as entityCache).
    @MainActor private static var palmPositionCache: [String: [(x: Float, z: Float, h: Float)]] = [:]

    // MARK: - Entity loading

    /// Builds a fully-styled `Entity` for `name` (a bundled `District` JSON resource name)
    /// from real OSM polygon data. On cache hit: returns a clone immediately. On cache miss:
    /// builds the geometry synchronously on the main actor and caches before returning a clone.
    @MainActor
    static func loadDistrictEntity(named name: String, isNight: Bool, mood: DistrictRealityScene.Mood = .parkDaylight) async throws -> Entity {
        let cacheKey = "\(name)_\(isNight)"
        if let cached = entityCache[cacheKey] {
            return cached.clone(recursive: true)
        }
        guard let district = District.load(named: name) else {
            throw LoadError.districtNotFound(name)
        }

        let root = Entity()
        root.name = name

        root.addChild(makeGroundPlane(for: district, mood: mood))

        if let water = makeWaterPlane(mood: mood, extent: district.extent, center: district.center, isNight: isNight) {
            root.addChild(water)
        }

        for greenEntity in makeGreenZoneEntities(from: district, isNight: isNight) {
            root.addChild(greenEntity)
        }

        for entity in try makeRoadEntities(from: district, mood: mood) {
            root.addChild(entity)
        }

        if let markings = try makeRoadMarkingEntity(from: district) {
            root.addChild(markings)
        }

        // Split buildings into 4 spatial quadrants (NW/NE/SW/SE relative to buildingCentroid).
        // Each quadrant gets a near tier (full polygon detail) and a far tier (simplified AABB boxes).
        // In orbit mode all quads show near; in venue (close-up) mode only near-camera quads show near.
        let centroid = district.buildingCentroid
        let quadrantBuildings = splitIntoQuadrants(district.buildings, centroid: centroid)

        // Palm positions computed once for the full district (cached on first call), then split by
        // quadrant. Palms live only in near containers — at LOD-far distance (~1.5km for Canggu)
        // palm silhouettes are sub-pixel so the far AABB tier omits them entirely.
        let allPalmPositions = districtPalmPositions(district: district)
        let palmsByQuadrant: [[(x: Float, z: Float, h: Float)]] = (0..<4).map { qi in
            allPalmPositions.filter { p in
                ((p.x >= centroid.x ? 1 : 0) | (p.z >= centroid.z ? 2 : 0)) == qi
            }
        }

        for (i, qBuildings) in quadrantBuildings.enumerated() {
            let qContainer = Entity()
            qContainer.name = "q\(i)"
            // Do NOT set qContainer.position — building vertex coordinates are in model-local space
            // (absolute offsets from the district anchor) and must be interpreted relative to the
            // root entity at the origin. A non-zero container position would double-translate them.
            // Quadrant centers for LOD distance checks are computed by the coordinator from
            // cachedDistrict rather than read from entity.position.

            let nearContainer = Entity()
            nearContainer.name = "near"
            nearContainer.isEnabled = true   // orbit default: all quads at full quality

            let farContainer = Entity()
            farContainer.name = "far"
            farContainer.isEnabled = false   // activated only during venue mode for distant quads

            for entity in (try? makeBuildingMeshes(buildings: qBuildings, isNight: isNight, quadrantIndex: i)) ?? [] {
                nearContainer.addChild(entity)
            }
            for entity in makeRoofCapEntities(buildings: qBuildings, isNight: isNight, quadrantIndex: i) {
                nearContainer.addChild(entity)
            }
            for entity in makeAuthoredRoofEntities(buildings: qBuildings, isNight: isNight, quadrantIndex: i) {
                nearContainer.addChild(entity)
            }
            for entity in makePalmEntities(positions: palmsByQuadrant[i], isNight: isNight, quadrantIndex: i) {
                nearContainer.addChild(entity)
            }
            if let farEntity = makeFarTierEntity(buildings: qBuildings, isNight: isNight, quadrantIndex: i) {
                farContainer.addChild(farEntity)
            }

            qContainer.addChild(nearContainer)
            qContainer.addChild(farContainer)
            root.addChild(qContainer)

            // Yield between quadrant builds so the static scene scaffold (lights, ground, sky)
            // can commit and render before the heavy geometry pops in.
            await Task.yield()
        }

        // POI label panels — only for districts with curated POI data (Bali districts).
        if let distEntry = CityManifest.shared.district(id: name),
           let distData = District.load(named: name) {
            let centroid = distData.buildingCentroid
            if let poiLayer = makePOILabelEntities(
                districtName: name,
                districtAnchor: distEntry.anchor,
                districtCentroid: SIMD2(centroid.x, centroid.z),
                districtExtent: distData.extent,
                isNight: isNight
            ) {
                root.addChild(poiLayer)
            }
        }

        entityCache[cacheKey] = root
        return root.clone(recursive: true)
    }

    private static let bronzeColor = UIColor(
        red: 0.80,
        green: 0.63,
        blue: 0.43,
        alpha: 1.0
    )

    private static let bronzeGlow = UIColor(
        red: 1.0,
        green: 0.86,
        blue: 0.55,
        alpha: 1.0
    )

    private static let bronzeDark = UIColor(
        red: 0.45,
        green: 0.33,
        blue: 0.20,
        alpha: 1.0
    )
    
 
    // MARK: - Building geometry

    /// Merges buildings into one `ModelEntity` per (style × variation-bucket).
    /// 3 buckets per style → ≤18 entities vs. 1 per building (up to 427 for SudirmanThamrin).
    /// Each bucket gets a distinct material variation so buildings of the same type read as
    /// individual neighbours — colonial blocks show warm/neutral/cool buff variants, glass
    /// towers show blue/green-tint/silver hues — without blowing the draw-call budget.
    @MainActor
    
    private static func makeBuildingMeshes(buildings: [BuildingFootprint], isNight: Bool, quadrantIndex: Int = -1) throws -> [ModelEntity] {
        // Bucket 0 → variation 0.0 (low end), 1 → 0.5 (mid), 2 → 1.0 (high end).
        // Using a local struct so we can mutate .buildings via dict[key, default:].
        struct Bucket {
            let style: BuildingStyle
            let variation: Float
            var buildings: [BuildingFootprint] = []
        }
        var buckets: [String: Bucket] = [:]
        for building in buildings {
            let v = deterministicVariation(seed: building.osmID)
            let b = min(Int(v * 3), 2)
            let key = "\(building.style.rawValue)_\(b)"
            buckets[key, default: Bucket(style: building.style, variation: Float(b) * 0.5)].buildings.append(building)
        }

        return try buckets.flatMap { (key, bucket) -> [ModelEntity] in
            let style    = bucket.style
            let variation = bucket.variation
            let buildings = bucket.buildings
            // Walls and roofs use separate MeshDescriptors → separate material slots.
            // Roofs get a style-specific material (terracotta colonial tile, dark glass
            // penthouse, etc.) that is clearly distinct from the wall material — the
            // difference is most visible from the orbit camera which is largely looking down.
            var wallPos:  [SIMD3<Float>] = []
            var wallNorm: [SIMD3<Float>] = []
            var wallUV:   [SIMD2<Float>] = []
            var wallIdx:  [UInt32]       = []

            var roofPos:  [SIMD3<Float>] = []
            var roofNorm: [SIMD3<Float>] = []
            var roofUV:   [SIMD2<Float>] = []
            var roofIdx:  [UInt32]       = []

            // UV tile sizes in world metres — 1 texture repeat per tile.
            // Walls: 5m wide × 3.5m tall (one floor bay). Roof: 10m per tile.
            let tileU: Float = 5.0
            let tileV: Float = 3.5
            let roofTile: Float = 10.0

            for building in buildings {
                let pts = building.polygon
                guard pts.count >= 3 else { continue }
                // Skip degenerate OSM artefacts:
                // • area < 4 m²: tiny fragments (shared-wall remnants, point-feature envelopes).
                //   Real district buildings are all ≥ 37 m² in practice so this is a safe guard.
                // • shortest non-zero edge < 0.5 m: thin slivers. Must exclude zero-length edges
                //   (duplicate vertices from Douglas-Peucker simplification are common and
                //   already skipped by the wall-quad loop's `guard len > 0.01` — including them
                //   in the min() would incorrectly flag every building as a degenerate sliver).
                guard polygonArea(pts) >= 4.0 else { continue }
                let minNonZeroEdge = (0..<pts.count).compactMap { i -> Float? in
                    let a = pts[i], b = pts[(i + 1) % pts.count]
                    let dx = b.x - a.x, dz = b.z - a.z
                    let len = sqrt(dx * dx + dz * dz)
                    return len > 0.01 ? len : nil
                }.min() ?? 0
                guard minNonZeroEdge >= 0.5 else { continue }

                // Height variation for estimated buildings: ±20% deterministic wobble so a
                // dense residential block reads as individually varied rather than a flat grid.
                let variation = deterministicVariation(seed: building.osmID)
                let h: Float = building.isHeightEstimated
                    ? building.heightMeters * (0.80 + variation * 0.40)
                    : building.heightMeters

                let n = pts.count

                // Walls — one quad per polygon edge, with UV tiled by physical dimensions so
                // the window texture (emissive, night mode) tiles as real individual windows.
                for i in 0..<n {
                    let a = pts[i], b = pts[(i + 1) % n]
                    let dx = b.x - a.x, dz = b.z - a.z
                    let len = sqrt(dx * dx + dz * dz)
                    guard len > 0.01 else { continue }

                    let nx = -dz / len, nz = dx / len
                    let normal = SIMD3<Float>(nx, 0, nz)
                    let uMax = len / tileU
                    let vMax = h   / tileV

                    let base = UInt32(wallPos.count)
                    wallPos  += [SIMD3(a.x, 0, a.z), SIMD3(b.x, 0, b.z), SIMD3(b.x, h, b.z), SIMD3(a.x, h, a.z)]
                    wallNorm += [normal, normal, normal, normal]
                    wallUV   += [SIMD2(0, 0), SIMD2(uMax, 0), SIMD2(uMax, vMax), SIMD2(0, vMax)]
                    wallIdx  += [base, base+3, base+2, base, base+2, base+1]
                }

                // Roof — centroid-fan triangulation with a signed-area guard.
                // The centroid of a concave polygon can fall outside it; the guard skips any
                // fan triangle whose signed area has the opposite sign from the polygon (it
                // lies outside the boundary). Gaps in highly concave roofs are correct — the
                // concave notch should have no geometry. From the orbit camera at 150m+ the
                // gaps are imperceptible; the walls (which use the full perimeter) still read.
                let cx = pts.map(\.x).reduce(0, +) / Float(pts.count)
                let cz = pts.map(\.z).reduce(0, +) / Float(pts.count)
                let polySA = signedPolygonArea(pts)   // negative for CW (OSM outer rings)
                let centIdx = UInt32(roofPos.count)
                roofPos.append(SIMD3(cx, h, cz))
                roofNorm.append(SIMD3(0, 1, 0))
                roofUV.append(SIMD2(cx / roofTile, cz / roofTile))
                let roofBase = UInt32(roofPos.count)
                for p in pts {
                    roofPos.append(SIMD3(p.x, h, p.z))
                    roofNorm.append(SIMD3(0, 1, 0))
                    roofUV.append(SIMD2(p.x / roofTile, p.z / roofTile))
                }
                for i in 0..<UInt32(pts.count) {
                    let j = (i + 1) % UInt32(pts.count)
                    let pi = pts[Int(i)], pj = pts[Int(j)]
                    // Signed area of triangle [C, pj, pi] (same winding as the fan index order)
                    let triSA = (cx - pj.x) * (pi.z - pj.z) - (pi.x - pj.x) * (cz - pj.z)
                    guard triSA * polySA > 0 else { continue }   // skip outside-boundary triangles
                    roofIdx += [centIdx, roofBase + j, roofBase + i]
                }
            }

            guard !wallPos.isEmpty else { return [] }

            // Walls and roofs MUST be separate ModelEntity instances, not two
            // MeshDescriptors inside one entity: both descriptors default to
            // materialIndex=0 in RealityKit, so the second material slot is never
            // referenced and roofMat is silently ignored, causing rooftops to render
            // with the wall glass material (bright teal) instead of dark charcoal.
            var wallDesc = MeshDescriptor(name: "buildings_\(style.rawValue)_walls")
            wallDesc.positions          = MeshBuffer(wallPos)
            wallDesc.normals            = MeshBuffer(wallNorm)
            wallDesc.textureCoordinates = MeshBuffer(wallUV)
            wallDesc.primitives         = .triangles(wallIdx)
            let wallMat     = pooledMaterial(for: style, variation: variation, isNight: isNight)
            let wallMesh    = try MeshResource.generate(from: [wallDesc])
            let wallEntity  = ModelEntity(mesh: wallMesh, materials: [wallMat])
            wallEntity.name = "buildings_\(key)_walls"

            var entities: [ModelEntity] = [wallEntity]

            if !roofIdx.isEmpty {
                var roofDesc = MeshDescriptor(name: "buildings_\(style.rawValue)_roofs")
                roofDesc.positions          = MeshBuffer(roofPos)
                roofDesc.normals            = MeshBuffer(roofNorm)
                roofDesc.textureCoordinates = MeshBuffer(roofUV)
                roofDesc.primitives         = .triangles(roofIdx)
                let roofMat     = roofMaterialPreset(for: style, isNight: isNight)
                let roofMesh    = try MeshResource.generate(from: [roofDesc])
                let roofEntity  = ModelEntity(mesh: roofMesh, materials: [roofMat])
                roofEntity.name = "buildings_\(key)_roofs"
                entities.append(roofEntity)
            }

            return entities
        }
    }

    // MARK: - Road geometry

    /// Merges all road quads of the same `kind` into one `ModelEntity` per kind.
    /// From ~2464 entities for Ancol's roads to ≤4 — the single largest draw-call saving.
    @MainActor
    private static func makeRoadEntities(from district: District, mood: DistrictRealityScene.Mood) throws -> [ModelEntity] {
        typealias Quad = (v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>, v3: SIMD3<Float>)
        var quadsByKind: [String: [Quad]] = [:]

        for road in district.roads {
            let kind = road.kind ?? "_default"
            let half = roadHalfWidth(for: road.kind)
            let pts = road.points
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let dx = b.x - a.x, dz = b.z - a.z
                let len = sqrt(dx * dx + dz * dz)
                guard len > 0.01 else { continue }
                let nx = -dz / len * half, nz = dx / len * half
                quadsByKind[kind, default: []].append((
                    SIMD3(a.x + nx, 0.02, a.z + nz),
                    SIMD3(a.x - nx, 0.02, a.z - nz),
                    SIMD3(b.x - nx, 0.02, b.z - nz),
                    SIMD3(b.x + nx, 0.02, b.z + nz)
                ))
            }
        }

        let upNormal = SIMD3<Float>(0, 1, 0)
        return try quadsByKind.compactMap { kind, quads -> ModelEntity? in
            guard !quads.isEmpty else { return nil }
            var positions: [SIMD3<Float>] = []
            var normals:   [SIMD3<Float>] = []
            var indices:   [UInt32]       = []

            for (i, q) in quads.enumerated() {
                let base = UInt32(i * 4)
                positions += [q.v0, q.v1, q.v2, q.v3]
                normals   += [upNormal, upNormal, upNormal, upNormal]
                // CCW in screen space from the orbit camera (above, +Z side).
                // Original [0,1,2,0,2,3] is CW from orbit = back-face culled.
                // Reversed split: [v0,v3,v2] + [v0,v2,v1] — both CCW regardless of road direction.
                indices   += [base, base+3, base+2, base, base+2, base+1]
            }

            var desc = MeshDescriptor(name: "roads_\(kind)")
            desc.positions  = MeshBuffer(positions)
            desc.normals    = MeshBuffer(normals)
            desc.primitives = .triangles(indices)

            let mesh   = try MeshResource.generate(from: [desc])
            let entity = ModelEntity(mesh: mesh, materials: [roadMaterial(for: kind, mood: mood)])
            entity.name = "roads_\(kind)"
            return entity
        }
    }

    private static func roadHalfWidth(for kind: String?) -> Float {
        switch kind {
        case "primary", "trunk":                  return 6.0
        case "secondary":                          return 4.5
        case "tertiary":                           return 3.0
        case "residential", "unclassified":        return 2.0
        case "pedestrian", "footway", "path":      return 1.0
        default:                                   return 2.0
        }
    }

    private static func roadMaterial(for kind: String, mood: DistrictRealityScene.Mood) -> PhysicallyBasedMaterial {
        var mat = PhysicallyBasedMaterial()
        mat.roughness = .init(floatLiteral: 0.95)
        mat.metallic  = .init(floatLiteral: 0.0)
        switch mood {
        case .beachResort:
            // Bleached tropical asphalt — warm sandy rather than Jakarta charcoal.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.75, green: 0.68, blue: 0.54, alpha: 1))
            case "primary", "primary_link", "busway":
                mat.baseColor = .init(tint: UIColor(red: 0.40, green: 0.34, blue: 0.25, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.54, green: 0.48, blue: 0.38, alpha: 1))
            }
        case .sacredSite:
            // Volcanic dark stone paving; pedestrian paths are lighter (beaten earth).
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.52, green: 0.44, blue: 0.34, alpha: 1))
            case "primary", "primary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.18, green: 0.15, blue: 0.12, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.26, green: 0.22, blue: 0.18, alpha: 1))
            }
        default:
            // Jakarta / Bandung / Yogya: dark asphalt, graded by road class.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(white: 0.62, alpha: 1))
            case "primary", "primary_link", "busway":
                mat.baseColor = .init(tint: UIColor(white: 0.12, alpha: 1))
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(white: 0.18, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified":
                mat.baseColor = .init(tint: UIColor(white: 0.24, alpha: 1))
            case "service":
                mat.baseColor = .init(tint: UIColor(red: 0.23, green: 0.20, blue: 0.16, alpha: 1))
            case "residential", "living_street":
                mat.baseColor = .init(tint: UIColor(white: 0.28, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(white: 0.20, alpha: 1))
            }
        }
        return mat
    }

    /// Dashed centre-line markings for primary/secondary/tertiary roads: 3m dashes every 7.5m,
    /// 0.2m wide, Y=0.025m (5mm above road surface). One merged `ModelEntity` for the entire district.
    @MainActor
    private static func makeRoadMarkingEntity(from district: District) throws -> ModelEntity? {
        let dashLen:    Float = 3.0
        let cycleLen:   Float = 7.5   // dash + gap
        let halfW:      Float = 0.10  // 0.2m total width
        let yOff:       Float = 0.025
        let markedKinds       = Set(["primary", "trunk", "secondary", "tertiary"])

        var pos:  [SIMD3<Float>] = []
        var norm: [SIMD3<Float>] = []
        var idx:  [UInt32]       = []
        let up = SIMD3<Float>(0, 1, 0)

        for road in district.roads {
            guard let kind = road.kind, markedKinds.contains(kind) else { continue }
            let pts = road.points
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let dx = b.x - a.x, dz = b.z - a.z
                let len = sqrt(dx * dx + dz * dz)
                guard len > 0.01 else { continue }
                let ux = dx / len, uz = dz / len   // unit along road
                let px = -uz * halfW, pz = ux * halfW  // perpendicular left half-width

                var t: Float = 0
                while t < len {
                    let tEnd = min(t + dashLen, len)
                    let sx = a.x + ux * t,    sz = a.z + uz * t
                    let ex = a.x + ux * tEnd, ez = a.z + uz * tEnd
                    let base = UInt32(pos.count)
                    pos  += [SIMD3(sx + px, yOff, sz + pz),
                             SIMD3(sx - px, yOff, sz - pz),
                             SIMD3(ex - px, yOff, ez - pz),
                             SIMD3(ex + px, yOff, ez + pz)]
                    norm += [up, up, up, up]
                    // CCW from orbit camera (same winding convention as road surface)
                    idx  += [base, base+3, base+2,  base, base+2, base+1]
                    t += cycleLen
                }
            }
        }

        guard !pos.isEmpty else { return nil }
        var desc = MeshDescriptor(name: "roadMarkings")
        desc.positions  = MeshBuffer(pos)
        desc.normals    = MeshBuffer(norm)
        desc.primitives = .triangles(idx)
        let mesh = try MeshResource.generate(from: [desc])
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor(white: 0.82, alpha: 1.0))
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.name = "roadMarkings"
        return entity
    }

    // MARK: - Ground + green zones

    @MainActor
    private static func makeGroundPlane(for district: District, mood: DistrictRealityScene.Mood) -> ModelEntity {
        let ext      = district.extent * 1.5
        let cx       = district.center.x
        let cz       = district.center.z
        let upN      = SIMD3<Float>(0, 1, 0)
        let tileSize = groundTileSize(for: mood)

        let x0 = cx - ext/2, x1 = cx + ext/2
        let z0 = cz - ext/2, z1 = cz + ext/2

        var desc = MeshDescriptor(name: "ground")
        desc.positions = MeshBuffer([
            SIMD3(x0, 0, z0), SIMD3(x1, 0, z0),
            SIMD3(x1, 0, z1), SIMD3(x0, 0, z1)
        ])
        desc.normals   = MeshBuffer([upN, upN, upN, upN])
        desc.textureCoordinates = MeshBuffer([
            SIMD2(x0 / tileSize, z0 / tileSize),
            SIMD2(x1 / tileSize, z0 / tileSize),
            SIMD2(x1 / tileSize, z1 / tileSize),
            SIMD2(x0 / tileSize, z1 / tileSize)
        ])
        // CCW from the orbit camera (above and behind, positive-Z side) — [0,1,2,0,2,3]
        // is CW from that vantage (back-face culled = invisible ground). Reversed here.
        desc.primitives = .triangles([0, 2, 1, 0, 3, 2])

        // Ground uses UnlitMaterial for the same reason as green zones: PBR on a large horizontal
        // surface at city scale (600m–3km) under a fixed shadow-map budget produces IBL washout and
        // shadow-stripe aliasing. UnlitMaterial bypasses the studio IBL and shows the texture color
        // exactly, making per-mood ground colors predictable across all lighting rigs.
        var umat = UnlitMaterial()
        if let tex = makeGroundTexture(mood: mood) {
            umat.color = .init(tint: .white, texture: .init(tex))
        } else {
            let fallback: UIColor
            switch mood {
            case .skyscraperCorridor: fallback = UIColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1)
            case .colonialSquare:     fallback = UIColor(red: 0.66, green: 0.52, blue: 0.38, alpha: 1)
            case .residentialDusk:    fallback = UIColor(red: 0.57, green: 0.41, blue: 0.29, alpha: 1)
            case .parkDaylight:       fallback = UIColor(red: 0.33, green: 0.51, blue: 0.24, alpha: 1)
            case .coastalPark:        fallback = UIColor(red: 0.76, green: 0.71, blue: 0.57, alpha: 1)
            case .beachResort:        fallback = UIColor(red: 0.88, green: 0.76, blue: 0.50, alpha: 1)
            case .sacredSite:         fallback = UIColor(red: 0.22, green: 0.20, blue: 0.18, alpha: 1)
            case .highlandMorning:    fallback = UIColor(red: 0.46, green: 0.48, blue: 0.51, alpha: 1)
            }
            umat.color = .init(tint: fallback)
        }

        let mesh   = (try? MeshResource.generate(from: [desc])) ?? MeshResource.generateBox(size: [ext, 0.01, ext])
        let entity = ModelEntity(mesh: mesh, materials: [umat])
        entity.name = "ground"
        entity.position = SIMD3(0, -0.02, 0)
        return entity
    }

    /// Water plane for coastal districts (beachResort + coastalPark moods). Placed at y = −0.05m
    /// so the ground plane (y = −0.02) sits slightly above it — the water is only visible where
    /// the district's ground plane doesn't cover, i.e. beyond the building cluster's edges and
    /// at the horizon. Uses `UnlitMaterial` for the same reason as green zones: PBR on a large
    /// horizontal surface under a city-scale shadow map produces visible shadow-stripe aliasing
    /// artifacts at oblique sun angles. Water at horizon reads as ambient colour — unlit is correct.
    @MainActor
    private static func makeWaterPlane(mood: DistrictRealityScene.Mood, extent: Float, center: (x: Float, z: Float), isNight: Bool) -> ModelEntity? {
        guard mood == .beachResort || mood == .coastalPark else { return nil }

        let waterExt = extent * 5.0   // large enough to fill the sky-dome horizon visually
        let cx = center.x, cz = center.z

        var desc = MeshDescriptor(name: "water")
        let x0 = cx - waterExt/2, x1 = cx + waterExt/2
        let z0 = cz - waterExt/2, z1 = cz + waterExt/2
        desc.positions = MeshBuffer([
            SIMD3(x0, 0, z0), SIMD3(x1, 0, z0),
            SIMD3(x1, 0, z1), SIMD3(x0, 0, z1)
        ])
        desc.normals = MeshBuffer([SIMD3<Float>(0, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 0)])
        desc.textureCoordinates = MeshBuffer([
            SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)
        ])
        // Same CCW fix as the ground plane — orbit camera is above and behind (+Z side),
        // so [0,1,2,0,2,3] is CW in screen space = back-face culled.
        desc.primitives = .triangles([0, 2, 1, 0, 3, 2])

        guard let mesh = try? MeshResource.generate(from: [desc]) else { return nil }

        var mat = UnlitMaterial()
        switch mood {
        case .beachResort:
            // Tropical shallow ocean — warm turquoise, reads as bright against sandy ground.
            // Night: deepen to midnight blue with faint moonlit shimmer.
            mat.color = .init(tint: isNight
                ? UIColor(red: 0.04, green: 0.10, blue: 0.22, alpha: 1)
                : UIColor(red: 0.18, green: 0.52, blue: 0.68, alpha: 1))
        case .coastalPark:
            // Jakarta Bay — murky green-brown Java Sea, far less vibrant than Bali.
            mat.color = .init(tint: isNight
                ? UIColor(red: 0.04, green: 0.08, blue: 0.14, alpha: 1)
                : UIColor(red: 0.14, green: 0.28, blue: 0.38, alpha: 1))
        default:
            return nil
        }

        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.name = "water"
        entity.position = SIMD3(0, -0.05, 0)   // just below the ground plane (y = -0.02)
        return entity
    }

    // MARK: - Dynamic ground color (venue visits)

    /// Swaps the "ground" entity's material tint to match a POI's category when the camera
    /// visits that venue. Called by `DistrictRealityView.Coordinator.flyToVenue`.
    /// Silently no-ops if the districtModel hasn't finished loading yet.
    @MainActor
    static func updateGroundColor(in anchor: AnchorEntity, for category: POICategory, mood: DistrictRealityScene.Mood) {
        guard let ground = anchor.findEntity(named: "ground") as? ModelEntity else { return }
        var mat = PhysicallyBasedMaterial()
        mat.roughness = .init(floatLiteral: 0.97)
        switch category {
        case .beach, .surf:
            mat.baseColor = .init(tint: UIColor(red: 0.85, green: 0.76, blue: 0.55, alpha: 1))
        case .temple:
            mat.baseColor = .init(tint: UIColor(red: 0.22, green: 0.20, blue: 0.18, alpha: 1))
        case .wellness:
            mat.baseColor = .init(tint: UIColor(red: 0.34, green: 0.40, blue: 0.28, alpha: 1))
        case .cafe, .restaurant:
            mat.baseColor = .init(tint: UIColor(red: 0.74, green: 0.62, blue: 0.44, alpha: 1))
        case .hotel, .villa:
            mat.baseColor = .init(tint: UIColor(red: 0.68, green: 0.65, blue: 0.60, alpha: 1))
        default:
            mat.baseColor = .init(tint: UIColor(red: 0.60, green: 0.55, blue: 0.48, alpha: 1))
        }
        ground.model?.materials = [mat]
    }

    /// Restores the "ground" entity to its district-wide mood color after a venue visit ends.
    @MainActor
    static func restoreGroundColor(in anchor: AnchorEntity, mood: DistrictRealityScene.Mood) {
        guard let ground = anchor.findEntity(named: "ground") as? ModelEntity else { return }
        var mat = PhysicallyBasedMaterial()
        mat.roughness = .init(floatLiteral: 0.95)
        switch mood {
        case .beachResort:
            mat.baseColor = .init(tint: UIColor(red: 0.78, green: 0.70, blue: 0.52, alpha: 1))
        case .sacredSite:
            mat.baseColor = .init(tint: UIColor(red: 0.22, green: 0.20, blue: 0.18, alpha: 1))
        default:
            mat.baseColor = .init(tint: UIColor(red: 0.56, green: 0.52, blue: 0.46, alpha: 1))
        }
        ground.model?.materials = [mat]
    }

    /// Returns the ground UV tile size in metres for each mood. Smaller = finer tile repeat.
    /// - `skyscraperCorridor`: 8m → concrete expansion joints at 2m pitch (4 joints in 32px)
    /// - `colonialSquare`: 5m → ~1.25m cobblestones (closer to real colonial paving scale)
    /// - `sacredSite`: 5m → tight volcanic stone blocks
    /// - `beachResort`: 9m → wide sandy patches
    /// - others: 10m default
    private static func groundTileSize(for mood: DistrictRealityScene.Mood) -> Float {
        switch mood {
        case .colonialSquare, .sacredSite:  return 5.0
        case .skyscraperCorridor:           return 8.0
        case .beachResort:                  return 9.0
        case .highlandMorning:              return 6.0
        default:                            return 10.0
        }
    }

    /// 32×32 tile for mood-specific ground surfaces — cached per mood key.
    /// Upgraded from 4×4: joints at every 8th pixel (≈2m at 8m tile) for realistic surface detail.
    /// Each mood has its own block colour, mortar colour, and micro-noise level.
    @MainActor
    private static func makeGroundTexture(mood: DistrictRealityScene.Mood) -> TextureResource? {
        let key = "\(mood)_ground"
        if let cached = groundColorCache[key] { return cached }
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)

        for y in 0..<size {
            for x in 0..<size {
                // Joint line at every 8th column/row → 4×4 grid of 7×7-pixel blocks per tile.
                // At 8m tileSize this puts one expansion joint every 2m — realistic concrete.
                let isJoint = (x % 8 == 0) || (y % 8 == 0)
                let blockParity = ((x / 8) + (y / 8)) % 2 == 0
                // Deterministic micro-noise 0…12 from a simple polynomial hash of (x, y).
                let noise = (x * 7 + y * 13 + x * y) % 13

                var r: UInt8 = 0
                var g: UInt8 = 0
                var b: UInt8 = 0

                switch mood {

                case .skyscraperCorridor:
                    // Jakarta CBD — sealed concrete pavement. Values raised from the original
                    // 38-50 range which appeared as near-black and left grey undistinguishable
                    // from any fill-light blue contribution. Current mid-grey (108-126) reads
                    // clearly as concrete regardless of IBL tint.
                    if isJoint {
                        r = 62; g = 60; b = 66
                    } else {
                        let base = blockParity ? 126 : 108
                        let v = UInt8(clamping: base + noise / 2)
                        r = v; g = v; b = UInt8(clamping: Int(v) + 4)
                    }

                case .colonialSquare:
                    // Kota Tua — warm limestone cobblestones, terracotta-tinted mortar.
                    if isJoint {
                        r = 88; g = 62; b = 38
                    } else {
                        let br = blockParity ? 162 : 148
                        let bg = blockParity ? 120 : 108
                        let bb = blockParity ? 82 : 72
                        r = UInt8(clamping: br + noise)
                        g = UInt8(clamping: bg + noise / 2)
                        b = UInt8(clamping: bb + noise / 3)
                    }

                case .residentialDusk:
                    // Kemang — reddish laterite earth with worn paving joints.
                    if isJoint {
                        r = 82; g = 54; b = 36
                    } else {
                        let br = blockParity ? 140 : 128
                        let bg = blockParity ? 98 : 88
                        let bb = blockParity ? 66 : 58
                        r = UInt8(clamping: br + noise)
                        g = UInt8(clamping: bg + noise / 2)
                        b = UInt8(clamping: bb)
                    }

                case .parkDaylight:
                    // Menteng diplomatic park — tropical grass, no hard grid, organic variation.
                    let br = blockParity ? 55 : 48
                    let bg = blockParity ? 128 : 112
                    r = UInt8(clamping: br + noise / 3)
                    g = UInt8(clamping: bg + noise)
                    b = UInt8(clamping: 38 + noise / 4)

                case .coastalPark:
                    // Ancol — sandy beige compacted ground.
                    if isJoint {
                        r = 138; g = 124; b = 100
                    } else {
                        let base = blockParity ? 188 : 174
                        r = UInt8(clamping: base + noise)
                        g = UInt8(clamping: base - 14 + noise)
                        b = UInt8(clamping: base - 42 + noise / 2)
                    }

                case .beachResort:
                    // Canggu/Bali — organic sandy grain, no geometric grid.
                    // Larger noise range (0…27) gives visible grain variation at orbit scale.
                    let bigNoise = (x * 17 + y * 31 + (x ^ y)) % 27
                    let br = blockParity ? 222 : 210
                    let bg = blockParity ? 192 : 180
                    let bb = blockParity ? 125 : 113
                    r = UInt8(clamping: br - bigNoise / 3 + noise / 4)
                    g = UInt8(clamping: bg - bigNoise / 4 + noise / 4)
                    b = UInt8(clamping: bb - bigNoise / 5 + noise / 6)

                case .sacredSite:
                    // Yogyakarta — dark volcanic andesite stone, tight block pattern.
                    // Kept darker than CBD concrete to convey aged stone, but boosted from
                    // 58–68 → 75–90 so the warm-dark read survives any IBL blue contribution.
                    if isJoint {
                        r = 46; g = 40; b = 36
                    } else {
                        let base = blockParity ? 90 : 75
                        r = UInt8(clamping: base + noise / 2)
                        g = UInt8(clamping: base - 8 + noise / 3)
                        b = UInt8(clamping: base - 16 + noise / 4)
                    }

                case .highlandMorning:
                    // Bandung — cool damp grey stone, morning-mist blue shift.
                    if isJoint {
                        r = 68; g = 72; b = 80
                    } else {
                        let base = blockParity ? 116 : 104
                        r = UInt8(clamping: base + noise / 3)
                        g = UInt8(clamping: base + noise / 3)
                        b = UInt8(clamping: base + 14 + noise / 2)
                    }
                }

                let i = (y * size + x) * 4
                pixels[i] = r; pixels[i+1] = g; pixels[i+2] = b; pixels[i+3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: size * 4, space: cs,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let tex = try? TextureResource.generate(from: cg, withName: key, options: .init(semantic: .color))
        groundColorCache[key] = tex
        return tex
    }

    /// Generates a 4×4 pixel mortar-grid pavement tile and caches it for all districts.
    /// - Left column (x==0) and top row (y==0) are mortar so adjacent tiles create a seamless
    ///   1-pixel joint when the texture repeats.
    /// - Inner pixels alternate between two warm-limestone shades for subtle variation.
    @MainActor
    private static func makePavementTexture() -> TextureResource? {
        if let cached = pavementTextureCache { return cached }
        let size = 4
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let mortar = (r: UInt8(100), g: UInt8(100), b: UInt8(105))   // cool grey joint
        let stoneA = (r: UInt8(162), g: UInt8(155), b: UInt8(140))   // warm limestone
        let stoneB = (r: UInt8(145), g: UInt8(139), b: UInt8(125))   // slightly darker
        for y in 0..<size {
            for x in 0..<size {
                let i  = (y * size + x) * 4
                let px = (x == 0 || y == 0) ? mortar : ((x + y) % 2 == 0 ? stoneA : stoneB)
                pixels[i] = px.r; pixels[i+1] = px.g; pixels[i+2] = px.b; pixels[i+3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: size * 4, space: cs,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let tex = try? TextureResource.generate(from: cg, withName: "pavement_tile",
                                                options: .init(semantic: .color))
        pavementTextureCache = tex
        return tex
    }

    /// Builds one `ModelEntity` per OSM land-use kind so each zone type renders with a
    /// geographically appropriate color (rice paddy ≠ beach ≠ forest ≠ park). All zones of
    /// the same kind are merged into a single `MeshDescriptor` — draw call cost is at most
    /// 5 (the number of distinct kinds), regardless of how many individual polygons exist.
    /// Uses `UnlitMaterial` for the same reason as the previous single-entity version:
    /// PBR on large horizontal surfaces at city scale produces shadow-stripe aliasing from the
    /// directional light's fixed-resolution shadow map — UnlitMaterial eliminates this.
    @MainActor
    private static func makeGreenZoneEntities(from district: District, isNight: Bool) -> [ModelEntity] {
        guard !district.greenZones.isEmpty else { return [] }
        let upN = SIMD3<Float>(0, 1, 0)

        struct KindGeom {
            var positions: [SIMD3<Float>] = []
            var normals:   [SIMD3<Float>] = []
            var indices:   [UInt32]       = []
        }
        var groups: [String: KindGeom] = [:]

        for zone in district.greenZones {
            guard zone.polygon.count >= 3 else { continue }
            let key = zone.kind ?? "leisure=park"
            var g = groups[key, default: KindGeom()]
            let base = UInt32(g.positions.count)
            for p in zone.polygon {
                g.positions.append(SIMD3(p.x, 0.03, p.z))
                g.normals.append(upN)
            }
            for i in 1..<UInt32(zone.polygon.count - 1) {
                // CCW from orbit camera (above, +Z side). OSM polygons are CW in XZ,
                // so [0,i+1,i] is back-face; reversed [0,i,i+1] is front-face.
                g.indices += [base, base + i, base + i + 1]
            }
            groups[key] = g
        }

        var entities: [ModelEntity] = []
        for (kind, geom) in groups {
            guard !geom.positions.isEmpty else { continue }
            let safeName = kind.replacingOccurrences(of: "=", with: "_")
            var desc = MeshDescriptor(name: "green_\(safeName)")
            desc.positions  = MeshBuffer(geom.positions)
            desc.normals    = MeshBuffer(geom.normals)
            desc.primitives = .triangles(geom.indices)
            guard let mesh = try? MeshResource.generate(from: [desc]) else { continue }
            let entity = ModelEntity(mesh: mesh,
                                     materials: [UnlitMaterial(color: greenZoneColor(kind: kind, isNight: isNight))])
            entity.name = "green_\(safeName)"
            entities.append(entity)
        }
        return entities
    }

    /// Kind → `UnlitMaterial` color. Night variants are near-black across all kinds so
    /// the darkness reads as a real city night rather than a neon-lit park.
    private static func greenZoneColor(kind: String, isNight: Bool) -> UIColor {
        if isNight {
            switch kind {
            case "natural=beach":
                return UIColor(red: 0.22, green: 0.20, blue: 0.16, alpha: 1)
            case "landuse=farmland", "landuse=orchard", "landuse=meadow":
                return UIColor(red: 0.04, green: 0.12, blue: 0.03, alpha: 1)
            case "landuse=forest":
                return UIColor(red: 0.02, green: 0.06, blue: 0.01, alpha: 1)
            case "natural=scrub", "landuse=allotments":
                return UIColor(red: 0.08, green: 0.10, blue: 0.04, alpha: 1)
            default:
                return UIColor(red: 0.05, green: 0.10, blue: 0.03, alpha: 1)
            }
        } else {
            switch kind {
            case "natural=beach":
                // Warm sun-bleached volcanic sand — slightly brighter than the beachResort
                // ground so the demarcated beach strip reads as a distinct zone from the orbit camera.
                return UIColor(red: 0.88, green: 0.80, blue: 0.60, alpha: 1)
            case "landuse=farmland", "landuse=orchard", "landuse=meadow":
                // Vivid paddy green — the dominant interior land cover of Canggu, and the single
                // color that makes it instantly recognisable vs. Jakarta's concrete blanket.
                return UIColor(red: 0.22, green: 0.48, blue: 0.15, alpha: 1)
            case "landuse=forest":
                return UIColor(red: 0.10, green: 0.26, blue: 0.06, alpha: 1)
            case "natural=scrub", "landuse=allotments":
                // Dry scrub / overgrown plots — olive, distinct from cultivated paddy.
                return UIColor(red: 0.35, green: 0.42, blue: 0.18, alpha: 1)
            default:
                // Tropical park green — used by Jakarta, Bandung, Yogya parks (all leisure=park).
                return UIColor(red: 0.20, green: 0.40, blue: 0.14, alpha: 1)
            }
        }
    }

    // MARK: - Roof caps

    /// Adds 3D hip-roof caps above buildings whose style calls for a pitched roofline:
    /// balinese, colonial, javanese, religious. Glass/concrete/government keep flat tops.
    ///
    /// Geometry: one merged `MeshDescriptor` per style → 1 `ModelEntity` per style → ≤4 draw
    /// calls, regardless of building count. The cap eave starts 5 cm above the flat wall top
    /// (`heightMeters + 0.05`) to avoid Z-fighting with the existing flat-roof polygon that
    /// `makeBuildingMeshes` already places at `heightMeters`.
    ///
    /// Shape: true hip roof — two sloped side faces and two triangular hip ends meeting at a
    /// ridge along the longer bounding-box axis. Square footprints collapse to a four-sided
    /// pyramid. Overhang and pitch are style-specific so Balinese compounds read as visually
    /// distinct from Dutch colonial blocks when viewed from the orbit camera above.
    @MainActor
    private static func makeRoofCapEntities(buildings: [BuildingFootprint], isNight: Bool, quadrantIndex: Int = -1) -> [ModelEntity] {
        let capStyles: Set<BuildingStyle> = [.balinese, .colonial, .javanese, .religious]
        var styleGroups: [BuildingStyle: [BuildingFootprint]] = [:]
        for b in buildings {
            guard capStyles.contains(b.style), b.polygon.count >= 3 else { continue }
            guard b.roofType == nil else { continue }  // authored overrides via makeAuthoredRoofEntities
            styleGroups[b.style, default: []].append(b)
        }
        var entities: [ModelEntity] = []
        for style in [BuildingStyle.balinese, .colonial, .javanese, .religious] {
            guard let buildings = styleGroups[style], !buildings.isEmpty else { continue }
            var pos: [SIMD3<Float>] = []
            var nrm: [SIMD3<Float>] = []
            var idx: [UInt32] = []
            let overhang      = roofCapOverhang(for: style)
            let pitchTan      = roofCapPitchTan(for: style)
            let maxRidgeInset = roofCapMaxRidgeInset(for: style)
            for building in buildings {
                addHipRoof(building: building, overhang: overhang, pitchTan: pitchTan,
                           maxRidgeInset: maxRidgeInset,
                           positions: &pos, normals: &nrm, indices: &idx)
            }
            guard !pos.isEmpty else { continue }
            var desc = MeshDescriptor(name: "roofCap_\(style.rawValue)")
            desc.positions  = MeshBuffer(pos)
            desc.normals    = MeshBuffer(nrm)
            desc.primitives = .triangles(idx)
            guard let mesh = try? MeshResource.generate(from: [desc]) else { continue }
            var mat = PhysicallyBasedMaterial()
            mat.baseColor         = .init(tint: roofCapColor(for: style, isNight: isNight))
            mat.roughness         = .init(floatLiteral: style == .balinese ? 0.92 : 0.88)
            mat.metallic          = .init(floatLiteral: 0.0)
            if style != .religious {
                // Faint clearcoat — fired-clay tile develops a micro-glaze from rain cycling.
                mat.clearcoat          = .init(floatLiteral: 0.07)
                mat.clearcoatRoughness = .init(floatLiteral: 0.62)
            }
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            entity.name = "roofCap_\(style.rawValue)"
            entities.append(entity)
        }
        return entities
    }

    private static func roofCapOverhang(for style: BuildingStyle) -> Float {
        switch style {
        case .balinese:  return 0.80   // wide overhang — Balinese hip roofs cantilever far out
        case .colonial:  return 0.30   // Dutch colonial shophouse — moderate
        case .javanese:  return 0.60   // Joglo — wider than colonial
        case .religious: return 0.25
        default:         return 0.0
        }
    }

    private static func roofCapPitchTan(for style: BuildingStyle) -> Float {
        switch style {
        case .balinese:  return 0.839  // ~40° — steep Bali hip
        case .colonial:  return 0.625  // ~32° — moderate Dutch hip
        case .javanese:  return 1.000  // 45° — steep Joglo
        case .religious: return 0.700  // ~35°
        default:         return 0.577
        }
    }

    /// Maximum ridgeInset (metres) — the horizontal depth of each hip slope measured from the
    /// eave to the ridge, in plan. Capping this instead of ridgeH preserves a consistent pitch
    /// angle across all building sizes: small buildings get a full pyramid or short-ridge hip;
    /// large buildings get a long flat ridge with steep hip ends at each short side. Without
    /// this cap, a 20m × 30m colonial warehouse would have ridgeInset = 10m → ridgeH = 6.25m
    /// OR (with the old ridgeH cap) ridgeInset = 10m → ridgeH = 2.5m → a 14° near-flat slab.
    private static func roofCapMaxRidgeInset(for style: BuildingStyle) -> Float {
        switch style {
        case .balinese:  return 3.5   // single-storey compounds — rarely wider than 7m short side
        case .colonial:  return 4.0   // shophouses fine at natural; warehouses get long ridge
        case .javanese:  return 4.0
        case .religious: return 3.5
        default:         return 4.0
        }
    }

    private static func roofCapColor(for style: BuildingStyle, isNight: Bool) -> UIColor {
        if isNight {
            switch style {
            case .balinese:  return UIColor(red: 0.22, green: 0.08, blue: 0.03, alpha: 1)
            case .colonial:  return UIColor(red: 0.28, green: 0.11, blue: 0.04, alpha: 1)
            case .javanese:  return UIColor(red: 0.18, green: 0.07, blue: 0.02, alpha: 1)
            case .religious: return UIColor(red: 0.18, green: 0.28, blue: 0.24, alpha: 1)
            default:         return UIColor(red: 0.20, green: 0.08, blue: 0.03, alpha: 1)
            }
        } else {
            switch style {
            case .balinese:
                // Dark volcanic terracotta — aged by tropical sun, darker than Dutch colonial.
                return UIColor(red: 0.55, green: 0.22, blue: 0.10, alpha: 1)
            case .colonial:
                // Classic Dutch terracotta — matches the existing roofMaterialPreset(.colonial).
                return UIColor(red: 0.66, green: 0.27, blue: 0.12, alpha: 1)
            case .javanese:
                // Deep aged terracotta — Yogya joglo roofs are older, darker than colonial.
                return UIColor(red: 0.45, green: 0.18, blue: 0.08, alpha: 1)
            case .religious:
                // Teal/copper patina — matches existing roofMaterialPreset(.religious).
                return UIColor(red: 0.42, green: 0.64, blue: 0.56, alpha: 1)
            default:
                return UIColor(red: 0.60, green: 0.24, blue: 0.10, alpha: 1)
            }
        }
    }

    /// Appends hip-roof geometry for one building into the shared per-style accumulator arrays.
    /// Bounding-box approach: OSM polygons can be concave so computing a hip from the actual
    /// outline would need ear-clipping; the bbox gives a rectanglar envelope that's geometrically
    /// correct at orbit-camera distance and costs O(polygon) vs. O(polygon²) per building.
    private static func addHipRoof(building: BuildingFootprint, overhang: Float, pitchTan: Float,
                                    maxRidgeInset: Float,
                                    positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>],
                                    indices: inout [UInt32]) {
        let poly = building.polygon
        guard let x0r = poly.map(\.x).min(), let x1r = poly.map(\.x).max(),
              let z0r = poly.map(\.z).min(), let z1r = poly.map(\.z).max() else { return }
        // Sub-metre buildings: hip cap would be sub-pixel at orbit scale — skip.
        guard x1r - x0r >= 1.5 && z1r - z0r >= 1.5 else { return }
        // Large-footprint buildings (short side > 12 m) are warehouses, museums, or civic
        // halls — in reality they have flat gravel or metal-sheet roofs, not terracotta hip
        // tiles. Skip the cap so they keep the clean flat top from makeBuildingMeshes.
        guard min(x1r - x0r, z1r - z0r) <= 12.0 else { return }

        let x0 = x0r - overhang, x1 = x1r + overhang
        let z0 = z0r - overhang, z1 = z1r + overhang
        let W = x1 - x0, D = z1 - z0
        // 5 cm above the flat roof polygon already in the wall+roof entity.
        let eaveY = building.heightMeters + 0.05

        let E0 = SIMD3<Float>(x0, eaveY, z0)   // front-left
        let E1 = SIMD3<Float>(x1, eaveY, z0)   // front-right
        let E2 = SIMD3<Float>(x1, eaveY, z1)   // back-right
        let E3 = SIMD3<Float>(x0, eaveY, z1)   // back-left

        // Cap ridgeInset so large buildings (warehouses, plazas) keep a consistent pitch
        // and produce a long flat ridge rather than an almost-flat near-slab.
        let ridgeInset = min(min(W, D) / 2.0, maxRidgeInset)
        let ridgeH     = ridgeInset * pitchTan

        if W >= D {
            // Ridge runs along X axis
            let midZ = (z0 + z1) / 2
            let R0 = SIMD3<Float>(x0 + ridgeInset, eaveY + ridgeH, midZ)
            let R1 = SIMD3<Float>(x1 - ridgeInset, eaveY + ridgeH, midZ)

            if R1.x - R0.x < 0.1 {
                // Square footprint → pyramid
                let apex = (R0 + R1) / 2
                addRoofFace([E0, E1, apex], positions: &positions, normals: &normals, indices: &indices)
                addRoofFace([E1, E2, apex], positions: &positions, normals: &normals, indices: &indices)
                addRoofFace([E2, E3, apex], positions: &positions, normals: &normals, indices: &indices)
                addRoofFace([E3, E0, apex], positions: &positions, normals: &normals, indices: &indices)
            } else {
                addRoofFace([E0, R0, R1, E1], positions: &positions, normals: &normals, indices: &indices) // front
                addRoofFace([E2, R1, R0, E3], positions: &positions, normals: &normals, indices: &indices) // back
                addRoofFace([E0, E3, R0],     positions: &positions, normals: &normals, indices: &indices) // left hip
                addRoofFace([E1, R1, E2],     positions: &positions, normals: &normals, indices: &indices) // right hip
            }
        } else {
            // Ridge runs along Z axis
            let midX = (x0 + x1) / 2
            let R0 = SIMD3<Float>(midX, eaveY + ridgeH, z0 + ridgeInset)
            let R1 = SIMD3<Float>(midX, eaveY + ridgeH, z1 - ridgeInset)

            if R1.z - R0.z < 0.1 {
                let apex = (R0 + R1) / 2
                addRoofFace([E0, E1, apex], positions: &positions, normals: &normals, indices: &indices)
                addRoofFace([E1, E2, apex], positions: &positions, normals: &normals, indices: &indices)
                addRoofFace([E2, E3, apex], positions: &positions, normals: &normals, indices: &indices)
                addRoofFace([E3, E0, apex], positions: &positions, normals: &normals, indices: &indices)
            } else {
                addRoofFace([E0, E3, R1, R0], positions: &positions, normals: &normals, indices: &indices) // left slope
                addRoofFace([E1, R0, R1, E2], positions: &positions, normals: &normals, indices: &indices) // right slope
                addRoofFace([E0, E1, R0],     positions: &positions, normals: &normals, indices: &indices) // front hip
                addRoofFace([E3, R1, E2],     positions: &positions, normals: &normals, indices: &indices) // back hip
            }
        }
    }

    /// Appends one planar face (triangle or quad) into shared accumulator arrays.
    /// Automatically flips the winding if the computed normal points downward (n.y < 0),
    /// guaranteeing all emitted faces are visible from the orbit camera above.
    private static func addRoofFace(_ verts: [SIMD3<Float>],
                                     positions: inout [SIMD3<Float>],
                                     normals: inout [SIMD3<Float>],
                                     indices: inout [UInt32]) {
        guard verts.count >= 3 else { return }
        var n = normalize(cross(verts[1] - verts[0], verts[2] - verts[0]))
        var fv = verts
        if n.y < 0 { n = -n; fv = Array(verts.reversed()) }
        let base = UInt32(positions.count)
        for v in fv { positions.append(v); normals.append(n) }
        for i in 1..<UInt32(fv.count - 1) { indices += [base, base + i, base + i + 1] }
    }

    // MARK: - Authored roof overrides

    /// Builds conical / thatched / dome roof entities for buildings whose `roofType` was set by
    /// an authored-overrides sidecar (`<district>_authored.json`). One `MeshDescriptor` per roof
    /// type → ≤3 extra draw calls regardless of how many buildings are overridden.
    @MainActor
    private static func makeAuthoredRoofEntities(buildings: [BuildingFootprint], isNight: Bool, quadrantIndex: Int = -1) -> [ModelEntity] {
        let authored = buildings.filter { $0.roofType != nil && $0.roofType != "flat" }
        guard !authored.isEmpty else { return [] }

        struct TypeGeom {
            var pos: [SIMD3<Float>] = []
            var nrm: [SIMD3<Float>] = []
            var idx: [UInt32]       = []
        }
        var groups: [String: TypeGeom] = [:]

        for b in authored {
            guard let rt = b.roofType, rt != "flat", b.polygon.count >= 3 else { continue }
            var g = groups[rt, default: TypeGeom()]
            switch rt {
            case "conical":
                addConicalRoof(building: b, overhang: 0.5, pitchTan: 1.19,
                               positions: &g.pos, normals: &g.nrm, indices: &g.idx)
            case "dome":
                addDomeRoof(building: b, overhang: 0.3,
                            positions: &g.pos, normals: &g.nrm, indices: &g.idx)
            case "thatched":
                // Steep alang-alang thatch — pitchTan ≈ 54°, wide eave, short ridge
                addHipRoof(building: b, overhang: 0.6, pitchTan: 1.40, maxRidgeInset: 2.5,
                           positions: &g.pos, normals: &g.nrm, indices: &g.idx)
            case "hip":
                addHipRoof(building: b,
                           overhang: roofCapOverhang(for: b.style),
                           pitchTan: roofCapPitchTan(for: b.style),
                           maxRidgeInset: roofCapMaxRidgeInset(for: b.style),
                           positions: &g.pos, normals: &g.nrm, indices: &g.idx)
            default: break
            }
            groups[rt] = g
        }

        var entities: [ModelEntity] = []
        for (rt, geom) in groups {
            guard !geom.pos.isEmpty else { continue }
            var desc = MeshDescriptor(name: "authoredRoof_\(rt)")
            desc.positions  = MeshBuffer(geom.pos)
            desc.normals    = MeshBuffer(geom.nrm)
            desc.primitives = .triangles(geom.idx)
            guard let mesh = try? MeshResource.generate(from: [desc]) else { continue }
            var mat = PhysicallyBasedMaterial()
            switch rt {
            case "conical":
                mat.baseColor = .init(tint: isNight
                    ? UIColor(red: 0.22, green: 0.08, blue: 0.03, alpha: 1)
                    : UIColor(red: 0.55, green: 0.22, blue: 0.10, alpha: 1))
                mat.roughness = .init(floatLiteral: 0.90)
                mat.metallic  = .init(floatLiteral: 0.0)
            case "dome":
                mat.baseColor = .init(tint: isNight
                    ? UIColor(red: 0.18, green: 0.22, blue: 0.28, alpha: 1)
                    : UIColor(red: 0.62, green: 0.66, blue: 0.72, alpha: 1))
                mat.roughness          = .init(floatLiteral: 0.55)
                mat.metallic           = .init(floatLiteral: 0.08)
                mat.clearcoat          = .init(floatLiteral: 0.20)
                mat.clearcoatRoughness = .init(floatLiteral: 0.45)
            default: // thatched, hip, fallback
                mat.baseColor = .init(tint: isNight
                    ? UIColor(red: 0.08, green: 0.05, blue: 0.02, alpha: 1)
                    : UIColor(red: 0.28, green: 0.18, blue: 0.08, alpha: 1))
                mat.roughness = .init(floatLiteral: 0.97)
                mat.metallic  = .init(floatLiteral: 0.0)
            }
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            entity.name = "authoredRoof_\(rt)"
            entities.append(entity)
        }
        return entities
    }

    private static func addConicalRoof(building: BuildingFootprint, overhang: Float, pitchTan: Float,
                                        positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>],
                                        indices: inout [UInt32]) {
        let poly = building.polygon
        guard let x0r = poly.map(\.x).min(), let x1r = poly.map(\.x).max(),
              let z0r = poly.map(\.z).min(), let z1r = poly.map(\.z).max() else { return }
        guard x1r - x0r >= 1.0 && z1r - z0r >= 1.0 else { return }
        let cx = (x0r + x1r) / 2
        let cz = (z0r + z1r) / 2
        let radius = min(x1r - x0r, z1r - z0r) / 2.0 + overhang
        let eaveY  = building.heightMeters + 0.05
        let apex   = SIMD3<Float>(cx, eaveY + radius * pitchTan, cz)
        let N = 8
        let eaveVerts: [SIMD3<Float>] = (0..<N).map { i in
            let angle = Float(i) / Float(N) * 2 * .pi
            return SIMD3<Float>(cx + radius * cos(angle), eaveY, cz + radius * sin(angle))
        }
        for i in 0..<N {
            addRoofFace([apex, eaveVerts[i], eaveVerts[(i+1) % N]],
                        positions: &positions, normals: &normals, indices: &indices)
        }
    }

    private static func addDomeRoof(building: BuildingFootprint, overhang: Float,
                                     positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>],
                                     indices: inout [UInt32]) {
        let poly = building.polygon
        guard let x0r = poly.map(\.x).min(), let x1r = poly.map(\.x).max(),
              let z0r = poly.map(\.z).min(), let z1r = poly.map(\.z).max() else { return }
        guard x1r - x0r >= 1.0 && z1r - z0r >= 1.0 else { return }
        let cx     = (x0r + x1r) / 2
        let cz     = (z0r + z1r) / 2
        let radius = min(x1r - x0r, z1r - z0r) / 2.0 + overhang
        let baseY  = building.heightMeters + 0.05
        let slices = 8
        // 3 latitude rings from the pole at φ = 30°, 60°, 90°
        let stackPhis: [Float] = [.pi / 6, .pi / 3, .pi / 2]
        let rings: [[SIMD3<Float>]] = stackPhis.map { phi in
            let y = baseY + radius * cos(phi)
            let r = radius * sin(phi)
            return (0..<slices).map { i in
                let a = Float(i) / Float(slices) * 2 * .pi
                return SIMD3<Float>(cx + r * cos(a), y, cz + r * sin(a))
            }
        }
        let apex = SIMD3<Float>(cx, baseY + radius, cz)
        for i in 0..<slices {
            addRoofFace([apex, rings[0][i], rings[0][(i+1) % slices]],
                        positions: &positions, normals: &normals, indices: &indices)
        }
        for r in 0..<(rings.count - 1) {
            for i in 0..<slices {
                let a = rings[r][i],        b = rings[r][(i+1) % slices]
                let c = rings[r+1][(i+1) % slices], d = rings[r+1][i]
                addRoofFace([a, b, c], positions: &positions, normals: &normals, indices: &indices)
                addRoofFace([a, c, d], positions: &positions, normals: &normals, indices: &indices)
            }
        }
    }

    // MARK: - Floating POI labels (minimal text style)

    private static var poiLabelTextureCache: [String: TextureResource] = [:]

    /// Builds minimal floating text labels for curated POIs.
    ///
    /// Assembly (2 draw calls total):
    ///   • Thin white hairline stem for each POI (all merged — 1 draw call)
    ///   • Horizontal name-pill card per POI (1 entity each, unique texture)
    ///
    /// Cards are HORIZONTAL (Rx −π/2 rotation): orbit camera looks down at ~29°,
    /// vertical cards appear nearly edge-on and are invisible.
    @MainActor
    private static func makePOILabelEntities(districtName: String,
                                              districtAnchor: GeoCoord,
                                              districtCentroid: SIMD2<Float>,
                                              districtExtent: Float,
                                              isNight: Bool) -> Entity? {
        guard let collection = CangguPOICollection.load(for: districtName),
              !collection.pois.isEmpty else { return nil }

        let root = Entity()
        root.name = "poiLabels"

        let stakeH: Float = districtExtent * 0.010
        let stakeW: Float = districtExtent * 0.0003

        var stakePos:  [SIMD3<Float>] = []
        var stakeNorm: [SIMD3<Float>] = []
        var stakeIdx:  [UInt32]       = []

        let stemColor = UIColor(white: 1.0, alpha: isNight ? 0.55 : 0.38)

        for poi in collection.pois {
            let offset = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                .sceneOffset(from: districtAnchor)
            let px = offset.x, pz = offset.z

            // Hairline stem (merged — 1 entity for all stems)
            appendPillarQuad(to: &stakePos, normals: &stakeNorm, indices: &stakeIdx,
                             cx: px, cz: pz, w: stakeW, h: stakeH)

            // Horizontal name-pill card
            let cardW: Float = poi.isFeatured ? districtExtent * 0.013 : districtExtent * 0.008
            let cardH: Float = districtExtent * 0.0028
            let cardMesh = MeshResource.generatePlane(width: cardW, height: cardH,
                                                      cornerRadius: cardH * 0.40)

            let night = isNight ? "n" : "d"
            let texKey = "\(poi.id)_\(night)"
            let texture: TextureResource?
            if let cached = poiLabelTextureCache[texKey] {
                texture = cached
            } else {
                texture = makeMinimalLabelTexture(poi: poi, isNight: isNight)
                if let t = texture { poiLabelTextureCache[texKey] = t }
            }

            var cardMat = UnlitMaterial()
            if let tex = texture {
                cardMat.color = .init(tint: .white, texture: .init(tex))
            } else {
                cardMat.color = .init(tint: UIColor(white: 0.08, alpha: 0.70))
            }

            let card = ModelEntity(mesh: cardMesh, materials: [cardMat])
            card.name = "poi:\(poi.id)"

            // `generatePlane` creates XY plane (face +Z). Rx(−π/2) rotates to XZ (face +Y)
            // so orbit camera looking down always sees the card face-on.
            card.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
            card.position = SIMD3(px, stakeH + districtExtent * 0.0025, pz)

            root.addChild(card)
        }

        // Merged stem entity (1 draw call)
        if !stakePos.isEmpty {
            var desc = MeshDescriptor(name: "poiStems")
            desc.positions  = MeshBuffer(stakePos)
            desc.normals    = MeshBuffer(stakeNorm)
            desc.primitives = .triangles(stakeIdx)
            if let mesh = try? MeshResource.generate(from: [desc]) {
                var mat = UnlitMaterial()
                mat.color = .init(tint: stemColor)
                let stems = ModelEntity(mesh: mesh, materials: [mat])
                stems.name = "poiStems"
                root.addChild(stems)
            }
        }

        return root
    }

    /// Appends a single front-face quad (stem) to the merged geometry accumulators.
    private static func appendPillarQuad(
        to positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>], indices: inout [UInt32],
        cx: Float, cz: Float, w: Float, h: Float
    ) {
        let base = UInt32(positions.count)
        let n = SIMD3<Float>(0, 0, 1)
        positions += [SIMD3(cx - w/2, 0, cz), SIMD3(cx + w/2, 0, cz),
                      SIMD3(cx + w/2, h, cz), SIMD3(cx - w/2, h, cz)]
        normals   += [n, n, n, n]
        indices   += [base, base+1, base+2, base, base+2, base+3]
    }

    /// Generates a minimal floating label texture: dark pill background + white name + category dot.
    @MainActor
    private static func makeMinimalLabelTexture(poi: CangguPOI, isNight: Bool) -> TextureResource? {
        let isFeatured = poi.isFeatured
        let imgW: CGFloat = isFeatured ? 360 : 260
        let imgH: CGFloat = 56

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: imgW, height: imgH))
        let uiImage = renderer.image { _ in
            UIColor(red: 0.04, green: 0.04, blue: 0.08,
                    alpha: isNight ? 0.78 : 0.65).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: imgW, height: imgH),
                         cornerRadius: imgH * 0.45).fill()

            if isFeatured {
                UIColor(red: 0.20, green: 0.82, blue: 0.65, alpha: 0.55).setStroke()
                let border = UIBezierPath(roundedRect: CGRect(x: 1, y: 1,
                                                               width: imgW - 2, height: imgH - 2),
                                          cornerRadius: imgH * 0.44)
                border.lineWidth = 1.0
                border.stroke()
            }

            let dotColor: UIColor = isFeatured
                ? UIColor(red: 0.20, green: 0.82, blue: 0.65, alpha: 0.90)
                : UIColor(white: 0.55, alpha: 0.70)
            dotColor.setFill()
            let dotSize: CGFloat = 7
            UIBezierPath(ovalIn: CGRect(x: 14, y: (imgH - dotSize) / 2,
                                         width: dotSize, height: dotSize)).fill()

            let fontSize: CGFloat = isFeatured ? 26 : 22
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize,
                                         weight: isFeatured ? .semibold : .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(isNight ? 1.0 : 0.92)
            ]
            let maxChars = isFeatured ? 18 : 14
            let name = poi.name.count > maxChars
                ? String(poi.name.prefix(maxChars - 1)) + "…" : poi.name
            name.draw(at: CGPoint(x: 26, y: (imgH - fontSize * 1.15) / 2),
                      withAttributes: nameAttrs)
        }

        guard let cgImage = uiImage.cgImage else { return nil }
        return try? TextureResource.generate(
            from: cgImage,
            withName: "label_\(poi.id)_\(isNight ? "n" : "d")",
            options: .init(semantic: .color)
        )
    }

    // MARK: - Focus building beacon

    /// A glowing beacon + 3D text above the focus building — shared by all 3D views.
    /// `BillboardComponent` and `MeshResource.generateCylinder` are both iOS 18+-only
    /// (confirmed against this project's iOS 17.0 target — see CLAUDE.md). A thin box stands
    /// in for the cylinder; the text faces `facing` once at creation rather than tracking the camera.
    static func makeFocusBeacon(for building: BuildingFootprint, districtExtent: Float, facing: SIMD3<Float> = SIMD3(0, 0, 1)) -> Entity {
        let group = Entity()
        let xs = building.polygon.map(\.x)
        let zs = building.polygon.map(\.z)
        let centroidX = xs.reduce(0, +) / Float(xs.count)
        let centroidZ = zs.reduce(0, +) / Float(zs.count)

        let beaconHeight = max(building.heightMeters * 0.6, districtExtent * 0.03)
        let beaconWidth  = districtExtent * 0.008
        var beaconMat    = PhysicallyBasedMaterial()
        beaconMat.baseColor       = .init(tint: .white)
        beaconMat.emissiveColor   = .init(color: UIColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1))
        beaconMat.emissiveIntensity = 4
        let beaconMesh = MeshResource.generateBox(width: beaconWidth, height: beaconHeight, depth: beaconWidth)
        let beacon = ModelEntity(mesh: beaconMesh, materials: [beaconMat])
        beacon.position = SIMD3(centroidX, building.heightMeters + beaconHeight / 2 + districtExtent * 0.015, centroidZ)
        group.addChild(beacon)

        let textMesh = MeshResource.generateText(
            building.name ?? "Focus",
            extrusionDepth: 0.05,
            font: .systemFont(ofSize: 3, weight: .semibold)
        )
        let textEntity = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: .white)])
        textEntity.position = SIMD3(centroidX, building.heightMeters + beaconHeight + districtExtent * 0.02, centroidZ)
        textEntity.look(at: textEntity.position + facing, from: textEntity.position, relativeTo: nil)
        group.addChild(textEntity)

        return group
    }

    // MARK: - Materials

    /// Style-specific roof material — visually distinct from the wall material so that the
    /// orbit camera (mostly looking down) reads the scene as architecturally rich rather than
    /// a sea of same-material boxes.
    private static func roofMaterialPreset(for style: BuildingStyle, isNight: Bool) -> any RealityKit.Material {
        // modernGlass rooftops use UnlitMaterial for the same reason green zones do:
        // ARView's non-removable studio IBL floods upward-facing PBR surfaces (normal=(0,1,0))
        // with its full overhead ambient even at metallic=0.10 + roughness=0.70, rendering a
        // grey (0.13) base as bright teal. UnlitMaterial sidesteps the IBL entirely.
        // Architecturally correct — HVAC/gravel penthouse is not a specular surface.
        if style == .modernGlass {
            var m = UnlitMaterial()
            m.color = .init(tint: isNight
                ? UIColor(red: 0.06, green: 0.08, blue: 0.15, alpha: 1) // dark cool-blue equipment glow
                : UIColor(white: 0.10, alpha: 1))                         // dark charcoal HVAC deck
            return m
        }

        var mat = PhysicallyBasedMaterial()
        switch style {
        case .colonial:
            // Red clay tile — the single most recognisable visual feature of colonial Jakarta
            // from above. Dutch-era shophouses and civic buildings universally use terracotta.
            let day = UIColor(red: 0.66, green: 0.27, blue: 0.12, alpha: 1)
            let ngt = UIColor(red: 0.22, green: 0.10, blue: 0.06, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.93)
            mat.metallic    = .init(floatLiteral: 0.0)
            mat.clearcoat   = .init(floatLiteral: 0.05)   // faint glaze from rain
            mat.clearcoatRoughness = .init(floatLiteral: 0.80)
        case .modernGlass:
            break   // handled above — unreachable
        case .modernConcrete:
            // Light grey concrete rooftop — typical of modern Jakarta residential/commercial.
            mat.baseColor   = .init(tint: UIColor(white: isNight ? 0.30 : 0.62, alpha: 1))
            mat.roughness   = .init(floatLiteral: 0.88)
            mat.metallic    = .init(floatLiteral: 0.0)
        case .government:
            // Pale warm stone — civic and office buildings tend toward lighter, often
            // cream-coloured rooftop parapets.
            let day = UIColor(red: 0.76, green: 0.73, blue: 0.66, alpha: 1)
            let ngt = UIColor(red: 0.30, green: 0.29, blue: 0.26, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.84)
            mat.metallic    = .init(floatLiteral: 0.0)
        case .religious:
            // Muted teal/copper-patina dome — Jakarta mosques and churches often have
            // glazed green tile or oxidised copper domes visible from any elevated viewpoint.
            mat.baseColor   = .init(tint: UIColor(red: 0.42, green: 0.64, blue: 0.56, alpha: 1))
            mat.roughness   = .init(floatLiteral: 0.55)
            mat.metallic    = .init(floatLiteral: 0.12)
            mat.clearcoat   = .init(floatLiteral: 0.30)
            mat.clearcoatRoughness = .init(floatLiteral: 0.35)
            if isNight {
                mat.emissiveColor     = .init(color: UIColor(red: 0.2, green: 0.5, blue: 0.4, alpha: 1))
                mat.emissiveIntensity = 0.55
            }
        case .balinese:
            // Warm volcanic stone / terracotta compound rooftop — low-pitch hip roofs,
            // often dark brown or terracotta. Visually distinct from Javanese colonial
            // (which is cream/buff). Rain-wet glaze on the fired-clay tiles.
            let day = UIColor(red: 0.48, green: 0.32, blue: 0.18, alpha: 1)  // dark terracotta
            let ngt = UIColor(red: 0.18, green: 0.12, blue: 0.07, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.90)
            mat.metallic    = .init(floatLiteral: 0.0)
            mat.clearcoat   = .init(floatLiteral: 0.06)
            mat.clearcoatRoughness = .init(floatLiteral: 0.85)
        case .javanese:
            // Traditional Javanese red clay tile — darker than Dutch colonial (0.66/0.27/0.12);
            // Joglo shophouses and the Kraton walls have a deeper, older burnt-sienna terracotta,
            // weathered rather than the bright red of a newly-fired Dutch roof.
            let day = UIColor(red: 0.52, green: 0.22, blue: 0.10, alpha: 1)  // deep burnt sienna
            let ngt = UIColor(red: 0.18, green: 0.08, blue: 0.04, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.95)   // weathered, not glazed
            mat.metallic    = .init(floatLiteral: 0.0)
            mat.clearcoat   = .init(floatLiteral: 0.03)   // faint rain-wet sheen only
            mat.clearcoatRoughness = .init(floatLiteral: 0.88)
        }
        return mat
    }

    @MainActor
    private static func pooledMaterial(for style: BuildingStyle, variation: Float, isNight: Bool) -> PhysicallyBasedMaterial {
        let bucket = min(Int(variation * 10), 9)
        let key    = "\(style.rawValue)_\(bucket)_\(isNight)"
        if let cached = materialPool[key] { return cached }
        let windowTex: TextureResource? = isNight ? cachedWindowTexture(for: style) : nil
        let mat = materialPreset(for: style, variation: Float(bucket) * 0.1 + 0.05, isNight: isNight, windowTexture: windowTex)
        materialPool[key] = mat
        return mat
    }

    @MainActor
    private static func cachedWindowTexture(for style: BuildingStyle) -> TextureResource? {
        if let cached = windowTextureCache[style.rawValue] { return cached }
        let tex = makeWindowTexture(for: style)
        windowTextureCache[style.rawValue] = tex
        return tex
    }

    @MainActor
    private static func makeWindowTexture(for style: BuildingStyle) -> TextureResource? {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        // density = fraction of window cells that are lit.  modernGlass uses 0.25 (not 0.70)
        // so at-distance the facade reads as scattered bright spots on dark glass, not a
        // uniform amber glow — the contrast between dark glass (baseColor ≈ 0.07) and lit
        // windows (emissiveIntensity 2.5) only works when the dark area dominates the texture.
        let (cols, rows, winW, winH, density): (Int, Int, Int, Int, Float)
        switch style {
        case .modernGlass:    (cols, rows, winW, winH, density) = (8, 16, 3, 4, 0.25)
        case .modernConcrete: (cols, rows, winW, winH, density) = (6, 12, 2, 3, 0.28)
        case .colonial:       (cols, rows, winW, winH, density) = (4,  6, 3, 3, 0.25)
        case .government:     (cols, rows, winW, winH, density) = (5,  8, 2, 4, 0.30)
        case .religious:      (cols, rows, winW, winH, density) = (3,  4, 5, 6, 0.15)
        case .balinese:       (cols, rows, winW, winH, density) = (3,  4, 4, 3, 0.10)
        case .javanese:       (cols, rows, winW, winH, density) = (4,  5, 3, 3, 0.18)
        }
        let cellW = size / cols, cellH = size / rows
        var seed: UInt32 = 2166136261
        for byte in style.rawValue.utf8 { seed ^= UInt32(byte); seed = seed &* 16777619 }
        for row in 0..<rows {
            for col in 0..<cols {
                seed = seed &* 1664525 &+ 1013904223
                guard Float(seed & 0xFF) / 255.0 < density else { continue }
                let startX = col * cellW + max(0, (cellW - winW) / 2)
                let startY = row * cellH + max(0, (cellH - winH) / 2)
                for wy in 0..<min(winH, cellH) {
                    for wx in 0..<min(winW, cellW) {
                        let px = startX + wx, py = startY + wy
                        guard px < size, py < size else { continue }
                        let i = (py * size + px) * 4
                        pixels[i] = 255; pixels[i+1] = 220; pixels[i+2] = 140; pixels[i+3] = 255
                    }
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: size * 4, space: cs,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource.generate(from: cg, withName: "windows_\(style.rawValue)",
                                             options: .init(semantic: .hdrColor))
    }

    private static func materialPreset(for style: BuildingStyle, variation: Float, isNight: Bool, windowTexture: TextureResource? = nil) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        let wobble = (variation - 0.5) * 2
        let cgWobble = CGFloat(wobble)

        switch style {
        case .modernGlass:
            if isNight {
                // At night a glass tower is primarily a window-grid emitter, not a sky mirror.
                // Drop metallic/roughness so the dim studio IBL no longer floods the facade with
                // specular white — the near-black base lets amber window dots pop as point sources.
                material.baseColor = .init(tint: UIColor(red: 0.06, green: 0.09, blue: 0.14, alpha: 1))
                material.metallic  = .init(floatLiteral: 0.20 + 0.08 * abs(wobble))
                material.roughness = .init(floatLiteral: 0.30 + 0.10 * abs(wobble))
                material.clearcoat = .init(floatLiteral: 0.12)
                material.clearcoatRoughness = .init(floatLiteral: 0.45)
            } else {
                // Three visually distinct curtain-wall identities for the Jakarta skyline:
                // - midnight navy: dark mirror glass — SCBD tower identity, very dark
                // - cool grey-blue: neutral modern office — majority mid-range towers
                // - neutral silver: near-achromatic — reads warm or cool depending on
                //   which light source (fill vs. IBL) hits each face. Avoids both
                //   "double-teal" (old petrol teal base + blue IBL) and "mud-brown"
                //   (0.42/0.36/0.24 warm bronze at 0.52 metallic overwhelmed by warm fill).
                let glassTint: UIColor
                if variation < 0.34 {
                    glassTint = UIColor(red: 0.07, green: 0.10, blue: 0.26, alpha: 1) // midnight navy
                } else if variation < 0.68 {
                    glassTint = UIColor(red: 0.26, green: 0.28, blue: 0.36, alpha: 1) // cool grey-blue
                } else {
                    glassTint = UIColor(red: 0.32, green: 0.31, blue: 0.31, alpha: 1) // neutral silver
                }
                material.baseColor = .init(tint: glassTint)
                // metallic 0.46: glass needs some specular to read as reflective, but above 0.50
                // the warm fill light (0.85,0.72,0.52) dominates lit faces and turns them brown.
                // At 0.46 the silver bucket reads as warm-neutral on sun faces and cool-dark on
                // shadow faces; the navy bucket stays dark; the grey-blue stays bluish.
                material.metallic  = .init(floatLiteral: 0.46 + 0.06 * abs(wobble))
                material.roughness = .init(floatLiteral: 0.18 + 0.08 * abs(wobble))
                material.clearcoat = .init(floatLiteral: 0.28)
                material.clearcoatRoughness = .init(floatLiteral: 0.14)
            }
        case .modernConcrete:
            material.baseColor = .init(tint: UIColor(white: 0.40 + 0.06 * cgWobble, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.08)
            material.roughness = .init(floatLiteral: 0.60 + 0.10 * abs(wobble))
            material.clearcoat = .init(floatLiteral: 0.10)
            material.clearcoatRoughness = .init(floatLiteral: 0.50)
        case .colonial:
            // Night: darken the lime-plaster facade — the wall goes into shadow, interior
            // warmth spilling from windows becomes the dominant visual signal.
            let dayR = 0.84 + 0.04 * cgWobble
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayR * 0.35, green: 0.79 * 0.35, blue: 0.62 * 0.35, alpha: 1)
                : UIColor(red: dayR, green: 0.79, blue: 0.62, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.02)
            material.roughness = .init(floatLiteral: 0.82 + 0.09 * abs(wobble))
        case .government:
            // White/cream marble — strongly differentiates government buildings from colonial
            // (warm buff) and modernConcrete (mid-grey). Jakarta's civic and ministry buildings
            // are consistently rendered in light Cipicung limestone and white marble cladding.
            material.baseColor = .init(tint: UIColor(red: 0.88 + 0.03 * cgWobble, green: 0.86, blue: 0.82, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.0)
            material.roughness = .init(floatLiteral: 0.62 + 0.06 * abs(wobble))
            material.clearcoat = .init(floatLiteral: 0.18)
            material.clearcoatRoughness = .init(floatLiteral: 0.35)
        case .religious:
            material.baseColor = .init(tint: UIColor(white: 0.91 + 0.03 * cgWobble, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.0)
            material.roughness = .init(floatLiteral: 0.40 + 0.06 * abs(wobble))
            material.clearcoat = .init(floatLiteral: 0.22)
            material.clearcoatRoughness = .init(floatLiteral: 0.28)
        case .balinese:
            // Dark volcanic andesite / paras stone walls — Bali's traditional building
            // material is grey-brown volcanic tuff and rendered lime-wash over brick, NOT
            // the pale cream of Javanese colonial. Must read as a distinctly darker warm
            // brown from the orbit camera. Previous value (0.72, 0.58, 0.42) was too light
            // and bleached to near-white under any directional sun — confirmed visually vs.
            // Kota Tua screenshots. Darkened to (0.48, 0.34, 0.22): reads as correct warm
            // volcanic stone under 35 klux and retains amber identity at night with emissive.
            material.baseColor = .init(tint: UIColor(red: 0.48 + 0.04 * cgWobble, green: 0.34, blue: 0.22, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.0)
            material.roughness = .init(floatLiteral: 0.86 + 0.06 * abs(wobble))
            material.clearcoat = .init(floatLiteral: 0.04)
            material.clearcoatRoughness = .init(floatLiteral: 0.90)
        case .javanese:
            // Traditional Javanese shophouse wall — warm buff plaster over brick, older and
            // dustier than Dutch colonial cream. Malioboro shophouses have a distinctive
            // warm ochre-buff hue (Jogja's sandstone and old limewash), distinct from:
            // - colonial (brighter, cooler Dutch lime-plaster, 0.84/0.79/0.62)
            // - balinese (dark volcanic stone, 0.48/0.34/0.22)
            // Three variation buckets: cool dusty buff / warm standard buff / amber-gold,
            // giving tonal variety along Malioboro's long shophouse row.
            let dayR = 0.72 + 0.10 * cgWobble   // 0.62–0.82 warm buff range
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayR * 0.28, green: 0.56 * 0.28, blue: 0.40 * 0.28, alpha: 1)
                : UIColor(red: dayR, green: 0.56, blue: 0.40, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.01)
            material.roughness = .init(floatLiteral: 0.85 + 0.06 * abs(wobble))
            material.clearcoat = .init(floatLiteral: 0.04)   // faint rain-washed plaster sheen
            material.clearcoatRoughness = .init(floatLiteral: 0.85)
        }

        if isNight {
            switch style {
            case .modernGlass:
                // Cool fluorescent/LED office light through dark glass. Window texture enabled:
                // at 25% cell density, scattered cool-blue dots read as individual offices on
                // medium towers (30–80m); on taller buildings the texture adds micro-sparkle rather
                // than averaging to a flat tone. The dark base (0.06, 0.09, 0.14) ensures dark glass
                // dominates and lit cells pop as point sources.
                material.emissiveColor     = .init(color: UIColor(red: 0.80, green: 0.88, blue: 1.0, alpha: 1))
                material.emissiveIntensity = 0.55
                if let windowTexture {
                    material.emissiveColor.texture = .init(windowTexture)
                }
            default:
                // Warm incandescent/warm-LED interior glow — residential, shophouse, civic,
                // religious. Colonial wall-darkening above makes these amber spots legible even at
                // orbit scale (3–4 UV repeats on a 10m building vs 70+ for a 200m glass tower).
                let intensity: Float = switch style {
                case .modernConcrete: 0.65
                case .colonial:       0.35
                case .government:     0.28
                case .religious:      0.85
                case .balinese:       0.20  // Bali has less dense electric lighting than Java
                case .javanese:       0.30  // Malioboro shophouses: warm amber lanterns, moderate density
                default:              0.35
                }
                material.emissiveColor     = .init(color: UIColor(red: 1.0, green: 0.84, blue: 0.55, alpha: 1))
                material.emissiveIntensity = intensity
                if let windowTexture {
                    material.emissiveColor.texture = .init(windowTexture)
                }
            }
        }
        return material
    }

    // MARK: - Spatial LOD helpers

    /// Assigns each building to one of 4 spatial quadrants: 0=NW, 1=NE, 2=SW, 3=SE,
    /// relative to the district's `buildingCentroid`. Each building is placed by its own
    /// polygon centroid so point-on-boundary buildings stay in one consistent quadrant.
    private static func splitIntoQuadrants(_ buildings: [BuildingFootprint],
                                            centroid: (x: Float, z: Float)) -> [[BuildingFootprint]] {
        var quads: [[BuildingFootprint]] = [[], [], [], []]
        for b in buildings {
            let n = Float(b.polygon.count)
            guard n > 0 else { continue }
            let bx = b.polygon.map(\.x).reduce(0, +) / n
            let bz = b.polygon.map(\.z).reduce(0, +) / n
            let idx = (bx >= centroid.x ? 1 : 0) | (bz >= centroid.z ? 2 : 0)
            quads[idx].append(b)
        }
        return quads
    }

    /// Simplified AABB-box representation of a building set — one merged `ModelEntity` with
    /// one axis-aligned box per building (top face + 4 walls). Used for far-LOD quadrant tiers
    /// in venue mode when those quadrants are more than `extent × 0.5` from the camera:
    /// a distant cluster reads correctly as "there are buildings there" at a fraction of the
    /// polygon-extrusion vertex count.
    @MainActor
    private static func makeFarTierEntity(buildings: [BuildingFootprint], isNight: Bool, quadrantIndex: Int) -> ModelEntity? {
        var positions: [SIMD3<Float>] = []
        var normals:   [SIMD3<Float>] = []
        var indices:   [UInt32]       = []

        for b in buildings {
            guard b.polygon.count >= 3, polygonArea(b.polygon) >= 4.0 else { continue }
            let xs = b.polygon.map(\.x)
            let zs = b.polygon.map(\.z)
            guard let x0 = xs.min(), let x1 = xs.max(), let z0 = zs.min(), let z1 = zs.max() else { continue }
            guard x1 - x0 >= 0.5, z1 - z0 >= 0.5 else { continue }

            let v = deterministicVariation(seed: b.osmID)
            let h: Float = b.isHeightEstimated ? b.heightMeters * (0.80 + v * 0.40) : b.heightMeters

            let base = UInt32(positions.count)
            positions += [
                SIMD3(x0, 0, z0), SIMD3(x1, 0, z0), SIMD3(x1, 0, z1), SIMD3(x0, 0, z1),
                SIMD3(x0, h, z0), SIMD3(x1, h, z0), SIMD3(x1, h, z1), SIMD3(x0, h, z1)
            ]
            let nUp = SIMD3<Float>(0, 1, 0); let nDn = SIMD3<Float>(0, -1, 0)
            normals += [nDn, nDn, nDn, nDn, nUp, nUp, nUp, nUp]
            // top
            indices += [base+4, base+5, base+6, base+4, base+6, base+7]
            // walls (z-min, x-max, z-max, x-min)
            indices += [base+0, base+4, base+5, base+0, base+5, base+1]
            indices += [base+1, base+5, base+6, base+1, base+6, base+2]
            indices += [base+2, base+6, base+7, base+2, base+7, base+3]
            indices += [base+3, base+7, base+4, base+3, base+4, base+0]
        }

        guard !positions.isEmpty else { return nil }
        var desc = MeshDescriptor(name: "far_q\(quadrantIndex)")
        desc.positions  = MeshBuffer(positions)
        desc.normals    = MeshBuffer(normals)
        desc.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [desc]) else { return nil }

        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: isNight
            ? UIColor(red: 0.10, green: 0.09, blue: 0.08, alpha: 1)
            : UIColor(red: 0.42, green: 0.38, blue: 0.32, alpha: 1))
        mat.roughness = .init(floatLiteral: 0.88)
        mat.metallic  = .init(floatLiteral: 0.0)

        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.name = "far_q\(quadrantIndex)"
        return entity
    }

    // MARK: - Palm trees

    /// Computes all palm positions for `district` from three placement rules:
    /// (1) both sides of roads that qualify by type, offset perpendicular to the center line;
    /// (2) the perimeter of `natural=beach` green zones (palms line the landward edge);
    /// (3) the perimeter of `landuse=farmland`, `landuse=orchard`, and `leisure=park` zones
    ///     (palms frame the transition between cultivated land and built area).
    ///
    /// Avoidance is O(n) via two spatial hash-sets: a 6-metre building-avoidance grid and a
    /// 5-metre palm-separation grid. Cached by district name — district data is immutable.
    @MainActor
    private static func districtPalmPositions(district: District) -> [(x: Float, z: Float, h: Float)] {
        if let cached = palmPositionCache[district.name] { return cached }

        // Palm trees are specific to tropical beach/rice districts. Districts without
        // beach, farmland, or orchard green zones are not in that category — Jakarta,
        // Bandung, and Yogya districts have only `leisure=park` zones and get no palms.
        let hasTropicalZones = district.greenZones.contains {
            $0.kind == "natural=beach" || $0.kind == "landuse=farmland" || $0.kind == "landuse=orchard"
        }
        guard hasTropicalZones else {
            palmPositionCache[district.name] = []
            return []
        }

        var candidates: [(Float, Float)] = []

        // 1. Road-edge palms: both sides of primary / secondary / tertiary / residential roads.
        for road in district.roads {
            guard let kind = road.kind,
                  ["primary", "secondary", "tertiary", "residential", "unclassified"].contains(kind)
            else { continue }
            let offset = palmRoadOffset(for: kind)
            let pts = road.points
            var cumDist: Float = 0
            let spacing: Float = 20.0
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i+1]
                let dx = b.x - a.x, dz = b.z - a.z
                let len = sqrt(dx*dx + dz*dz)
                guard len > 0.5 else { continue }
                let ux = dx/len, uz = dz/len
                let npx = -uz, npz = ux     // unit perpendicular
                var t = spacing - fmod(cumDist, spacing)
                while t < len {
                    let cx = a.x + ux*t, cz = a.z + uz*t
                    candidates.append((cx + npx*offset, cz + npz*offset))
                    candidates.append((cx - npx*offset, cz - npz*offset))
                    t += spacing
                }
                cumDist += len
            }
        }

        // 2. Beach-edge palms: denser spacing — palms cluster at the coast–vegetation transition.
        for zone in district.greenZones where zone.kind == "natural=beach" {
            let poly = zone.polygon
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i+1) % poly.count]
                let dx = b.x - a.x, dz = b.z - a.z
                let len = sqrt(dx*dx + dz*dz)
                guard len > 0.5 else { continue }
                let ux = dx/len, uz = dz/len
                let spacing: Float = 9.0
                var t: Float = 0
                while t < len {
                    candidates.append((a.x + ux*t, a.z + uz*t))
                    t += spacing
                }
            }
        }

        // 3. Farmland / orchard / park boundary palms (every 13m).
        let edgeKinds: Set<String> = ["landuse=farmland", "landuse=orchard", "leisure=park"]
        for zone in district.greenZones where zone.kind.map(edgeKinds.contains) ?? false {
            let poly = zone.polygon
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i+1) % poly.count]
                let dx = b.x - a.x, dz = b.z - a.z
                let len = sqrt(dx*dx + dz*dz)
                guard len > 0.5 else { continue }
                let ux = dx/len, uz = dz/len
                let spacing: Float = 13.0
                var t: Float = 0
                while t < len {
                    candidates.append((a.x + ux*t, a.z + uz*t))
                    t += spacing
                }
            }
        }

        // Building avoidance grid: 6m cells. Any candidate whose 3×3 cell neighbourhood
        // contains a building centroid is rejected (palm would clip into a building footprint).
        let bCell: Float = 6.0
        var buildGrid: Set<SIMD2<Int32>> = []
        for b in district.buildings {
            let n = Float(b.polygon.count)
            guard n > 0 else { continue }
            let bx = b.polygon.map(\.x).reduce(0,+) / n
            let bz = b.polygon.map(\.z).reduce(0,+) / n
            buildGrid.insert(SIMD2(Int32(floor(bx/bCell)), Int32(floor(bz/bCell))))
        }

        // Palm separation grid: 5m cells. Prevents visible clumping.
        let pCell: Float = 5.0
        var palmGrid: Set<SIMD2<Int32>> = []
        var result: [(x: Float, z: Float, h: Float)] = []

        for (cx, cz) in candidates {
            let bcx = Int32(floor(cx/bCell)), bcz = Int32(floor(cz/bCell))
            var blocked = false
            outer: for dx: Int32 in -1...1 { for dz: Int32 in -1...1 {
                if buildGrid.contains(SIMD2(bcx+dx, bcz+dz)) { blocked = true; break outer }
            }}
            if blocked { continue }

            let pcx = Int32(floor(cx/pCell)), pcz = Int32(floor(cz/pCell))
            var tooNear = false
            pOuter: for dx: Int32 in -1...1 { for dz: Int32 in -1...1 {
                if palmGrid.contains(SIMD2(pcx+dx, pcz+dz)) { tooNear = true; break pOuter }
            }}
            if tooNear { continue }

            palmGrid.insert(SIMD2(pcx, pcz))
            let v = deterministicVariation(seed: "\(Int32(cx*10))_\(Int32(cz*10))")
            result.append((x: cx, z: cz, h: 6.5 + v * 5.0))
        }

        palmPositionCache[district.name] = result
        return result
    }

    private static func palmRoadOffset(for kind: String) -> Float {
        switch kind {
        case "primary":   return 8.5
        case "secondary": return 6.5
        case "tertiary":  return 5.0
        default:          return 4.0   // residential / unclassified
        }
    }

    /// Returns at most two `ModelEntity`s (trunk batch + canopy batch) for palm positions in
    /// one quadrant. Merging all geometry into one `MeshDescriptor` per material type gives
    /// 2 draw calls for the entire palm layer of that quadrant regardless of tree count.
    ///
    /// - Trunk: `PhysicallyBasedMaterial` — vertical face receives the directional sun correctly.
    /// - Canopy: `UnlitMaterial` — flat horizontal quad; `PhysicallyBasedMaterial` on a large
    ///   horizontal surface produces shadow-map aliasing stripes (same documented issue as green zones).
    @MainActor
    private static func makePalmEntities(
        positions: [(x: Float, z: Float, h: Float)],
        isNight: Bool,
        quadrantIndex: Int
    ) -> [ModelEntity] {
        guard !positions.isEmpty else { return [] }

        var trunkPos: [SIMD3<Float>] = []
        var trunkNrm: [SIMD3<Float>] = []
        var trunkIdx: [UInt32]       = []
        var canPos:   [SIMD3<Float>] = []
        var canNrm:   [SIMD3<Float>] = []
        var canIdx:   [UInt32]       = []

        for p in positions {
            addPalmTrunk(x: p.x, z: p.z, height: p.h,
                         positions: &trunkPos, normals: &trunkNrm, indices: &trunkIdx)
            addPalmCanopy(x: p.x, z: p.z, height: p.h,
                          positions: &canPos, normals: &canNrm, indices: &canIdx)
        }

        var entities: [ModelEntity] = []

        if !trunkPos.isEmpty {
            var d = MeshDescriptor(name: "palm_trunk_q\(quadrantIndex)")
            d.positions  = MeshBuffer(trunkPos)
            d.normals    = MeshBuffer(trunkNrm)
            d.primitives = .triangles(trunkIdx)
            if let mesh = try? MeshResource.generate(from: [d]) {
                var mat = PhysicallyBasedMaterial()
                mat.baseColor = .init(tint: isNight
                    ? UIColor(red: 0.10, green: 0.07, blue: 0.04, alpha: 1)
                    : UIColor(red: 0.22, green: 0.15, blue: 0.09, alpha: 1))
                mat.roughness = .init(floatLiteral: 0.92)
                mat.metallic  = .init(floatLiteral: 0.0)
                let e = ModelEntity(mesh: mesh, materials: [mat])
                e.name = "palm_trunk_q\(quadrantIndex)"
                entities.append(e)
            }
        }

        if !canPos.isEmpty {
            var d = MeshDescriptor(name: "palm_canopy_q\(quadrantIndex)")
            d.positions  = MeshBuffer(canPos)
            d.normals    = MeshBuffer(canNrm)
            d.primitives = .triangles(canIdx)
            if let mesh = try? MeshResource.generate(from: [d]) {
                var mat = UnlitMaterial()
                mat.color = .init(tint: isNight
                    ? UIColor(red: 0.04, green: 0.12, blue: 0.03, alpha: 1)
                    : UIColor(red: 0.14, green: 0.40, blue: 0.10, alpha: 1))
                let e = ModelEntity(mesh: mesh, materials: [mat])
                e.name = "palm_canopy_q\(quadrantIndex)"
                entities.append(e)
            }
        }

        return entities
    }

    /// Tapered 4-sided trunk: 4 independent face quads so each face has its own outward normal.
    /// Winding verified CCW-from-outside for RealityKit's CCW front-face convention.
    /// br = base radius (0.28m), tr = top radius (0.17m) — gives a visible taper at orbit scale.
    private static func addPalmTrunk(x: Float, z: Float, height h: Float,
                                      positions: inout [SIMD3<Float>],
                                      normals: inout [SIMD3<Float>],
                                      indices: inout [UInt32]) {
        let br: Float = 0.28, tr: Float = 0.17
        struct Face { let v: [SIMD3<Float>]; let n: SIMD3<Float> }
        // For each face the vertex order produces CCW triangles when viewed from the face's
        // outward direction, verified analytically against the camera-space projection for each
        // of the four cardinal views (+Z, −Z, +X, −X).
        let faces: [Face] = [
            // South (outward +Z): left−bottom → right−bottom → right−top → left−top
            Face(v: [SIMD3(x-br,0,z+br), SIMD3(x+br,0,z+br),
                     SIMD3(x+tr,h,z+tr), SIMD3(x-tr,h,z+tr)], n: SIMD3(0,0,1)),
            // North (outward −Z): right−bottom → left−bottom → left−top → right−top
            Face(v: [SIMD3(x+br,0,z-br), SIMD3(x-br,0,z-br),
                     SIMD3(x-tr,h,z-tr), SIMD3(x+tr,h,z-tr)], n: SIMD3(0,0,-1)),
            // East (outward +X): south−bottom → north−bottom → north−top → south−top
            Face(v: [SIMD3(x+br,0,z+br), SIMD3(x+br,0,z-br),
                     SIMD3(x+tr,h,z-tr), SIMD3(x+tr,h,z+tr)], n: SIMD3(1,0,0)),
            // West (outward −X): north−bottom → south−bottom → south−top → north−top
            Face(v: [SIMD3(x-br,0,z-br), SIMD3(x-br,0,z+br),
                     SIMD3(x-tr,h,z+tr), SIMD3(x-tr,h,z-tr)], n: SIMD3(-1,0,0)),
        ]
        for f in faces {
            let b0 = UInt32(positions.count)
            positions += f.v
            normals   += [f.n, f.n, f.n, f.n]
            indices   += [b0, b0+1, b0+2,  b0, b0+2, b0+3]
        }
    }

    /// Four crossing frond quads at 0 / 45 / 90 / 135 °, lying flat at crown height.
    /// Vertex order [tip1-neg, tip2-neg, tip2-pos, tip1-pos] gives CCW from +Y (orbit camera).
    /// All normals point up (+Y) for correct response to the directional sun on the UnlitMaterial
    /// (normals are unused for UnlitMaterial lighting but kept for potential future PBR switch).
    private static func addPalmCanopy(x: Float, z: Float, height: Float,
                                       positions: inout [SIMD3<Float>],
                                       normals: inout [SIMD3<Float>],
                                       indices: inout [UInt32]) {
        let crownY = height + 0.3
        let L: Float = 1.70     // frond half-length  → total span 3.4m
        let W: Float = 0.45     // frond half-width
        let upN = SIMD3<Float>(0, 1, 0)

        for ai in 0..<4 {
            let a  = Float(ai) * (.pi / 4.0)
            let ax = cos(a), az = sin(a)      // arm direction
            let fpx = -az, fpz = ax           // perpendicular (width axis)

            // CCW from +Y (orbit): v0=tip1-neg, v1=tip2-neg, v2=tip2-pos, v3=tip1-pos
            // Verified: cross2D(v1-v0, v2-v0) > 0 for all four frond angles.
            let b0 = UInt32(positions.count)
            positions += [
                SIMD3(x - ax*L - fpx*W, crownY, z - az*L - fpz*W),   // tip1-neg
                SIMD3(x + ax*L - fpx*W, crownY, z + az*L - fpz*W),   // tip2-neg
                SIMD3(x + ax*L + fpx*W, crownY, z + az*L + fpz*W),   // tip2-pos
                SIMD3(x - ax*L + fpx*W, crownY, z - az*L + fpz*W),   // tip1-pos
            ]
            normals += [upN, upN, upN, upN]
            indices += [b0, b0+1, b0+2,  b0, b0+2, b0+3]
        }
    }

    // MARK: - Utilities

    private static func deterministicVariation(seed: String) -> Float {
        var hash: UInt32 = 2166136261
        for byte in seed.utf8 { hash ^= UInt32(byte); hash = hash &* 16777619 }
        return Float(hash % 1000) / 1000.0
    }

    /// Shoelace formula — returns the absolute area of the polygon in the X-Z plane (square metres).
    private static func polygonArea(_ pts: [LocalPoint]) -> Float { abs(signedPolygonArea(pts)) }

    /// Signed shoelace area. Negative for OSM outer rings (which are CCW geographically but
    /// CW in our X-Z space where Z = south = +Z). The sign is used to detect triangle
    /// orientation relative to the polygon when guarding the centroid-fan roof triangulation.
    private static func signedPolygonArea(_ pts: [LocalPoint]) -> Float {
        var area: Float = 0
        let n = pts.count
        for i in 0..<n {
            let j = (i + 1) % n
            area += pts[i].x * pts[j].z - pts[j].x * pts[i].z
        }
        return area * 0.5
    }

    // MARK: - Holographic scanner rings

    /// Amber holographic scanner shown beneath the tapped building: two concentric arc-segment rings
    /// that counter-rotate, plus a thin halo. Returns a container `Entity` with three named children:
    /// "outerArcs", "innerArcs", "haloRing". The caller drives rotation + breath scale each frame.
    @MainActor
    static func makeHoloScanner(centroid: SIMD3<Float>, radius: Float) -> Entity? {
        let effective: Float = max(radius, 2.5)

        // Outer ring: wider arcs, rotates CW
        let roOuter: Float = effective
        let roInner: Float = max(effective - 0.55, 1.5)

        // Inner ring: tighter arcs, rotates CCW
        let riOuter: Float = max(effective * 0.62, 1.5)
        let riInner: Float = max(riOuter - 0.38, 0.9)

        // Halo: thin full-circle glow
        let rhOuter: Float = effective * 1.22
        let rhInner: Float = max(rhOuter - 0.28, effective * 1.10)

        // Arc geometry constants: 3 arcs × 78° each, 42° gaps (total = 3×(78+42)° = 360°)
        let arcSpan: Float  = 78 * .pi / 180
        let arcSteps        = 13
        let arcStep: Float  = arcSpan / Float(arcSteps)
        let starts: [Float] = [0, 2 * .pi / 3, 4 * .pi / 3]
        let up = SIMD3<Float>(0, 1, 0)

        func arcDescriptor(name: String, rInner: Float, rOuter: Float) -> MeshDescriptor {
            var pos:  [SIMD3<Float>] = []
            var norm: [SIMD3<Float>] = []
            var uv:   [SIMD2<Float>] = []
            var idx:  [UInt32]       = []
            for s0 in starts {
                for k in 0..<arcSteps {
                    let a0 = s0 + Float(k) * arcStep
                    let a1 = a0 + arcStep
                    let b  = UInt32(pos.count)
                    pos  += [SIMD3(cos(a0)*rInner, 0, sin(a0)*rInner),
                             SIMD3(cos(a1)*rInner, 0, sin(a1)*rInner),
                             SIMD3(cos(a1)*rOuter, 0, sin(a1)*rOuter),
                             SIMD3(cos(a0)*rOuter, 0, sin(a0)*rOuter)]
                    norm += [up, up, up, up]
                    uv   += [.zero, .zero, .zero, .zero]
                    idx  += [b, b+1, b+2,  b, b+2, b+3]
                }
            }
            var d = MeshDescriptor(name: name)
            d.positions = MeshBuffer(pos); d.normals = MeshBuffer(norm)
            d.textureCoordinates = MeshBuffer(uv); d.primitives = .triangles(idx)
            return d
        }

        func haloDescriptor(name: String, rInner: Float, rOuter: Float) -> MeshDescriptor {
            let segs = 36
            var pos:  [SIMD3<Float>] = []
            var norm: [SIMD3<Float>] = []
            var uv:   [SIMD2<Float>] = []
            var idx:  [UInt32]       = []
            for i in 0..<segs {
                let a0 = Float(i)   / Float(segs) * 2 * .pi
                let a1 = Float(i+1) / Float(segs) * 2 * .pi
                let b  = UInt32(pos.count)
                pos  += [SIMD3(cos(a0)*rInner, 0, sin(a0)*rInner),
                         SIMD3(cos(a1)*rInner, 0, sin(a1)*rInner),
                         SIMD3(cos(a1)*rOuter, 0, sin(a1)*rOuter),
                         SIMD3(cos(a0)*rOuter, 0, sin(a0)*rOuter)]
                norm += [up, up, up, up]
                uv   += [.zero, .zero, .zero, .zero]
                idx  += [b, b+1, b+2,  b, b+2, b+3]
            }
            var d = MeshDescriptor(name: name)
            d.positions = MeshBuffer(pos); d.normals = MeshBuffer(norm)
            d.textureCoordinates = MeshBuffer(uv); d.primitives = .triangles(idx)
            return d
        }

        // #C69C6D amber palette
        func amberMat(alpha: Float) -> UnlitMaterial {
            var m = UnlitMaterial()
            m.color = .init(tint: UIColor(red: 198/255, green: 156/255, blue: 109/255, alpha: CGFloat(alpha)))
            return m
        }

        guard
            let outerMesh = try? MeshResource.generate(from: [arcDescriptor(name: "outerArcs", rInner: roInner, rOuter: roOuter)]),
            let innerMesh = try? MeshResource.generate(from: [arcDescriptor(name: "innerArcs", rInner: riInner, rOuter: riOuter)]),
            let haloMesh  = try? MeshResource.generate(from: [haloDescriptor(name:  "haloRing", rInner: rhInner, rOuter: rhOuter)])
        else { return nil }

        let outerArcs = ModelEntity(mesh: outerMesh, materials: [amberMat(alpha: 0.92)])
        outerArcs.name = "outerArcs"

        let innerArcs = ModelEntity(mesh: innerMesh, materials: [amberMat(alpha: 0.82)])
        innerArcs.name = "innerArcs"

        let haloRing = ModelEntity(mesh: haloMesh,  materials: [amberMat(alpha: 0.18)])
        haloRing.name = "haloRing"

        let container = Entity()
        // 3 cm levitation above ground — just enough to clear ground plane Z-fighting
        container.position = SIMD3(centroid.x, 0.03, centroid.z)
        container.addChild(outerArcs)
        container.addChild(innerArcs)
        container.addChild(haloRing)
        return container
    }

    /// Removes any selection ring / holo scanner added as a direct child of `anchor`.
    @MainActor
    static func clearSelectionRing(in anchor: AnchorEntity) {
        anchor.children.first(where: { $0.name == "selectionRing" })?.removeFromParent()
    }
}
