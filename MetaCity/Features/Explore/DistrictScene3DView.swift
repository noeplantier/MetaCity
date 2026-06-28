import SceneKit
import SwiftUI
import UIKit

/// Renders a real, OpenStreetMap-derived Jakarta district (see `District`, populated by
/// `tools/fetch_district_data.py`) by extruding *actual building footprint polygons* — not boxes —
/// plus real road centerlines and green spaces, all at true 1:1 meters. This is MetaCity's only 3D
/// rendering path as of the 2026-06-28 Jakarta-only scope cut — the old per-city artistic skyline
/// (`CityScene3DView`/`RealBuilding`) was removed. The node-building logic lives in
/// `SharedCityGeometry` so `SimulatedARSceneView`'s ground-level mode and `ARSceneView`'s tabletop
/// AR mode render from the exact same code — see CLAUDE.md.
struct DistrictScene3DView: UIViewRepresentable {
    let districtName: String
    var isNightMode: Bool
    var isAutoRotating: Bool
    var rotationSpeed: Double

    /// LOD switch distance as a fraction of the district's real extent — districts range from
    /// Kemang's ~400m strip to Ancol's ~1200m amusement park, so a fixed meter distance tuned for
    /// one district would switch far too early or late on the others.
    private static let lodSwitchFraction: CGFloat = 0.09

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene: SCNScene
        if let district = District.load(named: districtName) {
            context.coordinator.districtExtent = district.extent
            scene = Self.makeScene(from: district)
        } else {
            // Fail visibly rather than silently rendering nothing if a bundled district JSON is
            // ever missing/renamed — this should never happen for a shipped district.
            scene = SCNScene()
            assertionFailure("District '\(districtName)' could not be loaded — check it's bundled under MetaCity/Resources/Districts/")
        }
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "districtCamera", recursively: true)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        Self.applyAtmosphere(isNight: isNightMode, extent: context.coordinator.districtExtent, to: scene)
        return view
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        guard let scene = scnView.scene else { return }
        if let spin = scene.rootNode.childNode(withName: "districtSpin", recursively: true) {
            spin.removeAction(forKey: "spin")
            if isAutoRotating {
                let action = SCNAction.rotateBy(x: 0, y: CGFloat(rotationSpeed), z: 0, duration: 1)
                spin.runAction(.repeatForever(action), forKey: "spin")
            }
        }
        Self.applyAtmosphere(isNight: isNightMode, extent: context.coordinator.districtExtent, to: scene)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Real meters — the longer side of the loaded district's bounding box. Drives camera
        /// distance, LOD switch distance, and fog falloff so every district frames itself
        /// reasonably without per-district tuning. Default matches Kota Tua's scale, the
        /// district this view's framing was originally tuned and verified against.
        var districtExtent: Float = 800
    }

    // MARK: - Scene construction

    private static func makeScene(from district: District) -> SCNScene {
        let scene = SCNScene()
        let spin = SCNNode()
        spin.name = "districtSpin"
        scene.rootNode.addChildNode(spin)

        spin.addChildNode(makeGround())
        for zone in district.greenZones {
            if let node = SharedCityGeometry.makeDistrictGreenZoneNode(zone) { spin.addChildNode(node) }
        }
        for road in district.roads {
            SharedCityGeometry.makeDistrictRoadNodes(road).forEach(spin.addChildNode)
        }
        let lodSwitchDistance = CGFloat(district.extent) * lodSwitchFraction
        for building in district.buildings {
            if let node = SharedCityGeometry.makeDistrictBuildingNode(building, lodSwitchDistance: lodSwitchDistance) {
                spin.addChildNode(node)
            }
        }
        spin.addChildNode(makeAmbientParticles(extent: district.extent))

        // Camera framing scales off the district's own real extent — calibrated against Kota Tua
        // (extent ≈800m, distance 130m/height 95m looked right there) and applied as a ratio so
        // Ancol (≈1200m) pulls back further and Kemang (≈400m) moves in closer automatically.
        let center = district.center
        let distance = district.extent * 0.163
        let height = district.extent * 0.119
        let cameraStart = SCNVector3(center.x, height, center.z + distance)
        let lookAtTarget = SCNVector3(center.x, 0, center.z)

        let cameraNode = SCNNode()
        cameraNode.name = "districtCamera"
        let camera = SCNCamera()
        camera.wantsHDR = true
        camera.bloomIntensity = 0.3
        camera.bloomThreshold = 0.85
        camera.bloomBlurRadius = 7
        camera.zFar = Double(district.extent) * 1.6
        cameraNode.camera = camera
        cameraNode.position = cameraStart
        cameraNode.look(at: lookAtTarget)
        scene.rootNode.addChildNode(cameraNode)

        addLights(to: scene)
        return scene
    }

    private static func makeGround() -> SCNNode {
        let floor = SCNFloor()
        floor.reflectivity = 0.05
        floor.firstMaterial?.diffuse.contents = UIColor(white: 0.1, alpha: 1.0)
        floor.firstMaterial?.roughness.contents = 0.95
        let node = SCNNode(geometry: floor)
        node.name = "ground"
        return node
    }

    private static func makeAmbientParticles(extent: Float) -> SCNNode {
        let system = SCNParticleSystem()
        system.particleImage = SharedCityGeometry.glowParticleImage
        system.birthRate = 12
        system.particleLifeSpan = 8
        system.particleSize = 0.4
        system.particleSizeVariation = 0.15
        system.particleColor = .white
        system.emitterShape = SCNBox(width: CGFloat(extent) * 0.75, height: 1, length: CGFloat(extent) * 0.9, chamferRadius: 0)
        system.birthLocation = .volume
        system.particleVelocity = 1.5
        system.particleVelocityVariation = 0.5
        system.acceleration = SCNVector3(0, 0.8, 0)
        system.blendMode = .additive
        system.isLightingEnabled = false

        let node = SCNNode()
        node.position = SCNVector3(0, 1, 0)
        node.addParticleSystem(system)
        return node
    }

    private static func addLights(to scene: SCNScene) {
        let key = SCNNode()
        key.name = "keyLight"
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.castsShadow = true
        key.position = SCNVector3(60, 90, 60)
        key.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.name = "ambientLight"
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        scene.rootNode.addChildNode(ambient)
    }

    private static func applyAtmosphere(isNight: Bool, extent: Float, to scene: SCNScene) {
        scene.fogColor = isNight ? UIColor.black : UIColor(red: 0.68, green: 0.76, blue: 0.85, alpha: 1)
        scene.fogStartDistance = CGFloat(extent) * 0.113
        scene.fogEndDistance = CGFloat(extent) * (isNight ? 0.35 : 0.426)

        if let key = scene.rootNode.childNode(withName: "keyLight", recursively: true)?.light {
            key.intensity = isNight ? 150 : 1000
            key.color = isNight
                ? UIColor(red: 0.55, green: 0.62, blue: 0.95, alpha: 1)
                : UIColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1)
        }
        if let ambient = scene.rootNode.childNode(withName: "ambientLight", recursively: true)?.light {
            ambient.intensity = isNight ? 100 : 450
            ambient.color = isNight ? UIColor(red: 0.3, green: 0.34, blue: 0.5, alpha: 1) : UIColor.white
        }

        scene.rootNode.enumerateChildNodes { node, _ in
            guard let name = node.name, let material = node.geometry?.firstMaterial,
                  let style = SharedCityGeometry.styleEncodedInDistrictBuildingName(name) else { return }
            material.emission.intensity = isNight ? SharedCityGeometry.nightEmissionIntensity(for: style) : 0
        }
    }
}
