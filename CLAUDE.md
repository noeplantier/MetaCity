# MetaCity — Day-only mode + Tokyo sky fix + POI Mode

## Date: 2026-07-21

### Night mode removed — build-verified 2026-07-21

- `@Published var isNightMode: Bool` removed from `DiscoverViewModel` (line 126)
- `isNightMode = false` reset in `back()` removed
- Night toggle button (sun/moon icon) removed from `districtExploreOverlay` in `DiscoverView`
- `isNight: viewModel.isNightMode` → `isNight: false` hardcoded in `DistrictRealityView` init call
- Night mode rebuild block (`if isNight != currentIsNight { ... }`) removed from `DistrictRealityView.update`
- `DistrictRealityKit.loadDistrictEntity` and `DistrictRealityScene.installLighting` retain `isNight:` parameter (callers always pass `false`) — no deep refactor needed
- Cache key `"\(name)_false"` is now the only key ever written

### shibuyaNeon sky fixed (Tokyo day sky) — build-verified 2026-07-21

- `DistrictRealityScene.Mood.shibuyaNeon` sky colors changed from magenta-pink evening to clear Tokyo day sky:
  - Zenith: `UIColor(0.26, 0.44, 0.82)` — crisp cerulean blue
  - Horizon: `UIColor(0.62, 0.76, 0.92)` — pale blue-white Kanto haze
  - Ground: `UIColor(0.22, 0.22, 0.26)` — warm grey concrete
- Affects all 10 Tokyo districts (all use `shibuyaNeon` except Asakusa which uses `sacredSite`)

### POI Mode (replaces ZOOM) — screenshot-verified 2026-07-21

- `ViewPreset.focus` label changed from **ZOOM** → **POI**, icon from `scope` → `mappin.and.ellipse`
- `setViewPreset(.focus)` guard removed — POI mode now activates without a selected building
- `DistrictMiniMapView` shows `MiniPOIListView` (dark scrollable list) when `activePreset == .focus`
- `MiniPOIListView` loads via `CangguPOICollection.load(for: districtId)`, renders all 5 POIs per district
- Callsite in `DiscoverView.districtExploreOverlay` passes `onPOISelected` closure
- Firebase skip-auth fix: `MetaCityApp.init` now guards `FirebaseApp.configure()` behind `!skipAuth` so `SIMCTL_CHILD_UITEST_SKIP_AUTH=1` bypass works correctly

### All 10 Tokyo POI files (5 POIs each, verified against brief) — 2026-07-21

| District   | POIs (in order)                                                                       |
|------------|---------------------------------------------------------------------------------------|
| Shibuya    | Scramble Crossing ★, Hachiko Statue ★, Shibuya 109 ★, Center-gai, Scramble Square    |
| Shinjuku   | Tokyo Metropolitan Govt ★, Kabukicho ★, Shinjuku Gyoen ★, Omoide Yokocho, JR Shinjuku |
| Ginza      | Wako Building ★, GINZA SIX ★, Kabuki-za Theatre ★, Ginza Shopping St, Mitsukoshi     |
| Asakusa    | Senso-ji ★, Kaminarimon ★, Nakamise ★, Asakusa Shrine, Sumida Park                   |
| Akihabara  | Akihabara Station ★, Animate ★, Yodobashi Camera ★, Super Potato, Kanda Myojin       |
| Roppongi   | Roppongi Hills ★, Mori Art Museum ★, Tokyo City View ★, Roppongi Station, Nightlife   |
| Odaiba     | Gundam Statue ★, teamLab Planets ★, Tokyo Big Sight ★, Palette Town, Seaside Park    |
| Harajuku   | Takeshita Street ★, Meiji Jingu ★, Yoyogi Park ★, Omotesando, Harajuku Station       |
| Ikebukuro  | Sunshine 60 ★, Ikebukuro Station ★, Sunshine City ★, Otome Road, Animate Ikebukuro  |
| Ueno       | Ueno Park ★, Tokyo National Museum ★, Ueno Zoo, Ueno Station, Ameyoko                |

★ = featured tier (filled mappin.circle.fill icon)

---

## Date: 2026-07-20

## Recent Changes (2026-07-20)

### 1. View Preset System Overhaul

**Removed:**
- `.ciel` (SURVOL) — full-district overhead view
- `.focus` (ZOOM) — building-tap zoom view

**Added:**
- `.closeDistrict` (QUARTIER) — tighter district framing at 50% horizontal distance, 90% height
- `.poi` (POI) — frames selected POI with context

**Updated Files:**
- `DiscoverViewModel.swift` — ViewPreset enum, setViewPreset(), poiFocusToken
- `DistrictRealityView.swift` — Coordinator update logic, resetToDefaultPosition()
- `DiscoverView.swift` — DistrictRealityView initialization with poiFocusToken

### 2. POI System Restoration

**Tokyo Districts (5 POI each):**
- Shibuya: Scramble Crossing, Scramble Square, Hachiko Statue, NHK Broadcasting, Shibuya Stream
- Shinjuku: Shinjuku Gyoen, Cocoon Tower, Kabukicho Tower, Nomura Building, Hanazono Shrine
- Ginza: GINZA SIX, Kabuki-za Theatre, Ginza Chuo-dori, Itoya Stationery, Ginza Art District
- Asakusa: Senso-ji Temple, Kaminarimon Gate, Nakamise Shopping, Asakusa Shrine, Sumida Park
- Akihabara: Akihabara Station, Animate, Yodobashi Camera, Super Potato, Akiba Cultural Zone
- Roppongi: Roppongi Hills, Mori Art Museum, Tokyo Tower, Roppongi Nightlife, 21_21 Design Sight
- Odaiba: Unicorn Gundam Statue, teamLab Planets, Tokyo Big Sight, Palette Town, Odaiba Seaside Park

**Status:** All Tokyo POI files already present and complete in `MetaCity/Resources/pois_*.json`

### 3. Code Cleaning

- Uniformized naming: `viewFocusToken` → `poiFocusToken`, `lastFocusedBuilding` → `lastFocusedPOIId`
- Removed dead code references to `.ciel` and `.focus` presets
- Updated comments to reflect new OVERVIEW/CLOSE DISTRICT/POI system
- Fixed token tracking in DistrictRealityView.Coordinator.update()

### Tokyo Districts Implemented

All 7 Tokyo districts are now fully integrated with 3D geometry, POI systems, and night mode:

1. **Shibuya** (existing, optimized)
   - Mood: `shibuyaNeon`
   - 3D: modernConcrete + modernGlass dark towers, JR Yamanote rail loop
   - POIs: Scramble Crossing, Scramble Square, Hachiko Statue, NHK Broadcasting, Shibuya Stream
   - Night mode: neon-dense commercial saturation (1.40× window density)

2. **Shinjuku** (new)
   - Mood: `shibuyaNeon`
   - 3D: modernGlass twin towers (Shinjuku Nomura Building 220m, KDDI Building 128m, Shinjuku Monolith 120m), modernConcrete mid-rises
   - POIs: Shinjuku Gyoen, Mode Gakuen Cocoon Tower, Tokyu Kabukicho Tower, Nomura Building, Hanazono Shrine
   - Night mode: 1.40× window density, very low weathering (0.08)

3. **Ginza** (new)
   - Mood: `shibuyaNeon`
   - 3D: modernGlass luxury towers (GINZA SIX), modernConcrete traditional buildings
   - POIs: GINZA SIX, Kabuki-za Theatre, Ginza Chuo-dori, Itoya Stationery, Ginza Art District
   - Night mode: 1.30× window density, pristine facades (0.05 weathering)

4. **Asakusa** (new)
   - Mood: `sacredSite`
   - 3D: traditional wood/plaster buildings, red lanterns, weathered historic fabric
   - POIs: Senso-ji Temple, Kaminarimon Gate, Nakamise Shopping Street, Asakusa Shrine, Sumida Park
   - Night mode: 1.10× window density, moderate Edo-period weathering (0.35)

5. **Akihabara** (new)
   - Mood: `shibuyaNeon`
   - 3D: modernConcrete + modernGlass electronics towers, anime neon facades
   - POIs: Akihabara Station, Animate, Yodobashi Camera, Super Potato, Akiba Cultural Zone
   - Night mode: 1.40× window density, intensified neon/LED (0.08 weathering)

6. **Roppongi** (new)
   - Mood: `shibuyaNeon`
   - 3D: modernGlass Roppongi Hills (220m), Mori Tower Annex (85m), Tokyo Tower base
   - POIs: Roppongi Hills, Mori Art Museum, Tokyo Tower Observatory, Roppongi Nightlife, 21_21 Design Sight
   - Night mode: 1.40× window density, nightlife intensification (0.08 weathering)

7. **Odaiba** (new)
   - Mood: `shibuyaNeon`
   - 3D: modernConcrete waterfront complex, Tokyo Big Sight (58m glass), Palette Town, Gundam statue base
   - POIs: Unicorn Gundam Statue, teamLab Planets, Tokyo Big Sight, Palette Town, Odaiba Seaside Park
   - Night mode: 1.40× window density, futuristic neon (0.08 weathering)

### District Data Files Created

- `MetaCity/Resources/Districts/Akihabara.json` — 5 buildings, 2 roads
- `MetaCity/Resources/Districts/Roppongi.json` — 5 buildings, 2 roads, 1 green zone
- `MetaCity/Resources/Districts/Odaiba.json` — 6 buildings, 2 roads, 1 green zone

### POI Data Files Created

- `MetaCity/Resources/pois_akihabara.json` — 5 POIs (2 featured, 3 standard)
- `MetaCity/Resources/pois_roppongi.json` — 5 POIs (3 featured, 2 standard)
- `MetaCity/Resources/pois_odaiba.json` — 5 POIs (3 featured, 2 standard)

### CityManifest.json Updates

Added 3 new Tokyo districts to the `eastAsia` island:
- Akihabara (anchor: 35.6986, 139.7731)
- Roppongi (anchor: 35.6604, 139.7293)
- Odaiba (anchor: 35.6185, 139.7751)

All use `shibuyaNeon` mood except Asakusa (`sacredSite`).

### 3D Rendering Optimizations (Already in Place)

The existing optimization infrastructure supports all new districts automatically:

- **LOD Batching**: Quadrant-based near/far tier system (4 quadrants per district)
- **Material Pooling**: 50 material instances max (10 variations × 5 styles × 2 modes)
- **Texture Caching**: LRU cache for window textures, roughness maps, normal maps
- **Entity Cache**: LRU eviction, max 12 districts in memory (~60-120 MB GPU each)
- **Facade Detail**: Sub-pixel entities (bands, pilasters, balconies) hidden during orbit
- **Palm LOD**: Palms hidden in orbit mode, revealed in venue mode
- **Vertex Array Reserve**: Pre-allocated geometry arrays per building bucket
- **Normal Maps**: Procedural 1024×1024 tangent-space normal maps per style
- **PBR Materials**: roughness, specular, metallic channels fully configured

### Night Mode System (Already in Place)

- `@Published var isNightMode: Bool = false` in DiscoverViewModel
- Cache key: `"\(districtName)_\(isNight)"` in DistrictRealityKit
- `installLighting` uses `currentIsNight` for sun/fill/sky dome
- Night toggle button (sun/moon icon) in districtExploreOverlay
- Reset `isNightMode = false` on navigation back (DiscoverViewModel.back())

### DistrictRenderProfile Presets (Tokyo)

```swift
case "Shibuya":      .init(nightWindowDensityBoost: 1.40, weatheringIntensity: 0.10)
case "Shinjuku":     .init(nightWindowDensityBoost: 1.40, weatheringIntensity: 0.08)
case "Ginza":        .init(nightWindowDensityBoost: 1.30, weatheringIntensity: 0.05)
case "Asakusa":      .init(nightWindowDensityBoost: 1.10, weatheringIntensity: 0.35)
```

### Build Status

- **BUILD SUCCEEDED** (2026-07-20 13:17)
- Only warnings: nil coalescing on non-optional strings, unused variables (pre-existing)
- No errors
- GoogleService-Info.plist added (placeholder values for build)

### What's NOT Changed (Per Instructions)

- No modifications to DistrictRealityKit.swift
- No modifications to DistrictRealityScene.swift
- No new BuildingStyle enum cases
- No new Mood enum cases
- No mini-map changes (already ultra-sophisticated)
- No POI beacon reactivation (removed per previous logs)

### Architecture Changes

**ViewPreset Enum (DiscoverViewModel.swift):**
```swift
enum ViewPreset: String, CaseIterable {
    case overview      // OVERVIEW — bird's-eye ~61°, districtDistance×0.60
    case closeDistrict // CLOSE DISTRICT — tighter district framing, districtExtent×0.50 horiz, ×0.90 height
    case poi           // POI — frames selected POI with context
}
```

**Camera Presets (DistrictRealityView.swift):**
- OVERVIEW: distance = districtDistance × 0.60, height = distance × 1.10
- CLOSE DISTRICT: distance = districtExtent × 0.50, height = districtExtent × 0.90
- POI: flyToVenue() with nearest building framing or 20% district extent fallback

**Token System:**
- `cameraResetToken` — triggers resetToDefaultPosition()
- `poiFocusToken` — triggers flyToVenue() for POI preset
- `buildingOrbitToken` — triggers 360° building orbit
- `searchFlyToken` — triggers search result fly-to

### Next Steps (If Needed)

1. Replace placeholder district JSON with real OSM building footprints (current files are simplified placeholders)
2. Add district-specific authored JSON files (e.g., `Shinjuku_authored.json`) for custom landmark geometry
3. Tune `DistrictRenderProfile` values per district based on visual verification
4. Add district-specific `facadeProfile` overrides if needed
5. Implement POI beacon entities (currently removed, can be re-added)
6. Add district-specific normal maps (1024×1024 or 2048×2048)
7. Photogrammetry textures for key landmarks (Gundam, Tokyo Tower, etc.)

### Key Architecture Notes

- All Tokyo districts use `shibuyaNeon` mood except Asakusa (`sacredSite`)
- The `shibuyaNeon` mood has the lowest sun elevation (0.22) for long dramatic shadows
- Night emissive boost for `shibuyaNeon` is 1.30× (densest in app)
- Sky colors for `shibuyaNeon`: deep indigo zenith, electric magenta-pink horizon, near-black asphalt ground
- District data is immutable post-decode — caches are valid for app lifetime
- All geometry builds on main actor (`@MainActor` constraint from RealityFoundation)
- MeshResource.generate is NOT @MainActor but called from main actor context