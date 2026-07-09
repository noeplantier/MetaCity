import Combine
import RealityKit
import SwiftUI

/// City-level LOD (Level 0): district footprint volumes rendered as PBR city-blocks with
/// an orbiting oblique camera — shows relative heights (CBD towers vs colonial quarters vs parks),
/// giving instant geographic intuition before drilling into a district's full mesh.
///
/// Architecture notes:
/// - **Two anchors**: `sceneAnchor` (static, holds volumes + lights + ground) and `camAnchor`
///   (holds only the PerspectiveCamera). Separating them lets the camera orbit without
///   dragging the scene with it.
/// - **PBR materials** (`PhysicallyBasedMaterial`) + directional sun/fill lights give proper
///   shading depth. `UnlitMaterial` was flat; adding lights costs nothing on Simulator.
/// - **Height from moodKey**: CBD (skyscraperCorridor) → 0.25 × maxReach, park (parkDaylight)
///   → 0.04 × maxReach — immediately readable as a miniature city skyline.
/// - **Oblique camera** (35° elevation) orbiting at 30fps (every-other-frame guard from
///   the GPU draw-call pass) shows the volume silhouettes. All positions normalised to cluster
///   centroid so float precision stays in hundreds-of-metres, not thousands.
/// - **CollisionComponent** on every block enables `arView.entity(at:)` tap hit-testing;
///   walking the entity hierarchy finds the named district block.
struct CityOverviewView: UIViewRepresentable {
    let city: CityEntry
    let onSelectDistrict: (DistrictEntry) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.environment.background = .color(UIColor(red: 0.08, green: 0.18, blue: 0.42, alpha: 1))
        context.coordinator.setUp(arView: arView, city: city, onSelect: onSelectDistrict)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        private var arView: ARView?
        private var districtByID: [String: DistrictEntry] = [:]
        private var onSelect: ((DistrictEntry) -> Void)?
        private var orbitSubscription: Cancellable?

        func setUp(arView: ARView, city: CityEntry, onSelect: @escaping (DistrictEntry) -> Void) {
            self.arView = arView
            self.onSelect = onSelect

            let sceneAnchor = AnchorEntity(world: .zero)
            let camAnchor   = AnchorEntity(world: .zero)
            arView.scene.addAnchor(sceneAnchor)
            arView.scene.addAnchor(camAnchor)

            // All district positions relative to city anchor, then centred on cluster centroid
            let rawPositions = city.districts.map { $0.anchor.sceneOffset(from: city.anchor) }
            let clusterCenter: SIMD3<Float> = rawPositions.isEmpty ? .zero : {
                let n = Float(rawPositions.count)
                let cx = rawPositions.map(\.x).reduce(0, +) / n
                let cz = rawPositions.map(\.z).reduce(0, +) / n
                return SIMD3(cx, 0, cz)
            }()

            var maxReach: Float = 400
            for pos in rawPositions {
                maxReach = max(maxReach,
                               abs(pos.x - clusterCenter.x),
                               abs(pos.z - clusterCenter.z))
            }

            // Ground slab — warm asphalt tint (the sky gradient provides the horizon separation)
            let groundHalf = maxReach * 2.5
            let groundEnt = ModelEntity(
                mesh: MeshResource.generateBox(width: groundHalf * 2, height: 1, depth: groundHalf * 2),
                materials: [groundMaterial()]
            )
            groundEnt.position = SIMD3(0, -0.5, 0)
            groundEnt.name = "ground"
            sceneAnchor.addChild(groundEnt)

            // District volumes — PBR, height reflects urban density
            for district in city.districts {
                let entity = makeDistrictVolume(district: district,
                                                cityAnchor: city.anchor,
                                                clusterCenter: clusterCenter,
                                                maxReach: maxReach)
                sceneAnchor.addChild(entity)
                districtByID[district.id] = district
            }

            // Lighting: directional sun from upper-right + dim fill from opposite side
            installLighting(on: sceneAnchor, maxReach: maxReach)

            // Sky gradient sphere (inside-out, unlit — same pattern as DistrictRealityScene)
            Task { @MainActor in
                if let skyEnt = makeSkyDome(radius: maxReach * 4) {
                    sceneAnchor.addChild(skyEnt)
                }
            }

            // Oblique camera: 35° elevation, 30fps orbit
            let camH: Float = maxReach * 0.80     // lower for a more cinematic ground-level feel
            let camD: Float = maxReach * 2.20
            let cam = PerspectiveCamera()
            cam.camera.fieldOfViewInDegrees = 46
            cam.camera.far = maxReach * 12
            cam.look(at: SIMD3(0, maxReach * 0.05, 0),   // look slightly above ground
                     from: SIMD3(0, camH, camD),
                     relativeTo: nil)
            camAnchor.addChild(cam)

            var angle:      Float = 0
            var frameCount: Int   = 0
            let lookTarget = SIMD3<Float>(0, maxReach * 0.05, 0)
            orbitSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak cam] _ in
                frameCount &+= 1
                guard frameCount & 1 == 0 else { return }
                angle += 0.0025
                cam?.look(at: lookTarget,
                          from: SIMD3(sin(angle) * camD, camH, cos(angle) * camD),
                          relativeTo: nil)
            }

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            arView.addGestureRecognizer(tap)
        }

        // MARK: - District volume

        private func makeDistrictVolume(district: DistrictEntry,
                                        cityAnchor: GeoCoord,
                                        clusterCenter: SIMD3<Float>,
                                        maxReach: Float) -> ModelEntity {
            let offset = district.anchor.sceneOffset(from: cityAnchor)
            let bb     = district.boundingBox
            let latRad = Float(cityAnchor.latitude) * .pi / 180
            let bboxW  = max(Float((bb.east  - bb.west)  * 111_320.0) * cos(latRad), 120)
            let bboxD  = max(Float((bb.north - bb.south) * 111_320.0), 120)

            // Height encodes urban density — the most distinctive visual differentiator
            let chipH  = maxReach * heightFraction(for: district.moodKey)

            let mesh = MeshResource.generateBox(width: bboxW, height: chipH, depth: bboxD,
                                                cornerRadius: min(bboxW, bboxD) * 0.04)
            var mat  = PhysicallyBasedMaterial()
            let (base, rough, metal) = materialParams(for: district.moodKey)
            mat.baseColor    = .init(tint: base)
            mat.roughness    = .init(floatLiteral: rough)
            mat.metallic     = .init(floatLiteral: metal)
            mat.clearcoat    = .init(floatLiteral: district.moodKey == "skyscraperCorridor" ? 0.6 : 0.1)
            mat.clearcoatRoughness = .init(floatLiteral: 0.2)

            let entity = ModelEntity(mesh: mesh, materials: [mat])
            entity.name = district.id
            entity.position = SIMD3(offset.x - clusterCenter.x,
                                    chipH / 2,
                                    offset.z - clusterCenter.z)
            entity.components[CollisionComponent.self] = CollisionComponent(
                shapes: [.generateBox(size: SIMD3(bboxW, chipH, bboxD))]
            )
            return entity
        }

        // MARK: - Lighting

        private func installLighting(on anchor: AnchorEntity, maxReach: Float) {
            // Sun — warm golden-hour from upper-right front. Intensity matches
            // DistrictRealityScene's lux scale (35 klux) so that ARView's default
            // neutral-studio IBL doesn't dominate and wash out the PBR shading on the
            // city-block volumes. The old 6 klux value was SceneKit-era and too weak.
            let sun = Entity()
            sun.name = "sun"
            var sunLight = DirectionalLightComponent(
                color: UIColor(red: 1.0, green: 0.92, blue: 0.78, alpha: 1),
                intensity: 35_000)
            sunLight.isRealWorldProxy = false
            sun.components.set(sunLight)
            sun.components[DirectionalLightComponent.Shadow.self] = .init(
                maximumDistance: maxReach * 3, depthBias: 0.5)
            sun.orientation = simd_quatf(angle: .pi / 5, axis: SIMD3(0, 1, 0))
                            * simd_quatf(angle: -.pi / 4, axis: SIMD3(1, 0, 0))
            anchor.addChild(sun)

            // Fill — cool blue from opposite side at 18% of sun intensity.
            let fill = Entity()
            fill.name = "fill"
            var fillLight = DirectionalLightComponent(
                color: UIColor(red: 0.55, green: 0.68, blue: 0.90, alpha: 1),
                intensity: 35_000 * 0.18)
            fillLight.isRealWorldProxy = false
            fill.components.set(fillLight)
            fill.orientation = simd_quatf(angle: -.pi * 0.8, axis: SIMD3(0, 1, 0))
                            * simd_quatf(angle: -.pi / 6, axis: SIMD3(1, 0, 0))
            anchor.addChild(fill)
        }

        // MARK: - Sky dome

        @MainActor
        private func makeSkyDome(radius: Float) -> Entity? {
            let cacheKey = "cityOverviewSky"
            var mat = UnlitMaterial()
            if let tex = makeSkyTexture(cacheKey: cacheKey) {
                mat.color = .init(texture: .init(tex))
            } else {
                mat.color = .init(tint: UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1))
            }
            let dome = ModelEntity(mesh: MeshResource.generateSphere(radius: radius),
                                   materials: [mat])
            dome.name = "skyDome"
            dome.scale = SIMD3(-1, 1, 1)   // flip X only → reverses winding to face inward
            return dome
        }

        @MainActor
        private static var skyTextureCache: [String: TextureResource] = [:]

        @MainActor
        private func makeSkyTexture(cacheKey: String) -> TextureResource? {
            if let cached = Coordinator.skyTextureCache[cacheKey] { return cached }
            // 1 × 32 vertical gradient: ground→horizon→zenith (dusk/city-glow palette)
            let h = 32
            var pixels = [UInt8](repeating: 0, count: h * 4)
            for y in 0..<h {
                let t = Float(y) / Float(h - 1)  // 0 = south pole (ground inside dome), 1 = zenith
                // Daytime Jakarta sky: warm amber ground haze → pale blue horizon → deep blue zenith
                let r, g, b: UInt8
                if t < 0.18 {
                    // Ground-level: warm amber/orange haze (Jakarta humidity + city heat)
                    let s = t / 0.18
                    r = UInt8(mix(215, 175, s)); g = UInt8(mix(155, 165, s)); b = UInt8(mix(80, 135, s))
                } else if t < 0.50 {
                    // Low horizon: haze blending into pale sky blue
                    let s = smoothstep(0.18, 0.50, t)
                    r = UInt8(mix(175, 100, s)); g = UInt8(mix(165, 165, s)); b = UInt8(mix(135, 215, s))
                } else {
                    // Mid sky to zenith: sky blue → deep equatorial blue
                    let s = smoothstep(0.50, 1.0, t)
                    r = UInt8(mix(100, 22, s)); g = UInt8(mix(165, 75, s)); b = UInt8(mix(215, 185, s))
                }
                let i = y * 4
                pixels[i] = r; pixels[i+1] = g; pixels[i+2] = b; pixels[i+3] = 255
            }
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let cg = CGImage(width: 1, height: h,
                                   bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: 4, space: cs,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent)
            else { return nil }
            let tex = try? TextureResource.generate(from: cg, withName: cacheKey,
                                                    options: .init(semantic: .color))
            Coordinator.skyTextureCache[cacheKey] = tex
            return tex
        }

        // MARK: - Ground material

        private func groundMaterial() -> PhysicallyBasedMaterial {
            var mat = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: UIColor(red: 0.18, green: 0.17, blue: 0.16, alpha: 1))
            mat.roughness = .init(floatLiteral: 0.92)
            mat.metallic  = .init(floatLiteral: 0.0)
            return mat
        }

        // MARK: - Style helpers

        /// Height fraction of maxReach per mood — the single biggest depth cue in the overview
        private func heightFraction(for moodKey: String) -> Float {
            switch moodKey {
            case "skyscraperCorridor": return 0.22  // CBD tower cluster
            case "colonialSquare":     return 0.09  // 2-3 storey colonial
            case "residentialDusk":    return 0.12  // mid-rise residential
            case "parkDaylight":       return 0.07  // park — low but still visible
            case "coastalPark":        return 0.08  // coastal entertainment
            case "beachResort":        return 0.10  // beach hotels
            case "sacredSite":         return 0.08  // temples + low urban
            default:                   return 0.08
            }
        }

        /// PBR base color + roughness + metallic per mood
        private func materialParams(for moodKey: String) -> (UIColor, Float, Float) {
            switch moodKey {
            case "skyscraperCorridor":
                return (UIColor(red: 0.52, green: 0.66, blue: 0.84, alpha: 1), 0.12, 0.72)
            case "colonialSquare":
                return (UIColor(red: 0.82, green: 0.72, blue: 0.50, alpha: 1), 0.78, 0.02)
            case "residentialDusk":
                return (UIColor(red: 0.80, green: 0.52, blue: 0.36, alpha: 1), 0.72, 0.04)
            case "parkDaylight":
                return (UIColor(red: 0.32, green: 0.68, blue: 0.38, alpha: 1), 0.85, 0.0)
            case "coastalPark":
                return (UIColor(red: 0.32, green: 0.72, blue: 0.72, alpha: 1), 0.55, 0.15)
            case "beachResort":
                return (UIColor(red: 0.88, green: 0.76, blue: 0.42, alpha: 1), 0.60, 0.05)
            case "sacredSite":
                return (UIColor(red: 0.82, green: 0.58, blue: 0.32, alpha: 1), 0.65, 0.06)
            default:
                return (UIColor(white: 0.50, alpha: 1), 0.70, 0.0)
            }
        }

        // MARK: - Tap handling

        @objc private func handleTap(_ gr: UITapGestureRecognizer) {
            guard let arView else { return }
            let pt = gr.location(in: arView)
            guard let hit = arView.entity(at: pt) else { return }
            var e: Entity? = hit
            while let current = e {
                if let district = districtByID[current.name] { onSelect?(district); return }
                e = current.parent
            }
        }
    }
}

// MARK: - Math helpers (file-private)

private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
private func mix(_ a: Int, _ b: Int, _ t: Float) -> Float { Float(a) + Float(b - a) * t }
private func smoothstep(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - lo) / (hi - lo)))
    return t * t * (3 - 2 * t)
}
