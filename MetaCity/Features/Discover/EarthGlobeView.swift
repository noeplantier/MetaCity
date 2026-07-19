import SceneKit
import SwiftUI

// MARK: - EarthGlobeView
// Procedural SceneKit globe rendered to imitate the real planet Earth in miniature.
// - Realistic equirectangular day texture (oceans, continents, deserts, forests, ice)
// - Bump / normal-like relief via a grayscale height map derived from the same procedural pass
// - Specular map so oceans shine and continents stay matte
// - Emissive night lights on the dark side
// - Cloud layer that drifts slightly faster than the surface
// - Fresnel atmospheric rim glow
// Size and rotation speed are preserved (radius 1.0, 22 s per rotation, 23.5° tilt).

struct EarthGlobeView: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView(frame: .zero)
        scnView.scene = buildScene()
        scnView.backgroundColor = .clear
        scnView.isOpaque = false
        scnView.allowsCameraControl = false
        scnView.rendersContinuously = true
        scnView.antialiasingMode = .multisampling4X
        scnView.preferredFramesPerSecond = 30

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        scnView.addGestureRecognizer(tap)
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    class Coordinator: NSObject {
        let onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func handleTap() { onTap() }
    }

    // MARK: - Scene construction

    private func buildScene() -> SCNScene {
        EarthGlobeView.buildEarthScene(rotationDuration: 22.0).scene
    }

    // MARK: - Shared static builder
    // Returns the earth SCNNode so callers (e.g. EarthOverviewView) can attach city markers.

    static func buildEarthScene(rotationDuration: TimeInterval = 22.0) -> (scene: SCNScene, earthNode: SCNNode) {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        // Camera
        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        camNode.camera?.fieldOfView = 30
        camNode.camera?.zNear = 0.1
        camNode.camera?.zFar = 100
        camNode.position = SCNVector3(0, 0, 3.4)
        scene.rootNode.addChildNode(camNode)

        // Pre-render all procedural maps once
        let maps = EarthMaps.generate(width: 1024, height: 512)

        // ── Earth sphere ──
        let sphere = SCNSphere(radius: 1.0)
        sphere.segmentCount = 96
        sphere.isGeodesic = false

        let earthMat = SCNMaterial()
        earthMat.lightingModel = .physicallyBased
        earthMat.diffuse.contents = maps.day
        earthMat.diffuse.wrapS = .repeat
        earthMat.diffuse.wrapT = .clamp
        earthMat.diffuse.mipFilter = .linear

        // Specular / metallic-roughness — oceans reflective, land rough
        earthMat.roughness.contents = maps.roughness
        earthMat.metalness.contents = 0.0
        earthMat.specular.contents = UIColor(white: 0.35, alpha: 1)

        // Relief
        earthMat.normal.contents = maps.normal
        earthMat.normal.intensity = 0.8

        // Night side city lights
        earthMat.emission.contents = maps.night
        earthMat.emission.intensity = 1.0

        sphere.materials = [earthMat]

        let earthNode = SCNNode(geometry: sphere)
        earthNode.name = "earth"
        earthNode.eulerAngles.x = -0.4101524   // 23.5° axial tilt
        let rot = SCNAction.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: rotationDuration))
        earthNode.runAction(rot, forKey: "earthRot")
        scene.rootNode.addChildNode(earthNode)

        // ── Cloud layer ──
        let cloudSphere = SCNSphere(radius: 1.012)
        cloudSphere.segmentCount = 72
        let cloudMat = SCNMaterial()
        cloudMat.lightingModel = .lambert
        cloudMat.diffuse.contents = maps.clouds
        cloudMat.transparent.contents = maps.clouds
        cloudMat.transparencyMode = .rgbZero
        cloudMat.isDoubleSided = false
        cloudMat.writesToDepthBuffer = false
        cloudSphere.materials = [cloudMat]

        let cloudNode = SCNNode(geometry: cloudSphere)
        cloudNode.eulerAngles.x = -0.4101524
        // Clouds rotate slightly faster than the surface (weather drift)
        let cloudDuration = rotationDuration * (18.0 / 22.0)
        let cloudRot = SCNAction.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: cloudDuration))
        cloudNode.runAction(cloudRot)
        scene.rootNode.addChildNode(cloudNode)

        // ── Atmosphere: inner soft halo ──
        let atmSphere = SCNSphere(radius: 1.045)
        atmSphere.segmentCount = 48
        let atmMat = SCNMaterial()
        atmMat.lightingModel = .constant
        atmMat.diffuse.contents = UIColor.clear
        atmMat.emission.contents = UIColor(red: 0.38, green: 0.68, blue: 1.0, alpha: 1.0)
        // Fresnel: transparent at center, glowing at rim
        atmMat.transparent.contents = UIColor.white
        atmMat.transparencyMode = .default
        atmMat.transparency = 0.28
        atmMat.isDoubleSided = true
        atmMat.writesToDepthBuffer = false
        atmMat.cullMode = .front
        atmSphere.materials = [atmMat]
        scene.rootNode.addChildNode(SCNNode(geometry: atmSphere))

        // ── Atmosphere: outer wispy rim ──
        let outerAtm = SCNSphere(radius: 1.09)
        outerAtm.segmentCount = 40
        let outerMat = SCNMaterial()
        outerMat.lightingModel = .constant
        outerMat.diffuse.contents = UIColor(red: 0.40, green: 0.70, blue: 1.0, alpha: 0.10)
        outerMat.isDoubleSided = true
        outerMat.writesToDepthBuffer = false
        outerMat.cullMode = .front
        outerAtm.materials = [outerMat]
        scene.rootNode.addChildNode(SCNNode(geometry: outerAtm))

        // ── Sun (directional) ──
        let sunNode = SCNNode()
        sunNode.light = SCNLight()
        sunNode.light!.type = .directional
        sunNode.light!.color = UIColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1)
        sunNode.light!.intensity = 1_800
        sunNode.light!.castsShadow = false
        sunNode.eulerAngles = SCNVector3(-0.35, -0.7, 0)
        scene.rootNode.addChildNode(sunNode)

        // ── Deep space ambient ──
        let ambNode = SCNNode()
        ambNode.light = SCNLight()
        ambNode.light!.type = .ambient
        ambNode.light!.color = UIColor(white: 0.06, alpha: 1)
        scene.rootNode.addChildNode(ambNode)

        return (scene, earthNode)
    }
}

// MARK: - Procedural Earth map generator
// Produces a coherent set of equirectangular textures from the same underlying
// land/height field so day / night / clouds / normal / roughness all agree.

private struct EarthMaps {
    let day: UIImage
    let night: UIImage
    let clouds: UIImage
    let normal: UIImage
    let roughness: UIImage

    static func generate(width: Int, height: Int) -> EarthMaps {
        let field = LandField(width: width, height: height)

        return EarthMaps(
            day: renderDay(field),
            night: renderNight(field),
            clouds: renderClouds(field),
            normal: renderNormal(field),
            roughness: renderRoughness(field)
        )
    }

    // MARK: Day / albedo

    private static func renderDay(_ f: LandField) -> UIImage {
        let w = f.width, h = f.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        for y in 0..<h {
            let v = Double(y) / Double(h - 1)          // 0 top → 1 bottom
            let lat = (0.5 - v) * .pi                  // +π/2 north … -π/2 south
            let absLat = abs(lat)
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let elev = f.elevation(x: x, y: y)     // -1 ocean … +1 mountain
                let moist = f.moisture(x: x, y: y)     // 0 dry … 1 wet
                let temp = cos(lat) - max(0, elev) * 0.35  // hot at equator, cold at altitude/poles

                let color = biomeColor(elev: elev, moist: moist, temp: temp, absLat: absLat)
                pixels[idx]     = color.r
                pixels[idx + 1] = color.g
                pixels[idx + 2] = color.b
                pixels[idx + 3] = 255
            }
        }
        return imageFromRGBA(pixels, width: w, height: h)
    }

    private static func biomeColor(elev: Double, moist: Double, temp: Double,
                                   absLat: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        // Polar ice
        if absLat > 1.30 || (elev > 0 && temp < -0.05) {
            let n = UInt8(240 + Int.random(in: -8...8))
            return (n, n, min(255, Int(n) + 10) |> UInt8.init)
        }

        if elev < 0 {
            // Ocean: depth shading
            let depth = min(1.0, -elev)                // 0 shore … 1 abyss
            let shallow = SIMD3<Double>(0.16, 0.42, 0.62)
            let deep    = SIMD3<Double>(0.02, 0.08, 0.28)
            let c = mix(shallow, deep, t: depth)
            return rgb(c)
        }

        // Land
        let beach   = SIMD3<Double>(0.86, 0.80, 0.58)
        let desert  = SIMD3<Double>(0.78, 0.66, 0.38)
        let steppe  = SIMD3<Double>(0.55, 0.55, 0.28)
        let forest  = SIMD3<Double>(0.16, 0.36, 0.14)
        let jungle  = SIMD3<Double>(0.10, 0.30, 0.08)
        let tundra  = SIMD3<Double>(0.42, 0.44, 0.36)
        let mountain = SIMD3<Double>(0.42, 0.36, 0.30)
        let snow    = SIMD3<Double>(0.95, 0.96, 0.98)

        var base: SIMD3<Double>

        if elev < 0.02 {
            base = beach
        } else if temp < 0.10 {
            base = tundra
        } else if moist < 0.28 {
            base = mix(desert, steppe, t: moist / 0.28)
        } else if moist < 0.55 {
            base = mix(steppe, forest, t: (moist - 0.28) / 0.27)
        } else {
            base = mix(forest, jungle, t: min(1, (moist - 0.55) / 0.45))
        }

        // Mountain blend
        if elev > 0.45 {
            let t = min(1.0, (elev - 0.45) / 0.35)
            base = mix(base, mountain, t: t)
        }
        // Snow caps on high / cold
        let snowLine = 0.65 - max(0, temp) * 0.35
        if elev > snowLine {
            let t = min(1.0, (elev - snowLine) / 0.25)
            base = mix(base, snow, t: t)
        }

        return rgb(base)
    }

    // MARK: Night lights

    private static func renderNight(_ f: LandField) -> UIImage {
        let w = f.width, h = f.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var rng = SeededRNG(seed: 1337)

        for y in 0..<h {
            let v = Double(y) / Double(h - 1)
            let lat = (0.5 - v) * .pi
            let absLat = abs(lat)
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let elev = f.elevation(x: x, y: y)
                let moist = f.moisture(x: x, y: y)
                var lum = 0
                if elev > 0.02 && elev < 0.55 && absLat < 1.15 {
                    // Habitability proxy: temperate + not desert + not high mountain
                    let habit = (1.0 - abs(moist - 0.55)) * (1.0 - min(1, elev / 0.6))
                    let r = rng.next()
                    if r < habit * 0.06 {
                        lum = Int(160 + rng.next() * 95)
                    } else if r < habit * 0.14 {
                        lum = Int(40 + rng.next() * 60)
                    }
                }
                if lum > 0 {
                    // Warm sodium-vapor tint
                    pixels[idx]     = UInt8(min(255, lum))
                    pixels[idx + 1] = UInt8(min(255, Int(Double(lum) * 0.75)))
                    pixels[idx + 2] = UInt8(min(255, Int(Double(lum) * 0.35)))
                    pixels[idx + 3] = 255
                }
            }
        }
        return imageFromRGBA(pixels, width: w, height: h)
    }

    // MARK: Clouds

    private static func renderClouds(_ f: LandField) -> UIImage {
        let w = f.width, h = f.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let noise = FBMNoise(seed: 91, octaves: 5, persistence: 0.55, lacunarity: 2.1)

        for y in 0..<h {
            let v = Double(y) / Double(h - 1)
            let lat = (0.5 - v) * .pi
            // Real Earth cloud belts: ITCZ (equator), mid-lat storms, polar
            let belt = 0.55 + 0.35 * cos(lat * 3.0) + 0.25 * cos(lat * 1.0)
            for x in 0..<w {
                let u = Double(x) / Double(w)
                let n = noise.sample(u * 6.0, v * 3.0)   // 0..1
                let density = smoothstep(0.45, 0.85, n * belt)
                let a = UInt8(min(255, Int(density * 235)))
                let idx = (y * w + x) * 4
                pixels[idx]     = 255
                pixels[idx + 1] = 255
                pixels[idx + 2] = 255
                pixels[idx + 3] = a
            }
        }
        return imageFromRGBA(pixels, width: w, height: h)
    }

    // MARK: Normal map from elevation

    private static func renderNormal(_ f: LandField) -> UIImage {
        let w = f.width, h = f.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let strength = 3.5
        for y in 0..<h {
            for x in 0..<w {
                let l = f.heightForNormal(x: (x - 1 + w) % w, y: y)
                let r = f.heightForNormal(x: (x + 1) % w, y: y)
                let u = f.heightForNormal(x: x, y: max(0, y - 1))
                let d = f.heightForNormal(x: x, y: min(h - 1, y + 1))
                let dx = (r - l) * strength
                let dy = (d - u) * strength
                var nx = -dx, ny = -dy, nz = 1.0
                let len = sqrt(nx * nx + ny * ny + nz * nz)
                nx /= len; ny /= len; nz /= len
                let idx = (y * w + x) * 4
                pixels[idx]     = UInt8((nx * 0.5 + 0.5) * 255)
                pixels[idx + 1] = UInt8((ny * 0.5 + 0.5) * 255)
                pixels[idx + 2] = UInt8((nz * 0.5 + 0.5) * 255)
                pixels[idx + 3] = 255
            }
        }
        return imageFromRGBA(pixels, width: w, height: h)
    }

    // MARK: Roughness — oceans smooth (shiny), land rough

    private static func renderRoughness(_ f: LandField) -> UIImage {
        let w = f.width, h = f.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let elev = f.elevation(x: x, y: y)
                let r: UInt8 = elev < 0 ? 40 : 220
                let idx = (y * w + x) * 4
                pixels[idx] = r; pixels[idx+1] = r; pixels[idx+2] = r; pixels[idx+3] = 255
            }
        }
        return imageFromRGBA(pixels, width: w, height: h)
    }
}

// MARK: - Land / elevation / moisture field
// Built from Earth-shaped continent seed ellipses so the silhouette reads as our planet,
// then perturbed by fBm noise for coastlines, rivers of moisture, and mountain detail.

private final class LandField {
    let width: Int
    let height: Int
    private let elev: [Double]      // -1..+1
    private let moist: [Double]     // 0..1

    init(width: Int, height: Int) {
        self.width = width
        self.height = height

        // Continent centers (u, v, ru, rv, weight) — u:0..1 longitude, v:0..1 latitude (0 north)
        // Tuned to match Earth's actual continental outline on an equirectangular map.
        let continents: [(Double, Double, Double, Double, Double)] = [
            // North America
            (0.19, 0.32, 0.11, 0.17, 1.0),
            (0.22, 0.20, 0.06, 0.07, 0.9),   // Canadian shield
            (0.17, 0.44, 0.05, 0.05, 0.7),   // Central America
            // South America
            (0.28, 0.62, 0.07, 0.14, 1.0),
            (0.24, 0.55, 0.05, 0.06, 0.8),
            // Europe
            (0.52, 0.28, 0.07, 0.08, 0.9),
            (0.49, 0.22, 0.04, 0.05, 0.7),   // Scandinavia
            // Africa
            (0.55, 0.48, 0.09, 0.17, 1.0),
            (0.54, 0.38, 0.07, 0.07, 0.9),   // North Africa
            // Middle East + Asia
            (0.60, 0.36, 0.05, 0.07, 0.8),
            (0.72, 0.28, 0.16, 0.16, 1.0),   // Asia mass
            (0.68, 0.42, 0.05, 0.09, 0.8),   // India
            (0.80, 0.45, 0.05, 0.06, 0.7),   // SE Asia
            // Indonesia archipelago
            (0.82, 0.52, 0.06, 0.03, 0.6),
            // Australia
            (0.83, 0.63, 0.08, 0.07, 0.95),
            // Greenland
            (0.35, 0.14, 0.04, 0.06, 0.8),
            // Antarctica (belt handled separately via latitude)
        ]

        let shape = FBMNoise(seed: 7,  octaves: 5, persistence: 0.55, lacunarity: 2.0)
        let detail = FBMNoise(seed: 21, octaves: 6, persistence: 0.5,  lacunarity: 2.2)
        let moistN = FBMNoise(seed: 42, octaves: 4, persistence: 0.55, lacunarity: 2.0)

        var e = [Double](repeating: -0.5, count: width * height)
        var m = [Double](repeating: 0.5,  count: width * height)

        for y in 0..<height {
            let v = Double(y) / Double(height - 1)
            let lat = (0.5 - v) * .pi
            for x in 0..<width {
                let u = Double(x) / Double(width)
                // Base continent field
                var base = -0.6
                for c in continents {
                    var du = u - c.0
                    if du > 0.5 { du -= 1 } else if du < -0.5 { du += 1 }
                    let dv = (v - c.1)
                    let d = (du * du) / (c.2 * c.2) + (dv * dv) / (c.3 * c.3)
                    let contrib = (1.0 - d) * c.4
                    if contrib > base { base = contrib }
                }

                // Antarctica belt
                if v > 0.90 {
                    base = max(base, 1.2 - (v - 0.90) * 2.0)
                }

                // Warp coastlines with noise
                let n = shape.sample(u * 4.0, v * 2.5) * 2.0 - 1.0   // -1..1
                let coast = base + n * 0.55

                // Mountain detail on land
                let mtn = detail.sample(u * 8.0, v * 4.5)
                var elev = coast
                if elev > 0 {
                    elev += (mtn - 0.5) * 0.6
                }
                elev = clamp(elev, -1.0, 1.0)

                // Moisture: base noise, boosted near equator & shorelines, reduced at desert latitudes
                var moist = moistN.sample(u * 3.5, v * 2.2)
                let desertBand = exp(-pow((abs(lat) - 0.45) / 0.18, 2.0))  // ~±25° latitude
                moist -= desertBand * 0.35
                let equator = exp(-pow(lat / 0.25, 2.0))
                moist += equator * 0.25
                moist = clamp(moist, 0.0, 1.0)

                let idx = y * width + x
                e[idx] = elev
                m[idx] = moist
            }
        }
        self.elev = e
        self.moist = m
    }

    @inline(__always) func elevation(x: Int, y: Int) -> Double { elev[y * width + x] }
    @inline(__always) func moisture(x: Int, y: Int)  -> Double { moist[y * width + x] }
    @inline(__always) func heightForNormal(x: Int, y: Int) -> Double {
        // Only land contributes to relief
        let e = elev[y * width + x]
        return e > 0 ? e : 0
    }
}

// MARK: - Noise (value-noise fBm, seeded, deterministic)

private final class FBMNoise {
    private let perm: [Int]
    private let octaves: Int
    private let persistence: Double
    private let lacunarity: Double

    init(seed: UInt64, octaves: Int, persistence: Double, lacunarity: Double) {
        var rng = SeededRNG(seed: seed)
        var p = Array(0..<256)
        for i in stride(from: 255, to: 0, by: -1) {
            let j = Int(rng.next() * Double(i + 1))
            p.swapAt(i, j)
        }
        self.perm = p + p
        self.octaves = octaves
        self.persistence = persistence
        self.lacunarity = lacunarity
    }

    /// Returns 0..1
    func sample(_ x: Double, _ y: Double) -> Double {
        var amp = 1.0, freq = 1.0, sum = 0.0, norm = 0.0
        for _ in 0..<octaves {
            sum += amp * value(x * freq, y * freq)
            norm += amp
            amp *= persistence
            freq *= lacunarity
        }
        return clamp(sum / norm, 0.0, 1.0)
    }

    private func value(_ x: Double, _ y: Double) -> Double {
        let xi = Int(floor(x)) & 255
        let yi = Int(floor(y)) & 255
        let xf = x - floor(x)
        let yf = y - floor(y)
        let u = fade(xf), v = fade(yf)
        let aa = Double(perm[perm[xi] + yi] & 255) / 255.0
        let ab = Double(perm[perm[xi] + yi + 1] & 255) / 255.0
        let ba = Double(perm[perm[xi + 1] + yi] & 255) / 255.0
        let bb = Double(perm[perm[xi + 1] + yi + 1] & 255) / 255.0
        let x1 = aa + u * (ba - aa)
        let x2 = ab + u * (bb - ab)
        return x1 + v * (x2 - x1)
    }

    @inline(__always) private func fade(_ t: Double) -> Double {
        t * t * t * (t * (t * 6 - 15) + 10)
    }
}

private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xDEADBEEF : seed }
    /// 0..1
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state & 0xFFFFFF) / Double(0x1000000)
    }
}

// MARK: - Math helpers

@inline(__always) private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(x, lo), hi)
}
@inline(__always) private func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double) -> SIMD3<Double> {
    a + (b - a) * t
}
@inline(__always) private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)
}
@inline(__always) private func rgb(_ c: SIMD3<Double>) -> (r: UInt8, g: UInt8, b: UInt8) {
    (UInt8(clamp(c.x, 0, 1) * 255),
     UInt8(clamp(c.y, 0, 1) * 255),
     UInt8(clamp(c.z, 0, 1) * 255))
}

// Tiny forward-pipe used above (Int -> UInt8 via a converter). Kept local.
precedencegroup ForwardApplication { associativity: left }
infix operator |> : ForwardApplication
@inline(__always) private func |> <A, B>(value: A, function: (A) -> B) -> B { function(value) }

// MARK: - RGBA buffer → UIImage

private func imageFromRGBA(_ pixels: [UInt8], width: Int, height: Int) -> UIImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
    var data = pixels
    guard let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData) else {
        return UIImage()
    }
    guard let cg = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ) else { return UIImage() }
    return UIImage(cgImage: cg)
}

// MARK: - EarthGlobeButton (SwiftUI wrapper)

struct EarthGlobeButton: View {
    let onTap: () -> Void

    var body: some View {
        EarthGlobeView(onTap: onTap)
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.30, green: 0.60, blue: 1.0).opacity(0.40),
                    radius: 10, y: 2)
            .contentShape(Circle())
    }
}
