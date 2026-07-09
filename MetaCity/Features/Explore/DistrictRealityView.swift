import Combine
import RealityKit
import SwiftUI

/// Orbit inspector for a real Jakarta district, rendered by RealityKit (`ARView` in `.nonAR`
/// mode — a virtual camera, no real-world tracking). Geometry is built at runtime from the bundled
/// district JSON via `MeshDescriptor` in `DistrictRealityKit` — real OSM building footprints,
/// roads, and green zones — then styled with PBR materials and cached per `(district, isNight)`.
///
/// **Camera control**: Single-finger pan orbits azimuth and elevation; pinch zooms in/out;
/// pinching past 5× district extent triggers the map-back transition (`onZoomBack`); double-tap
/// resets to the default framed position. Auto-rotation is available but defaults off.
struct DistrictRealityView: UIViewRepresentable {
    let districtName: String
    let mood: DistrictRealityScene.Mood
    var isAutoRotating: Bool
    var rotationSpeed: Double
    /// Bumped by the parent to fly the camera back to the default orbit position.
    var cameraResetToken: Int = 0
    /// Bumped by `DiscoverViewModel.startBuildingOrbit()`. Signals the coordinator to begin a
    /// persistent 360° orbit around the currently inspected building's centroid.
    var buildingOrbitToken: Int = 0
    /// Called when the user pinches out past the map-transition threshold.
    var onZoomBack: (() -> Void)? = nil
    /// Called on each successful building tap with the selected `BuildingFootprint`.
    var onBuildingSelected: ((BuildingFootprint) -> Void)? = nil
    /// Called when the user taps a POI beacon sphere. Argument is the POI id string
    /// (the `"poi:<id>"` entity name with the prefix stripped).
    var onPOISelected: ((String) -> Void)? = nil
    /// POI id to fly the camera to. Non-nil → compute approach position from the POI's
    /// lat/lon + approachBearing and call flyCamera. Nil → return to default orbit.
    var venueTargetPOIId: String? = nil
    /// Incremented by `DiscoverViewModel.selectSearchResult(_:)`. The coordinator detects the
    /// token change in `update(...)` and flies to `searchFlyCentroid`.
    var searchFlyToken: Int = 0
    /// Model-local camera target (metres from district anchor) for the most-recent search selection.
    var searchFlyCentroid: SIMD3<Float> = .zero

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        // Set the ARView background to the mood's horizon color instead of clear/grey.
        // When the sky dome sphere doesn't cover every pixel at large extents (e.g. Canggu 3km),
        // the default neutral grey of ARView shows through at the edges. Using the horizon color
        // ensures any uncovered gap blends seamlessly with the dome's horizon band.
        arView.environment.background = .color(mood.skyColors.horizon)
        arView.backgroundColor = mood.skyColors.horizon
        arView.isOpaque = true

        context.coordinator.onZoomBack = onZoomBack
        context.coordinator.onBuildingSelected = onBuildingSelected
        context.coordinator.onPOISelected = onPOISelected
        context.coordinator.setUp(
            in: arView,
            districtName: districtName,
            mood: mood,
            isAutoRotating: isAutoRotating,
            rotationSpeed: rotationSpeed
        )

        // Single-finger pan → orbit azimuth + elevation
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        arView.addGestureRecognizer(pan)

        // Pinch → zoom; past max → map transition
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        arView.addGestureRecognizer(pinch)

        // Double-tap → reset camera
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        arView.addGestureRecognizer(doubleTap)

        // Single-tap → building selection (requires double-tap to fail first, adding ~0.35s delay
        // only when buildings mode is active — acceptable latency for a pick gesture).
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        arView.addGestureRecognizer(singleTap)

        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.onZoomBack = onZoomBack
        context.coordinator.onBuildingSelected = onBuildingSelected
        context.coordinator.onPOISelected = onPOISelected
        context.coordinator.update(
            isAutoRotating: isAutoRotating,
            rotationSpeed: rotationSpeed,
            venueTargetPOIId: venueTargetPOIId,
            resetToken: cameraResetToken,
            buildingOrbitToken: buildingOrbitToken,
            searchFlyToken: searchFlyToken,
            searchFlyCentroid: searchFlyCentroid
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// References to a single quadrant's LOD containers, plus the quadrant's spatial center in
    /// model-local space. Used by the coordinator to toggle near/far tier visibility.
    private struct QuadrantLODNode {
        let near: Entity
        let far: Entity
        let center: SIMD3<Float>   // XZ center in model-local space (≈ world space: anchor at origin)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var arView: ARView?
        private var orbitSubscription: Cancellable?
        private var flySubscription: Cancellable?
        private var cinematicSubscription: Cancellable?
        private var lodSubscription: Cancellable?   // per-frame LOD check, runs only in venue mode
        private var selectionRingSubscription: Cancellable?
        private var cameraEntity: Entity?

        /// Populated after each `loadModel` completes. Empty until the entity tree is placed.
        private var quadrantLOD: [QuadrantLODNode] = []
        private var districtAnchor: AnchorEntity?
        private var districtName = ""
        private var mood: DistrictRealityScene.Mood = .parkDaylight

        // Camera geometry — fixed after setUp, used by gestures for clamping
        private var center: SIMD3<Float> = .zero
        private var distance: Float = 100      // default orbit radius
        private var height: Float = 50         // default orbit height
        private var districtExtent: Float = 200
        // Saved district-wide defaults so building-overview mode can restore them on reset
        private var districtCenter: SIMD3<Float> = .zero
        private var districtDistance: Float = 100

        // Live gesture state — mutated by pan/pinch
        private var azimuth: Float = 0
        private var currentElevation: Float = 50
        private var currentDistance: Float = 100

        private var currentIsAutoRotating = false
        private var currentVenueTargetPOIId: String? = nil
        private var rotationSpeed: Double = 1.0
        private var loadGeneration = 0
        private var lastResetToken: Int = 0
        private var lastSearchFlyToken: Int = 0
        private var lastBuildingOrbitToken: Int = 0
        // Updated on each building tap — used by buildingOrbitToken to restart the orbit
        // around the selected building's centroid rather than the district centre.
        private var inspectedBuildingCentroid: SIMD3<Float>? = nil
        private var inspectedOrbitDist: Float = 0
        private var inspectedOrbitH: Float = 0
        /// Cached after first load — `handleSingleTap` looks up building centroids on every tap,
        /// so we avoid re-fetching from the `District` cache on the gesture hot path.
        private var cachedDistrict: District?

        var onZoomBack: (() -> Void)? = nil
        var onBuildingSelected: ((BuildingFootprint) -> Void)? = nil
        var onPOISelected: ((String) -> Void)? = nil

        func setUp(in arView: ARView, districtName: String, mood: DistrictRealityScene.Mood,
                   isAutoRotating: Bool, rotationSpeed: Double) {
            self.arView = arView
            self.districtName = districtName
            self.mood = mood
            self.currentIsAutoRotating = isAutoRotating
            self.rotationSpeed = rotationSpeed

            guard let district = District.load(named: districtName) else {
                assertionFailure("District '\(districtName)' could not be loaded — check it's bundled under MetaCity/Resources/Districts/")
                return
            }
            cachedDistrict = district

            let anchor = AnchorEntity(world: .zero)
            arView.scene.addAnchor(anchor)
            districtAnchor = anchor

            // Night mode removed — always day. isNight: false throughout.
            DistrictRealityScene.installLighting(in: arView, anchor: anchor, mood: mood,
                                                  extent: district.extent, isNight: false)

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = mood.fieldOfViewDegrees
            camera.camera.far = district.extent * 6
            anchor.addChild(camera)
            cameraEntity = camera

            let lookY: Float = district.extent * 0.03
            center = SIMD3(district.buildingCentroid.x, lookY, district.buildingCentroid.z)
            // Start wider than the mood default so the user opens to a full district overview.
            // Continuous pinch replaces the old binary isElevated split.
            distance = district.extent * mood.cameraDistanceFraction * 1.5
            height   = district.extent * mood.cameraHeightFraction   * 1.4
            districtExtent = district.extent
            districtCenter = center
            districtDistance = distance

            // Initialise gesture state to match the starting camera position (azimuth = 0
            // places the camera at center + (0, height, +distance) which is what setUp uses).
            azimuth = 0
            currentElevation = height
            currentDistance = distance

            camera.look(at: center, from: SIMD3(center.x, height, center.z + distance), relativeTo: nil)

            loadModel(named: districtName, into: anchor)
            restartOrbit(isAutoRotating: isAutoRotating)
            startCinematicEntry(camera: camera, scene: arView.scene)
        }

        func update(isAutoRotating: Bool, rotationSpeed: Double,
                    venueTargetPOIId: String?, resetToken: Int, buildingOrbitToken: Int,
                    searchFlyToken: Int, searchFlyCentroid: SIMD3<Float>) {
            guard let arView else { return }

            self.rotationSpeed = rotationSpeed

            if isAutoRotating != currentIsAutoRotating {
                currentIsAutoRotating = isAutoRotating
                if venueTargetPOIId == nil { restartOrbit(isAutoRotating: isAutoRotating) }
            }

            if venueTargetPOIId != currentVenueTargetPOIId {
                currentVenueTargetPOIId = venueTargetPOIId
                if let poiId = venueTargetPOIId {
                    flyToVenue(poiId: poiId, districtName: districtName, scene: arView.scene)
                    startVenueLOD(scene: arView.scene)
                } else {
                    flySubscription?.cancel()
                    flySubscription = nil
                    if let anchor = districtAnchor {
                        DistrictRealityKit.restoreGroundColor(in: anchor, mood: mood)
                    }
                    applyOrbitLOD()
                    restartOrbit(isAutoRotating: isAutoRotating)
                }
            }

            if resetToken != lastResetToken {
                lastResetToken = resetToken
                inspectedBuildingCentroid = nil   // reset clears building-focus state
                resetToDefaultPosition()
            }

            if buildingOrbitToken != lastBuildingOrbitToken {
                lastBuildingOrbitToken = buildingOrbitToken
                if let bc = inspectedBuildingCentroid {
                    startBuildingOrbit360(center: bc, orbDist: inspectedOrbitDist,
                                          orbH: inspectedOrbitH, scene: arView.scene)
                }
            }

            if searchFlyToken != lastSearchFlyToken {
                lastSearchFlyToken = searchFlyToken
                orbitSubscription?.cancel()
                orbitSubscription = nil
                cinematicSubscription?.cancel()
                cinematicSubscription = nil
                let eyePos = SIMD3<Float>(
                    searchFlyCentroid.x,
                    searchFlyCentroid.y + 20,
                    searchFlyCentroid.z + Float(districtExtent) * 0.12
                )
                flyCamera(to: eyePos, lookAt: searchFlyCentroid, scene: arView.scene)
            }
        }

        /// Computes approach camera position from the POI's lat/lon + approachBearing and flies there.
        private func flyToVenue(poiId: String, districtName: String, scene: RealityKit.Scene) {
            guard let collection = CangguPOICollection.load(for: districtName),
                  let poi = collection.pois.first(where: { $0.id == poiId }),
                  let districtEntry = CityManifest.shared.district(id: districtName)
            else { return }

            let geoAnchor = districtEntry.anchor
            let offset = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                .sceneOffset(from: geoAnchor)

            let bearingRad = Float((poi.approachBearing ?? 180) * .pi / 180)
            let approachDist = poi.approachDistance ?? 40
            let camX = offset.x + sin(bearingRad) * approachDist
            let camZ = offset.z + cos(bearingRad) * approachDist
            let camPos = SIMD3<Float>(camX, 8, camZ)
            let lookAt = SIMD3<Float>(offset.x, 5, offset.z)

            orbitSubscription?.cancel()
            orbitSubscription = nil
            if let anchor = districtAnchor {
                DistrictRealityKit.updateGroundColor(in: anchor, for: poi.category, mood: mood)
            }
            flyCamera(to: camPos, lookAt: lookAt, scene: scene)
        }

        // MARK: - Gesture handlers

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let arView else { return }

            // Pause auto-orbit when the user starts dragging so there's no jitter from
            // two systems writing camera position simultaneously. Resume on lift.
            if gesture.state == .began {
                orbitSubscription?.cancel()
                orbitSubscription = nil
            }

            let delta = gesture.translation(in: arView)
            gesture.setTranslation(.zero, in: arView)

            azimuth += Float(delta.x) * 0.005
            // Allow descending to near-ground-level (2 m floor) so the user can look at
            // building walls and window grids, not just rooftops, at close zoom.
            let minElev = max(2.0, height * 0.02)
            let maxElev = height * 2.5
            // Scale elevation sensitivity proportionally to distance so close-up dragging
            // is precise and wide-orbit dragging isn't too sluggish.
            let distRatio = currentDistance / max(districtExtent, 1)
            let elevStep = Float(delta.y) * 0.004 * max(distRatio, 0.2)
            currentElevation = min(max(currentElevation + elevStep, minElev), maxElev)

            updateCameraPosition()

            if gesture.state == .ended || gesture.state == .cancelled {
                if currentIsAutoRotating {
                    // Resume orbit from the current manually-set position.
                    let orbitCenter = inspectedBuildingCentroid ?? center
                    startBuildingOrbit360(center: orbitCenter,
                                          orbDist: currentDistance,
                                          orbH: currentElevation,
                                          scene: arView.scene)
                }
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            let scale = Float(gesture.scale)
            gesture.scale = 1.0
            guard scale > 0 else { return }

            // Allow zooming in to ~1% of extent (floor 6 m) so window grids, hip roofs,
            // and palm fronds are visually resolvable at close range.
            let minDist = max(6.0, districtExtent * 0.010)
            let maxDist = districtExtent * 5.0
            currentDistance = min(max(currentDistance / scale, minDist), maxDist)

            updateCameraPosition()

            // At 98% of maximum zoom-out, fire the map transition callback.
            if currentDistance >= maxDist * 0.98 {
                onZoomBack?()
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            resetToDefaultPosition()
        }

        /// Single-tap handler. Priority order:
        /// 1. POI beacon hit (works in any camera mode) — exact entity hit-test.
        /// 2. Building selection (only in buildings mode) — geometric ray-cast.
        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView else { return }
            let loc = gesture.location(in: arView)

            // POI beacon tap — traverse hit entity and its ancestors for a "poi:" name.
            if let hit = arView.entity(at: loc) {
                var cursor: Entity? = hit
                while let e = cursor {
                    if e.name.hasPrefix("poi:") {
                        onPOISelected?(String(e.name.dropFirst(4)))
                        return
                    }
                    cursor = e.parent
                }
            }

            guard let district = cachedDistrict, !district.buildings.isEmpty else { return }

            guard let ray = arView.ray(through: loc) else { return }

            let origin = ray.origin
            let dir    = normalize(ray.direction)

            func distToRay(_ p: SIMD3<Float>) -> Float {
                let v  = p - origin
                let t  = dot(v, dir)
                guard t > 0 else { return .greatestFiniteMagnitude }
                return length(p - (origin + dir * t))
            }

            // Find closest building centroid to the tap ray, but only commit the selection
            // if the ray actually passes within a plausible screen-radius of the building.
            // Without this guard, `min` always returns something — even a tap on empty sky
            // selects the most centrally-placed building, which is the primary source of
            // phantom BuildingInfoCard pop-ups and erratic camera flies.
            var minDist: Float = .greatestFiniteMagnitude
            var bestBuilding: BuildingFootprint? = nil
            for b in district.buildings where !b.polygon.isEmpty {
                let n = Float(b.polygon.count)
                let bc = SIMD3(b.polygon.map(\.x).reduce(0,+)/n,
                               b.heightMeters * 0.5,
                               b.polygon.map(\.z).reduce(0,+)/n)
                let d = distToRay(bc)
                if d < minDist { minDist = d; bestBuilding = b }
            }
            // Threshold: tap ray must pass within 10% of district extent from the centroid.
            // Scales naturally: 50m for 500m Jakarta, 300m for 3km Canggu.
            guard let building = bestBuilding, minDist < districtExtent * 0.10 else { return }

            onBuildingSelected?(building)

            let n       = Float(building.polygon.count)
            let cx      = building.polygon.map(\.x).reduce(0,+) / n
            let cz      = building.polygon.map(\.z).reduce(0,+) / n
            let midH    = building.heightMeters * 0.5
            let eyeDist = max(building.heightMeters * 2.2, districtExtent * 0.08)
            let orbitH  = midH + building.heightMeters * 0.2

            // Record the inspected building so buildingOrbitToken and post-pan resume both
            // orbit around the selected building, not the district centre.
            inspectedBuildingCentroid = SIMD3(cx, center.y, cz)
            inspectedOrbitDist = eyeDist
            inspectedOrbitH    = orbitH

            // Holographic amber scanner rings — two counter-rotating arc-segment rings + halo.
            selectionRingSubscription?.cancel()
            selectionRingSubscription = nil
            let ringCX = cx, ringCZ = cz
            Task { @MainActor [weak self] in
                guard let self, let anchor = self.districtAnchor else { return }
                DistrictRealityKit.clearSelectionRing(in: anchor)
                let ringRadius = building.polygon.map { p -> Float in
                    sqrt((p.x - ringCX) * (p.x - ringCX) + (p.z - ringCZ) * (p.z - ringCZ))
                }.max() ?? 5.0
                guard let scanner = DistrictRealityKit.makeHoloScanner(
                    centroid: SIMD3(ringCX, 0, ringCZ),
                    radius: max(ringRadius, 3.0)
                ) else { return }
                scanner.name = "selectionRing"
                anchor.addChild(scanner)
                let outerArcs = scanner.children.first(where: { $0.name == "outerArcs" })
                let innerArcs = scanner.children.first(where: { $0.name == "innerArcs" })
                var outerAngle: Float = 0
                var innerAngle: Float = 0
                var breathPhase: Float = 0
                guard let av = self.arView else { return }
                self.selectionRingSubscription = av.scene.subscribe(to: SceneEvents.Update.self) {
                    [weak scanner, weak outerArcs, weak innerArcs] _ in
                    guard let root = scanner else { return }
                    outerAngle  += 0.018                            // CW ~62°/s at 60fps
                    innerAngle  -= 0.013                            // CCW ~45°/s
                    outerArcs?.transform.rotation = simd_quatf(angle: outerAngle, axis: SIMD3(0, 1, 0))
                    innerArcs?.transform.rotation = simd_quatf(angle: innerAngle, axis: SIMD3(0, 1, 0))
                    breathPhase += 0.042                            // breathing period ~2.5 s
                    let s = 1.0 + 0.045 * sin(breathPhase)
                    root.scale = SIMD3(s, 1, s)
                }
            }

            // Shift orbit center to this building so subsequent pan gestures orbit around it.
            let lookY = center.y
            center = SIMD3(cx, lookY, cz)
            currentDistance = eyeDist

            // Approach from the current azimuth direction so the view preserves the user's
            // current vantage angle rather than always snapping to front-facing +Z.
            let approachX = cx + sin(azimuth) * eyeDist
            let approachZ = cz + cos(azimuth) * eyeDist
            flyCamera(
                to:     SIMD3(approachX, orbitH, approachZ),
                lookAt: SIMD3(cx, midH, cz),
                scene:  arView.scene
            )

            // If auto-rotate is on, start orbiting around the building after the fly lands.
            if currentIsAutoRotating {
                let bc = SIMD3<Float>(cx, center.y, cz)
                let d  = eyeDist
                let h  = orbitH
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_250_000_000)   // ~fly duration + margin
                    guard let self else { return }
                    self.startBuildingOrbit360(center: bc, orbDist: d, orbH: h, scene: arView.scene)
                }
            }
        }

        private func updateCameraPosition() {
            guard let camera = cameraEntity else { return }
            let x = center.x + sin(azimuth) * currentDistance
            let z = center.z + cos(azimuth) * currentDistance
            camera.position = SIMD3(x, currentElevation, z)
            camera.look(at: center, from: camera.position, relativeTo: nil)
        }

        private func resetToDefaultPosition() {
            // Restore district-wide orbit pivot (building overview shifts this to a building centroid)
            center = districtCenter
            currentDistance = districtDistance
            azimuth = 0
            currentElevation = height
            guard let arView else { return }
            flyCamera(to: SIMD3(center.x, height, center.z + districtDistance),
                      lookAt: center, scene: arView.scene)
        }

        // Pan and pinch can fire simultaneously — lets the user orbit while slowly zooming.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: - Model loading

        private func loadModel(named districtName: String, into anchor: AnchorEntity) {
            loadGeneration += 1
            let generation = loadGeneration
            Task { @MainActor [weak self] in
                guard let entity = try? await DistrictRealityKit.loadDistrictEntity(
                    named: districtName, isNight: false, mood: self?.mood ?? .parkDaylight)
                else { return }
                guard let self, self.loadGeneration == generation else { return }
                anchor.children.first(where: { $0.name == "districtModel" })?.removeFromParent()
                self.selectionRingSubscription?.cancel()
                self.selectionRingSubscription = nil
                DistrictRealityKit.clearSelectionRing(in: anchor)
                entity.name = "districtModel"
                anchor.addChild(entity)
                self.extractQuadrantLOD(from: entity)
                // Apply orbit or venue LOD now that quadrantLOD is populated.
                // `applyOrbitLOD()` at setUp time ran against an empty `quadrantLOD` array,
                // so it was a no-op — the palm entities were still enabled in the cached clone.
                // Calling here (after extractQuadrantLOD fills the array) is the first chance
                // to actually toggle palm visibility. Venue mode already has a per-frame
                // subscription that will correct on its next tick regardless.
                if self.currentVenueTargetPOIId == nil {
                    self.applyOrbitLOD()
                }
            }
        }

        /// Walks the placed entity tree to find the four quadrant containers and their near/far
        /// children. Quadrant centers are derived from `cachedDistrict` rather than from
        /// `entity.position` — the containers are at the origin (no position offset) so that
        /// MeshDescriptor vertices stay in model-local space without double-translation.
        private func extractQuadrantLOD(from root: Entity) {
            guard let district = cachedDistrict else { return }
            let cx = district.buildingCentroid.x, cz = district.buildingCentroid.z

            // Compute the AABB center of each quadrant's building set (matches the split logic
            // in DistrictRealityKit.splitIntoQuadrants: idx = (bx>=cx ? 1:0) | (bz>=cz ? 2:0)).
            var xMin: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]
            var xMax: [Float] = [-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
            var zMin: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]
            var zMax: [Float] = [-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
            for b in district.buildings {
                let n = Float(b.polygon.count); guard n > 0 else { continue }
                let bx = b.polygon.map(\.x).reduce(0, +) / n
                let bz = b.polygon.map(\.z).reduce(0, +) / n
                let idx = (bx >= cx ? 1 : 0) | (bz >= cz ? 2 : 0)
                for p in b.polygon {
                    xMin[idx] = min(xMin[idx], p.x); xMax[idx] = max(xMax[idx], p.x)
                    zMin[idx] = min(zMin[idx], p.z); zMax[idx] = max(zMax[idx], p.z)
                }
            }

            quadrantLOD = (0..<4).compactMap { i -> QuadrantLODNode? in
                guard let q = root.findEntity(named: "q\(i)") else { return nil }
                guard let near = q.children.first(where: { $0.name == "near" }),
                      let far  = q.children.first(where: { $0.name == "far"  }) else { return nil }
                let qCX = xMin[i] < xMax[i] ? (xMin[i] + xMax[i]) / 2 : cx
                let qCZ = zMin[i] < zMax[i] ? (zMin[i] + zMax[i]) / 2 : cz
                return QuadrantLODNode(near: near, far: far,
                                       center: SIMD3<Float>(qCX, 0, qCZ))
            }
        }

        /// Orbit mode: every quadrant at full quality, but palms hidden.
        ///
        /// Palm trunk geometry (4-sided prisms 0.17–0.28 m wide, 6.5–11.5 m tall) is sub-pixel at
        /// typical orbit camera distances yet still present in the near mesh batch → they appear as
        /// a forest of thin coloured spikes across the skyline. Hiding them in orbit mode costs
        /// nothing visually (sub-pixel = invisible) and eliminates the noise.  They reappear
        /// automatically when venue mode activates (camera drops to ~8m height / 40m forward).
        private func applyOrbitLOD() {
            lodSubscription?.cancel()
            lodSubscription = nil
            for node in quadrantLOD {
                node.near.isEnabled = true
                node.far.isEnabled  = false
                setPalmsEnabled(false, in: node.near)
            }
        }

        /// Venue mode: per-frame camera-proximity check. Quadrants within
        /// `districtExtent × 0.5` show full quality (palms included); farther ones use AABB boxes.
        private func startVenueLOD(scene: RealityKit.Scene) {
            lodSubscription?.cancel()
            let threshold = districtExtent * 0.5
            lodSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                guard let self, let cam = self.cameraEntity else { return }
                let camX = cam.position.x, camZ = cam.position.z
                for node in self.quadrantLOD {
                    let dx = camX - node.center.x, dz = camZ - node.center.z
                    let isNear = sqrt(dx * dx + dz * dz) <= threshold
                    let wasNear = node.near.isEnabled
                    node.near.isEnabled = isNear
                    node.far.isEnabled  = !isNear
                    // Sync palm visibility: show when near, hide when far.
                    if isNear != wasNear {
                        self.setPalmsEnabled(isNear, in: node.near)
                    }
                }
            }
        }

        /// Toggles palm trunk + canopy entities (`"palm_trunk_qN"` / `"palm_canopy_qN"`) within
        /// a quadrant's near container. All other near children (buildings, roofs, roads, ground)
        /// are unaffected.
        private func setPalmsEnabled(_ enabled: Bool, in nearContainer: Entity) {
            for child in nearContainer.children {
                if child.name.hasPrefix("palm_") {
                    child.isEnabled = enabled
                }
            }
        }

        // MARK: - Camera animation

        /// Starts a smooth 360° orbit around `center` at the given distance and height.
        /// Used by the building-select flow and the ORBIT 360° button via `buildingOrbitToken`.
        private func startBuildingOrbit360(center: SIMD3<Float>, orbDist: Float, orbH: Float,
                                            scene: RealityKit.Scene) {
            cinematicSubscription?.cancel()
            cinematicSubscription = nil
            orbitSubscription?.cancel()
            orbitSubscription = nil
            guard let cameraEntity else { return }
            orbitSubscription = DistrictRealityScene.startOrbit(
                camera: cameraEntity,
                scene: scene,
                center: center,
                distance: orbDist,
                height: orbH,
                rotationSpeed: { [weak self] in self?.rotationSpeed ?? 1.0 }
            )
        }

        private func restartOrbit(isAutoRotating: Bool) {
            cinematicSubscription?.cancel()
            cinematicSubscription = nil
            flySubscription?.cancel()
            flySubscription = nil
            orbitSubscription?.cancel()
            orbitSubscription = nil
            guard isAutoRotating, let arView, let cameraEntity else { return }
            orbitSubscription = DistrictRealityScene.startOrbit(
                camera: cameraEntity,
                scene: arView.scene,
                center: center,
                distance: distance,
                height: height,
                rotationSpeed: { [weak self] in self?.rotationSpeed ?? 1.0 }
            )
        }

        /// Crane-down establishing shot — starts at 2.5× distance overhead and descends
        /// smoothly to the default orbit position over 1.2s (cubic Hermite ease).
        private func startCinematicEntry(camera: Entity, scene: RealityKit.Scene) {
            let endPos   = SIMD3<Float>(center.x, height, center.z + distance)
            let startPos = SIMD3<Float>(center.x, height * 2.2, center.z + distance * 2.5)
            camera.position = startPos
            camera.look(at: center, from: startPos, relativeTo: nil)

            let duration: Float = 1.2
            var elapsed: Float  = 0
            var lastTime: TimeInterval = 0

            cinematicSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                guard let self else { return }
                if lastTime == 0 { lastTime = event.deltaTime; return }
                elapsed += Float(event.deltaTime)
                lastTime  = event.deltaTime
                let t = min(elapsed / duration, 1.0)
                let s = t * t * (3 - 2 * t)   // cubic Hermite smoothstep
                let pos = startPos + (endPos - startPos) * s
                camera.position = pos
                camera.look(at: self.center, from: pos, relativeTo: nil)
                if t >= 1.0 {
                    self.cinematicSubscription?.cancel()
                    self.cinematicSubscription = nil
                    // Sync gesture state so the first pan starts from the landed position.
                    self.azimuth = 0
                    self.currentElevation = self.height
                    self.currentDistance  = self.distance
                }
            }
        }

        /// Smoothly flies the camera from its current position to `target`, looking at `lookAt`,
        /// over 1.0s with a cubic-Hermite ease. Self-cancels when t ≥ 1.
        private func flyCamera(to target: SIMD3<Float>, lookAt: SIMD3<Float>, scene: RealityKit.Scene) {
            cinematicSubscription?.cancel()
            cinematicSubscription = nil
            guard let camera = cameraEntity else { return }
            let startPos = camera.position
            let duration: Float = 1.0
            var elapsed: Float  = 0
            var lastTime: TimeInterval = 0

            flySubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] (event: SceneEvents.Update) in
                guard let self else { return }
                if lastTime == 0 { lastTime = event.deltaTime; return }
                elapsed += Float(event.deltaTime)
                lastTime  = event.deltaTime

                let t = min(elapsed / duration, 1.0)
                let s = t * t * (3 - 2 * t)
                let pos = startPos + (target - startPos) * s
                camera.position = pos

                let forward = normalize(lookAt - pos)
                let right   = normalize(cross(SIMD3<Float>(0, 1, 0), forward))
                let up      = cross(forward, right)
                camera.orientation = simd_quatf(simd_float3x3(columns: (right, up, -forward)))

                if t >= 1.0 {
                    self.flySubscription?.cancel()
                    self.flySubscription = nil
                }
            }
        }
    }
}
