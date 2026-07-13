import Combine
import RealityKit
import UIKit

extension DistrictEntry {
    /// Which `DistrictRealityScene.Mood` this district renders with — derived from `moodKey`
    /// in `CityManifest.json` rather than a hardcoded switch, so adding a new city/district
    /// with any mood requires no Swift changes.
    var mood: DistrictRealityScene.Mood {
        switch moodKey {
        case "colonialSquare":    return .colonialSquare
        case "skyscraperCorridor": return .skyscraperCorridor
        case "residentialDusk":   return .residentialDusk
        case "parkDaylight":      return .parkDaylight
        case "coastalPark":       return .coastalPark
        case "beachResort":       return .beachResort
        case "sacredSite":        return .sacredSite
        case "highlandMorning":   return .highlandMorning
        case "parisianCore":      return .parisianCore
        case "bordeauxWaterfront": return .bordeauxWaterfront
        case "rennesMedieval":    return .rennesMedieval
        case "londonSilver":      return .londonSilver
        case "madridAfternoon":   return .madridAfternoon
        case "romanGoldenHour":   return .romanGoldenHour
        case "vancouverCoastal":  return .vancouverCoastal
        case "sfMorning":         return .sfMorning
        case "nycDusk":           return .nycDusk
        default:                  return .parkDaylight
        }
    }
}

/// Lighting, sky/IBL, and camera rig for the RealityKit district scenes — shared by the orbit
/// inspector, the Simulator ground-level view, and (for lighting tuning, not placement) the
/// physical-device AR tabletop view. Kept separate from `DistrictRealityKit` (loading/materials)
/// so each file stays focused on one concern, matching the existing `SharedCityGeometry` split.
enum DistrictRealityScene {
    /// A deliberate lighting/camera "mood" per district, reflecting something real and specific
    /// about that place rather than one generic preset reused five times — addressing the brief's
    /// "each one must feel distinct" without inventing facts: a colonial square, a skyscraper
    /// corridor, a residential tower cluster, a diplomatic park, and a beachfront park really do
    /// call for different light and framing, the way a photographer would actually shoot each.
    enum Mood {
        case colonialSquare      // Kota Tua
        case skyscraperCorridor  // Bundaran HI / Sudirman-Thamrin
        case residentialDusk     // Kemang
        case parkDaylight        // Taman Suropati / Menteng
        case coastalPark         // Ancol
        case beachResort         // Bali (Seminyak, Kuta, Canggu)
        case sacredSite          // Yogyakarta (Malioboro, Kraton)
        case highlandMorning     // Bandung (Dago, Braga) — 700m highland, cool mist, morning light
        case parisianCore        // Paris (Le Marais, Saint-Germain, Montmartre) — overcast soft grey sky, limestone cream
        case bordeauxWaterfront  // Bordeaux (Vieux-Bordeaux, Chartrons) — golden hour Garonne riverside light
        case rennesMedieval      // Rennes (Vieux-Rennes, Thabor) — morning mist, slate-grey Breton sky
        case londonSilver        // City of London / London brick districts — cool overcast silver sky
        case madridAfternoon     // Madrid (Salamanca, Retiro) — warm golden afternoon, azotea rooftops
        case romanGoldenHour     // Rome (Centro Storico) — warm sienna-amber golden hour, sanpietrini cobbles
        case vancouverCoastal    // Vancouver (Downtown + West End) — Pacific NW diffuse overcast, Coal Harbour blue-grey
        case sfMorning           // San Francisco (Downtown + Fisherman's Wharf) — coastal morning, Karl the Fog
        case nycDusk             // New York (Midtown + Lower Manhattan) — late-afternoon canyon golden light

        var sunColor: UIColor {
            switch self {
            case .colonialSquare: UIColor(red: 1.0, green: 0.86, blue: 0.64, alpha: 1) // low golden-hour sun
            case .skyscraperCorridor: UIColor(red: 0.86, green: 0.91, blue: 1.0, alpha: 1) // cool high-rise daylight
            case .residentialDusk: UIColor(red: 1.0, green: 0.78, blue: 0.6, alpha: 1) // warm dusk
            case .parkDaylight: UIColor(red: 1.0, green: 0.98, blue: 0.92, alpha: 1) // clean midday
            case .coastalPark: UIColor(red: 1.0, green: 0.95, blue: 0.82, alpha: 1) // bright coastal sun
            case .beachResort: UIColor(red: 1.0, green: 0.92, blue: 0.72, alpha: 1) // warm tropical midday
            case .sacredSite: UIColor(red: 1.0, green: 0.88, blue: 0.65, alpha: 1)  // amber afternoon over stone
            case .highlandMorning: UIColor(red: 0.88, green: 0.92, blue: 1.0, alpha: 1) // cool Bandung highland morning
            case .parisianCore:    UIColor(red: 0.90, green: 0.90, blue: 0.94, alpha: 1) // cool pearl overcast Parisian light
            case .bordeauxWaterfront: UIColor(red: 1.0, green: 0.88, blue: 0.65, alpha: 1) // warm golden-hour Garonne light
            case .rennesMedieval:  UIColor(red: 0.95, green: 0.92, blue: 0.80, alpha: 1) // soft Breton morning gold
            case .londonSilver:    UIColor(red: 0.88, green: 0.90, blue: 0.95, alpha: 1) // cool silver London overcast
            case .madridAfternoon: UIColor(red: 1.0,  green: 0.84, blue: 0.55, alpha: 1) // warm Madrid afternoon gold
            case .romanGoldenHour: UIColor(red: 1.0,  green: 0.82, blue: 0.52, alpha: 1) // warm amber Roman afternoon
            case .vancouverCoastal: UIColor(red: 0.86, green: 0.92, blue: 0.98, alpha: 1) // cool Pacific NW diffuse — near-white sky through cloud cover
            case .sfMorning:       UIColor(red: 0.94, green: 0.90, blue: 0.82, alpha: 1) // warm coastal morning through marine layer
            case .nycDusk:         UIColor(red: 1.0,  green: 0.78, blue: 0.48, alpha: 1) // intense amber dusk — canyon light carving shadows between towers
            }
        }

        /// Real, physically-plausible lux values (direct sun is ~32,000–100,000 lux; these sit in
        /// a "bright but not high-noon" daylight band per mood), not the old SceneKit-carried-over
        /// values (2,400–6,000) this replaced. Those numbers read fine under SceneKit's renderer,
        /// which has no automatic baseline scene lighting to compete with — but RealityKit's
        /// `ARView` *does* contribute its own default neutral-studio illumination even with no
        /// custom `EnvironmentResource` set, and at the old SceneKit-scale intensities that default
        /// baseline completely dominated: the first on-device screenshot of this scene came back
        /// flatly, evenly lit with no visible shadow and barely any night/day difference. Lux-scale
        /// intensity is what actually lets these lights — and their shadows — read as dominant.
        var sunIntensity: Float {
            switch self {
            case .colonialSquare: 28000
            case .skyscraperCorridor: 45000
            case .residentialDusk: 22000
            case .parkDaylight: 50000
            case .coastalPark: 55000
            case .beachResort: 35000  // bright tropical sun — reduced from 60000 which bleached balinese stone to white
            case .sacredSite: 30000   // golden late-afternoon over temple stone
            case .highlandMorning: 20000  // highland overcast — diffuse, soft, not dominant
            case .parisianCore:    22000  // overcast Parisian sky — bright but diffuse, no harsh shadows
            case .bordeauxWaterfront: 30000 // golden-hour Garonne riverfront — warm and strong
            case .rennesMedieval:  25000  // morning mist softens but doesn't kill the Breton sun
            case .londonSilver:    26000  // overcast but bright London sky — diffuse, moderate intensity
            case .madridAfternoon: 38000  // intense Iberian afternoon sun — strong enough for crisp azotea shadows
            case .romanGoldenHour: 32000  // warm afternoon Roman light — lower than Madrid, more diffuse
            case .vancouverCoastal: 24000  // Pacific NW overcast — bright diffuse cloud layer, no harsh shadows
            case .sfMorning:       28000  // coastal morning — sun cutting through marine layer, moderate contrast
            case .nycDusk:         36000  // intense low-angle dusk — strong enough to carve canyon shadows
            }
        }

        /// Sun elevation as a fraction of the orbit distance (low = long dramatic shadows, high =
        /// overhead midday) — paired with `sunColor`/`sunIntensity` per mood above.
        var sunElevationFraction: Float {
            switch self {
            case .colonialSquare: 0.35
            case .skyscraperCorridor: 0.75
            case .residentialDusk: 0.25
            case .parkDaylight: 0.85
            case .coastalPark: 0.7
            case .beachResort: 0.80  // near-overhead equatorial sun, short shadows
            case .sacredSite: 0.38   // low angle, long dramatic shadows across temple courts
            case .highlandMorning: 0.42   // soft morning angle — highland mist diffuses harsh shadows
            case .parisianCore:    0.55   // high sun through overcast — diffuse, minimal shadow angle
            case .bordeauxWaterfront: 0.40 // golden-hour angle — moderate elevation, long warm shadows
            case .rennesMedieval:  0.38   // low morning sun — long shadows across half-timber facades
            case .londonSilver:    0.45   // moderate overcast elevation — diffuse, no dramatic shadows
            case .madridAfternoon: 0.38   // classic Madrid late-afternoon angle — long warm shadows
            case .romanGoldenHour: 0.32   // low golden-hour angle — maximises cobblestone texture relief
            case .vancouverCoastal: 0.42   // moderate Pacific NW elevation — cloud diffusion softens shadows
            case .sfMorning:       0.40   // coastal morning angle — moderate elevation through fog
            case .nycDusk:         0.28   // very low — maximises tower shadow depth between canyon streets
            }
        }

        /// Sky gradient fed to `EnvironmentResource.generate(fromEquirectangular:)` for ambient/
        /// fill light and reflections — RealityKit has no flat "ambient light" component the way
        /// SceneKit does; real ambient comes from the sky, so this is the actual mechanism, not a
        /// cosmetic backdrop.
        var skyColors: (zenith: UIColor, horizon: UIColor, ground: UIColor) {
            switch self {
            case .colonialSquare:
                (UIColor(red: 0.55, green: 0.6, blue: 0.75, alpha: 1), UIColor(red: 0.95, green: 0.78, blue: 0.55, alpha: 1), UIColor(white: 0.2, alpha: 1))
            case .skyscraperCorridor:
                // Deep Jakarta urban sky — dark blue zenith, haze-grey horizon (NOT bright blue-white
                // which was visible as a large teal wash between towers), dark grey ground.
                (UIColor(red: 0.12, green: 0.22, blue: 0.48, alpha: 1), UIColor(red: 0.46, green: 0.54, blue: 0.72, alpha: 1), UIColor(white: 0.18, alpha: 1))
            case .residentialDusk:
                (UIColor(red: 0.3, green: 0.28, blue: 0.45, alpha: 1), UIColor(red: 0.95, green: 0.62, blue: 0.45, alpha: 1), UIColor(white: 0.15, alpha: 1))
            case .parkDaylight:
                (UIColor(red: 0.4, green: 0.65, blue: 0.92, alpha: 1), UIColor(red: 0.88, green: 0.93, blue: 0.97, alpha: 1), UIColor(white: 0.3, alpha: 1))
            case .coastalPark:
                (UIColor(red: 0.42, green: 0.68, blue: 0.9, alpha: 1), UIColor(red: 0.97, green: 0.9, blue: 0.78, alpha: 1), UIColor(white: 0.35, alpha: 1))
            case .beachResort:
                // Tropical blue above, warm golden horizon haze, sandy earth ground.
                // Horizon pushed to warm amber-gold (was near-white 0.96/0.92/0.80 — looked
                // grey-ish in contrast to saturated orange balinese rooftops). Zenith kept
                // slightly de-saturated (red=0.38 not 0.28) so the fill light doesn't cast
                // a harsh blue-grey onto balinese stone walls.
                (UIColor(red: 0.38, green: 0.62, blue: 0.90, alpha: 1), UIColor(red: 0.92, green: 0.78, blue: 0.52, alpha: 1), UIColor(red: 0.80, green: 0.65, blue: 0.42, alpha: 1))
            case .sacredSite:
                // Muted dusty zenith, amber horizon, dark volcanic earth ground
                (UIColor(red: 0.48, green: 0.52, blue: 0.70, alpha: 1), UIColor(red: 0.98, green: 0.82, blue: 0.58, alpha: 1), UIColor(red: 0.22, green: 0.19, blue: 0.16, alpha: 1))
            case .highlandMorning:
                // Blue-grey highland sky, pale misty horizon, cool earth ground — Bandung at 700m
                (UIColor(red: 0.48, green: 0.58, blue: 0.78, alpha: 1), UIColor(red: 0.82, green: 0.86, blue: 0.92, alpha: 1), UIColor(red: 0.30, green: 0.28, blue: 0.26, alpha: 1))
            case .parisianCore:
                // Pearl-grey Parisian sky — blue-grey zenith, pale silver horizon, warm limestone ground
                (UIColor(red: 0.52, green: 0.58, blue: 0.70, alpha: 1), UIColor(red: 0.78, green: 0.80, blue: 0.84, alpha: 1), UIColor(red: 0.32, green: 0.30, blue: 0.28, alpha: 1))
            case .bordeauxWaterfront:
                // Warm golden-hour sky — blue zenith, golden horizon (Garonne reflection), sandy ground
                (UIColor(red: 0.42, green: 0.58, blue: 0.82, alpha: 1), UIColor(red: 0.98, green: 0.82, blue: 0.52, alpha: 1), UIColor(red: 0.55, green: 0.45, blue: 0.32, alpha: 1))
            case .rennesMedieval:
                // Morning mist — slate-grey zenith, pale misty horizon, dark Breton granite ground
                (UIColor(red: 0.54, green: 0.60, blue: 0.72, alpha: 1), UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1), UIColor(red: 0.28, green: 0.26, blue: 0.24, alpha: 1))
            case .londonSilver:
                // Cool silver-grey London overcast — muted blue zenith, pale silver horizon, dark wet tarmac ground
                (UIColor(red: 0.44, green: 0.52, blue: 0.68, alpha: 1), UIColor(red: 0.72, green: 0.76, blue: 0.82, alpha: 1), UIColor(red: 0.30, green: 0.28, blue: 0.26, alpha: 1))
            case .madridAfternoon:
                // Intense Iberian afternoon — deep blue zenith, golden-amber horizon, warm sandstone ground
                (UIColor(red: 0.38, green: 0.55, blue: 0.85, alpha: 1), UIColor(red: 0.88, green: 0.75, blue: 0.52, alpha: 1), UIColor(red: 0.45, green: 0.38, blue: 0.28, alpha: 1))
            case .romanGoldenHour:
                // Roman golden hour — deep blue zenith, amber-gold horizon (sundown over the Tiber), warm ochre earth
                (UIColor(red: 0.38, green: 0.50, blue: 0.78, alpha: 1), UIColor(red: 0.92, green: 0.76, blue: 0.52, alpha: 1), UIColor(red: 0.38, green: 0.30, blue: 0.22, alpha: 1))
            case .vancouverCoastal:
                // Pacific NW overcast — muted blue-grey zenith, pale coastal haze horizon, dark concrete/glass ground.
                // Cooler and more desaturated than London's silver — Pacific atmosphere has a slight blue-green cast
                // from ocean spray and Douglas fir forests at the tree-line behind the glass towers.
                (UIColor(red: 0.28, green: 0.42, blue: 0.64, alpha: 1), UIColor(red: 0.64, green: 0.74, blue: 0.84, alpha: 1), UIColor(red: 0.20, green: 0.22, blue: 0.24, alpha: 1))
            case .sfMorning:
                // Karl the Fog morning — deep coastal blue zenith, flat white-grey fog horizon that the sun
                // hasn't yet burned off, warm medium-grey SF concrete ground. The flat horizon is the key
                // visual signature: SF's morning sky terminates at an almost featureless grey-white band.
                (UIColor(red: 0.26, green: 0.36, blue: 0.60, alpha: 1), UIColor(red: 0.70, green: 0.72, blue: 0.74, alpha: 1), UIColor(red: 0.32, green: 0.30, blue: 0.28, alpha: 1))
            case .nycDusk:
                // Manhattan dusk — deep navy-purple zenith (city sky before the last light drains),
                // warm amber-orange horizon glow (the sun just past the horizon line over New Jersey),
                // very dark asphalt ground.
                (UIColor(red: 0.16, green: 0.22, blue: 0.48, alpha: 1), UIColor(red: 0.72, green: 0.54, blue: 0.32, alpha: 1), UIColor(red: 0.20, green: 0.18, blue: 0.16, alpha: 1))
            }
        }

        /// Camera distance/height as fractions of the district's real extent — same self-scaling
        /// idea as `DistrictScene3DView`'s old orbit math, but distinct per mood: the skyscraper
        /// corridor wants a steep upward angle to sell height, the park wants a lower, wider,
        /// almost-eye-level establishing view.
        var cameraDistanceFraction: Float {
            switch self {
            case .colonialSquare: 0.20   // pulled back from 0.14 — tighter value left buildings off-top
            case .skyscraperCorridor: 0.2
            case .residentialDusk: 0.16
            case .parkDaylight: 0.22
            case .coastalPark: 0.24
            case .beachResort: 0.20
            case .sacredSite: 0.18
            case .highlandMorning: 0.18  // similar to sacredSite — tight framing for dense Braga blocks
            case .parisianCore:    0.16  // Haussmann blocks are dense, pull in tighter
            case .bordeauxWaterfront: 0.18 // riverfront needs a little extra breathing room
            case .rennesMedieval:  0.16  // compact medieval fabric — tight like colonialSquare
            case .londonSilver:    0.18  // City of London — mix of medieval lanes and glass towers, slightly looser framing
            case .madridAfternoon: 0.18  // Ensanche grid — regular blocks, standard pull-back
            case .romanGoldenHour: 0.18  // Centro Storico irregular fabric — needs slight breathing room
            case .vancouverCoastal: 0.16  // Vancouver Downtown glass towers are dense — tight like Paris
            case .sfMorning:       0.16  // SF Financial District — similar density to Vancouver
            case .nycDusk:         0.18  // NYC Midtown/Lower Manhattan — slight extra breathing room for skyline silhouette
            }
        }

        var cameraHeightFraction: Float {
            switch self {
            case .colonialSquare: 0.12   // raised from 0.08 — better oblique angle over low colonial rooftops
            case .skyscraperCorridor: 0.16
            case .residentialDusk: 0.1
            case .parkDaylight: 0.07
            case .coastalPark: 0.09
            case .beachResort: 0.14
            case .sacredSite: 0.09
            case .highlandMorning: 0.13  // slightly elevated for highland downward angle
            case .parisianCore:    0.14  // elevated to show mansard rooftops — the defining aerial detail
            case .bordeauxWaterfront: 0.12 // lower angle to read the riverfront facade from water level
            case .rennesMedieval:  0.13  // slightly elevated — reads the steep medieval pitched roofscape
            case .londonSilver:    0.13  // moderate elevation — reads both Victorian rooflines and glass tower tops
            case .madridAfternoon: 0.12  // flatter azotea roofs — lower elevation to read the facade rhythm
            case .romanGoldenHour: 0.13  // slightly elevated — reads orange canal-tile rooftops across the Forum area
            case .vancouverCoastal: 0.14  // moderate elevation — reads Coal Harbour glass towers from above the waterline
            case .sfMorning:       0.16  // elevated — reads SF's varied terrain (Nob Hill silhouette behind FiDi towers)
            case .nycDusk:         0.16  // elevated — reads the setback skyscraper silhouette from outside the street canyon
            }
        }

        var fieldOfViewDegrees: Float {
            switch self {
            case .skyscraperCorridor, .nycDusk: 50  // wide FOV to maximise vertical tower impact in dense skylines
            default: 42
            }
        }
    }

    // MARK: - Lighting + sky

    /// Installs a sun (real-time shadow-casting `DirectionalLight`) plus a soft, mood-tinted fill
    /// light standing in for full image-based sky lighting onto `arView`. `isNight` dims the sun
    /// toward moonlight and the fill toward a cool dark tone, the RealityKit equivalent of the old
    /// `DistrictScene3DView.applyAtmosphere`'s day/night light swap. **Removes any previously
    /// installed sun/fill lights first** — every call used to just add two more `Entity`s without
    /// removing the old pair, so toggling night mode back and forth silently accumulated lights
    /// (a real perf leak) with the *old* lights still fully active underneath the new ones. That
    /// bug is also most of why the day/night contrast looked muted in the original investigation
    /// below: the comparison was never actually isolating one lighting state, it was layering
    /// every state ever installed on top of each other.
    ///
    /// **Still a real, separate limitation**: a *custom* `EnvironmentResource` (true equirectangular
    /// sky IBL — reflections, sky-colored ambient) needs iOS 18+ on both its current
    /// (`init(equirectangular:)`) and deprecated (`generate(fromEquirectangular:)`) forms —
    /// confirmed by trying both against this project's iOS 17.0 target. That's the same constraint
    /// that already ruled out RealityKit's `LowLevelMesh` (see CLAUDE.md), just hitting a second
    /// RealityKit API. This fill light is the practical substitute: it does not give PBR materials
    /// real reflections of a sky, only directional ambient fill. Revisit if the deployment target
    /// ever moves to 18+. `intensityExponent` (an EV-style stop count, base-2, default 0) is dialed
    /// down regardless, in case it has any effect on `ARView`'s non-removable default environment.
    /// Cache of 1×32 sky gradient textures, keyed by "colonialSquare_false" etc. Generated once
    /// per (mood, isNight) pair and reused — the gradient never changes between same-mood views.
    private static var skyGradientCache: [String: TextureResource] = [:]

    /// 1×32 vertical gradient: zenith at top (UV.y = 1, camera looking up), horizon at middle,
    /// ground at bottom. Applied to an inside-out sphere (`scale.x = -1` flips normals) so the
    /// gradient wraps the entire scene as an atmospheric sky backdrop rather than the flat single-
    /// color `background = .color(...)` this replaces. The texture upload is deferred to a
    /// `Task { @MainActor }` so the sync half of `installLighting` (lights + solid-color dome)
    /// commits on the same frame the function is called.
    @MainActor
    private static func makeSkyGradient(mood: Mood, isNight: Bool) -> TextureResource? {
        // TextureResource.generate is @MainActor — only call from within Task { @MainActor in }
        let height = 32, width = 1
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let zenith = isNight ? UIColor(red: 0.03, green: 0.04, blue: 0.10, alpha: 1) : mood.skyColors.zenith
        let horizon = isNight ? UIColor(red: 0.07, green: 0.08, blue: 0.16, alpha: 1) : mood.skyColors.horizon
        let ground  = isNight ? UIColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1) : mood.skyColors.ground
        for y in 0..<height {
            let t = Float(y) / Float(height - 1)  // 0 = south pole (down), 1 = north pole (up)
            // Split: 0→0.4 = ground→horizon, 0.4→1.0 = horizon→zenith
            var rR: CGFloat=0, rG: CGFloat=0, rB: CGFloat=0
            if t < 0.4 {
                let s = t / 0.4
                let smooth = s * s * (3 - 2 * s)
                var gR: CGFloat=0, gG: CGFloat=0, gB: CGFloat=0
                var hR: CGFloat=0, hG: CGFloat=0, hB: CGFloat=0
                ground.getRed(&gR, green: &gG, blue: &gB, alpha: nil)
                horizon.getRed(&hR, green: &hG, blue: &hB, alpha: nil)
                let f = CGFloat(smooth)
                rR = gR + f * (hR - gR); rG = gG + f * (hG - gG); rB = gB + f * (hB - gB)
            } else {
                let s = (t - 0.4) / 0.6
                let smooth = s * s * (3 - 2 * s)
                var hR: CGFloat=0, hG: CGFloat=0, hB: CGFloat=0
                var zR: CGFloat=0, zG: CGFloat=0, zB: CGFloat=0
                horizon.getRed(&hR, green: &hG, blue: &hB, alpha: nil)
                zenith.getRed(&zR, green: &zG, blue: &zB, alpha: nil)
                let f = CGFloat(smooth)
                rR = hR + f * (zR - hR); rG = hG + f * (zG - hG); rB = hB + f * (zB - hB)
            }
            let i = y * width * 4
            pixels[i] = UInt8(max(0, min(1, rR)) * 255)
            pixels[i+1] = UInt8(max(0, min(1, rG)) * 255)
            pixels[i+2] = UInt8(max(0, min(1, rB)) * 255)
            pixels[i+3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: cs,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource.generate(from: cg, withName: "sky_\(mood)_\(isNight)",
                                             options: .init(semantic: .hdrColor))
    }

    static func installLighting(in arView: ARView, anchor: AnchorEntity, mood: Mood, extent: Float, isNight: Bool) {
        anchor.children.filter { ["sun", "fill", "fill2", "skyDome"].contains($0.name) }.forEach { $0.removeFromParent() }
        arView.environment.lighting.intensityExponent = isNight ? -5 : -2

        let sun = Entity()
        sun.name = "sun"
        // Night isn't literal moonlight (~0.1–1 lux) — a real city block at night has street
        // lighting and light pollution; ~60–90 lux reads as "dark but not pitch black", the same
        // intent as the old SceneKit night-mode key light, just recalibrated to RealityKit's scale.
        let sunColor = isNight ? UIColor(red: 0.55, green: 0.62, blue: 0.95, alpha: 1) : mood.sunColor
        let sunIntensity: Float = isNight ? 70 : mood.sunIntensity
        let sunComponent = DirectionalLightComponent(color: sunColor, intensity: sunIntensity)
        sun.components[DirectionalLightComponent.self] = sunComponent
        // depthBias 0.35 — tight enough to avoid shadow acne at grazing angles on flat
        // ground quads, loose enough that the shadow edge visibly starts at the building
        // footprint rather than 1–2m away (the old 1.5 was too aggressive and hid contact
        // shadows entirely on low-rise colonial buildings).
        // maximumDistance extent×1.2 — covers the full building cluster with a 20% margin;
        // the old ×2.2 spread the fixed shadow-map budget over too much area, producing
        // visible diagonal aliasing bands on large flat horizontal surfaces (green zones).
        sun.components[DirectionalLightComponent.Shadow.self] = .init(maximumDistance: extent * 1.2, depthBias: 0.35)
        let sunHeight = extent * (0.4 + mood.sunElevationFraction)
        sun.look(at: .zero, from: SIMD3(extent * 0.3, sunHeight, extent * 0.3), relativeTo: nil)
        anchor.addChild(sun)

        let fill = Entity()
        fill.name = "fill"
        // Fill light color follows the sky zenith for most moods. `skyscraperCorridor` is the
        // exception: its zenith (0.35, 0.55, 0.85) is intentionally extreme for a dramatic blue-sky
        // backdrop, but used as a fill light it over-saturates ground, road and green-zone surfaces
        // with deep blue. Desaturated to (0.68, 0.78, 0.96) here — still clearly blue but blue:red
        // ratio drops from 2.4:1 to 1.41:1, in line with colonialSquare's 1.36:1 fill balance.
        let fillColor: UIColor
        if isNight {
            fillColor = UIColor(red: 0.1, green: 0.13, blue: 0.25, alpha: 1)
        } else if mood == .skyscraperCorridor {
            // Warm city-glow bounce — creates orange-and-teal contrast (Blade Runner aesthetic)
            // instead of adding more blue-teal onto already-blue metallic glass surfaces.
            fillColor = UIColor(red: 0.85, green: 0.72, blue: 0.52, alpha: 1)
        } else {
            fillColor = mood.skyColors.zenith
        }
        let fillIntensity: Float = isNight ? 25 : mood.sunIntensity * 0.18
        fill.components[DirectionalLightComponent.self] = DirectionalLightComponent(color: fillColor, intensity: fillIntensity)
        fill.look(at: .zero, from: SIMD3(-extent * 0.4, extent * 0.5, -extent * 0.2), relativeTo: nil)
        anchor.addChild(fill)

        // Forward fill: a weak third light from the +z front arc ensures that faces pointing toward
        // the viewer at angle=0 (and any face not directly illuminated by sun or fill) receive at
        // least some bounce light. Without it, high-metallic (modernGlass) wall faces perpendicular
        // to both sun and fill directions render as nearly-black panels — especially visible on large
        // commercial/hotel buildings in Malioboro/Braga where the wall area dominates the scene.
        let fill2 = Entity()
        fill2.name = "fill2"
        let fill2Intensity: Float = isNight ? 8 : mood.sunIntensity * 0.09
        fill2.components[DirectionalLightComponent.self] = DirectionalLightComponent(color: fillColor, intensity: fill2Intensity)
        fill2.look(at: .zero, from: SIMD3(extent * 0.1, extent * 0.35, extent * 0.6), relativeTo: nil)
        anchor.addChild(fill2)

        // Sky dome: large inside-out sphere (scale.x = -1 flips normals to face inward) used as
        // an atmospheric sky backdrop. Background is set to .black so only the dome geometry is
        // visible where no buildings or roads cover it. A gradient texture is applied asynchronously
        // on the next main-actor turn so this sync call commits lights+dome immediately; the texture
        // pop-in is imperceptible since the dome fills at once — only the gradient vs. solid color
        // changes. TextureResource.generate is @MainActor so it must stay inside the Task.
        let domeRadius = extent * 4
        let domeMesh = MeshResource.generateSphere(radius: domeRadius)
        let fallback = isNight ? UIColor(red: 0.04, green: 0.04, blue: 0.10, alpha: 1) : mood.skyColors.horizon
        let domeMaterial = UnlitMaterial(color: fallback)
        let dome = ModelEntity(mesh: domeMesh, materials: [domeMaterial])
        dome.name = "skyDome"
        dome.scale = SIMD3(-1, 1, 1)
        anchor.addChild(dome)
        arView.environment.background = .color(.black)

        Task { @MainActor [weak dome] in
            let cacheKey = "\(mood)_\(isNight)"
            let gradTex: TextureResource
            if let cached = skyGradientCache[cacheKey] {
                gradTex = cached
            } else if let fresh = makeSkyGradient(mood: mood, isNight: isNight) {
                skyGradientCache[cacheKey] = fresh
                gradTex = fresh
            } else { return }

            guard let dome else { return }
            var upgraded = UnlitMaterial(color: .white)
            upgraded.color = .init(tint: .white, texture: .init(gradTex))
            dome.model?.materials = [upgraded]
        }
    }

    // MARK: - Camera

    /// Continuous slow orbit, driven by a per-frame scene subscription rather than chained finite
    /// animations — the RealityKit-idiomatic way to get smooth indefinite rotation (mirrors what
    /// `SCNAction.rotateBy(...).repeatForever` did on the SceneKit side). Returns the
    /// `Cancellable` so the caller can stop it outright (auto-rotate toggled off, or the view
    /// tears down) — but deliberately should **not** need to cancel-and-restart this just to
    /// change speed: `rotationSpeed` is a closure, polled fresh every frame, and the angle is
    /// accumulated incrementally from the *delta* time since the last frame rather than computed
    /// from total-elapsed-time-times-current-speed. That avoids two real problems the original
    /// version had: (1) restarting the subscription on every speed change reset the camera to
    /// angle zero — a visible jump on every tick of a slider drag, since `DistrictRealityView`
    /// used to call this on every `updateUIView`, not just on a real auto-rotate toggle; (2) even
    /// without a restart, `elapsed * newSpeed` would have made the angle *jump* discontinuously the
    /// instant speed changed (multiplying a large elapsed-time by a different rate), rather than
    /// smoothly accelerating/decelerating from wherever the camera already was.
    static func startOrbit(
        camera: Entity,
        scene: RealityKit.Scene,
        center: SIMD3<Float>,
        distance: Float,
        height: Float,
        rotationSpeed: @escaping () -> Double
    ) -> Cancellable {
        var lastFrameDate = Date()
        var angle: Float = 0
        var frameCount = 0
        return scene.subscribe(to: SceneEvents.Update.self) { _ in
            // Throttle to 30 fps: the camera moves smoothly enough, and halving the
            // subscription's work is the cheapest GPU/CPU saving on a hot-path that fires
            // every display-link tick. `lastFrameDate` is only updated on execute frames so
            // the delta naturally spans 2 display frames (~33ms at 60Hz).
            frameCount += 1
            guard frameCount & 1 == 0 else { return }
            let now = Date()
            let delta = Float(now.timeIntervalSince(lastFrameDate))
            lastFrameDate = now
            angle += delta * Float(rotationSpeed()) * 0.3
            let position = SIMD3(
                center.x + distance * cos(angle),
                center.y + height,
                center.z + distance * sin(angle)
            )
            camera.look(at: center, from: position, relativeTo: nil)
        }
    }

    // MARK: - Focus building beacon

    /// A glowing beacon plus 3D text above the focus building — visible from across the district
    /// so the user can orient toward it. Shared by the ground-level Simulator view and the
    /// physical-device AR tabletop view; the orbit inspector doesn't need it (the camera already
    /// centers there directly). Static, not pulsing, and not billboarded: `BillboardComponent` and
    /// `MeshResource.generateCylinder` are both iOS 18+-only (confirmed by trying them against
    /// this project's iOS 17.0 target — a third and fourth instance of that same recurring
    /// constraint, see CLAUDE.md). A thin box stands in for the cylinder; the text faces `facing`
    /// (the viewer's known approximate position when the scene is set up) once, rather than
    /// continuously tracking the camera.
    static func makeFocusBeacon(for building: BuildingFootprint, districtExtent: Float, facing: SIMD3<Float> = SIMD3(0, 0, 1)) -> Entity {
        let group = Entity()
        let xs = building.polygon.map(\.x)
        let zs = building.polygon.map(\.z)
        let centroidX = xs.reduce(0, +) / Float(xs.count)
        let centroidZ = zs.reduce(0, +) / Float(zs.count)

        let beaconHeight = max(building.heightMeters * 0.6, districtExtent * 0.03)
        let beaconWidth = districtExtent * 0.008
        var beaconMaterial = PhysicallyBasedMaterial()
        beaconMaterial.baseColor = .init(tint: .white)
        beaconMaterial.emissiveColor = .init(color: UIColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1))
        beaconMaterial.emissiveIntensity = 4
        let beaconMesh = MeshResource.generateBox(width: beaconWidth, height: beaconHeight, depth: beaconWidth)
        let beacon = ModelEntity(mesh: beaconMesh, materials: [beaconMaterial])
        beacon.position = SIMD3(centroidX, building.heightMeters + beaconHeight / 2 + districtExtent * 0.015, centroidZ)
        group.addChild(beacon)

        let textMesh = MeshResource.generateText(
            building.name ?? "Focus",
            extrusionDepth: 0.05,
            font: .systemFont(ofSize: 3, weight: .semibold)
        )
        let textMaterial = UnlitMaterial(color: .white)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        textEntity.position = SIMD3(centroidX, building.heightMeters + beaconHeight + districtExtent * 0.02, centroidZ)
        textEntity.look(at: textEntity.position + facing, from: textEntity.position, relativeTo: nil)
        group.addChild(textEntity)

        return group
    }
}
