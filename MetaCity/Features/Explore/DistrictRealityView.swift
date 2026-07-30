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
    /// Called in HUMAN mode when the player taps a POI to trigger the in-world mini-game.
    var onPOIInteract: ((String) -> Void)? = nil
    /// POI id to fly the camera to. Non-nil → compute approach position from the POI's
    /// lat/lon + approachBearing and call flyCamera. Nil → return to default orbit.
    var venueTargetPOIId: String? = nil
    /// Incremented by `DiscoverViewModel.selectSearchResult(_:)`. The coordinator detects the
    /// token change in `update(...)` and flies to `searchFlyCentroid`.
    var searchFlyToken: Int = 0
    /// Model-local camera target (metres from district anchor) for the most-recent search selection.
    var searchFlyCentroid: SIMD3<Float> = .zero
        /// Bumped by `DiscoverViewModel.setViewPreset(.poi)`. Re-triggers `flyToVenue`
        /// for the POI stored from the last selection.
        var poiFocusToken: Int = 0
    /// The currently selected building — mirrored from DiscoverViewModel so the coordinator
    /// can access it when `viewFocusToken` fires without storing state across sessions.
    var selectedBuilding: BuildingFootprint? = nil
    /// Current camera preset — used by the coordinator to choose OVERVIEW / POI.
    var activeViewPreset: ViewPreset = .overview
    /// Day/night mode toggle. When changed, the coordinator discards and rebuilds the district
    /// entity with the appropriate emissive/roughness materials and lighting rig.
    var isNight: Bool = false

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        // Set the ARView background to the mood's horizon color instead of clear/grey.
        // When the sky dome sphere doesn't cover every pixel at large extents (e.g. Canggu 3km),
        // the default neutral grey of ARView shows through at the edges. Using the horizon color
        // ensures any uncovered gap blends seamlessly with the dome's horizon band.
        arView.environment.background = .color(mood.skyColors.horizon)
        arView.backgroundColor = mood.skyColors.horizon
        arView.isOpaque = true

        // ProMotion: RealityKit's internal CADisplayLink already targets the display's maximum
        // refresh rate (120fps on ProMotion hardware) — no explicit configuration required.
        // CALayer.preferredFrameRateRange does not exist (only CADisplayLink/CAAnimation have it);
        // ARView's own display link is private and handles this automatically.

        context.coordinator.onZoomBack = onZoomBack
        context.coordinator.onBuildingSelected = onBuildingSelected
        context.coordinator.onPOISelected = onPOISelected
        context.coordinator.onPOIInteract = onPOIInteract
        context.coordinator.setUp(
            in: arView,
            districtName: districtName,
            mood: mood,
            isAutoRotating: isAutoRotating,
            rotationSpeed: rotationSpeed,
            isNight: isNight,
            activeViewPreset: activeViewPreset
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
        context.coordinator.onPOIInteract = onPOIInteract
        context.coordinator.update(
            isAutoRotating: isAutoRotating,
            rotationSpeed: rotationSpeed,
            isNight: isNight,
            venueTargetPOIId: venueTargetPOIId,
            resetToken: cameraResetToken,
            buildingOrbitToken: buildingOrbitToken,
            searchFlyToken: searchFlyToken,
            searchFlyCentroid: searchFlyCentroid,
            poiFocusToken: poiFocusToken,
            selectedBuilding: selectedBuilding,
            activeViewPreset: activeViewPreset
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
        private var cameraEntity: Entity?

        /// Populated after each `loadModel` completes. Empty until the entity tree is placed.
        private var quadrantLOD: [QuadrantLODNode] = []
        /// Sub-pixel-at-orbit entities: _bands, _pilasters, _balconies.
        /// Hidden during orbit, revealed when camera moves within ~30% of districtExtent (building tap / venue).
        private var facadeDetailEntities: [Entity] = []
        /// Tracks whether facade detail is currently shown — avoids repeated `setFacadeDetailEnabled`
        /// calls on every pinch frame when the threshold hasn't been crossed.
        private var facadeDetailEnabled: Bool = false
        private var poiPulseSubscription: Cancellable?
        private var poiBeaconsEntity: Entity?
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
        private var currentViewPreset: ViewPreset = .overview
        private var currentVenueTargetPOIId: String? = nil
        private var rotationSpeed: Double = 1.0
        private var loadGeneration = 0
        private var lastResetToken: Int = 0
        private var lastSearchFlyToken: Int = 0
        private var lastBuildingOrbitToken: Int = 0
        private var lastViewFocusToken: Int = 0
        /// Stored from the last successful `flyToVenue` call so `.poi` preset
        /// can re-trigger the fly without needing another tap.
        private var lastFocusedPOIId: String?
        // Updated on each building tap — used by buildingOrbitToken to restart the orbit
        // around the selected building's centroid rather than the district centre.
        private var inspectedBuildingCentroid: SIMD3<Float>? = nil
        private var inspectedOrbitDist: Float = 0
        private var inspectedOrbitH: Float = 0
        /// Cached after first load — `handleSingleTap` looks up building centroids on every tap,
        /// so we avoid re-fetching from the `District` cache on the gesture hot path.
        private var cachedDistrict: District?

        private var currentIsNight: Bool = false

        // MARK: - HUMAN mode state (3rd-person)
        private var humanNearbySubscription: Cancellable?
        private var humanFollowSubscription: Cancellable?
        private var characterEntity: ModelEntity?
        private var humanCharacterPos: SIMD3<Float> = .zero
        private var humanCharacterAzimuth: Float = 0
        private var activeMiniGameEntities: [Entity] = []
        private var miniGameHits: Int = 0
        private var miniGameTotal: Int = 0
        private var activeMiniGamePOIId: String? = nil
        private var humanBoostEntity: Entity? = nil
        private var humanNearPOIId: String? = nil

        var onZoomBack: (() -> Void)? = nil
        var onBuildingSelected: ((BuildingFootprint) -> Void)? = nil
        var onPOISelected: ((String) -> Void)? = nil
        var onPOIInteract: ((String) -> Void)? = nil

        func setUp(in arView: ARView, districtName: String, mood: DistrictRealityScene.Mood,
                   isAutoRotating: Bool, rotationSpeed: Double, isNight: Bool = false,
                   activeViewPreset: ViewPreset = .overview) {
            self.arView = arView
            self.districtName = districtName
            self.mood = mood
            self.currentIsAutoRotating = isAutoRotating
            self.currentViewPreset = activeViewPreset
            self.currentIsNight = isNight
            self.rotationSpeed = rotationSpeed

            guard let district = District.load(named: districtName) else {
                assertionFailure("District '\(districtName)' could not be loaded — check it's bundled under MetaCity/Resources/Districts/")
                return
            }
            cachedDistrict = district

            let anchor = AnchorEntity(world: .zero)
            arView.scene.addAnchor(anchor)
            districtAnchor = anchor

            DistrictRealityScene.installLighting(in: arView, anchor: anchor, mood: mood,
                                                  extent: district.extent, isNight: currentIsNight)

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = mood.fieldOfViewDegrees
            camera.camera.far = district.extent * 6
            anchor.addChild(camera)
            cameraEntity = camera

            let lookY: Float = district.extent * 0.03
            center = SIMD3(district.buildingCentroid.x, lookY, district.buildingCentroid.z)
            districtExtent   = district.extent
            districtCenter   = center
            // Orbit reference: 1.5× the mood fraction — same as original, used by
            // resetToDefaultPosition multipliers. Do NOT reduce this without verifying
            // all moods: it is the anchor for OVERVIEW/CLOSE DISTRICT/POI multipliers.
            districtDistance = district.extent * mood.cameraDistanceFraction * 1.5

            // Initial camera position respects the active preset.
            switch currentViewPreset {
            case .overview:
                // OVERVIEW: bird's-eye ~61° elevation.
                distance = districtDistance * 0.60
                height   = distance * 1.10
            default:
                distance = districtDistance
                height   = district.extent * mood.cameraHeightFraction * 1.4
            }

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

        func update(isAutoRotating: Bool, rotationSpeed: Double, isNight: Bool = false,
                    venueTargetPOIId: String?, resetToken: Int, buildingOrbitToken: Int,
                    searchFlyToken: Int, searchFlyCentroid: SIMD3<Float>,
                    poiFocusToken: Int, selectedBuilding: BuildingFootprint?,
                    activeViewPreset: ViewPreset = .overview) {
            guard let arView else { return }
            // Always track the current selection so poiFocusToken has a POI to fly to
            if let poiId = venueTargetPOIId { lastFocusedPOIId = poiId }

            self.rotationSpeed = rotationSpeed
            let prevPreset = currentViewPreset
            currentViewPreset = activeViewPreset

            // HUMAN mode transition
            if prevPreset != .human && activeViewPreset == .human {
                enterHumanMode(scene: arView.scene)
            } else if prevPreset == .human && activeViewPreset != .human {
                exitHumanMode()
            }

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

            if poiFocusToken != lastViewFocusToken {
                lastViewFocusToken = poiFocusToken
                if let poiId = lastFocusedPOIId ?? venueTargetPOIId {
                    flyToVenue(poiId: poiId, districtName: districtName, scene: arView.scene)
                    startVenueLOD(scene: arView.scene)
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

        /// Flies to a POI venue. Primary path: finds the nearest building to the POI's
        /// lat/lon and calls `flyToBuildingWithFraming` for building-level close-up framing.
        /// Fallback (no nearby building): elevated overview at 20% district extent.
        private func flyToVenue(poiId: String, districtName: String, scene: RealityKit.Scene) {
            guard let collection = CangguPOICollection.load(for: districtName),
                  let poi = collection.pois.first(where: { $0.id == poiId }),
                  let districtEntry = CityManifest.shared.district(id: districtName)
            else { return }

            let geoAnchor = districtEntry.anchor
            let offset = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                .sceneOffset(from: geoAnchor)
            let poiPos = SIMD3<Float>(offset.x, 0, offset.z)

            // Primary: fly to nearest building to the POI coordinates.
            if let district = cachedDistrict,
               let nearest = nearestBuilding(to: poiPos, in: district.buildings, maxMeters: 120),
               nearest.heightMeters > 4.0 {
                flyToBuildingWithFraming(nearest, scene: scene)
                return
            }

            // Fallback: no building within 120m — elevated overview zoom centred on POI coords.
            let orbitDist: Float  = Float(districtExtent) * 0.20
            let elevSin: Float    = 0.259   // sin(15°)
            let elevCos: Float    = 0.966   // cos(15°)
            let lookTarget        = SIMD3<Float>(offset.x, 3.0, offset.z)
            let camY              = lookTarget.y + orbitDist * elevSin
            let groundDist        = orbitDist * elevCos
            let overviewPos       = SIMD3<Float>(
                offset.x + sin(azimuth) * groundDist,
                camY,
                offset.z + cos(azimuth) * groundDist
            )
            center           = lookTarget
            currentDistance  = orbitDist
            currentElevation = camY
            orbitSubscription?.cancel()
            orbitSubscription = nil
            flyCamera(to: overviewPos, lookAt: lookTarget, scene: scene)
        }

        // MARK: - POI visitable camera API

        /// Fly the camera to an approach position in front of `poi` (street-level, looking at the
        /// building face), then call `completion`. Pairs with `exitPOI` to restore the orbit.
        /// The approach position is derived from the POI's lat/lon + a 12 m forward offset so the
        /// camera stands on the "street" side rather than inside the geometry.
        func enterPOI(_ poi: CangguPOI, completion: @escaping () -> Void) {
            guard let arView, let districtEntry = CityManifest.shared.district(id: districtName)
            else { completion(); return }
            let offset = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                .sceneOffset(from: districtEntry.anchor)
            let approachZ  = offset.z + 12      // 12 m in front (south side)
            let eyeHeight: Float = 1.8          // eye level
            let eyePos   = SIMD3<Float>(offset.x, eyeHeight, approachZ)
            let lookPos  = SIMD3<Float>(offset.x, eyeHeight + 1.0, offset.z)
            orbitSubscription?.cancel()
            orbitSubscription = nil
            flyCamera(to: eyePos, lookAt: lookPos, scene: arView.scene) { [weak self] in
                guard let self else { return }
                self.startVenueLOD(scene: arView.scene)
                completion()
            }
        }

        /// Restore the orbit camera after a POI visit.
        func exitPOI(completion: @escaping () -> Void) {
            guard let arView else { completion(); return }
            if let anchor = districtAnchor {
                DistrictRealityKit.restoreGroundColor(in: anchor, mood: mood)
            }
            applyOrbitLOD()
            flyCamera(to: SIMD3(center.x, currentElevation, center.z + currentDistance),
                      lookAt: center, scene: arView.scene) { [weak self] in
                self?.restartOrbit(isAutoRotating: self?.currentIsAutoRotating ?? false)
                completion()
            }
        }

        /// Returns the building whose polygon centroid is closest to `target` within `maxMeters`.
        private func nearestBuilding(to target: SIMD3<Float>,
                                     in buildings: [BuildingFootprint],
                                     maxMeters: Float) -> BuildingFootprint? {
            let maxSq = maxMeters * maxMeters
            var best: BuildingFootprint? = nil
            var bestSq: Float = maxSq
            for b in buildings where !b.polygon.isEmpty {
                let n  = Float(b.polygon.count)
                let cx = b.polygon.map(\.x).reduce(0, +) / n
                let cz = b.polygon.map(\.z).reduce(0, +) / n
                let sq = (cx - target.x) * (cx - target.x) + (cz - target.z) * (cz - target.z)
                if sq < bestSq { bestSq = sq; best = b }
            }
            return best
        }

        // MARK: - Gesture handlers

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let arView else { return }

            // HUMAN mode 3P: horizontal pan turns character, vertical pan walks forward/back
            if currentViewPreset == .human {
                let delta = gesture.translation(in: arView)
                gesture.setTranslation(.zero, in: arView)
                humanCharacterAzimuth += Float(delta.x) * 0.008
                let fwd = SIMD3<Float>(-sin(humanCharacterAzimuth), 0, -cos(humanCharacterAzimuth))
                humanCharacterPos += fwd * Float(-delta.y) * 0.12
                characterEntity?.position = SIMD3<Float>(humanCharacterPos.x, 0.75, humanCharacterPos.z)
                characterEntity?.orientation = simd_quatf(angle: humanCharacterAzimuth, axis: SIMD3(0, 1, 0))
                return
            }

            // Cancel any in-flight camera animation when the user starts dragging.
            // Both orbitSubscription AND flySubscription/cinematicSubscription can be active
            // simultaneously — without cancelling all three, the fly animation and the pan
            // handler both write camera.position on the same frame, producing visible jitter.
            if gesture.state == .began {
                orbitSubscription?.cancel()
                orbitSubscription = nil
                flySubscription?.cancel()
                flySubscription = nil
                cinematicSubscription?.cancel()
                cinematicSubscription = nil
                // Capture initial velocity for momentum/inertia
                panVelocity = gesture.velocity(in: arView)
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

            // Track velocity for momentum
            if gesture.state == .changed {
                panVelocity = gesture.velocity(in: arView)
            }

            if gesture.state == .ended || gesture.state == .cancelled {
                // Apply momentum/inertia to the pan gesture
                applyPanMomentum(in: arView.scene)
                
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
            let rawScale = Float(gesture.scale)
            gesture.scale = 1.0
            guard rawScale > 0, rawScale != 1.0 else { return }

            let minDist = max(6.0, districtExtent * 0.010)
            let maxDist = districtExtent * 5.0

            // Rubber-band resistance near zoom limits:
            // tMin approaches 0 as currentDistance approaches minDist (zooming in).
            // tMax approaches 0 as currentDistance approaches maxDist (zooming out).
            // Beyond the soft-zone (15% of each limit) full response applies (t = 1).
            let tMin = min((currentDistance - minDist) / max(minDist * 0.15, 1), 1.0)
            let tMax = min((maxDist - currentDistance) / max(maxDist * 0.08, 1), 1.0)
            let t: Float = rawScale < 1.0 ? tMin : tMax
            let easedScale = 1.0 + (rawScale - 1.0) * max(t, 0.12)   // ≥12% response at boundary
            currentDistance = min(max(currentDistance / easedScale, minDist), maxDist)

            updateCameraPosition()

            // Dynamic FOV: narrow slightly (telephoto effect) when zoomed in close.
            // Gives better spatial depth and a more architectural "prime lens" feel.
            // 0 = far/overview, 1 = minimum distance / maximum detail.
            let normZoom = 1.0 - (currentDistance - minDist) / max(maxDist - minDist, 1)
            updateFOV(normalizedZoom: normZoom)

            // Pinch-triggered facade LOD: reveal bands/balconies/chimneys when close enough
            // even without a building tap. Only active in orbit mode (no inspected building),
            // so it doesn't fight `flyToBuildingWithFraming`'s explicit enable.
            // Threshold 22% of district extent: ~110m for Paris, ~660m for Canggu.
            if inspectedBuildingCentroid == nil {
                let showDetail = currentDistance < districtExtent * 0.22
                if showDetail != facadeDetailEnabled {
                    facadeDetailEnabled = showDetail
                    setFacadeDetailEnabled(showDetail)
                }
            }

            if currentDistance >= maxDist * 0.98 { onZoomBack?() }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            resetToDefaultPosition()
        }
        
        // MARK: - Momentum / Inertia
        
        /// Velocity tracker for pan gesture momentum
        private var panVelocity: CGPoint = .zero
        private var momentumSubscription: Cancellable?
        
        /// Applies momentum/inertia to the camera after a pan gesture ends.
        /// The camera continues moving with decreasing velocity until it naturally stops.
        private func applyPanMomentum(in scene: RealityKit.Scene) {
            guard let arView else { return }
            
            let velocity = panVelocity
            guard velocity != .zero else { return }
            
            // Decay factor: controls how quickly momentum fades
            // Higher = longer momentum (0.92 = ~2 seconds of noticeable movement)
            let decay: Float = 0.92
            let minVelocity: Float = 0.5  // Stop when velocity drops below this
            
            // Scale velocity to reasonable camera movement speeds
            // 5-10 m/s as specified in requirements
            let azimuthSpeed: Float = 0.003
            let elevationSpeed: Float = 0.002
            
            var currentVelocity = SIMD2<Float>(Float(velocity.x), Float(velocity.y))
            
            momentumSubscription?.cancel()
            momentumSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                guard let self else { return }
                
                // Apply velocity
                self.azimuth += currentVelocity.x * azimuthSpeed
                let elevDelta = currentVelocity.y * elevationSpeed
                let minElev = max(2.0, self.height * 0.02)
                let maxElev = self.height * 2.5
                self.currentElevation = min(max(self.currentElevation + elevDelta, minElev), maxElev)
                
                self.updateCameraPosition()
                
                // Decay velocity
                currentVelocity *= decay
                
                // Stop when velocity is negligible
                if length(currentVelocity) < minVelocity {
                    self.momentumSubscription?.cancel()
                    self.momentumSubscription = nil
                    
                    // Resume orbit if auto-rotate is enabled
                    if self.currentIsAutoRotating {
                        let orbitCenter = self.inspectedBuildingCentroid ?? self.center
                        self.startBuildingOrbit360(center: orbitCenter,
                                                  orbDist: self.currentDistance,
                                                  orbH: self.currentElevation,
                                                  scene: scene)
                    }
                }
            }
        }

        /// Single-tap handler. Priority order:
        /// 1. Mini-game target hit (HUMAN mode) — exact entity hit-test.
        /// 2. POI beacon hit — traverse ancestors for "poi:" name.
        /// 3. Building selection — geometric ray-cast.
        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView else { return }
            let loc = gesture.location(in: arView)

            // Mini-game target hit (HUMAN mode)
            if currentViewPreset == .human, let hit = arView.entity(at: loc) {
                var cursor: Entity? = hit
                while let e = cursor {
                    if e.name.hasPrefix("_minigame_") {
                        scoreMiniGameHit(e)
                        return
                    }
                    cursor = e.parent
                }
            }

            // POI beacon tap — traverse hit entity and its ancestors for a "poi:" name.
            if let hit = arView.entity(at: loc) {
                var cursor: Entity? = hit
                while let e = cursor {
                    if e.name.hasPrefix("poi:") {
                        let poiId = String(e.name.dropFirst(4))
                        onPOISelected?(poiId)
                        // In HUMAN mode: spawn mini-game at the POI's world position
                        if currentViewPreset == .human {
                            onPOIInteract?(poiId)
                            if let spec = miniGameSpec(for: poiId) {
                                var spawnPos = humanCharacterPos
                                if let distEntry = CityManifest.shared.district(id: districtName),
                                   let collection = CangguPOICollection.load(for: districtName),
                                   let poi = collection.pois.first(where: { $0.id == poiId }) {
                                    let off = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                                        .sceneOffset(from: distEntry.anchor)
                                    spawnPos = SIMD3<Float>(off.x, 0, off.z)
                                }
                                startMiniGame(poiId: poiId, spec: spec, at: spawnPos, scene: arView.scene)
                            }
                        }
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
        }

        private func updateCameraPosition() {
            guard let camera = cameraEntity else { return }
            let x = center.x + sin(azimuth) * currentDistance
            let z = center.z + cos(azimuth) * currentDistance
            camera.position = SIMD3(x, currentElevation, z)
            camera.look(at: center, from: camera.position, relativeTo: nil)
        }

        private func resetToDefaultPosition() {
            center = districtCenter
            azimuth = 0
            updateFOV(normalizedZoom: 0)
            setFacadeDetailEnabled(false)
            facadeDetailEnabled = false
            guard let arView else { return }

            if currentViewPreset == .overview {
                // OVERVIEW: bird's-eye ~61°.
                let overviewDist = districtDistance * 0.60
                let overviewH    = overviewDist * 1.10
                currentDistance  = overviewDist
                currentElevation = overviewH
                flyCamera(to: SIMD3(center.x, overviewH, center.z + overviewDist),
                          lookAt: center, scene: arView.scene)
                orbitSubscription?.cancel()
                orbitSubscription = nil
            } else {
                currentDistance  = districtDistance
                currentElevation = height
                flyCamera(to: SIMD3(center.x, height, center.z + districtDistance),
                          lookAt: center, scene: arView.scene)
            }
        }

        // Pan and pinch can fire simultaneously — lets the user orbit while slowly zooming.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        
        // macOS trackpad support removed — iOS only target.

        // MARK: - HUMAN mode

        /// Enter HUMAN mode: spawn 3rd-person character, position follow-cam behind them.
        private func enterHumanMode(scene: RealityKit.Scene) {
            orbitSubscription?.cancel(); orbitSubscription = nil
            flySubscription?.cancel();   flySubscription = nil
            cinematicSubscription?.cancel(); cinematicSubscription = nil

            // Character spawns at district center facing north
            humanCharacterPos = SIMD3<Float>(districtCenter.x, 0, districtCenter.z)
            humanCharacterAzimuth = 0

            let char = makeCharacterEntity()
            char.position = SIMD3<Float>(humanCharacterPos.x, 0.75, humanCharacterPos.z)
            districtAnchor?.addChild(char)
            characterEntity = char

            // Camera: 5 m behind character, 2.5 m above ground
            let camPos = SIMD3<Float>(humanCharacterPos.x, 2.5, humanCharacterPos.z + 5.0)
            let lookAt  = SIMD3<Float>(humanCharacterPos.x, 0.9, humanCharacterPos.z)
            cameraEntity?.position = camPos
            cameraEntity?.look(at: lookAt, from: camPos, relativeTo: nil)

            // Widen FOV for immersive 3P feel
            if var cam = cameraEntity?.components[PerspectiveCameraComponent.self] {
                cam.fieldOfViewInDegrees = mood.humanModeFOV
                cameraEntity?.components[PerspectiveCameraComponent.self] = cam
            }
            // Boost fill lights
            if let anch = districtAnchor {
                DistrictRealityScene.applyHumanModeLighting(anchor: anch, mood: mood, isHuman: true)
            }

            startHumanFollowCamera(scene: scene)
            startHumanNearbyCheck(scene: scene)
        }

        /// Exit HUMAN mode: remove character, cancel subscriptions, restore FOV + lights.
        private func exitHumanMode() {
            humanFollowSubscription?.cancel(); humanFollowSubscription = nil
            humanNearbySubscription?.cancel(); humanNearbySubscription = nil
            endActiveMiniGame()
            characterEntity?.removeFromParent(); characterEntity = nil
            humanBoostEntity?.removeFromParent(); humanBoostEntity = nil
            humanNearPOIId = nil
            if var cam = cameraEntity?.components[PerspectiveCameraComponent.self] {
                cam.fieldOfViewInDegrees = mood.fieldOfViewDegrees
                cameraEntity?.components[PerspectiveCameraComponent.self] = cam
            }
            if let anch = districtAnchor {
                DistrictRealityScene.applyHumanModeLighting(anchor: anch, mood: mood, isHuman: false)
            }
        }

        /// Neon-cyan box body (0.4 × 1.2 × 0.24 m) + white sphere head — simple 3rd-person avatar.
        private func makeCharacterEntity() -> ModelEntity {
            let body = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.40, 1.20, 0.24)),
                materials: [UnlitMaterial(color: UIColor(red: 0.05, green: 0.85, blue: 1.00, alpha: 0.92))]
            )
            let head = ModelEntity(
                mesh: .generateSphere(radius: 0.20),
                materials: [UnlitMaterial(color: UIColor(red: 0.92, green: 0.95, blue: 1.00, alpha: 1.0))]
            )
            head.position = SIMD3(0, 0.80, 0)
            body.addChild(head)
            body.name = "_humanCharacter"
            body.components.set(CollisionComponent(shapes: [
                .generateBox(size: SIMD3<Float>(0.40, 1.20, 0.24))
            ]))
            return body
        }

        /// Spring-follow: camera locks 5 m behind + 2.5 m above the character, lerp α = 0.12.
        private func startHumanFollowCamera(scene: RealityKit.Scene) {
            humanFollowSubscription?.cancel()
            humanFollowSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                guard let self, let cam = self.cameraEntity else { return }
                let behindX = sin(self.humanCharacterAzimuth) * 5.0
                let behindZ = cos(self.humanCharacterAzimuth) * 5.0
                let targetPos = SIMD3<Float>(
                    self.humanCharacterPos.x + behindX,
                    2.5,
                    self.humanCharacterPos.z + behindZ
                )
                let lookTarget = SIMD3<Float>(self.humanCharacterPos.x, 0.9, self.humanCharacterPos.z)
                let newPos = cam.position + (targetPos - cam.position) * 0.12
                cam.position = newPos
                cam.look(at: lookTarget, from: newPos, relativeTo: nil)
            }
        }

        /// Per-frame proximity check — uses character position (not camera) to detect POIs.
        private func startHumanNearbyCheck(scene: RealityKit.Scene) {
            humanNearbySubscription?.cancel()
            humanNearbySubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                guard let self else { return }
                guard let collection = CangguPOICollection.load(for: self.districtName),
                      let distEntry = CityManifest.shared.district(id: self.districtName) else { return }
                let charPos = self.humanCharacterPos
                var nearestId: String? = nil
                var nearestDist: Float = .greatestFiniteMagnitude
                for poi in collection.pois {
                    let off = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                        .sceneOffset(from: distEntry.anchor)
                    let dx = charPos.x - off.x, dz = charPos.z - off.z
                    let d = sqrt(dx*dx + dz*dz)
                    if d < nearestDist { nearestDist = d; nearestId = poi.id }
                }
                let enterThresh: Float = 12
                let exitThresh: Float  = 15
                if nearestDist < enterThresh, let id = nearestId, id != self.humanNearPOIId {
                    self.humanNearPOIId = id
                    self.boostNearbyPortal(poiId: id, scene: scene)
                } else if nearestDist > exitThresh, self.humanNearPOIId != nil {
                    self.humanNearPOIId = nil
                    self.humanBoostEntity?.removeFromParent(); self.humanBoostEntity = nil
                }
            }
        }

        /// Spawns a color-coded proximity sphere above the portal when player enters 12m.
        private func boostNearbyPortal(poiId: String, scene: RealityKit.Scene) {
            humanBoostEntity?.removeFromParent()
            guard let anch = districtAnchor,
                  let collection = CangguPOICollection.load(for: districtName),
                  let poi = collection.pois.first(where: { $0.id == poiId }),
                  let distEntry = CityManifest.shared.district(id: districtName) else { return }

            let off = GeoCoord(latitude: poi.latitude, longitude: poi.longitude)
                .sceneOffset(from: distEntry.anchor)

            let color = portalColor(for: poi)
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.35),
                materials: [UnlitMaterial(color: color.withAlphaComponent(0.92))]
            )
            sphere.position = SIMD3<Float>(off.x, 2.5, off.z)
            sphere.name = "_humanPrompt_\(poiId)"
            anch.addChild(sphere)
            humanBoostEntity = sphere
        }

        /// Category-aware portal color for the proximity sphere.
        private func portalColor(for poi: CangguPOI) -> UIColor {
            switch poi.category {
            case .shop:                    return UIColor(red: 1.00, green: 0.18, blue: 0.62, alpha: 1)
            case .restaurant, .cafe:       return UIColor(red: 1.00, green: 0.60, blue: 0.08, alpha: 1)
            case .temple:                  return UIColor(red: 0.95, green: 0.22, blue: 0.12, alpha: 1)
            case .beach, .surf:            return UIColor(red: 0.18, green: 0.95, blue: 0.38, alpha: 1)
            case .nightlife:               return UIColor(red: 0.75, green: 0.10, blue: 1.00, alpha: 1)
            default:                       return UIColor(red: 0.00, green: 0.92, blue: 1.00, alpha: 1)
            }
        }

        // MARK: - Mini-game

        private struct MiniGameSpec {
            let color: UIColor
            let count: Int
        }

        private func miniGameSpec(for poiId: String) -> MiniGameSpec? {
            guard let collection = CangguPOICollection.load(for: districtName),
                  let poi = collection.pois.first(where: { $0.id == poiId }) else { return nil }
            return MiniGameSpec(color: portalColor(for: poi), count: 5)
        }

        private func startMiniGame(poiId: String, spec: MiniGameSpec, at pos: SIMD3<Float>, scene: RealityKit.Scene) {
            endActiveMiniGame()
            activeMiniGamePOIId = poiId
            miniGameHits = 0
            miniGameTotal = spec.count
            guard let anch = districtAnchor else { return }
            for _ in 0..<spec.count {
                let rx = Float.random(in: -4...4)
                let rz = Float.random(in: -4...4)
                let ry = Float.random(in: 1.0...2.8)
                let target = ModelEntity(
                    mesh: .generateSphere(radius: 0.45),
                    materials: [UnlitMaterial(color: spec.color.withAlphaComponent(0.90))]
                )
                target.position = SIMD3<Float>(pos.x + rx, pos.y + ry, pos.z + rz)
                target.name = "_minigame_\(poiId)"
                target.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.70)]))
                anch.addChild(target)
                activeMiniGameEntities.append(target)
            }
        }

        private func endActiveMiniGame() {
            activeMiniGameEntities.forEach { $0.removeFromParent() }
            activeMiniGameEntities.removeAll()
            activeMiniGamePOIId = nil
            miniGameHits = 0
        }

        private func scoreMiniGameHit(_ entity: Entity) {
            entity.removeFromParent()
            activeMiniGameEntities.removeAll { $0 === entity }
            miniGameHits += 1
            if activeMiniGameEntities.isEmpty { endActiveMiniGame() }
        }

        // MARK: - Model loading

        private func loadModel(named districtName: String, into anchor: AnchorEntity) {
            loadGeneration += 1
            let generation = loadGeneration
            let isNightSnapshot = currentIsNight
            Task { @MainActor [weak self] in
                guard let entity = try? await DistrictRealityKit.loadDistrictEntity(
                    named: districtName, isNight: isNightSnapshot, mood: self?.mood ?? .parkDaylight)
                else { return }
                guard let self, self.loadGeneration == generation else { return }
                anchor.children.first(where: { $0.name == "districtModel" })?.removeFromParent()
                entity.name = "districtModel"
                anchor.addChild(entity)
                self.extractQuadrantLOD(from: entity)
                self.cacheFacadeDetailEntities(from: entity)
                // Apply orbit or venue LOD now that quadrantLOD is populated.
                // `applyOrbitLOD()` at setUp time ran against an empty `quadrantLOD` array,
                // so it was a no-op — the palm entities were still enabled in the cached clone.
                // Calling here (after extractQuadrantLOD fills the array) is the first chance
                // to actually toggle palm visibility. Venue mode already has a per-frame
                // subscription that will correct on its next tick regardless.
                if self.currentVenueTargetPOIId == nil {
                    self.applyOrbitLOD()
                }
                // Re-add POI beacons (CollisionComponent-equipped so entity(at:) finds them in HUMAN mode)
                anchor.children.first(where: { $0.name == "poiBeacons" })?.removeFromParent()
                if let distEntry = CityManifest.shared.district(id: districtName),
                   let dist = self.cachedDistrict,
                   let beacons = DistrictRealityKit.makePOIBeaconEntities(
                       districtName: districtName,
                       districtAnchor: distEntry.anchor,
                       districtExtent: dist.extent) {
                    anchor.addChild(beacons)
                    self.poiBeaconsEntity = beacons
                    if let scene = self.arView?.scene { self.startPOIPulse(scene: scene) }
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

        /// Caches references to fine-detail facade entities (`_bands`, `_pilasters`, `_balconies`)
        /// from all quadrant near-containers. Called once after `extractQuadrantLOD` populates the tree.
        /// These entities are sub-pixel at full-orbit camera distances: hiding them at orbit gives a
        /// cleaner overview; they re-appear when the camera zooms to building-tap or venue distance.
        private func cacheFacadeDetailEntities(from root: Entity) {
            facadeDetailEntities = []
            for q in 0..<4 {
                guard let quad = root.findEntity(named: "q\(q)"),
                      let near = quad.children.first(where: { $0.name == "near" }) else { continue }
                for child in near.children {
                    let n = child.name
                    if n.hasSuffix("_bands") || n.hasSuffix("_pilasters") || n.hasSuffix("_balconies") || n.hasSuffix("_chimneys") || n.hasSuffix("_recesses") || n.hasSuffix("_railings") || n.hasSuffix("_dormers") || n.hasSuffix("_equipment") {
                        facadeDetailEntities.append(child)
                    }
                }
            }
        }

        private func setFacadeDetailEnabled(_ enabled: Bool) {
            for e in facadeDetailEntities { e.isEnabled = enabled }
        }

        /// Pulses the cyan neon featured POI beacons at 1.5 Hz (scale 0.92–1.08).
        /// Throttled to 30 fps (every-other-frame guard, same as orbit camera).
        /// Pre-caches the featured-sphere entity array so the per-frame closure does
        /// zero name-based lookup work.
        @MainActor
        private func startPOIPulse(scene: RealityKit.Scene) {
            poiPulseSubscription?.cancel()
            guard let beacons = poiBeaconsEntity else { return }
            let featuredBeacons = Array(beacons.children.filter { $0.name.hasPrefix("poi:") })
            guard !featuredBeacons.isEmpty else { return }
            var elapsed: Double = 0
            var frameCount = 0
            poiPulseSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                guard self != nil else { return }
                frameCount += 1
                guard frameCount & 1 == 0 else { return }  // 30fps throttle
                elapsed += Double(event.deltaTime)
                let pulse = Float(0.92 + 0.08 * sin(elapsed * .pi * 2.0 * 1.5))
                for beacon in featuredBeacons {
                    beacon.scale = SIMD3(repeating: pulse)
                }
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
            setFacadeDetailEnabled(false)
            facadeDetailEnabled = false
        }

        /// Venue mode: per-frame camera-proximity check. Quadrants within
        /// `districtExtent × 0.5` show full quality (palms included); farther ones use AABB boxes.
        private func startVenueLOD(scene: RealityKit.Scene) {
            lodSubscription?.cancel()
            let threshold = districtExtent * 0.5
            let thresholdSq = threshold * threshold  // avoid sqrt per frame per quadrant
            lodSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                guard let self, let cam = self.cameraEntity else { return }
                let camX = cam.position.x, camZ = cam.position.z
                for node in self.quadrantLOD {
                    let dx = camX - node.center.x, dz = camZ - node.center.z
                    let isNear = dx * dx + dz * dz <= thresholdSq
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
        /// with a cubic-Hermite ease. Duration scales with travel distance (0.6–1.4s) so close
        /// taps feel snappy and long cross-district flies feel deliberate.
        private func flyCamera(to target: SIMD3<Float>, lookAt: SIMD3<Float>, scene: RealityKit.Scene,
                                completion: (() -> Void)? = nil) {
            cinematicSubscription?.cancel()
            cinematicSubscription = nil
            guard let camera = cameraEntity else { completion?(); return }
            let startPos = camera.position
            // 0.6s for a 0-distance no-op; scales linearly with travel until capped at 1.4s.
            let travelDist = simd_length(target - startPos)
            let duration = min(max(0.6 + travelDist / max(districtExtent, 100) * 0.5, 0.6), 1.4)
            var elapsed: Float  = 0
            var lastTime: TimeInterval = 0

            flySubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] (event: SceneEvents.Update) in
                guard let self else { return }
                if lastTime == 0 { lastTime = event.deltaTime; return }
                elapsed += Float(event.deltaTime)
                lastTime  = event.deltaTime

                let t = min(elapsed / duration, 1.0)
                let s = t * t * (3 - 2 * t)   // cubic Hermite smoothstep
                let pos = startPos + (target - startPos) * s
                camera.position = pos

                let forward = normalize(lookAt - pos)
                let right   = normalize(cross(SIMD3<Float>(0, 1, 0), forward))
                let up      = cross(forward, right)
                camera.orientation = simd_quatf(simd_float3x3(columns: (right, up, -forward)))

                if t >= 1.0 {
                    self.flySubscription?.cancel()
                    self.flySubscription = nil
                    completion?()
                }
            }
        }

        // MARK: - Camera framing helpers

        /// Narrows FOV slightly as the user zooms in — telephoto effect that reduces wide-angle
        /// distortion at close range and gives a more architectural, "prime lens" spatial quality.
        /// `normalizedZoom` is 0 at maximum distance (overview) and 1 at minimum distance (close-up).
        private func updateFOV(normalizedZoom: Float) {
            // Up to 16% narrower than the base FOV at full zoom-in.
            // Example: parisianCore 45° → 37.8° at closest approach (walls fill the frame correctly).
            let baseFOV = mood.fieldOfViewDegrees
            let targetFOV = baseFOV * (1.0 - max(normalizedZoom, 0) * 0.16)
            if var camComp = cameraEntity?.components[PerspectiveCameraComponent.self] {
                camComp.fieldOfViewInDegrees = targetFOV
                cameraEntity?.components[PerspectiveCameraComponent.self] = camComp
            }
        }

        /// Cinematic building-focus fly — replaces the scalar `height × 2.2` heuristic with a
        /// proper 3D bounding-sphere calculation so the entire building volume fits in frame.
        ///
        /// **Algorithm**:
        /// 1. Compute XZ bounding box from footprint polygon → `halfW`, `halfD`.
        /// 2. Bounding sphere radius = diagonal from volume centre to corner: √(halfW² + halfD² + halfH²).
        /// 3. Camera distance = sphere_radius / tan(halfFOV) × 1.30 (30% margin).
        /// 4. Clamp: never closer than footprint diagonal, never farther than 38–52% of district extent
        ///    (tall-building threshold: > 60m switches to looser cap + steeper elevation angle).
        /// 5. Look-at height = 35–40% of building height so both base and crown are in frame.
        /// 6. Camera elevation = look-at + dist × sin(15°–20°) — oblique angle reads depth well.
        ///
        /// Sets `inspectedBuildingCentroid`, `inspectedOrbitDist`, `inspectedOrbitH`, `center`,
        /// `currentDistance`, and `currentElevation` as side effects so post-fly pan/orbit resume
        /// from the landed position.
        private func flyToBuildingWithFraming(_ building: BuildingFootprint, scene: RealityKit.Scene) {
            let pts = building.polygon
            guard !pts.isEmpty else { return }

            let n  = Float(pts.count)
            let cx = pts.map(\.x).reduce(0, +) / n
            let cz = pts.map(\.z).reduce(0, +) / n

            // 3D bounding box of the building volume
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
            let minZ = pts.map(\.z).min()!, maxZ = pts.map(\.z).max()!
            let halfW = (maxX - minX) * 0.5
            let halfD = (maxZ - minZ) * 0.5
            let halfH = building.heightMeters * 0.5
            let footprintR = sqrt(halfW * halfW + halfD * halfD)

            // Bounding sphere from the volumetric centre (cx, halfH, cz)
            let sphereR = sqrt(halfW * halfW + halfD * halfD + halfH * halfH)

            // FOV-based fitting distance: sphere must fit inside the camera frustum with margin
            let halfFovRad = (mood.fieldOfViewDegrees * 0.5) * (Float.pi / 180)
            let fovFitDist = sphereR / tan(halfFovRad) * 1.85

            // Tall buildings (> 60 m) get a looser distance cap and steeper elevation so the
            // camera rises above the mid-point and the full height remains in frame.
            let isTall = building.heightMeters > 60
            let maxRelDist: Float = isTall ? 0.65 : 0.50
            let eyeDist = min(max(fovFitDist, footprintR * 1.2, 12.0), districtExtent * maxRelDist)

            // Elevation angle: 20° for tall buildings (wider vertical frame), 15° for low-rise
            let elevSin: Float = isTall ? 0.342 : 0.259   // sin(20°) / sin(15°)
            let elevCos: Float = isTall ? 0.940 : 0.966   // cos(20°) / cos(15°)

            // Look-at Y: lower 1/3–2/5 of building height for a balanced full-building frame
            let lookH = building.heightMeters * (isTall ? 0.35 : 0.28)
            let lookTarget = SIMD3<Float>(cx, lookH, cz)

            // Camera position: approach from current azimuth, elevated above look-at
            let camY       = lookH + eyeDist * elevSin
            let groundDist = eyeDist * elevCos
            let camPos = SIMD3<Float>(
                cx + sin(azimuth) * groundDist,
                camY,
                cz + cos(azimuth) * groundDist
            )

            // Update gesture state so post-fly pan/pinch resume from the landed position
            center           = SIMD3(cx, lookH, cz)
            currentDistance  = eyeDist
            currentElevation = camY

            // Orbit resume state
            inspectedBuildingCentroid = SIMD3(cx, districtCenter.y, cz)
            inspectedOrbitDist = eyeDist
            inspectedOrbitH    = camY

            // Sync FOV to match the new zoom level
            let minDist = max(6.0, districtExtent * 0.010)
            let maxDist = districtExtent * 5.0
            let normZoom = 1.0 - (eyeDist - minDist) / max(maxDist - minDist, 1)
            updateFOV(normalizedZoom: max(normZoom, 0))

            setFacadeDetailEnabled(true)
            facadeDetailEnabled = true
            flyCamera(to: camPos, lookAt: lookTarget, scene: scene)
        }
    }
}
