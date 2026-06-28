import ARKit
import SceneKit
import SwiftUI

/// Thin UIViewRepresentable bridge to ARKit + SceneKit. Tapping a detected horizontal surface
/// places a compressed-scale (~0.9m across) model of the selected district — built from the exact
/// same `District`/`SharedCityGeometry` data and node code as the orbit and ground-level views —
/// right there, like a tabletop architectural model, with its `focusBuildingName` marked by a
/// glowing beacon. This is real, runnable ARKit code, but world tracking needs a camera, so it
/// only actually does anything on a physical device; the Simulator has no camera to track against
/// (see `ARViewModel.isARSupported`, checked before this is shown — `SimulatedARSceneView` is the
/// Simulator-only, full-scale, free-standing stand-in).
struct ARSceneView: UIViewRepresentable {
    var location: ARLocation
    @Binding var placedCount: Int

    /// Real-world footprint of the placed miniature, in meters — small enough to read as "a model
    /// on a table", large enough that individual buildings and the focus beacon stay legible.
    private static let tabletopExtentMeters: Float = 0.9

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.autoenablesDefaultLighting = true
        view.automaticallyUpdatesLighting = true

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        view.session.run(configuration)

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
        context.coordinator.arView = view
        context.coordinator.location = location

        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.location = location
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(placedCount: $placedCount)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject {
        @Binding var placedCount: Int
        var location: ARLocation = .kotaTua
        weak var arView: ARSCNView?
        private var placedNode: SCNNode?

        init(placedCount: Binding<Int>) {
            self._placedCount = placedCount
        }

        /// Re-tapping moves the model instead of stacking another copy — one tabletop placement
        /// at a time reads far better in a demo than overlapping miniatures.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView,
                  let query = arView.raycastQuery(from: gesture.location(in: arView), allowing: .estimatedPlane, alignment: .horizontal),
                  let result = arView.session.raycast(query).first else {
                return
            }

            guard let district = District.load(named: location.jsonResourceName) else {
                assertionFailure("District '\(location.jsonResourceName)' could not be loaded — check it's bundled under MetaCity/Resources/Districts/")
                return
            }

            placedNode?.removeFromParentNode()
            let node = ARSceneView.makeTabletopDistrictNode(from: district, focusBuildingName: location.focusBuildingName)
            node.simdTransform = result.worldTransform
            arView.scene.rootNode.addChildNode(node)
            placedNode = node
            placedCount = 1
        }
    }

    // MARK: - Tabletop model construction

    private static func makeTabletopDistrictNode(from district: District, focusBuildingName: String) -> SCNNode {
        let root = SCNNode()
        let scale = tabletopExtentMeters / max(district.extent, 1)
        root.scale = SCNVector3(scale, scale, scale)
        // Re-center so the district's own centroid (not its arithmetic bounding-box corner) sits
        // at the tapped point — otherwise larger districts could place most of their content well
        // away from where the user actually tapped.
        root.pivot = SCNMatrix4MakeTranslation(district.center.x, 0, district.center.z)

        let baseSize = CGFloat(district.extent) * 1.08
        let base = SCNBox(width: baseSize, height: 0.4, length: baseSize, chamferRadius: 0.4)
        let baseMaterial = SCNMaterial()
        baseMaterial.diffuse.contents = UIColor(white: 0.08, alpha: 1)
        baseMaterial.roughness.contents = 0.9
        base.materials = [baseMaterial]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(district.center.x, -0.22, district.center.z)
        root.addChildNode(baseNode)

        for zone in district.greenZones {
            if let node = SharedCityGeometry.makeDistrictGreenZoneNode(zone) { root.addChildNode(node) }
        }
        for road in district.roads {
            SharedCityGeometry.makeDistrictRoadNodes(road).forEach(root.addChildNode)
        }
        // Tabletop scale is always viewed close-up, so every building stays at full detail — a
        // LOD threshold tuned for hundreds of real-world meters would never fire once the whole
        // model is compressed to under a meter.
        for building in district.buildings {
            if let node = SharedCityGeometry.makeDistrictBuildingNode(building, lodSwitchDistance: .greatestFiniteMagnitude) {
                root.addChildNode(node)
            }
        }

        if let focusBuilding = district.buildings.first(where: { $0.name == focusBuildingName }) {
            root.addChildNode(makeFocusBeacon(for: focusBuilding, districtExtent: district.extent))
        }

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        root.addChildNode(ambient)

        // Flattening batches draw calls across nodes that share render state (e.g. every
        // `modernGlass` building, every road of the same `highway` kind — see
        // `SharedCityGeometry`'s per-kind material caches) — the single biggest lever for keeping
        // a full-detail, ~350-430-building district smooth while it's composited live over the
        // camera feed at 60fps. Lights/actions on the beacon are left alone; SceneKit only folds
        // in nodes it can safely merge.
        return root.flattenedClone()
    }

    private static func makeFocusBeacon(for building: BuildingFootprint, districtExtent: Float) -> SCNNode {
        let xs = building.polygon.map(\.x)
        let zs = building.polygon.map(\.z)
        let centroidX = xs.reduce(0, +) / Float(xs.count)
        let centroidZ = zs.reduce(0, +) / Float(zs.count)

        let beaconHeight = max(building.heightMeters * 0.6, districtExtent * 0.03)
        let beacon = SCNCylinder(radius: CGFloat(districtExtent) * 0.004, height: CGFloat(beaconHeight))
        let beaconMaterial = SCNMaterial()
        beaconMaterial.diffuse.contents = UIColor.white
        beaconMaterial.emission.contents = UIColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1)
        beaconMaterial.emission.intensity = 3
        beacon.materials = [beaconMaterial]

        let node = SCNNode(geometry: beacon)
        node.position = SCNVector3(centroidX, building.heightMeters + beaconHeight / 2 + districtExtent * 0.015, centroidZ)
        node.runAction(.repeatForever(.sequence([
            .fadeOpacity(to: 0.3, duration: 1.1),
            .fadeOpacity(to: 1.0, duration: 1.1)
        ])))
        return node
    }
}
