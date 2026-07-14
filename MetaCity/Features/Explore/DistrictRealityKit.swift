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
        // isNight is always false — night mode removed. Key is district name only.
        let cacheKey = name
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
            if let beaconLayer = makePOIBeaconEntities(
                districtName: name,
                districtAnchor: distEntry.anchor,
                districtExtent: distData.extent
            ) {
                root.addChild(beaconLayer)
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

            var bandPos:  [SIMD3<Float>] = []
            var bandNorm: [SIMD3<Float>] = []
            var bandUV:   [SIMD2<Float>] = []
            var bandIdx:  [UInt32]       = []

            var groundPos:  [SIMD3<Float>] = []
            var groundNorm: [SIMD3<Float>] = []
            var groundUV:   [SIMD2<Float>] = []
            var groundIdx:  [UInt32]       = []

            var balkPos:  [SIMD3<Float>] = []
            var balkNorm: [SIMD3<Float>] = []
            var balkUV:   [SIMD2<Float>] = []
            var balkIdx:  [UInt32]       = []

            var pilasterPos:  [SIMD3<Float>] = []
            var pilasterNorm: [SIMD3<Float>] = []
            var pilasterUV:   [SIMD2<Float>] = []
            var pilasterIdx:  [UInt32]       = []

            let profile = facadeProfile(for: style)

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
                let area = polygonArea(pts)
                guard area >= 4.0 else { continue }
                let minNonZeroEdge = (0..<pts.count).compactMap { i -> Float? in
                    let a = pts[i], b = pts[(i + 1) % pts.count]
                    let dx = b.x - a.x, dz = b.z - a.z
                    let len = sqrt(dx * dx + dz * dz)
                    return len > 0.01 ? len : nil
                }.min() ?? 0
                guard minNonZeroEdge >= 0.5 else { continue }

                let h = displayHeight(for: building, area: area)

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

                // Facade articulation: floor ledge bands, cornice, base plinth
                addFacadeBands(building: building, profile: profile, h: h,
                               positions: &bandPos, normals: &bandNorm,
                               uvs: &bandUV, indices: &bandIdx)

                // Ground-floor cladding: projecting panel at lobby/arcade level with distinct material
                if profile.groundFloorH > 0 {
                    addGroundFloorPanel(building: building,
                                        groundFloorH: profile.groundFloorH,
                                        depth: profile.groundFloorDepth, h: h,
                                        positions: &groundPos, normals: &groundNorm,
                                        uvs: &groundUV, indices: &groundIdx)
                }

                // Balcony slabs: deep projecting ledge at select floor levels (wrought-iron material)
                addBalconies(building: building, profile: profile, h: h,
                             positions: &balkPos, normals: &balkNorm,
                             uvs: &balkUV, indices: &balkIdx)

                // Pilasters: vertical relief strips at equal bay spacing along each polygon edge
                addPilasters(building: building, profile: profile, h: h,
                             positions: &pilasterPos, normals: &pilasterNorm,
                             uvs: &pilasterUV, indices: &pilasterIdx)
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

            if !bandIdx.isEmpty {
                var bandDesc = MeshDescriptor(name: "buildings_\(key)_bands")
                bandDesc.positions          = MeshBuffer(bandPos)
                bandDesc.normals            = MeshBuffer(bandNorm)
                bandDesc.textureCoordinates = MeshBuffer(bandUV)
                bandDesc.primitives         = .triangles(bandIdx)
                let bandMat    = bandMaterialPreset(for: style, isNight: isNight)
                let bandMesh   = try MeshResource.generate(from: [bandDesc])
                let bandEntity = ModelEntity(mesh: bandMesh, materials: [bandMat])
                bandEntity.name = "buildings_\(key)_bands"
                entities.append(bandEntity)
            }

            if !groundIdx.isEmpty {
                var groundDesc = MeshDescriptor(name: "buildings_\(key)_ground")
                groundDesc.positions          = MeshBuffer(groundPos)
                groundDesc.normals            = MeshBuffer(groundNorm)
                groundDesc.textureCoordinates = MeshBuffer(groundUV)
                groundDesc.primitives         = .triangles(groundIdx)
                let groundMat    = groundFloorMaterialPreset(for: style, isNight: isNight)
                let groundMesh   = try MeshResource.generate(from: [groundDesc])
                let groundEntity = ModelEntity(mesh: groundMesh, materials: [groundMat])
                groundEntity.name = "buildings_\(key)_ground"
                entities.append(groundEntity)
            }

            if !balkIdx.isEmpty {
                var balkDesc = MeshDescriptor(name: "buildings_\(key)_balkony")
                balkDesc.positions          = MeshBuffer(balkPos)
                balkDesc.normals            = MeshBuffer(balkNorm)
                balkDesc.textureCoordinates = MeshBuffer(balkUV)
                balkDesc.primitives         = .triangles(balkIdx)
                let balkMat    = balconyMaterialPreset(for: style, isNight: isNight)
                let balkMesh   = try MeshResource.generate(from: [balkDesc])
                let balkEntity = ModelEntity(mesh: balkMesh, materials: [balkMat])
                balkEntity.name = "buildings_\(key)_balkony"
                entities.append(balkEntity)
            }

            if !pilasterIdx.isEmpty {
                var pilasterDesc = MeshDescriptor(name: "buildings_\(key)_pilasters")
                pilasterDesc.positions          = MeshBuffer(pilasterPos)
                pilasterDesc.normals            = MeshBuffer(pilasterNorm)
                pilasterDesc.textureCoordinates = MeshBuffer(pilasterUV)
                pilasterDesc.primitives         = .triangles(pilasterIdx)
                let pilasterMat    = bandMaterialPreset(for: style, isNight: isNight)
                let pilasterMesh   = try MeshResource.generate(from: [pilasterDesc])
                let pilasterEntity = ModelEntity(mesh: pilasterMesh, materials: [pilasterMat])
                pilasterEntity.name = "buildings_\(key)_pilasters"
                entities.append(pilasterEntity)
            }

            return entities
        }
    }

    // MARK: - Facade articulation

    private struct FacadeProfile {
        let floorInterval: Float     // metres between floor bands
        let bandDepth: Float         // outward projection of each floor ledge
        let bandThick: Float         // vertical thickness of each floor ledge
        let corniceDepth: Float      // top cornice projection
        let corniceHeight: Float     // top cornice height (0 = no cornice)
        let plinthDepth: Float       // base plinth projection
        let plinthHeight: Float      // base plinth height (0 = no plinth)
        let groundFloorH: Float      // height of ground-floor cladding panel (0 = none)
        let groundFloorDepth: Float  // outward projection of ground-floor cladding (0 = none)
        // Balcony slabs — deep projecting ledge at select floors with wrought-iron/cast-iron material
        let balconyDepth: Float      // projection depth (0 = no balconies)
        let balconyThick: Float      // slab thickness
        let balconyFirstFloor: Int   // 1-based floor index of first balcony (1 = ground, 2 = 1st étage)
        let balconyFloorStep: Int    // every N floors: 1 = every floor, 2 = every other floor
        // Pilasters — vertical relief strips at equal bay spacing along polygon edges
        let pilasterWidth: Float     // strip width (0 = no pilasters)
        let pilasterDepth: Float     // outward projection
        let pilasterSpacing: Float   // horizontal interval between strips (0 = none)
        static let none = FacadeProfile(floorInterval: 3.5, bandDepth: 0, bandThick: 0,
                                        corniceDepth: 0, corniceHeight: 0,
                                        plinthDepth: 0, plinthHeight: 0,
                                        groundFloorH: 0, groundFloorDepth: 0,
                                        balconyDepth: 0, balconyThick: 0,
                                        balconyFirstFloor: 2, balconyFloorStep: 1,
                                        pilasterWidth: 0, pilasterDepth: 0, pilasterSpacing: 0)
    }

    private static func facadeProfile(for style: BuildingStyle) -> FacadeProfile {
        switch style {
        case .haussmannien:
            // Second-Empire: cast-iron balcony at every floor from 1st étage, heavy zinc cornice,
            // rusticated ashlar soubassement ~5m; Corinthian pilasters at 2.5m bay rhythm.
            return FacadeProfile(floorInterval: 3.5, bandDepth: 0.38, bandThick: 0.22,
                                 corniceDepth: 0.50, corniceHeight: 0.55,
                                 plinthDepth: 0.12, plinthHeight: 0.80,
                                 groundFloorH: 5.0, groundFloorDepth: 0.08,
                                 balconyDepth: 0.80, balconyThick: 0.15,
                                 balconyFirstFloor: 2, balconyFloorStep: 1,
                                 pilasterWidth: 0.22, pilasterDepth: 0.12, pilasterSpacing: 2.5)
        case .bordelaisClassical:
            // Bordeaux bourgeois: Gironde limestone balconies every floor from 1st, moulded cornice,
            // rusticated limestone base ~5m; Ionic pilasters at 3.0m bay rhythm.
            return FacadeProfile(floorInterval: 3.5, bandDepth: 0.32, bandThick: 0.20,
                                 corniceDepth: 0.42, corniceHeight: 0.50,
                                 plinthDepth: 0.10, plinthHeight: 0.70,
                                 groundFloorH: 5.0, groundFloorDepth: 0.08,
                                 balconyDepth: 0.70, balconyThick: 0.14,
                                 balconyFirstFloor: 2, balconyFloorStep: 1,
                                 pilasterWidth: 0.20, pilasterDepth: 0.10, pilasterSpacing: 3.0)
        case .madrileño:
            // Ensanche: cast-iron miradors every floor from 1st, cornice, Sierra granite plinth ~5.5m;
            // Corinthian engaged-column strips at 2.8m rhythm.
            return FacadeProfile(floorInterval: 3.5, bandDepth: 0.30, bandThick: 0.18,
                                 corniceDepth: 0.38, corniceHeight: 0.50,
                                 plinthDepth: 0.10, plinthHeight: 0.65,
                                 groundFloorH: 5.5, groundFloorDepth: 0.06,
                                 balconyDepth: 0.65, balconyThick: 0.14,
                                 balconyFirstFloor: 2, balconyFloorStep: 1,
                                 pilasterWidth: 0.18, pilasterDepth: 0.09, pilasterSpacing: 2.8)
        case .colonial:
            // Dutch colonial shophouses: verandah arcade facing ground ~4.5m, narrow floor ledges;
            // slim Doric colonnette strips at 4.0m bay rhythm. No upper balconies.
            return FacadeProfile(floorInterval: 3.5, bandDepth: 0.22, bandThick: 0.16,
                                 corniceDepth: 0.28, corniceHeight: 0.35,
                                 plinthDepth: 0.10, plinthHeight: 0.50,
                                 groundFloorH: 4.5, groundFloorDepth: 0.06,
                                 balconyDepth: 0, balconyThick: 0,
                                 balconyFirstFloor: 2, balconyFloorStep: 1,
                                 pilasterWidth: 0.14, pilasterDepth: 0.07, pilasterSpacing: 4.0)
        case .romanOchre:
            // Palazzo romano: travertine string courses, projecting cornice, travertine base ~5.5m;
            // giant order pilasters at 4.0m. Balconies on piano nobile and belvedere (every 2 floors).
            return FacadeProfile(floorInterval: 3.2, bandDepth: 0.28, bandThick: 0.18,
                                 corniceDepth: 0.38, corniceHeight: 0.48,
                                 plinthDepth: 0.12, plinthHeight: 0.60,
                                 groundFloorH: 5.5, groundFloorDepth: 0.08,
                                 balconyDepth: 0.55, balconyThick: 0.14,
                                 balconyFirstFloor: 2, balconyFloorStep: 2,
                                 pilasterWidth: 0.28, pilasterDepth: 0.14, pilasterSpacing: 4.0)
        case .londonBrick:
            // Victorian terrace: subtle string courses, narrow parapet, Portland stone ground ~5m;
            // slim brick piers at 4.5m. Juliet balconies only at floors 2 and 5 (step 3).
            return FacadeProfile(floorInterval: 3.5, bandDepth: 0.14, bandThick: 0.12,
                                 corniceDepth: 0.20, corniceHeight: 0.32,
                                 plinthDepth: 0.06, plinthHeight: 0.35,
                                 groundFloorH: 5.0, groundFloorDepth: 0.06,
                                 balconyDepth: 0.45, balconyThick: 0.12,
                                 balconyFirstFloor: 2, balconyFloorStep: 3,
                                 pilasterWidth: 0.14, pilasterDepth: 0.07, pilasterSpacing: 4.5)
        case .medieval:
            // Half-timber Breton: heavy eave at top, Breton granite soubassement ~3.5m.
            // No balconies, no pilasters — organic half-timber rhythm has no classical order.
            return FacadeProfile(floorInterval: 3.5, bandDepth: 0.12, bandThick: 0.10,
                                 corniceDepth: 0.30, corniceHeight: 0.40,
                                 plinthDepth: 0, plinthHeight: 0,
                                 groundFloorH: 3.5, groundFloorDepth: 0.05,
                                 balconyDepth: 0, balconyThick: 0,
                                 balconyFirstFloor: 2, balconyFloorStep: 1,
                                 pilasterWidth: 0, pilasterDepth: 0, pilasterSpacing: 0)
        case .modernGlass:
            // Curtain-wall: thin metallic spandrel panels, dark granite lobby ~8m.
            // No balconies, no pilasters.
            return FacadeProfile(floorInterval: 3.5, bandDepth: 0.06, bandThick: 0.08,
                                 corniceDepth: 0, corniceHeight: 0,
                                 plinthDepth: 0, plinthHeight: 0,
                                 groundFloorH: 8.0, groundFloorDepth: 0.10,
                                 balconyDepth: 0, balconyThick: 0,
                                 balconyFirstFloor: 2, balconyFloorStep: 1,
                                 pilasterWidth: 0, pilasterDepth: 0, pilasterSpacing: 0)
        case .nycBrick:
            // Pre-war brick: terracotta string courses, heavy projecting cornice, brownstone ground ~5.5m;
            // limestone piers at 3.0m. Fire-escape balconies every 2 floors from 1st.
            return FacadeProfile(floorInterval: 3.5, bandDepth: 0.20, bandThick: 0.15,
                                 corniceDepth: 0.35, corniceHeight: 0.50,
                                 plinthDepth: 0.10, plinthHeight: 0.55,
                                 groundFloorH: 5.5, groundFloorDepth: 0.08,
                                 balconyDepth: 0.65, balconyThick: 0.13,
                                 balconyFirstFloor: 2, balconyFloorStep: 2,
                                 pilasterWidth: 0.22, pilasterDepth: 0.10, pilasterSpacing: 3.0)
        default:
            return .none
        }
    }

    private static func addFacadeBands(
        building: BuildingFootprint,
        profile: FacadeProfile,
        h: Float,
        positions: inout [SIMD3<Float>],
        normals:   inout [SIMD3<Float>],
        uvs:       inout [SIMD2<Float>],
        indices:   inout [UInt32]
    ) {
        guard profile.bandDepth > 0 || profile.corniceDepth > 0 || profile.plinthDepth > 0 else { return }
        let pts = building.polygon
        let n = pts.count
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let dx = b.x - a.x, dz = b.z - a.z
            let len = sqrt(dx*dx + dz*dz)
            guard len > 0.01 else { continue }
            let nx = -dz / len, nz = dx / len

            // Floor ledge bands at each floor interval, stopping before the cornice zone
            if profile.bandDepth > 0 && profile.bandThick > 0 {
                let topGuard = profile.corniceHeight + profile.bandThick + 0.1
                var bandY = profile.floorInterval
                while bandY <= h - topGuard {
                    addBandStrip(a: a, b: b, nx: nx, nz: nz,
                                 yBase: bandY, thick: profile.bandThick, depth: profile.bandDepth,
                                 positions: &positions, normals: &normals, uvs: &uvs, indices: &indices)
                    bandY += profile.floorInterval
                }
            }

            // Cornice at top
            if profile.corniceDepth > 0 && profile.corniceHeight > 0
                && h > profile.corniceHeight + profile.plinthHeight {
                addBandStrip(a: a, b: b, nx: nx, nz: nz,
                             yBase: h - profile.corniceHeight, thick: profile.corniceHeight,
                             depth: profile.corniceDepth,
                             positions: &positions, normals: &normals, uvs: &uvs, indices: &indices)
            }

            // Base plinth
            if profile.plinthDepth > 0 && profile.plinthHeight > 0
                && h > profile.plinthHeight + profile.corniceHeight {
                addBandStrip(a: a, b: b, nx: nx, nz: nz,
                             yBase: 0, thick: profile.plinthHeight, depth: profile.plinthDepth,
                             positions: &positions, normals: &normals, uvs: &uvs, indices: &indices)
            }
        }
    }

    /// Appends the outward front face + upward top face of one projecting ledge strip.
    /// The underside is omitted (not visible from orbit camera).
    /// Winding verified: front face normal = (nx,0,nz), top face normal = (0,+1,0),
    /// both confirmed via cross-product for CW building polygon winding in X-Z.
    private static func addBandStrip(
        a: LocalPoint, b: LocalPoint,
        nx: Float, nz: Float,
        yBase: Float, thick: Float, depth: Float,
        positions: inout [SIMD3<Float>],
        normals:   inout [SIMD3<Float>],
        uvs:       inout [SIMD2<Float>],
        indices:   inout [UInt32]
    ) {
        let yTop = yBase + thick
        let axO = a.x + nx * depth, azO = a.z + nz * depth
        let bxO = b.x + nx * depth, bzO = b.z + nz * depth

        // Front face: outward-facing, same normal as the parent wall quad
        let outN = SIMD3<Float>(nx, 0, nz)
        let fBase = UInt32(positions.count)
        positions += [SIMD3(axO, yBase, azO), SIMD3(bxO, yBase, bzO),
                      SIMD3(bxO, yTop,  bzO), SIMD3(axO, yTop,  azO)]
        normals   += [outN, outN, outN, outN]
        uvs       += [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        indices   += [fBase, fBase+1, fBase+3,  fBase+1, fBase+2, fBase+3]

        // Top face: upward-facing — orbit camera sees the ledge surface
        // Winding [3,1,2] + [3,0,1] (inner-B, outer-A, outer-B + inner-B, inner-A, outer-A)
        // cross-verified: n.y = depth × len > 0 for CW polygon winding
        let upN = SIMD3<Float>(0, 1, 0)
        let tBase = UInt32(positions.count)
        positions += [SIMD3(a.x, yTop, a.z), SIMD3(axO, yTop, azO),
                      SIMD3(bxO, yTop, bzO), SIMD3(b.x, yTop, b.z)]
        normals   += [upN, upN, upN, upN]
        uvs       += [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        indices   += [tBase+3, tBase+1, tBase+2,  tBase+3, tBase+0, tBase+1]
    }

    /// Appends a projecting ground-floor cladding panel for each polygon edge.
    /// Uses `addBandStrip` (front face + upward top face) so the horizontal cap is visible
    /// from the orbit camera looking down. Skipped if the building is barely taller than the
    /// ground-floor zone (< 1m clearance leaves no distinguishable upper zone to contrast with).
    private static func addGroundFloorPanel(
        building: BuildingFootprint,
        groundFloorH: Float,
        depth: Float,
        h: Float,
        positions: inout [SIMD3<Float>],
        normals:   inout [SIMD3<Float>],
        uvs:       inout [SIMD2<Float>],
        indices:   inout [UInt32]
    ) {
        let gH = min(groundFloorH, h - 1.0)
        guard gH > 1.0 else { return }
        let pts = building.polygon
        let n = pts.count
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let dx = b.x - a.x, dz = b.z - a.z
            let len = sqrt(dx*dx + dz*dz)
            guard len > 0.01 else { continue }
            let nx = -dz / len, nz = dx / len
            addBandStrip(a: a, b: b, nx: nx, nz: nz,
                         yBase: 0, thick: gH, depth: depth,
                         positions: &positions, normals: &normals, uvs: &uvs, indices: &indices)
        }
    }

    /// Adds balcony slab geometry for each applicable floor level of the building.
    /// Uses `addBandStrip` — balconies are identical in geometry to floor bands, just
    /// much deeper (0.55–0.80m vs 0.12–0.38m) and rendered with a distinct wrought-iron material.
    private static func addBalconies(
        building: BuildingFootprint,
        profile: FacadeProfile,
        h: Float,
        positions: inout [SIMD3<Float>],
        normals:   inout [SIMD3<Float>],
        uvs:       inout [SIMD2<Float>],
        indices:   inout [UInt32]
    ) {
        guard profile.balconyDepth > 0, profile.balconyThick > 0 else { return }
        let pts = building.polygon
        let n = pts.count
        let stopY = h - profile.balconyThick - max(profile.corniceHeight, 0.5)
        var balkY = Float(profile.balconyFirstFloor - 1) * profile.floorInterval
        while balkY <= stopY {
            for i in 0..<n {
                let a = pts[i], b = pts[(i + 1) % n]
                let dx = b.x - a.x, dz = b.z - a.z
                let len = sqrt(dx*dx + dz*dz)
                guard len > 0.01 else { continue }
                let nx = -dz / len, nz = dx / len
                addBandStrip(a: a, b: b, nx: nx, nz: nz,
                             yBase: balkY, thick: profile.balconyThick, depth: profile.balconyDepth,
                             positions: &positions, normals: &normals, uvs: &uvs, indices: &indices)
            }
            balkY += Float(profile.balconyFloorStep) * profile.floorInterval
        }
    }

    /// Adds pilaster front-face geometry at equal bay spacing along each polygon edge.
    /// A pilaster is a vertical relief strip (full building height) projecting `pilasterDepth` outward,
    /// width `pilasterWidth` along the edge. Only the front face is emitted — sides are hidden by the
    /// adjacent wall surface and are not visible from orbit or street-view cameras.
    private static func addPilasters(
        building: BuildingFootprint,
        profile: FacadeProfile,
        h: Float,
        positions: inout [SIMD3<Float>],
        normals:   inout [SIMD3<Float>],
        uvs:       inout [SIMD2<Float>],
        indices:   inout [UInt32]
    ) {
        guard profile.pilasterWidth > 0, profile.pilasterDepth > 0, profile.pilasterSpacing > 0 else { return }
        let pts = building.polygon
        let n = pts.count
        let hw = profile.pilasterWidth * 0.5
        let pd = profile.pilasterDepth
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let dx = b.x - a.x, dz = b.z - a.z
            let len = sqrt(dx*dx + dz*dz)
            guard len > profile.pilasterSpacing else { continue }
            let ex = dx / len, ez = dz / len
            let nx = -dz / len, nz = dx / len
            let outN = SIMD3<Float>(nx, 0, nz)
            var t = profile.pilasterSpacing * 0.5
            while t <= len - profile.pilasterSpacing * 0.2 {
                let cx = a.x + ex * t, cz = a.z + ez * t
                let fBase = UInt32(positions.count)
                // Front face: outward normal, full height strip
                // Winding [0,1,3, 1,2,3] = same as wall quads → outward-facing for CW polygon
                positions += [
                    SIMD3(cx - hw*ex + pd*nx,  0, cz - hw*ez + pd*nz),   // BL
                    SIMD3(cx + hw*ex + pd*nx,  0, cz + hw*ez + pd*nz),   // BR
                    SIMD3(cx + hw*ex + pd*nx,  h, cz + hw*ez + pd*nz),   // TR
                    SIMD3(cx - hw*ex + pd*nx,  h, cz - hw*ez + pd*nz)    // TL
                ]
                normals += [outN, outN, outN, outN]
                uvs     += [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, h / 3.5), SIMD2(0, h / 3.5)]
                indices += [fBase, fBase+1, fBase+3,  fBase+1, fBase+2, fBase+3]
                t += profile.pilasterSpacing
            }
        }
    }

    private static var bandMaterialCache: [String: PhysicallyBasedMaterial] = [:]

    /// Returns a material for facade bands (floor ledges, cornice, plinth) — slightly distinct from
    /// the wall surface to read as dressed stone, metallic spandrel, or Portland stone cornice.
    @MainActor
    private static func bandMaterialPreset(for style: BuildingStyle, isNight: Bool) -> any RealityKit.Material {
        let key = "\(style.rawValue)_band_\(isNight)"
        if let cached = bandMaterialCache[key] { return cached }
        var m = PhysicallyBasedMaterial()
        let n: CGFloat = isNight ? 0.50 : 1.0

        switch style {
        case .modernGlass:
            // Dark metallic spandrel panel — structural steel/aluminium cladding between floor plates
            m.baseColor = .init(tint: UIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1))
            m.metallic  = .init(floatLiteral: 0.88)
            m.roughness = .init(floatLiteral: 0.24)
        case .haussmannien:
            // Cut Lutetian limestone: slightly lighter and higher-polish than weathered wall
            m.baseColor  = .init(tint: UIColor(red: n*0.93, green: n*0.91, blue: n*0.85, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.66)
            m.clearcoat  = .init(floatLiteral: 0.20)
            m.clearcoatRoughness = .init(floatLiteral: 0.48)
        case .bordelaisClassical:
            // Calcaire à astéries dressed bands: brighter amber than wall, mild polish
            m.baseColor  = .init(tint: UIColor(red: n*0.92, green: n*0.84, blue: n*0.66, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.68)
            m.clearcoat  = .init(floatLiteral: 0.12)
            m.clearcoatRoughness = .init(floatLiteral: 0.55)
        case .madrileño:
            // Concrete azotea soffit / wrought-iron balcony rail — cooler neutral grey
            m.baseColor  = .init(tint: UIColor(red: n*0.82, green: n*0.80, blue: n*0.74, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.74)
        case .colonial:
            // Dutch lime-wash string course: brighter white than the ochre wall surface
            m.baseColor  = .init(tint: UIColor(red: n*0.92, green: n*0.90, blue: n*0.80, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.72)
        case .romanOchre:
            // Travertine cornice / rusticated base: lighter warm cream band against sienna wall
            m.baseColor  = .init(tint: UIColor(red: n*0.88, green: n*0.80, blue: n*0.62, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.70)
            m.clearcoat  = .init(floatLiteral: 0.08)
            m.clearcoatRoughness = .init(floatLiteral: 0.60)
        case .londonBrick:
            // Portland stone string course: cool grey-white against yellow stock brick
            m.baseColor  = .init(tint: UIColor(red: n*0.72, green: n*0.72, blue: n*0.72, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.80)
        case .medieval:
            // Dark Breton granite eave: cool grey against warm half-timber infill
            m.baseColor  = .init(tint: UIColor(red: n*0.52, green: n*0.50, blue: n*0.48, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.86)
        case .nycBrick:
            // Limestone cornice / brownstone string course: warm sand against dark brick
            m.baseColor  = .init(tint: UIColor(red: n*0.72, green: n*0.64, blue: n*0.52, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.80)
        default:
            return roofMaterialPreset(for: style, isNight: isNight)
        }
        bandMaterialCache[key] = m
        return m
    }

    // MARK: - Ground-floor cladding material

    private static var groundFloorMaterialCache: [String: PhysicallyBasedMaterial] = [:]

    /// Per-style ground-floor cladding material — darker/different from the upper wall surface
    /// to read as polished stone lobby (glass towers), rusticated ashlar base (Paris, Rome, Bordeaux),
    /// Portland stone ground storey (London), dark granite plinth (Madrid, NYC), arcade facing (colonial).
    @MainActor
    private static func groundFloorMaterialPreset(for style: BuildingStyle, isNight: Bool) -> PhysicallyBasedMaterial {
        let key = "\(style.rawValue)_gnd_\(isNight)"
        if let cached = groundFloorMaterialCache[key] { return cached }
        var m = PhysicallyBasedMaterial()
        let n: CGFloat = isNight ? 0.35 : 1.0

        switch style {
        case .modernGlass:
            // Dark polished granite lobby — characteristic podium material on glass curtain-wall towers.
            // Low roughness + high clearcoat produces a faint directional-light specular streak.
            m.baseColor  = .init(tint: UIColor(red: n*0.08, green: n*0.09, blue: n*0.12, alpha: 1))
            m.metallic   = .init(floatLiteral: 0.22)
            m.roughness  = .init(floatLiteral: 0.30)
            m.clearcoat  = .init(floatLiteral: 0.72)
            m.clearcoatRoughness = .init(floatLiteral: 0.14)
        case .haussmannien:
            // Bossed rusticated Lutetian limestone — coarser than dressed upper-floor stone,
            // slightly darker with deeper shadow in the joint reveals.
            m.baseColor  = .init(tint: UIColor(red: n*0.72, green: n*0.68, blue: n*0.58, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.84)
            m.clearcoat  = .init(floatLiteral: 0.05)
            m.clearcoatRoughness = .init(floatLiteral: 0.72)
        case .colonial:
            // Dutch colonial arcade verandah front — ochre lime-wash over brick, shaded from sun.
            m.baseColor  = .init(tint: UIColor(red: n*0.58, green: n*0.40, blue: n*0.24, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.82)
        case .londonBrick:
            // Portland stone / painted stucco ground storey — cooler and lighter than upper stock brick.
            m.baseColor  = .init(tint: UIColor(red: n*0.70, green: n*0.70, blue: n*0.68, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.76)
            m.clearcoat  = .init(floatLiteral: 0.06)
            m.clearcoatRoughness = .init(floatLiteral: 0.65)
        case .romanOchre:
            // Travertine base — lighter warm cream against sienna ochre upper, mild clearcoat from rain polish.
            m.baseColor  = .init(tint: UIColor(red: n*0.88, green: n*0.80, blue: n*0.64, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.70)
            m.clearcoat  = .init(floatLiteral: 0.12)
            m.clearcoatRoughness = .init(floatLiteral: 0.52)
        case .bordelaisClassical:
            // Rusticated Gironde limestone base — deeper amber-gold, heavier joint shadow vs. dressed upper.
            m.baseColor  = .init(tint: UIColor(red: n*0.70, green: n*0.56, blue: n*0.32, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.82)
            m.clearcoat  = .init(floatLiteral: 0.06)
            m.clearcoatRoughness = .init(floatLiteral: 0.68)
        case .madrileño:
            // Sierra de Guadarrama dark-grey granite plinth — polished, characteristic of Madrid.
            m.baseColor  = .init(tint: UIColor(red: n*0.44, green: n*0.42, blue: n*0.40, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.65)
            m.clearcoat  = .init(floatLiteral: 0.15)
            m.clearcoatRoughness = .init(floatLiteral: 0.42)
        case .medieval:
            // Breton granite soubassement — cool dark grey, rougher than upper half-timber plaster.
            m.baseColor  = .init(tint: UIColor(red: n*0.38, green: n*0.36, blue: n*0.34, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.90)
        case .nycBrick:
            // Brownstone entry storey — warm dark red-brown stone, typical NYC pre-war commercial base.
            m.baseColor  = .init(tint: UIColor(red: n*0.38, green: n*0.28, blue: n*0.20, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.80)
            m.clearcoat  = .init(floatLiteral: 0.05)
            m.clearcoatRoughness = .init(floatLiteral: 0.75)
        default:
            m.baseColor  = .init(tint: UIColor(white: n*0.50, alpha: 1))
            m.roughness  = .init(floatLiteral: 0.80)
        }
        groundFloorMaterialCache[key] = m
        return m
    }

    // MARK: - Balcony material

    private static var balconyMaterialCache: [String: PhysicallyBasedMaterial] = [:]

    /// Per-style balcony slab material — primarily wrought/cast iron for European styles.
    /// Significantly more metallic than the band/pilaster stone material to read as iron
    /// under the directional sun even at small scale (0.55–0.80m projection).
    @MainActor
    private static func balconyMaterialPreset(for style: BuildingStyle, isNight: Bool) -> PhysicallyBasedMaterial {
        let key = "\(style.rawValue)_balk_\(isNight)"
        if let cached = balconyMaterialCache[key] { return cached }
        var m = PhysicallyBasedMaterial()
        let n: CGFloat = isNight ? 0.40 : 1.0

        switch style {
        case .haussmannien, .bordelaisClassical:
            // Classic Haussmann/Bordeaux cast-iron balcony with zinc paint — near-black metallic
            m.baseColor = .init(tint: UIColor(red: n*0.04, green: n*0.04, blue: n*0.06, alpha: 1))
            m.metallic  = .init(floatLiteral: 0.72)
            m.roughness = .init(floatLiteral: 0.38)
            m.clearcoat = .init(floatLiteral: 0.18)
            m.clearcoatRoughness = .init(floatLiteral: 0.45)
        case .madrileño:
            // Madrid wrought-iron mirador rail — slightly warmer dark iron with paint oxidation
            m.baseColor = .init(tint: UIColor(red: n*0.06, green: n*0.05, blue: n*0.05, alpha: 1))
            m.metallic  = .init(floatLiteral: 0.68)
            m.roughness = .init(floatLiteral: 0.44)
            m.clearcoat = .init(floatLiteral: 0.14)
            m.clearcoatRoughness = .init(floatLiteral: 0.55)
        case .romanOchre:
            // Roman travertine balustrade — warm cream stone, not iron
            m.baseColor = .init(tint: UIColor(red: n*0.86, green: n*0.78, blue: n*0.62, alpha: 1))
            m.roughness = .init(floatLiteral: 0.72)
            m.clearcoat = .init(floatLiteral: 0.06)
            m.clearcoatRoughness = .init(floatLiteral: 0.65)
        case .londonBrick:
            // Victorian wrought-iron Juliet balcony — dark painted iron, London black
            m.baseColor = .init(tint: UIColor(red: n*0.05, green: n*0.05, blue: n*0.06, alpha: 1))
            m.metallic  = .init(floatLiteral: 0.65)
            m.roughness = .init(floatLiteral: 0.42)
            m.clearcoat = .init(floatLiteral: 0.16)
            m.clearcoatRoughness = .init(floatLiteral: 0.50)
        case .nycBrick:
            // NYC fire-escape platform — raw galvanised/rusty steel, more matte than iron
            m.baseColor = .init(tint: UIColor(red: n*0.22, green: n*0.18, blue: n*0.14, alpha: 1))
            m.metallic  = .init(floatLiteral: 0.55)
            m.roughness = .init(floatLiteral: 0.62)
        default:
            // Generic dark stone ledge for any other style with balconies
            m.baseColor = .init(tint: UIColor(red: n*0.12, green: n*0.10, blue: n*0.08, alpha: 1))
            m.roughness = .init(floatLiteral: 0.55)
        }
        balconyMaterialCache[key] = m
        return m
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
        case .parisianCore:
            // Paris limestone macadam — warm grey-beige Haussmann pavement.
            // Pedestrian zones: pale limestone paving slabs. Grands boulevards: dark compressed gravel.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.72, green: 0.68, blue: 0.60, alpha: 1))
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.28, green: 0.25, blue: 0.22, alpha: 1))
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.34, green: 0.31, blue: 0.27, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified":
                mat.baseColor = .init(tint: UIColor(red: 0.40, green: 0.37, blue: 0.32, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.44, green: 0.41, blue: 0.36, alpha: 1))
            }
        case .bordeauxWaterfront:
            // Bordeaux warm golden asphalt and sandstone quay paving.
            // Pedestrian: pale Gironde sandstone slabs (Cours de l'Intendance, esplanade).
            // Primary: compressed warm asphalt (quais, Cours Victor Hugo).
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.68, green: 0.60, blue: 0.44, alpha: 1))
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.26, green: 0.22, blue: 0.16, alpha: 1))
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.32, green: 0.27, blue: 0.20, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified", "residential":
                mat.baseColor = .init(tint: UIColor(red: 0.38, green: 0.32, blue: 0.24, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.42, green: 0.36, blue: 0.27, alpha: 1))
            }
        case .rennesMedieval:
            // Rennes dark Breton granite cobblestone paving.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.48, green: 0.46, blue: 0.44, alpha: 1))
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.20, green: 0.19, blue: 0.18, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.28, green: 0.27, blue: 0.26, alpha: 1))
            }
        case .londonSilver:
            // City of London — wet dark tarmac (perpetually damp) + cream Portland stone pedestrian zones.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.68, green: 0.66, blue: 0.62, alpha: 1))  // Portland stone
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1))  // dark wet tarmac
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified", "residential":
                mat.baseColor = .init(tint: UIColor(red: 0.26, green: 0.26, blue: 0.28, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.30, green: 0.30, blue: 0.32, alpha: 1))
            }
        case .madridAfternoon:
            // Madrid — warm grey granite (granito de la Sierra) paving, sun-bleached asphalt.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.72, green: 0.68, blue: 0.58, alpha: 1))  // warm granite
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.28, green: 0.24, blue: 0.20, alpha: 1))  // compressed warm asphalt
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.34, green: 0.30, blue: 0.25, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified":
                mat.baseColor = .init(tint: UIColor(red: 0.40, green: 0.36, blue: 0.30, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.44, green: 0.40, blue: 0.34, alpha: 1))
            }
        case .romanGoldenHour:
            // Rome — sanpietrini basalt cobblestones, warm dark grey with ochre-lit joints.
            // Distinct from any other city: the cube-stone paving creates a unique texture at close range.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.54, green: 0.48, blue: 0.38, alpha: 1))  // travertine pedestrian zones
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.22, green: 0.20, blue: 0.18, alpha: 1))  // dark basalt primary road
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.28, green: 0.25, blue: 0.22, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified", "residential":
                mat.baseColor = .init(tint: UIColor(red: 0.34, green: 0.30, blue: 0.26, alpha: 1))  // warm basalt secondary
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.38, green: 0.34, blue: 0.29, alpha: 1))
            }
        case .vancouverCoastal:
            // Vancouver — dark wet asphalt (Pacific North Coast — perpetually damp like London) +
            // light concrete pedestrian zones. Similar to londonSilver but slightly cooler/greener tint.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.62, green: 0.62, blue: 0.60, alpha: 1))  // cool concrete
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.16, green: 0.17, blue: 0.18, alpha: 1))  // dark wet tarmac
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.20, green: 0.21, blue: 0.22, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified", "residential":
                mat.baseColor = .init(tint: UIColor(red: 0.24, green: 0.25, blue: 0.26, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.28, green: 0.29, blue: 0.30, alpha: 1))
            }
        case .sfMorning:
            // SF: warm cool-grey concrete (the city's dominant street surface) +
            // cream sidewalks (concrete slabs, not stone). Tinted slightly warmer than Vancouver.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.68, green: 0.65, blue: 0.60, alpha: 1))  // warm concrete sidewalk
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.20, green: 0.19, blue: 0.18, alpha: 1))  // dark asphalt
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.26, green: 0.25, blue: 0.23, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified", "residential":
                mat.baseColor = .init(tint: UIColor(red: 0.32, green: 0.30, blue: 0.28, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.36, green: 0.34, blue: 0.32, alpha: 1))
            }
        case .nycDusk:
            // NYC dusk: dark near-black asphalt under dusk orange sky. Crosswalk / pedestrian
            // zones slightly lighter warm concrete. The contrast between warm sky and near-black
            // streets is the definitive Manhattan night-falls visual.
            switch kind {
            case "pedestrian", "footway", "path", "steps", "cycleway":
                mat.baseColor = .init(tint: UIColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1))  // warm concrete sidewalk
            case "primary", "primary_link", "trunk", "trunk_link":
                mat.baseColor = .init(tint: UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1))  // near-black NYC asphalt
            case "secondary", "secondary_link":
                mat.baseColor = .init(tint: UIColor(red: 0.14, green: 0.13, blue: 0.14, alpha: 1))
            case "tertiary", "tertiary_link", "unclassified", "residential":
                mat.baseColor = .init(tint: UIColor(red: 0.18, green: 0.17, blue: 0.18, alpha: 1))
            default:
                mat.baseColor = .init(tint: UIColor(red: 0.22, green: 0.21, blue: 0.22, alpha: 1))
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
            case .parisianCore:       fallback = UIColor(red: 0.58, green: 0.55, blue: 0.50, alpha: 1)  // worn limestone pavement
            case .bordeauxWaterfront: fallback = UIColor(red: 0.55, green: 0.46, blue: 0.33, alpha: 1)  // sandy Garonne riverside
            case .rennesMedieval:     fallback = UIColor(red: 0.30, green: 0.28, blue: 0.26, alpha: 1)  // dark Breton granite cobblestones
            case .londonSilver:       fallback = UIColor(red: 0.22, green: 0.22, blue: 0.25, alpha: 1)  // dark wet London tarmac
            case .madridAfternoon:    fallback = UIColor(red: 0.62, green: 0.56, blue: 0.44, alpha: 1)  // warm Madrid granite
            case .romanGoldenHour:    fallback = UIColor(red: 0.32, green: 0.26, blue: 0.20, alpha: 1)  // dark Roman sanpietrini basalt
            case .vancouverCoastal:   fallback = UIColor(red: 0.22, green: 0.23, blue: 0.25, alpha: 1)  // dark wet Pacific Northwest concrete
            case .sfMorning:          fallback = UIColor(red: 0.30, green: 0.28, blue: 0.26, alpha: 1)  // warm SF concrete sidewalk
            case .nycDusk:            fallback = UIColor(red: 0.12, green: 0.11, blue: 0.12, alpha: 1)  // near-black NYC asphalt at dusk
            case .shibuyaNeon:        fallback = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1)  // near-black Tokyo wet asphalt with neon-indigo tint
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
        guard mood == .beachResort || mood == .coastalPark || mood == .vancouverCoastal || mood == .sfMorning else { return nil }

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
        case .vancouverCoastal:
            // Burrard Inlet / English Bay — cold Pacific deep blue-grey. Much cooler and deeper
            // than Bali turquoise; the overcast Pacific light removes tropical brightness.
            mat.color = .init(tint: isNight
                ? UIColor(red: 0.04, green: 0.08, blue: 0.18, alpha: 1)
                : UIColor(red: 0.10, green: 0.22, blue: 0.38, alpha: 1))
        case .sfMorning:
            // San Francisco Bay — cool medium blue-grey. Slightly lighter/warmer than Vancouver
            // (morning sun on the Bay creates a silvery glint), but clearly cold-water Pacific.
            mat.color = .init(tint: isNight
                ? UIColor(red: 0.04, green: 0.09, blue: 0.20, alpha: 1)
                : UIColor(red: 0.12, green: 0.28, blue: 0.44, alpha: 1))
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

                case .parisianCore:
                    // Paris — Lutetian limestone cobblestones, worn grey-beige joints.
                    // Warm off-white blocks with pale yellow-grey mortar: the classic Parisian
                    // pavement read from a Haussmann building window or orbit camera.
                    if isJoint {
                        r = 132; g = 124; b = 112
                    } else {
                        let br = blockParity ? 185 : 170
                        let bg = blockParity ? 178 : 163
                        let bb = blockParity ? 158 : 144
                        r = UInt8(clamping: br + noise / 2)
                        g = UInt8(clamping: bg + noise / 2)
                        b = UInt8(clamping: bb + noise / 3)
                    }

                case .bordeauxWaterfront:
                    // Bordeaux — sandy Garonne quayside limestone, warm golden cast.
                    // Slightly warmer and sandier than Paris — Atlantic port limestone has
                    // a golden hue that reads beautifully in the golden-hour mood.
                    if isJoint {
                        r = 118; g = 98; b = 72
                    } else {
                        let br = blockParity ? 178 : 162
                        let bg = blockParity ? 148 : 132
                        let bb = blockParity ? 100 : 88
                        r = UInt8(clamping: br + noise / 2)
                        g = UInt8(clamping: bg + noise / 3)
                        b = UInt8(clamping: bb + noise / 4)
                    }

                case .rennesMedieval:
                    // Rennes — dark Breton granite cobblestones, very tight block pattern.
                    // Vieux-Rennes medieval streets use dark schist and granite — much darker
                    // than Paris limestone, with a cool blue-grey cast from Atlantic humidity.
                    if isJoint {
                        r = 48; g = 46; b = 52
                    } else {
                        let base = blockParity ? 88 : 74
                        r = UInt8(clamping: base + noise / 3)
                        g = UInt8(clamping: base - 2 + noise / 4)
                        b = UInt8(clamping: base + 8 + noise / 3)
                    }

                case .londonSilver:
                    // City of London — perpetually wet dark tarmac, almost featureless.
                    // No cobblestone grid — British tarmac roads have minimal surface texture.
                    // Cool near-black with slight blue-grey from ambient light in overcast sky.
                    let base = blockParity ? 62 : 52
                    r = UInt8(clamping: base + noise / 4)
                    g = UInt8(clamping: base + noise / 5)
                    b = UInt8(clamping: base + 6 + noise / 3)  // faint blue-grey from London sky reflection

                case .madridAfternoon:
                    // Madrid — warm sun-bleached granite slab (granito de la Sierra).
                    // Lighter and warmer than Paris limestone — sun-baked Iberian granite reads
                    // as a warm creamy-beige, almost golden in the late-afternoon light.
                    if isJoint {
                        r = 122; g = 110; b = 88
                    } else {
                        let br = blockParity ? 190 : 174
                        let bg = blockParity ? 172 : 158
                        let bb = blockParity ? 136 : 124
                        r = UInt8(clamping: br + noise / 2)
                        g = UInt8(clamping: bg + noise / 3)
                        b = UInt8(clamping: bb + noise / 4)
                    }

                case .romanGoldenHour:
                    // Rome — sanpietrini basalt cobblestones. Tighter joint grid (every 4px vs
                    // every 8px) creates the characteristic fine-grained cube-stone texture visible
                    // from orbit. Dark basalt with warm amber-golden mortar joints lit by late sun.
                    // The amber joints (high R, moderate G, low B) are the key distinguisher from
                    // grey European cobblestone streets — fired clay mortar warmed by centuries of sun.
                    let sanJoint = (x % 4 == 0) || (y % 4 == 0)
                    let sanParity = ((x / 4) + (y / 4)) % 2 == 0
                    if sanJoint {
                        r = 108; g = 82; b = 54   // warm amber-terracotta mortar
                    } else {
                        let base = sanParity ? 68 : 58
                        r = UInt8(clamping: base + noise / 3)
                        g = UInt8(clamping: base - 2 + noise / 4)
                        b = UInt8(clamping: base - 6 + noise / 5)  // dark warm-grey basalt
                    }

                case .vancouverCoastal:
                    // Vancouver Downtown — dark cool wet concrete, Pacific Northwest character.
                    // No stone paving grid here — Vancouver's streets are standard North American
                    // poured concrete and asphalt. Subtle cool-blue tint from overcast sky reflection.
                    let base = blockParity ? 64 : 54
                    r = UInt8(clamping: base + noise / 5)
                    g = UInt8(clamping: base + 1 + noise / 5)
                    b = UInt8(clamping: base + 6 + noise / 3)  // cool Pacific sky reflection

                case .sfMorning:
                    // San Francisco Downtown / FiDi — warm medium concrete sidewalks.
                    // SF has concrete paving typical of North American cities, but the morning
                    // light gives it a warm cast (vs Vancouver's cool overcast). Slightly lighter.
                    if isJoint {
                        r = 76; g = 72; b = 66
                    } else {
                        let br = blockParity ? 112 : 98
                        let bg = blockParity ? 106 : 93
                        let bb = blockParity ? 94 : 82
                        r = UInt8(clamping: br + noise / 3)
                        g = UInt8(clamping: bg + noise / 4)
                        b = UInt8(clamping: bb + noise / 5)
                    }

                case .nycDusk:
                    // New York City — near-black asphalt at dusk. Manhattan streets are the
                    // darkest ground in the app — thick layers of resurfaced blacktop absorb the
                    // orange dusk sky completely. Almost featureless, like londonSilver but warmer
                    // (slightly less blue-grey, slightly more warm dark from the dusk sky).
                    let base = blockParity ? 36 : 28
                    r = UInt8(clamping: base + 2 + noise / 6)  // faint warm tint from dusk orange
                    g = UInt8(clamping: base + noise / 7)
                    b = UInt8(clamping: base + noise / 8)

                case .shibuyaNeon:
                    // Tokyo Shibuya — dark wet asphalt with a faint indigo-blue cast from neon
                    // signage and building illumination bouncing off rain-slicked pavement.
                    let base = blockParity ? 30 : 24
                    r = UInt8(clamping: base + noise / 8)
                    g = UInt8(clamping: base + noise / 8)
                    b = UInt8(clamping: base + 8 + noise / 5)  // neon glow tints blue channel
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
            let zoneMaterial: any RealityKit.Material = (kind == "natural=water")
                ? waterMaterial(isNight: isNight)
                : UnlitMaterial(color: greenZoneColor(kind: kind, isNight: isNight))
            let entity = ModelEntity(mesh: mesh, materials: [zoneMaterial])
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
            case "natural=water":
                // Garonne at night: dark pewter-blue, faint ambient reflection of city lights.
                return UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1)
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
            case "natural=water":
                // Garonne river: tidal muddy brown-blue. The Gironde carries heavy silt from
                // the Dordogne/Garonne confluence — not the azure of the Mediterranean but a
                // characteristic warm blue-grey. Chosen to contrast with the golden limestone
                // quays without reading as sky-blue (which would compete with the sky dome).
                return UIColor(red: 0.32, green: 0.44, blue: 0.52, alpha: 1)
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

    /// PBR material for `natural=water` zone polygons (rivers, harbours, canals).
    /// Clearcoat 0.80 + roughness 0.16 = faint directional-light specular streak at city-block
    /// scale, reading as sun glinting on still or slow-moving water viewed from orbit camera.
    /// `UnlitMaterial` is used for all other green zone kinds; water is the one zone type
    /// where a specular highlight adds genuine information (water vs. land distinction).
    private static func waterMaterial(isNight: Bool) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if isNight {
            // Night: dark pewter-blue with a faint ambient-light clearcoat shimmer.
            m.baseColor = .init(tint: UIColor(red: 0.05, green: 0.09, blue: 0.15, alpha: 1))
            m.metallic  = .init(floatLiteral: 0.08)
            m.roughness = .init(floatLiteral: 0.38)
            m.clearcoat = .init(floatLiteral: 0.55)
            m.clearcoatRoughness = .init(floatLiteral: 0.28)
        } else {
            // Day: tidal blue-grey base (Garonne silt, Vancouver Pacific, Jakarta bay).
            m.baseColor = .init(tint: UIColor(red: 0.26, green: 0.40, blue: 0.56, alpha: 1))
            m.metallic  = .init(floatLiteral: 0.15)
            m.roughness = .init(floatLiteral: 0.16)
            m.clearcoat = .init(floatLiteral: 0.80)
            m.clearcoatRoughness = .init(floatLiteral: 0.18)
        }
        return m
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
        let capStyles: Set<BuildingStyle> = [.balinese, .colonial, .javanese, .religious, .haussmannien, .medieval, .bordelaisClassical, .londonBrick, .romanOchre]
        var styleGroups: [BuildingStyle: [BuildingFootprint]] = [:]
        for b in buildings {
            guard capStyles.contains(b.style), b.polygon.count >= 3 else { continue }
            guard b.roofType == nil else { continue }  // authored overrides via makeAuthoredRoofEntities
            styleGroups[b.style, default: []].append(b)
        }
        var entities: [ModelEntity] = []
        for style in [BuildingStyle.balinese, .colonial, .javanese, .religious,
                      .haussmannien, .medieval, .bordelaisClassical, .londonBrick, .romanOchre] {
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
            mat.baseColor = .init(tint: roofCapColor(for: style, isNight: isNight))
            // Roughness per material: zinc (haussmannien) is smoother than terracotta; balinese volcanic tile is roughest.
            let roughness: Float = switch style {
            case .balinese:         0.92  // rough volcanic tuff tile
            case .haussmannien:     0.86  // patinated zinc — matte but slightly smoother than terracotta
            case .londonBrick:      0.90  // London Welsh slate — matte, aged by rain
            case .romanOchre:       0.91  // Roman terracotta coppo — rough fired clay, centuries of weathering
            default:                0.88  // fired clay tile (colonial, javanese, medieval, bordelaisClassical, religious)
            }
            mat.roughness = .init(floatLiteral: roughness)
            mat.metallic  = .init(floatLiteral: (style == .haussmannien || style == .londonBrick) ? 0.04 : 0.0)
            if style != .religious {
                // Faint clearcoat — fired-clay tile / zinc / slate all develop a micro-glaze from rain cycling.
                let cc: Float = switch style {
                case .bordelaisClassical: 0.04
                case .haussmannien:       0.08
                case .londonBrick:        0.06  // wet Welsh slate sheen in London rain
                default:                  0.07
                }
                let ccr: Float = switch style {
                case .haussmannien: 0.70
                case .londonBrick:  0.72  // similar to zinc but slightly rougher
                default:            0.62
                }
                mat.clearcoat          = .init(floatLiteral: cc)
                mat.clearcoatRoughness = .init(floatLiteral: ccr)
            }
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            entity.name = "roofCap_\(style.rawValue)"
            entities.append(entity)
        }
        return entities
    }

    private static func roofCapOverhang(for style: BuildingStyle) -> Float {
        switch style {
        case .balinese:      return 0.80   // wide overhang — Balinese hip roofs cantilever far out
        case .colonial:      return 0.30   // Dutch colonial shophouse — moderate
        case .javanese:      return 0.60   // Joglo — wider than colonial
        case .religious:     return 0.25
        case .haussmannien:        return 0.15   // Haussmann mansard — minimal eave, nearly vertical face
        case .medieval:            return 0.35   // Breton medieval — moderate gabled overhang
        case .bordelaisClassical:  return 0.25   // Bordeaux classical cornice — narrow eave
        case .londonBrick:         return 0.20   // Victorian brick terrace — narrow eave, stack of flats
        case .romanOchre:          return 0.30   // Roman canal-tile cornice — moderate eave, Mediterranean
        default:                   return 0.0
        }
    }

    private static func roofCapPitchTan(for style: BuildingStyle) -> Float {
        switch style {
        case .balinese:      return 0.839  // ~40° — steep Bali hip
        case .colonial:      return 0.625  // ~32° — moderate Dutch hip
        case .javanese:      return 1.000  // 45° — steep Joglo
        case .religious:     return 0.700  // ~35°
        case .haussmannien:        return 2.747  // ~70° — mansard nearly vertical face (Second Empire profile)
        case .medieval:            return 1.192  // ~50° — steep Breton/French medieval pitched roof
        case .bordelaisClassical:  return 0.577  // ~30° — Provençal/Bordelais low-pitch canal-tile
        case .londonBrick:         return 0.466  // ~25° — shallow London slate roof, long ridgeline
        case .romanOchre:          return 0.700  // ~35° — Roman canal-tile, steeper than Bordeaux
        default:                   return 0.577
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
        case .balinese:      return 3.5  // single-storey compounds — rarely wider than 7m short side
        case .colonial:      return 4.0  // shophouses fine at natural; warehouses get long ridge
        case .javanese:      return 4.0
        case .religious:     return 3.5
        case .haussmannien:        return 1.8  // tight mansard — very short ridge, near-pyramidal at eaves
        case .medieval:            return 2.5  // moderate gabled ridge
        case .bordelaisClassical:  return 3.0  // moderate Bordelais ridge — readable hip at 30° pitch
        case .londonBrick:         return 5.0  // long shallow London ridge — terraces often 15–20m span
        case .romanOchre:          return 3.5  // moderate Roman ridge — similar to religious, varied building widths
        default:                   return 4.0
        }
    }

    private static func roofCapColor(for style: BuildingStyle, isNight: Bool) -> UIColor {
        if isNight {
            switch style {
            case .balinese:     return UIColor(red: 0.22, green: 0.08, blue: 0.03, alpha: 1)
            case .colonial:     return UIColor(red: 0.28, green: 0.11, blue: 0.04, alpha: 1)
            case .javanese:     return UIColor(red: 0.18, green: 0.07, blue: 0.02, alpha: 1)
            case .religious:    return UIColor(red: 0.18, green: 0.28, blue: 0.24, alpha: 1)
            case .haussmannien:        return UIColor(red: 0.14, green: 0.16, blue: 0.20, alpha: 1)  // dark zinc at night
            case .medieval:            return UIColor(red: 0.18, green: 0.06, blue: 0.02, alpha: 1)  // dark Breton tile
            case .bordelaisClassical:  return UIColor(red: 0.22, green: 0.10, blue: 0.05, alpha: 1)  // dark Bordelais canal tile
            case .londonBrick:         return UIColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1)  // dark London slate at night
            case .romanOchre:          return UIColor(red: 0.24, green: 0.10, blue: 0.04, alpha: 1)  // dark Roman canal tile
            default:                   return UIColor(red: 0.20, green: 0.08, blue: 0.03, alpha: 1)
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
            case .haussmannien:
                // Paris zinc grey-blue — the classic aerial signature of the Haussmann city.
                return UIColor(red: 0.42, green: 0.46, blue: 0.52, alpha: 1)
            case .medieval:
                // Dark Breton clay tile — darker and more matte than colonial Dutch terracotta.
                return UIColor(red: 0.48, green: 0.18, blue: 0.08, alpha: 1)
            case .bordelaisClassical:
                // Provençal/Bordelais canal tile — warmer and more orange than Dutch colonial terracotta.
                // Flat S-shaped tile, slightly brighter than medieval due to lower pitch and sun exposure.
                return UIColor(red: 0.64, green: 0.28, blue: 0.12, alpha: 1)
            case .londonBrick:
                // London Welsh slate — cool blue-grey, the defining aerial rooftop colour of Victorian London.
                // Distinguishes the City's terrace rows from warm-tile continental European cities.
                return UIColor(red: 0.44, green: 0.46, blue: 0.50, alpha: 1)
            case .romanOchre:
                // Roman canal tile (coppo/tegola): dark warm terracotta, older and more weathered than
                // Dutch colonial, richer orange than Bordeaux canal tile — the rooftop colour of the
                // historic centre from the Gianicolo overlook.
                return UIColor(red: 0.62, green: 0.24, blue: 0.10, alpha: 1)
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
        let bboxArea = (x1r - x0r) * (z1r - z0r)
        let eaveY = displayHeight(for: building, area: bboxArea) + 0.05

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
        let eaveY  = displayHeight(for: building, area: (x1r - x0r) * (z1r - z0r)) + 0.05
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
        let baseY  = displayHeight(for: building, area: (x1r - x0r) * (z1r - z0r)) + 0.05
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

    // MARK: - POI Beacons

    /// Small glowing spheres over each POI location — no stems, no text.
    /// Featured POIs: amber sphere (radius 0.6% of district extent).
    /// Standard POIs: grey sphere (radius 0.3%). Named "poi:<id>" for hit-testing.
    @MainActor
    private static func makePOIBeaconEntities(
        districtName: String,
        districtAnchor: GeoCoord,
        districtExtent: Float
    ) -> Entity? {
        guard let collection = CangguPOICollection.load(for: districtName),
              !collection.pois.isEmpty else { return nil }

        let root = Entity()
        root.name = "poiBeacons"
        let beaconY: Float = districtExtent * 0.008

        for poi in collection.pois {
            let offset = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                .sceneOffset(from: districtAnchor)
            let radius: Float = poi.isFeatured ? districtExtent * 0.006 : districtExtent * 0.003
            let color: UIColor = poi.isFeatured
                ? UIColor(red: 1.0, green: 0.78, blue: 0.20, alpha: 0.92)
                : UIColor(white: 0.80, alpha: 0.60)
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: radius),
                materials: [UnlitMaterial(color: color)]
            )
            sphere.name = "poi:\(poi.id)"
            sphere.position = SIMD3(offset.x, beaconY, offset.z)
            root.addChild(sphere)
        }

        return root
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

        let dh = displayHeight(for: building, area: polygonArea(building.polygon))
        let beaconHeight = max(dh * 0.6, districtExtent * 0.03)
        let beaconWidth  = districtExtent * 0.008
        var beaconMat    = PhysicallyBasedMaterial()
        beaconMat.baseColor       = .init(tint: .white)
        beaconMat.emissiveColor   = .init(color: UIColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1))
        beaconMat.emissiveIntensity = 4
        let beaconMesh = MeshResource.generateBox(width: beaconWidth, height: beaconHeight, depth: beaconWidth)
        let beacon = ModelEntity(mesh: beaconMesh, materials: [beaconMat])
        beacon.position = SIMD3(centroidX, dh + beaconHeight / 2 + districtExtent * 0.015, centroidZ)
        group.addChild(beacon)

        let textMesh = MeshResource.generateText(
            building.name ?? "Focus",
            extrusionDepth: 0.05,
            font: .systemFont(ofSize: 3, weight: .semibold)
        )
        let textEntity = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: .white)])
        textEntity.position = SIMD3(centroidX, dh + beaconHeight + districtExtent * 0.02, centroidZ)
        textEntity.look(at: textEntity.position + facing, from: textEntity.position, relativeTo: nil)
        group.addChild(textEntity)

        return group
    }

    // MARK: - Materials

    /// Style-specific roof material — visually distinct from the wall material so that the
    /// orbit camera (mostly looking down) reads the scene as architecturally rich rather than
    /// a sea of same-material boxes.
    private static func roofMaterialPreset(for style: BuildingStyle, isNight: Bool) -> any RealityKit.Material {
        // modernGlass + nycBrick rooftops use UnlitMaterial: ARView's non-removable studio IBL floods
        // upward-facing PBR surfaces (normal=(0,1,0)) with overhead ambient even at low metallic,
        // rendering near-black bases as bright teal. UnlitMaterial sidesteps the IBL entirely.
        // Architecturally correct — HVAC/gravel/tar roof is not a specular surface.
        if style == .modernGlass {
            var m = UnlitMaterial()
            m.color = .init(tint: isNight
                ? UIColor(red: 0.06, green: 0.08, blue: 0.15, alpha: 1) // dark cool-blue equipment glow
                : UIColor(white: 0.10, alpha: 1))                         // dark charcoal HVAC deck
            return m
        }
        if style == .nycBrick {
            // NYC flat tar/EPDM roof — near-black membrane from orbit camera.
            // UnlitMaterial: even metallic=0 PBR reads as teal on a flat black face under the studio IBL.
            var m = UnlitMaterial()
            m.color = .init(tint: isNight
                ? UIColor(red: 0.05, green: 0.04, blue: 0.04, alpha: 1)  // near-black night roof
                : UIColor(red: 0.12, green: 0.11, blue: 0.11, alpha: 1)) // very dark warm-grey tar membrane
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
        case .modernGlass, .nycBrick:
            break   // both handled above by early UnlitMaterial return — unreachable
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
        case .haussmannien:
            // Paris zinc mansard — the classic grey-blue zinc patina that defines the Parisian
            // aerial silhouette. Matte (roughness 0.86), near-zero metallic (patinated zinc, not
            // polished) so the IBL teal problem doesn't apply. The grey-blue tint is real:
            // Lutetian limestone oxidises the zinc to a characteristic blue-grey patina.
            let day = UIColor(red: 0.42, green: 0.46, blue: 0.52, alpha: 1)  // classic Paris zinc
            let ngt = UIColor(red: 0.14, green: 0.16, blue: 0.20, alpha: 1)  // dark zinc at night
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.86)   // matte patinated zinc
            mat.metallic    = .init(floatLiteral: 0.04)   // slight metallic sheen (bare zinc under patina)
            mat.clearcoat   = .init(floatLiteral: 0.08)   // faint wet-zinc gloss in Paris rain
            mat.clearcoatRoughness = .init(floatLiteral: 0.70)
        case .medieval:
            // Breton clay tile — dark red-brown, steeper pitch than Dutch colonial, weathered
            // by centuries of Atlantic rain. Darker and more matte than colonial terracotta.
            let day = UIColor(red: 0.48, green: 0.18, blue: 0.08, alpha: 1)  // dark Breton clay
            let ngt = UIColor(red: 0.18, green: 0.06, blue: 0.02, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.93)
            mat.metallic    = .init(floatLiteral: 0.0)
            mat.clearcoat   = .init(floatLiteral: 0.04)   // slight rain-wet glaze
            mat.clearcoatRoughness = .init(floatLiteral: 0.85)
        case .bordelaisClassical:
            // Provençal/Bordelais canal tile — flat S-shaped terracotta, low-pitch (~30°).
            // Warmer and more orange than Dutch colonial tile, not zinc like Paris mansard.
            // The flat top face visible from orbit reads as warm terracotta on the Port de la Lune.
            let day = UIColor(red: 0.64, green: 0.28, blue: 0.12, alpha: 1)  // warm canal tile
            let ngt = UIColor(red: 0.22, green: 0.10, blue: 0.05, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.91)
            mat.metallic    = .init(floatLiteral: 0.0)
            mat.clearcoat   = .init(floatLiteral: 0.04)   // faint slip-coat glaze on canal tiles
            mat.clearcoatRoughness = .init(floatLiteral: 0.88)
        case .londonBrick:
            // Welsh slate — cool blue-grey, the defining aerial rooftop colour of Victorian London.
            let day = UIColor(red: 0.44, green: 0.46, blue: 0.50, alpha: 1)  // slate grey-blue
            let ngt = UIColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.90)
            mat.metallic    = .init(floatLiteral: 0.04)   // wet slate micro-sheen
            mat.clearcoat   = .init(floatLiteral: 0.06)
            mat.clearcoatRoughness = .init(floatLiteral: 0.72)
        case .madrileño:
            // Madrid azotea — flat rooftop terrace, exposed concrete or light stone cladding.
            // The flat face is visible from orbit above the Ensanche grid. Warm light grey.
            let day = UIColor(red: 0.80, green: 0.76, blue: 0.68, alpha: 1)  // warm light concrete
            let ngt = UIColor(red: 0.26, green: 0.24, blue: 0.22, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.86)
            mat.metallic    = .init(floatLiteral: 0.0)
        case .romanOchre:
            // Roman terracotta rooftop tile — deep warm terracotta, the dominant aerial colour
            // of the historic centre. Darker and more saturated than Dutch colonial (0.66/0.27/0.12).
            let day = UIColor(red: 0.62, green: 0.24, blue: 0.10, alpha: 1)  // deep Roman coppo
            let ngt = UIColor(red: 0.20, green: 0.08, blue: 0.04, alpha: 1)
            mat.baseColor   = .init(tint: isNight ? ngt : day)
            mat.roughness   = .init(floatLiteral: 0.93)
            mat.metallic    = .init(floatLiteral: 0.0)
            mat.clearcoat   = .init(floatLiteral: 0.05)
            mat.clearcoatRoughness = .init(floatLiteral: 0.82)
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
        // 256×256 for higher resolution window grid — 2× improvement on 128×128 predecessor.
        // Each window cell gets a 1px dark frame border so windows read as distinct panes
        // rather than a solid amber rectangle, even at moderate zoom.
        let size = 256
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        // density = fraction of window cells that are lit.  modernGlass uses 0.25 (not 0.70)
        // so at-distance the facade reads as scattered bright spots on dark glass, not a
        // uniform amber glow — the contrast between dark glass (baseColor ≈ 0.07) and lit
        // windows (emissiveIntensity 2.5) only works when the dark area dominates the texture.
        let (cols, rows, winW, winH, density): (Int, Int, Int, Int, Float)
        switch style {
        case .modernGlass:    (cols, rows, winW, winH, density) = (8, 16, 6, 8, 0.25)
        case .modernConcrete: (cols, rows, winW, winH, density) = (6, 12, 5, 6, 0.28)
        case .colonial:       (cols, rows, winW, winH, density) = (4,  6, 7, 7, 0.25)
        case .government:     (cols, rows, winW, winH, density) = (5,  8, 5, 8, 0.30)
        case .religious:      (cols, rows, winW, winH, density) = (3,  4, 10, 12, 0.15)
        case .balinese:       (cols, rows, winW, winH, density) = (3,  4, 8, 6, 0.10)
        case .javanese:       (cols, rows, winW, winH, density) = (4,  5, 7, 7, 0.18)
        case .haussmannien:       (cols, rows, winW, winH, density) = (5,  8, 7, 9, 0.35)
        case .medieval:           (cols, rows, winW, winH, density) = (3,  5, 9, 9, 0.20)
        case .bordelaisClassical: (cols, rows, winW, winH, density) = (4,  6, 7, 9, 0.30)
        case .londonBrick:        (cols, rows, winW, winH, density) = (4,  7, 7, 9, 0.32)
        case .madrileño:          (cols, rows, winW, winH, density) = (5,  8, 7, 11, 0.38)
        case .romanOchre:         (cols, rows, winW, winH, density) = (3,  5, 9, 11, 0.22)
        case .nycBrick:           (cols, rows, winW, winH, density) = (4,  6, 7, 9, 0.30)
        }
        let cellW = size / cols, cellH = size / rows
        var seed: UInt32 = 2166136261
        for byte in style.rawValue.utf8 { seed ^= UInt32(byte); seed = seed &* 16777619 }
        for row in 0..<rows {
            for col in 0..<cols {
                seed = seed &* 1664525 &+ 1013904223
                guard Float(seed & 0xFF) / 255.0 < density else { continue }
                // Window pane: centred in cell, 1px dark frame border leaves frame visible
                let startX = col * cellW + max(1, (cellW - winW) / 2)
                let startY = row * cellH + max(1, (cellH - winH) / 2)
                let endX   = min(startX + winW, col * cellW + cellW - 1)
                let endY   = min(startY + winH, row * cellH + cellH - 1)
                for py in startY..<endY {
                    for px in startX..<endX {
                        guard px < size, py < size else { continue }
                        // 1px dark frame: skip outermost ring of each pane
                        let isFrameX = (px == startX || px == endX - 1)
                        let isFrameY = (py == startY || py == endY - 1)
                        let i = (py * size + px) * 4
                        if isFrameX || isFrameY {
                            // Dark window frame — near-black so individual panes read clearly
                            pixels[i] = 8; pixels[i+1] = 8; pixels[i+2] = 10; pixels[i+3] = 255
                        } else {
                            // Amber warm light fill
                            pixels[i] = 255; pixels[i+1] = 220; pixels[i+2] = 140; pixels[i+3] = 255
                        }
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
        case .haussmannien:
            // Lutetian limestone — calcaire lutétien — the defining material of Paris and Bordeaux.
            // Warm cream to off-white, cut and polished by centuries of weather. The characteristic
            // "stone colour" Paris is globally known for: neither white nor yellow but that particular
            // warm ochre-cream. Three variation buckets: cool pale stone / warm standard cream / warm amber.
            let dayR = 0.86 + 0.04 * cgWobble   // 0.82–0.90 range
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayR * 0.28, green: 0.82 * 0.28, blue: 0.72 * 0.28, alpha: 1)
                : UIColor(red: dayR, green: 0.82, blue: 0.72, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.01)
            material.roughness = .init(floatLiteral: 0.74 + 0.06 * abs(wobble))
            material.clearcoat = .init(floatLiteral: 0.10)   // faint wet-stone sheen after Paris rain
            material.clearcoatRoughness = .init(floatLiteral: 0.55)
        case .medieval:
            // Half-timber plaster and Breton granite — Vieux-Rennes pan-de-bois facades mix white
            // lime-washed plaster between colombage frames with dark grey granite ground floors.
            // Three variation buckets: cool grey granite / warm standard plaster / warm buff.
            let dayBase = 0.76 + 0.06 * cgWobble   // 0.70–0.82 range, granite to plaster
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayBase * 0.32, green: 0.68 * 0.32, blue: 0.58 * 0.32, alpha: 1)
                : UIColor(red: dayBase, green: 0.68, blue: 0.58, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.0)
            material.roughness = .init(floatLiteral: 0.84 + 0.08 * abs(wobble))
            material.clearcoat = .init(floatLiteral: 0.06)   // granite micro-sheen in wet Breton weather
            material.clearcoatRoughness = .init(floatLiteral: 0.80)
        case .bordelaisClassical:
            // Calcaire à astéries — Bordeaux's shelly Gironde limestone, distinctly warmer
            // and more amber-gold than Parisian Lutetian limestone (cream-white 0.86–0.90).
            // The characteristic Port de la Lune "gold": notably more ochre in afternoon sun.
            // Three variation buckets: warm pale stone / standard amber-gold / deep amber.
            let dayR = 0.82 + 0.06 * cgWobble   // 0.76–0.88 — warmer base than Paris (0.82–0.90 but cooler tones)
            let dayG = 0.72 + 0.03 * cgWobble   // 0.69–0.75 — clearly lower G than Paris (0.82)
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayR * 0.28, green: dayG * 0.28, blue: 0.50 * 0.28, alpha: 1)
                : UIColor(red: dayR, green: dayG, blue: 0.50, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.01)
            material.roughness = .init(floatLiteral: 0.76 + 0.06 * abs(wobble))   // rough-cut stone
            material.clearcoat = .init(floatLiteral: 0.08)   // faint rain-wet stone sheen
            material.clearcoatRoughness = .init(floatLiteral: 0.60)
        case .londonBrick:
            // London stock brick — fired yellow-buff clay brick, the defining Victorian/Georgian wall
            // surface. Warm buff-to-ochre (not red — London stock is yellow-buff, not the red Flemish
            // bond associated with Manchester). Three buckets: pale buff / warm standard ochre / deep amber.
            // Key constraint: low B channel (≤0.42) keeps it warm-toned and distinct from pale haussmannien
            // limestone (B=0.72). G channel ≤0.70 keeps it below the golden-beige of bordelaisClassical.
            let dayR = 0.74 + 0.08 * cgWobble  // 0.66–0.82 warm buff range
            let dayG = 0.62 + 0.06 * cgWobble  // 0.56–0.68 — clearly lower than haussmannien (0.82)
            let dayB = 0.38 + 0.04 * cgWobble  // 0.34–0.42 — low blue, anchors warm-buff identity
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayR * 0.26, green: dayG * 0.26, blue: dayB * 0.26, alpha: 1)
                : UIColor(red: dayR, green: dayG, blue: dayB, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.0)
            material.roughness = .init(floatLiteral: 0.82 + 0.07 * abs(wobble))  // rough fired brick
            material.clearcoat = .init(floatLiteral: 0.05)   // faint London rain gloss
            material.clearcoatRoughness = .init(floatLiteral: 0.78)
        case .madrileño:
            // 19th-century Madrid Ensanche — limestone/sandstone render in a warm golden-beige.
            // Distinctly warmer than haussmannien cream (G=0.82, B=0.72) and more uniform/polished
            // than London brick. The Salamanca grid reads as a continuous warm gold plane from above.
            // Three buckets: pale warm stone / standard golden-beige / deep amber-sand.
            // B channel: 0.50–0.60 — warmer than Paris (0.72), cooler than Bordeaux (0.50 baseline).
            // Characteristic flat azotea top face visible from orbit — no cap geometry, so the base
            // material is what the camera sees looking down.
            let dayR = 0.84 + 0.06 * cgWobble  // 0.78–0.90 warm base
            let dayG = 0.76 + 0.04 * cgWobble  // 0.72–0.80 — clearly golden-beige
            let dayB = 0.54 + 0.06 * cgWobble  // 0.48–0.60 — warmer than Paris, cooler than Bordeaux
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayR * 0.28, green: dayG * 0.28, blue: dayB * 0.28, alpha: 1)
                : UIColor(red: dayR, green: dayG, blue: dayB, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.01)
            material.roughness = .init(floatLiteral: 0.72 + 0.07 * abs(wobble))  // polished render over limestone
            material.clearcoat = .init(floatLiteral: 0.12)   // Madrid sun gloss on polished stone
            material.clearcoatRoughness = .init(floatLiteral: 0.50)
        case .romanOchre:
            // Roman tuff/brick with ochre render plaster — sienna-amber, the defining colour of the
            // Historic Centre from any overlook point. Warmer and more saturated than madrileño
            // (golden-beige) and bordelaisClassical (amber-gold). Key constraint: B channel must stay
            // ≤0.38 — the low blue is what distinguishes Rome's terracotta-sienna from other European
            // limestone cities. Three buckets: pale warm ochre / standard sienna-amber / deep terracotta.
            let dayR = 0.78 + 0.08 * cgWobble  // 0.70–0.86 — deep sienna base
            let dayG = 0.54 + 0.06 * cgWobble  // 0.48–0.60 — clearly lower G than madrileño (0.76)
            let dayB = 0.30 + 0.06 * cgWobble  // 0.24–0.36 — low blue, sienna-amber identity
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayR * 0.26, green: dayG * 0.26, blue: dayB * 0.26, alpha: 1)
                : UIColor(red: dayR, green: dayG, blue: dayB, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.0)
            material.roughness = .init(floatLiteral: 0.78 + 0.08 * abs(wobble))  // rough tuff/render plaster
            material.clearcoat = .init(floatLiteral: 0.07)   // warm-rain sheen on ancient plaster
            material.clearcoatRoughness = .init(floatLiteral: 0.72)
        case .nycBrick:
            // New York City red-brown fired brick — the defining wall material of Manhattan's pre-war
            // fabric: tenements, brownstones, and the limestone-clad office buildings of the 1900–1940s.
            // Distinctly redder than London stock brick (yellow-buff, B≈0.38) and darker/more saturated
            // than Roman ochre (sienna, B≈0.30). Low B channel (B≈0.20) + low G (G≈0.30) locks the
            // warm red-brown identity across all three variation buckets.
            // Three buckets: muted pale red / standard warm red-brown / deep terracotta-red.
            let dayR = 0.56 + 0.06 * cgWobble  // 0.50–0.62 warm red-brown range
            let dayG = 0.30 + 0.04 * cgWobble  // 0.26–0.34 — clearly lower than londonBrick (0.62)
            let dayB = 0.20 + 0.04 * cgWobble  // 0.16–0.24 — lower than romanOchre (0.30)
            material.baseColor = .init(tint: isNight
                ? UIColor(red: dayR * 0.24, green: dayG * 0.24, blue: dayB * 0.24, alpha: 1)
                : UIColor(red: dayR, green: dayG, blue: dayB, alpha: 1))
            material.metallic  = .init(floatLiteral: 0.0)
            material.roughness = .init(floatLiteral: 0.88 + 0.05 * abs(wobble))  // rough fired common brick
            material.clearcoat = .init(floatLiteral: 0.04)   // minimal — just a hint of rain-wet brick sheen
            material.clearcoatRoughness = .init(floatLiteral: 0.86)
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
                case .haussmannien:        0.40  // Parisian café/apartment glow — warm yellow through shuttered balconies
                case .medieval:            0.28  // modest Breton town lighting — intimate, low-density
                case .bordelaisClassical:  0.38  // Bordeaux café-terrace amber glow — denser than Rennes, warmer than Paris
                case .londonBrick:         0.30  // London terrace — warm yellow-orange sodium streetlight glow
                case .madrileño:           0.35  // Madrid terrace — warm incandescent balcony glow, moderate density
                case .romanOchre:          0.22  // Rome historic core — intimate, lower electric density than Madrid
                case .nycBrick:            0.34  // NYC tenements / brownstones — dense amber glow from apartment windows
                default:                   0.35
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

            let h = displayHeight(for: b, area: polygonArea(b.polygon))

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

    /// Deterministic display height for a building.
    ///
    /// For `isHeightEstimated` buildings of low-rise compound styles (`balinese`, `colonial`,
    /// `javanese`, `medieval`), applies area-bucketed height scaling: small footprints become
    /// gate pavilions / single rooms (3–5 m), large resort footprints become multi-story blocks
    /// (9–15 m). This eliminates the "flat carpet" effect in Bali districts where the
    /// `balinese` default of 7 m produced 560 Kuta buildings all at exactly the same height.
    ///
    /// All other styles retain the existing ±20 % wobble from the style default.
    /// A separate seed suffix `"_h"` keeps height variation uncorrelated with material bucket.
    // swiftlint:disable function_body_length
    private static func displayHeight(for building: BuildingFootprint, area: Float) -> Float {
        guard building.isHeightEstimated else { return building.heightMeters }
        let v = deterministicVariation(seed: building.osmID + "_h")
        let baseH: Float; let rangeH: Float
        switch building.style {

        // MARK: Tropical compound (3–15 m) — gate pavilions to resort wings
        case .balinese, .colonial, .javanese, .medieval:
            switch area {
            case ..<40:    (baseH, rangeH) = (3.0, 2.0)
            case ..<100:   (baseH, rangeH) = (4.0, 2.5)
            case ..<250:   (baseH, rangeH) = (5.5, 3.0)
            case ..<600:   (baseH, rangeH) = (7.0, 4.0)
            default:       (baseH, rangeH) = (9.0, 6.0)
            }

        // MARK: Urban concrete infill (4–22 m) — service rooms to major commercial blocks
        case .modernConcrete:
            switch area {
            case ..<60:    (baseH, rangeH) = (4.0, 3.0)
            case ..<150:   (baseH, rangeH) = (6.0, 4.0)
            case ..<400:   (baseH, rangeH) = (8.5, 5.5)
            case ..<900:   (baseH, rangeH) = (11.0, 7.0)
            default:       (baseH, rangeH) = (14.0, 8.0)
            }

        // MARK: Haussmannien limestone (12–27 m) — 4-8 floors, street-width regulated
        // Small footprints are courtyard wings / narrow lots (4 floors); large footprints
        // sit on wide boulevards or are institutional buildings (7-8 floors).
        case .haussmannien:
            switch area {
            case ..<80:    (baseH, rangeH) = (12.0, 6.0)   // narrow lot / courtyard wing
            case ..<250:   (baseH, rangeH) = (15.0, 6.0)   // standard 5-floor
            case ..<600:   (baseH, rangeH) = (18.0, 6.0)   // corner / boulevard block
            default:       (baseH, rangeH) = (20.0, 7.0)   // institutional / grand hôtel
            }

        // MARK: Bordeaux classical (10–22 m) — 3-5 floors, Atlantic limestone
        case .bordelaisClassical:
            switch area {
            case ..<60:    (baseH, rangeH) = (10.0, 4.0)
            case ..<150:   (baseH, rangeH) = (12.0, 6.0)
            case ..<400:   (baseH, rangeH) = (14.0, 6.0)
            default:       (baseH, rangeH) = (16.0, 6.0)
            }

        // MARK: London Victorian brick (7–22 m) — mews cottages to mansion blocks
        case .londonBrick:
            switch area {
            case ..<60:    (baseH, rangeH) = (7.0, 4.0)    // mews cottage
            case ..<150:   (baseH, rangeH) = (9.0, 5.0)    // standard terrace
            case ..<400:   (baseH, rangeH) = (11.0, 7.0)   // corner / commercial
            default:       (baseH, rangeH) = (14.0, 8.0)   // mansion block / warehouse
            }

        // MARK: Madrid Ensanche (12–28 m) — 4-7 floors, Bourbon height regulation
        case .madrileño:
            switch area {
            case ..<80:    (baseH, rangeH) = (12.0, 6.0)
            case ..<200:   (baseH, rangeH) = (16.0, 6.0)   // standard 5-floor Ensanche
            case ..<600:   (baseH, rangeH) = (18.0, 6.0)
            default:       (baseH, rangeH) = (20.0, 8.0)
            }

        // MARK: Roman ochre fabric (8–22 m) — vicolo lots to grand palazzi
        case .romanOchre:
            switch area {
            case ..<60:    (baseH, rangeH) = (8.0, 4.0)    // narrow vicolo plot
            case ..<150:   (baseH, rangeH) = (10.0, 6.0)   // standard 3-4 floor
            case ..<400:   (baseH, rangeH) = (13.0, 6.0)   // palazzo facade
            default:       (baseH, rangeH) = (15.0, 7.0)   // large palazzo block
            }

        // MARK: NYC pre-war brick (8–40 m) — brownstones to pre-war loft buildings
        // Named supertalls (Empire State, Chrysler) have real heights via authored overrides
        // and bypass this path (isHeightEstimated == false). This covers the fabric buildings
        // which span 2-story brownstones to 12-story 1920s apartment houses.
        case .nycBrick:
            switch area {
            case ..<80:    (baseH, rangeH) = (8.0, 6.0)    // brownstone / row house: 8-14 m
            case ..<200:   (baseH, rangeH) = (10.0, 10.0)  // tenement block: 10-20 m
            case ..<500:   (baseH, rangeH) = (14.0, 16.0)  // apartment house: 14-30 m
            default:       (baseH, rangeH) = (18.0, 22.0)  // commercial loft: 18-40 m
            }

        // MARK: Civic buildings (5–25 m) — scales with footprint mass
        case .government:
            switch area {
            case ..<80:    (baseH, rangeH) = (5.0, 5.0)    // small district office
            case ..<200:   (baseH, rangeH) = (7.0, 7.0)    // municipal building
            case ..<500:   (baseH, rangeH) = (10.0, 10.0)  // ministry / prefecture
            default:       (baseH, rangeH) = (12.0, 13.0)  // large civic complex
            }

        // MARK: Religious (4–24 m) — small shrines to major church naves
        // Towers / spires get real heights via KNOWN_HEIGHTS or authored overrides
        // and bypass this path. This covers the nave body and ancillary structures.
        case .religious:
            switch area {
            case ..<60:    (baseH, rangeH) = (4.0, 4.0)    // small shrine / chapel
            case ..<150:   (baseH, rangeH) = (6.0, 6.0)    // parish church
            case ..<400:   (baseH, rangeH) = (8.0, 10.0)   // significant church
            default:       (baseH, rangeH) = (10.0, 14.0)  // major church / cathedral nave
            }

        // MARK: modernGlass — estimated height is already well-calibrated by the fetch script
        // (auto-promoted at ≥30 m via height-based classification, or KNOWN_HEIGHTS matched).
        // ±20 % wobble gives sufficient tower-to-tower variety without distorting height bands.
        default:
            return building.heightMeters * (0.80 + v * 0.40)
        }
        return baseH + v * rangeH
    }
    // swiftlint:enable function_body_length

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
