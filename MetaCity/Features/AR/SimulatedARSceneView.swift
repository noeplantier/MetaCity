import SceneKit
import SwiftUI
import UIKit

/// `ARWorldTrackingConfiguration` fundamentally requires a camera, so real ARKit can never run in
/// the Simulator (see `ARViewModel.isARSupported`). This is the Simulator's stand-in: a plain
/// SceneKit (no ARKit) ground-level view of one of the 5 real, OpenStreetMap-derived Jakarta
/// districts (see `District`/`SharedCityGeometry`) — the exact same data and node-building code as
/// `DistrictScene3DView`'s orbit view, just from a pedestrian's eye height instead of an aerial
/// orbit. The camera starts deliberately looking at that district's `focusBuildingName` — "visiting"
/// a place means standing in front of its defining building, not floating above an arbitrary
/// coordinate. The user can look around by dragging and place markers by tapping, the same
/// interaction model as the real `ARSceneView`.
struct SimulatedARSceneView: UIViewRepresentable {
    var location: ARLocation
    @Binding var placedMarkerCount: Int

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = Self.makeScene(for: location)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "arCamera", recursively: true)
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true // pan to look around, two-finger pan to move
        view.defaultCameraController.interactionMode = .fly
        view.defaultCameraController.inertiaEnabled = true
        // See DistrictScene3DView for why this is deliberately not `rendersContinuously = true`.

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
        context.coordinator.scnView = view

        return view
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        guard context.coordinator.currentLocation != location else { return }
        context.coordinator.currentLocation = location
        let scene = Self.makeScene(for: location)
        scnView.scene = scene
        scnView.pointOfView = scene.rootNode.childNode(withName: "arCamera", recursively: true)
        placedMarkerCount = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(placedMarkerCount: $placedMarkerCount, currentLocation: location)
    }

    final class Coordinator: NSObject {
        @Binding var placedMarkerCount: Int
        var currentLocation: ARLocation
        weak var scnView: SCNView?

        init(placedMarkerCount: Binding<Int>, currentLocation: ARLocation) {
            self._placedMarkerCount = placedMarkerCount
            self.currentLocation = currentLocation
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let scnView else { return }
            let point = gesture.location(in: scnView)
            let results = scnView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let hit = results.first(where: { ($0.node.name ?? "").hasPrefix("street") || ($0.node.name ?? "").hasPrefix("building") }) else { return }

            let markerNode = SCNNode(geometry: SCNSphere(radius: 0.12))
            markerNode.geometry?.firstMaterial?.diffuse.contents = UIColor.systemBlue
            markerNode.geometry?.firstMaterial?.emission.contents = UIColor.systemBlue
            markerNode.position = hit.worldCoordinates
            scnView.scene?.rootNode.addChildNode(markerNode)
            placedMarkerCount += 1
        }
    }

    // MARK: - Scene construction

    private static let nightTint = UIColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 1)

    private static func makeScene(for location: ARLocation) -> SCNScene {
        guard let district = District.load(named: location.jsonResourceName) else {
            assertionFailure("District '\(location.jsonResourceName)' could not be loaded — check it's bundled under MetaCity/Resources/Districts/")
            return SCNScene()
        }
        return makeDistrictGroundScene(from: district, focusBuildingName: location.focusBuildingName)
    }

    /// Same building/road/green-zone construction as `DistrictScene3DView`, just with a
    /// pedestrian-height camera that starts looking at `focusBuildingName` instead of orbiting the
    /// whole district from above — "you are standing in front of Museum Sejarah Jakarta", not
    /// "looking down at Kota Tua in the abstract".
    private static func makeDistrictGroundScene(from district: District, focusBuildingName: String) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode

        let ground = SCNFloor()
        ground.reflectivity = 0.05
        ground.firstMaterial?.diffuse.contents = UIColor(white: 0.1, alpha: 1)
        ground.firstMaterial?.roughness.contents = 0.95
        let groundNode = SCNNode(geometry: ground)
        groundNode.name = "street"
        root.addChildNode(groundNode)

        for zone in district.greenZones {
            if let node = SharedCityGeometry.makeDistrictGreenZoneNode(zone) { root.addChildNode(node) }
        }
        for road in district.roads {
            SharedCityGeometry.makeDistrictRoadNodes(road).forEach(root.addChildNode)
        }
        // No LOD here: at pedestrian eye level the camera rarely sees far enough for the
        // simplification to matter — that's the orbit view's job. Distance scales with the
        // district's real extent so a never-reached LOD threshold doesn't silently do nothing on
        // a much bigger district than Kota Tua.
        let lodSwitchDistance = CGFloat(district.extent) * 0.3
        for building in district.buildings {
            if let node = SharedCityGeometry.makeDistrictBuildingNode(building, lodSwitchDistance: lodSwitchDistance) {
                root.addChildNode(node)
            }
        }
        root.addChildNode(makeAmbientParticles(
            extent: SCNVector3(district.extent * 0.1, 1, district.extent * 0.125),
            particleSize: 0.4,
            velocity: 1.5
        ))

        let focusBuilding = district.buildings.first { $0.name == focusBuildingName }
        if let focusBuilding {
            root.addChildNode(makeFocusHighlight(for: focusBuilding))
        }

        placeCamera(in: root, district: district, focusBuilding: focusBuilding)
        addLights(to: root, tint: nightTint, intensity: 240, ambientIntensity: 160)

        scene.fogColor = UIColor.black
        scene.fogStartDistance = CGFloat(district.extent) * 0.075
        scene.fogEndDistance = CGFloat(district.extent) * 0.28

        return scene
    }

    /// Stands the camera in front of `focusBuilding` — backed off proportionally to its own
    /// footprint and height (a 7m doll-house pavilion and a 224m tower need very different
    /// standoff distances to read well from eye level) — rather than the district's geometric
    /// anchor, so "visit Bundaran HI" actually means "look up at Menara BCA", not "stand at some
    /// arithmetic midpoint and hope the right building is in frame". Falls back to the old
    /// anchor-relative framing if a focus building is ever missing (should not happen for any
    /// shipped district — see `ARLocation.focusBuildingName`).
    private static func placeCamera(in root: SCNNode, district: District, focusBuilding: BuildingFootprint?) {
        let cameraNode = SCNNode()
        cameraNode.name = "arCamera"
        let camera = SCNCamera()
        camera.wantsHDR = true
        camera.bloomIntensity = 0.3
        camera.bloomThreshold = 0.85
        camera.bloomBlurRadius = 7
        camera.zFar = Double(district.extent) * 0.6
        cameraNode.camera = camera

        if let focusBuilding {
            let centroid = centroid(of: focusBuilding.polygon)
            let radius = footprintRadius(of: focusBuilding.polygon)
            let standoff = max(radius * 2.4, focusBuilding.heightMeters * 0.32, 16)
            let lookHeight = max(focusBuilding.heightMeters * 0.38, 1.3)
            cameraNode.position = SCNVector3(centroid.x, 1.7, centroid.z + standoff)
            cameraNode.look(at: SCNVector3(centroid.x, lookHeight, centroid.z))
        } else {
            let standoff = district.extent * 0.08
            cameraNode.position = SCNVector3(0, 1.6, -standoff)
            cameraNode.look(at: SCNVector3(0, 1.3, standoff))
        }

        root.addChildNode(cameraNode)
    }

    /// A pulsing light beacon plus a billboarded name label above the focus building — visible
    /// from across the district, so the user can orient toward it even before the camera settles.
    private static func makeFocusHighlight(for building: BuildingFootprint) -> SCNNode {
        let group = SCNNode()
        group.name = "focusHighlight"
        let centroid = centroid(of: building.polygon)
        let beaconHeight: Float = 14

        let beacon = SCNCylinder(radius: 0.18, height: CGFloat(beaconHeight))
        let beaconMaterial = SCNMaterial()
        beaconMaterial.diffuse.contents = UIColor.white
        beaconMaterial.emission.contents = UIColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1)
        beaconMaterial.emission.intensity = 2.5
        beaconMaterial.isDoubleSided = true
        beacon.materials = [beaconMaterial]
        let beaconNode = SCNNode(geometry: beacon)
        beaconNode.position = SCNVector3(centroid.x, building.heightMeters + beaconHeight / 2 + 1, centroid.z)
        beaconNode.runAction(.repeatForever(.sequence([
            .fadeOpacity(to: 0.35, duration: 1.1),
            .fadeOpacity(to: 1.0, duration: 1.1)
        ])))
        group.addChildNode(beaconNode)

        let text = SCNText(string: building.name ?? "Focus", extrusionDepth: 0.3)
        text.font = UIFont.systemFont(ofSize: 6, weight: .semibold)
        text.flatness = 0.2
        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = UIColor.white
        textMaterial.emission.contents = UIColor.white
        text.materials = [textMaterial]
        let textNode = SCNNode(geometry: text)
        textNode.scale = SCNVector3(0.5, 0.5, 0.5)
        textNode.position = SCNVector3(centroid.x, building.heightMeters + beaconHeight + 2, centroid.z)
        textNode.constraints = [SCNBillboardConstraint()]
        group.addChildNode(textNode)

        return group
    }

    private static func centroid(of polygon: [LocalPoint]) -> LocalPoint {
        let count = Float(polygon.count)
        return LocalPoint(x: polygon.map(\.x).reduce(0, +) / count, z: polygon.map(\.z).reduce(0, +) / count)
    }

    private static func footprintRadius(of polygon: [LocalPoint]) -> Float {
        let xs = polygon.map(\.x)
        let zs = polygon.map(\.z)
        return max((xs.max() ?? 0) - (xs.min() ?? 0), (zs.max() ?? 0) - (zs.min() ?? 0)) / 2
    }

    private static func addLights(to root: SCNNode, tint: UIColor, intensity: CGFloat, ambientIntensity: CGFloat) {
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = intensity
        key.light?.color = tint
        key.position = SCNVector3(3, 5, 4)
        key.look(at: SCNVector3Zero)
        root.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = ambientIntensity
        ambient.light?.color = tint
        root.addChildNode(ambient)
    }

    private static func makeAmbientParticles(extent: SCNVector3, particleSize: CGFloat, velocity: CGFloat) -> SCNNode {
        let system = SCNParticleSystem()
        system.particleImage = SharedCityGeometry.glowParticleImage
        system.birthRate = 14
        system.particleLifeSpan = 7
        system.particleSize = particleSize
        system.particleSizeVariation = particleSize * 0.5
        system.particleColor = .white
        system.emitterShape = SCNBox(width: CGFloat(extent.x), height: CGFloat(extent.y), length: CGFloat(extent.z), chamferRadius: 0)
        system.birthLocation = .volume
        system.particleVelocity = velocity
        system.particleVelocityVariation = velocity * 0.5
        system.acceleration = SCNVector3(0, 0.12, 0)
        system.blendMode = .additive
        system.isLightingEnabled = false

        let node = SCNNode()
        node.position = SCNVector3(0, 0.2, 0)
        node.addParticleSystem(system)
        return node
    }
}
