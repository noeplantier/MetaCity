import SceneKit
import UIKit

/// Procedural materials and textures shared between `DistrictScene3DView` (orbit 3D inspector),
/// `SimulatedARSceneView` (ground-level Simulator fallback), and `ARSceneView` (real-device
/// tabletop AR) — one place, so the three views never visually disagree about what a building,
/// road, or green zone looks like. Zero bundled image assets: every texture is generated in code
/// via Core Graphics. Road/green-zone materials are cached per kind/style rather than allocated
/// fresh per node — see `roadMaterialCache`/`greenZoneMaterial` — both for lower memory overhead
/// and so SceneKit (and `flattenedClone()` in the tabletop AR path) can batch same-material nodes
/// into fewer draw calls.
enum SharedCityGeometry {
    /// One fixed material per style, used consistently everywhere — a skyline reads as a
    /// deliberate, coherent place when every building of a given style looks the same, rather than
    /// each one picking a random color.
    static func materialForStyle(_ style: BuildingStyle) -> SCNMaterial {
        let material = SCNMaterial()
        switch style {
        case .modernGlass:
            material.diffuse.contents = UIColor(red: 0.42, green: 0.58, blue: 0.72, alpha: 1.0)
            material.metalness.contents = 0.85
            material.roughness.contents = 0.15
        case .modernConcrete:
            material.diffuse.contents = UIColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1.0)
            material.metalness.contents = 0.15
            material.roughness.contents = 0.7
        case .colonial:
            material.diffuse.contents = UIColor(red: 0.86, green: 0.8, blue: 0.68, alpha: 1.0)
            material.metalness.contents = 0.0
            material.roughness.contents = 0.85
        case .government:
            material.diffuse.contents = UIColor(red: 0.78, green: 0.7, blue: 0.55, alpha: 1.0)
            material.metalness.contents = 0.0
            material.roughness.contents = 0.8
        case .religious:
            material.diffuse.contents = UIColor(red: 0.93, green: 0.92, blue: 0.86, alpha: 1.0)
            material.metalness.contents = 0.0
            material.roughness.contents = 0.6
        }
        material.emission.contents = windowTexture
        material.emission.wrapS = .repeat
        material.emission.wrapT = .repeat
        return material
    }

    /// How brightly each style's windows glow at night — modern towers read as fully-lit offices,
    /// colonial/government/religious buildings stay mostly dark with just a few warm lights, like
    /// a real heritage building at night rather than an office tower.
    static func nightEmissionIntensity(for style: BuildingStyle) -> CGFloat {
        switch style {
        case .modernGlass: 0.85
        case .modernConcrete: 0.55
        case .colonial: 0.15
        case .government: 0.2
        case .religious: 0.3
        }
    }

    // MARK: - Generated textures

    static let windowTexture: UIImage = {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.55, alpha: 1).cgColor)
            for row in stride(from: CGFloat(2), to: size.height, by: 8) {
                for col in stride(from: CGFloat(2), to: size.width, by: 8) {
                    guard Bool.random() else { continue }
                    cg.fill(CGRect(x: col, y: row, width: 3, height: 3))
                }
            }
        }
    }()

    static let glowParticleImage: UIImage = {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors = [UIColor.white.withAlphaComponent(0.9).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width / 2, options: [])
        }
    }()

    // MARK: - Real district geometry (BuildingFootprint / RoadSegment / GreenZone → SCNNode)
    //
    // Shared between `DistrictScene3DView` (orbit) and `SimulatedARSceneView`'s district mode
    // (ground-level), so both render Kota Tua (and future districts) from the exact same code —
    // no risk of the two views drifting apart on what "real" looks like.

    /// Real building footprint → extruded 3D volume. `SCNShape` extrudes a 2D path along its own
    /// local Z axis; building the path from (x, -z) and then rotating -90° about X re-orients that
    /// extrusion to point up (+Y) with the footprint lying flat in the ground plane. `isDoubleSided`
    /// is set defensively so that re-orientation can never produce invisible (backface-culled)
    /// walls regardless of winding order.
    static func makeDistrictBuildingNode(_ building: BuildingFootprint, lodSwitchDistance: CGFloat) -> SCNNode? {
        guard building.polygon.count >= 3 else { return nil }

        let material = materialForStyle(building.style)
        material.isDoubleSided = true
        // Defaults to the night-styled intensity for this style. `DistrictScene3DView.applyAtmosphere`
        // overrides this immediately (and on every day/night toggle); `SimulatedARSceneView`'s AR
        // mode has no day/night toggle at all, so this default is also its final, correct value —
        // without this, SceneKit's own default (full intensity, 1.0) would light every building
        // regardless of style.
        material.emission.intensity = nightEmissionIntensity(for: building.style)
        material.emission.contentsTransform = SCNMatrix4MakeScale(4, Float(building.heightMeters) * 0.6, 1)

        let detailedShape = extrudedDistrictShape(path: footprintPath(building.polygon), heightMeters: building.heightMeters, material: material)
        let node = SCNNode(geometry: detailedShape)
        // Style is encoded into the name (not via KVC's setValue(forKey:) — SCNNode has no such
        // property, and that would throw NSUnknownKeyException at runtime) so callers can recover
        // it later without a separate side table.
        node.name = "building:\(building.osmID):\(building.style.rawValue)"
        node.eulerAngles.x = -Float.pi / 2

        // LOD: beyond lodSwitchDistance, swap to the footprint's bounding-box rectangle (4
        // vertices vs. up to 16 for the real polygon) — built with the exact same path/extrusion
        // convention as the detailed shape above, so it lines up perfectly when SceneKit swaps to
        // it; a plain `SCNBox` would render centered on the node's origin instead of the
        // building's real position, since this node carries no position offset of its own (the
        // real position is baked into the path coordinates).
        let bounds = districtBoundingBox(of: building.polygon)
        let simpleShape = extrudedDistrictShape(path: rectanglePath(bounds), heightMeters: building.heightMeters, material: material)
        node.geometry?.levelsOfDetail = [
            SCNLevelOfDetail(geometry: simpleShape, worldSpaceDistance: lodSwitchDistance)
        ]

        return node
    }

    /// One shared instance, not one-per-zone — every green zone uses the exact same fixed color,
    /// so a fresh `SCNMaterial` per call was pure allocation waste and an extra distinct render
    /// state for SceneKit to sort/batch around for no visual benefit.
    private static let greenZoneMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.22, green: 0.38, blue: 0.22, alpha: 1.0)
        material.roughness.contents = 0.95
        material.isDoubleSided = true
        return material
    }()

    static func makeDistrictGreenZoneNode(_ zone: GreenZone) -> SCNNode? {
        guard zone.polygon.count >= 3 else { return nil }
        let shape = SCNShape(path: footprintPath(zone.polygon), extrusionDepth: 0.25)
        shape.materials = [greenZoneMaterial]

        let node = SCNNode(geometry: shape)
        node.name = "greenZone:\(zone.osmID)"
        node.eulerAngles.x = -Float.pi / 2
        node.position.y = 0.02 // just above the ground plane, avoids z-fighting
        return node
    }

    /// Cached per `highway` kind (`"secondary"`, `"footway"`, ...) rather than allocated fresh per
    /// road — a district can have 100+ `RoadSegment`s sharing only a handful of distinct kinds, so
    /// this turns "one material object per road" into "one material object per kind, ever".
    private static var roadMaterialCache: [String: SCNMaterial] = [:]

    private static func roadMaterial(for kind: String?) -> SCNMaterial {
        let key = kind ?? "_default"
        if let cached = roadMaterialCache[key] { return cached }
        let material = SCNMaterial()
        material.diffuse.contents = districtRoadColor(for: kind)
        material.roughness.contents = 0.9
        roadMaterialCache[key] = material
        return material
    }

    /// A road polyline becomes a chain of flat oriented segments between consecutive points —
    /// simpler and just as effective as a true swept-ribbon geometry at this scale.
    static func makeDistrictRoadNodes(_ road: RoadSegment) -> [SCNNode] {
        guard road.points.count >= 2 else { return [] }
        let width = districtRoadWidth(for: road.kind)
        let material = roadMaterial(for: road.kind)

        var nodes: [SCNNode] = []
        for (start, end) in zip(road.points, road.points.dropFirst()) {
            let dx = end.x - start.x
            let dz = end.z - start.z
            let length = sqrt(dx * dx + dz * dz)
            guard length > 0.01 else { continue }

            let segment = SCNBox(width: CGFloat(length), height: 0.05, length: CGFloat(width), chamferRadius: 0)
            segment.materials = [material]
            let node = SCNNode(geometry: segment)
            node.name = "road"
            node.position = SCNVector3((start.x + end.x) / 2, 0.01, (start.z + end.z) / 2)
            node.eulerAngles.y = -atan2(dz, dx)
            nodes.append(node)
        }
        return nodes
    }

    /// Path in the shape's pre-rotation local space: (x, -z), so that after a node's
    /// eulerAngles.x = -π/2 rotation, world position becomes (x, [0...height], z) — real ground
    /// position preserved, extrusion axis becomes "up".
    private static func footprintPath(_ polygon: [LocalPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        let first = polygon[0]
        path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(-first.z)))
        for point in polygon.dropFirst() {
            path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(-point.z)))
        }
        path.close()
        return path
    }

    private static func rectanglePath(_ bounds: (minX: Float, maxX: Float, minZ: Float, maxZ: Float)) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: CGFloat(bounds.minX), y: CGFloat(-bounds.minZ)))
        path.addLine(to: CGPoint(x: CGFloat(bounds.maxX), y: CGFloat(-bounds.minZ)))
        path.addLine(to: CGPoint(x: CGFloat(bounds.maxX), y: CGFloat(-bounds.maxZ)))
        path.addLine(to: CGPoint(x: CGFloat(bounds.minX), y: CGFloat(-bounds.maxZ)))
        path.close()
        return path
    }

    private static func extrudedDistrictShape(path: UIBezierPath, heightMeters: Float, material: SCNMaterial) -> SCNShape {
        let shape = SCNShape(path: path, extrusionDepth: CGFloat(heightMeters))
        shape.materials = [material]
        return shape
    }

    private static func districtBoundingBox(of polygon: [LocalPoint]) -> (minX: Float, maxX: Float, minZ: Float, maxZ: Float) {
        let xs = polygon.map(\.x)
        let zs = polygon.map(\.z)
        return (xs.min() ?? 0, xs.max() ?? 1, zs.min() ?? 0, zs.max() ?? 1)
    }

    private static func districtRoadWidth(for kind: String?) -> Float {
        switch kind {
        case "secondary", "tertiary": 6
        case "residential", "living_street", "service": 4
        case "busway": 7
        default: 2.5 // pedestrian, footway, path
        }
    }

    private static func districtRoadColor(for kind: String?) -> UIColor {
        switch kind {
        case "pedestrian", "footway", "path", "living_street":
            UIColor(white: 0.55, alpha: 1) // paved/cobblestone plaza tone, not asphalt
        default:
            UIColor(white: 0.22, alpha: 1) // asphalt
        }
    }

    /// Recovers the `BuildingStyle` encoded into a district building node's name by
    /// `makeDistrictBuildingNode` — see that function's doc comment for why KVC isn't used instead.
    static func styleEncodedInDistrictBuildingName(_ name: String) -> BuildingStyle? {
        guard name.hasPrefix("building:"), let token = name.split(separator: ":").last else { return nil }
        return BuildingStyle(rawValue: String(token))
    }
}
