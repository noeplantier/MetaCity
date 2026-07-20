# MetaCity Memory — Clean + POI Reality Max Implementation

## 2026-07-20 — View Preset System Overhaul & Code Cleaning

### What Was Implemented

**View Preset System Changes:**
- Removed `.ciel` (SURVOL) mode — full-district overhead view
- Removed `.focus` (ZOOM) mode — building-tap zoom view
- Added `.closeDistrict` (QUARTIER) — tighter district framing at 50% horizontal distance, 90% height
- Added `.poi` (POI) — frames selected POI with context

**Code Cleaning:**
- Uniformized naming: `viewFocusToken` → `poiFocusToken`, `lastFocusedBuilding` → `lastFocusedPOIId`
- Removed dead code references to `.ciel` and `.focus` presets
- Updated comments to reflect new OVERVIEW/CLOSE DISTRICT/POI system
- Fixed token tracking in DistrictRealityView.Coordinator.update()

**Files Modified:**
- `DiscoverViewModel.swift` — ViewPreset enum, setViewPreset(), poiFocusToken
- `DistrictRealityView.swift` — Coordinator update logic, resetToDefaultPosition()
- `DiscoverView.swift` — DistrictRealityView initialization with poiFocusToken
- `CLAUDE.md` — Updated documentation

### Files Created

**District Data:**
- `MetaCity/Resources/Districts/Akihabara.json`
- `MetaCity/Resources/Districts/Roppongi.json`
- `MetaCity/Resources/Districts/Odaiba.json`

**POI Data:**
- `MetaCity/Resources/pois_akihabara.json`
- `MetaCity/Resources/pois_roppongi.json`
- `MetaCity/Resources/pois_odaiba.json`

**Build Fix:**
- `MetaCity/Resources/GoogleService-Info.plist` (placeholder values)

**Documentation:**
- `CLAUDE.md` (updated with Tokyo implementation details)

### Files Modified

- `MetaCity/Resources/CityManifest.json` — Added Akihabara, Roppongi, Odaiba to Tokyo city

### Tokyo Districts Now Available

1. Shibuya (existing)
2. Shinjuku (existing)
3. Ginza (existing)
4. Asakusa (existing)
5. **Akihabara** (new)
6. **Roppongi** (new)
7. **Odaiba** (new)

### Technical Details

- All new districts use `shibuyaNeon` mood except Asakusa (`sacredSite`)
- DistrictRenderProfile presets already in place for Shibuya, Shinjuku, Ginza, Asakusa
- New districts fall back to default profile (can be tuned later)
- Build succeeds with only pre-existing warnings
- No changes to core 3D rendering code (DistrictRealityKit, DistrictRealityView, DistrictRealityScene)
- No changes to DiscoverViewModel
- POI system already functional via CangguPOICollection

### What Was NOT Changed (Per Instructions)

- No modifications to existing Tokyo district data (Shibuya, Shinjuku, Ginza, Asakusa)
- No modifications to core 3D rendering pipeline
- No new BuildingStyle enum cases
- No new Mood enum cases
- No mini-map changes
- No POI beacon reactivation

### Tokyo Districts Available (All with 5+ POIs)

1. **Shibuya** — Scramble Crossing, Scramble Square, Hachiko Statue, NHK Broadcasting, Shibuya Stream
2. **Shinjuku** — Shinjuku Gyoen, Cocoon Tower, Kabukicho Tower, Nomura Building, Hanazono Shrine
3. **Ginza** — GINZA SIX, Kabuki-za Theatre, Ginza Chuo-dori, Itoya Stationery, Ginza Art District
4. **Asakusa** — Senso-ji Temple, Kaminarimon Gate, Nakamise Shopping, Asakusa Shrine, Sumida Park
5. **Akihabara** — Akihabara Station, Animate, Yodobashi Camera, Super Potato, Akiba Cultural Zone
6. **Roppongi** — Roppongi Hills, Mori Art Museum, Tokyo Tower, Roppongi Nightlife, 21_21 Design Sight
7. **Odaiba** — Unicorn Gundam Statue, teamLab Planets, Tokyo Big Sight, Palette Town, Odaiba Seaside Park

### Next Steps for Tokyo 3D Max

1. Replace placeholder district JSON with real OSM building footprints
2. Add district-specific authored JSON files for custom landmarks
3. Tune DistrictRenderProfile for Akihabara, Roppongi, Odaiba
4. Add district-specific normal maps (2048×2048 for key landmarks)
5. Photogrammetry textures for Gundam, Tokyo Tower, etc.
6. Re-activate POI beacons if desired
7. Visual verification on device (night mode, 3D quality, performance)

### View Preset System Architecture

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

### Key Learnings

- District data files are simple JSON with buildings, roads, greenZones
- POI files are flat JSON with id, name, category, tier, lat/lon, description
- CityManifest.json drives district discovery and UI
- Mood system controls lighting, sky colors, camera behavior
- DistrictRenderProfile controls night window density and weathering
- Build system requires GoogleService-Info.plist (even if placeholder)
- iOS 17 target limits some RealityKit features (EnvironmentResource, LowLevelMesh, BillboardComponent)

### Performance Notes

- Existing LOD batching handles new districts automatically
- Material pooling prevents draw call explosion
- Entity cache LRU eviction keeps memory bounded
- Quadrant-based LOD ensures 60fps even with dense districts
- Night mode rebuilds entity with cache key `"\(name)_\(isNight)"`

### Verification

- Build: ✅ SUCCEEDED (2026-07-20 13:17)
- Warnings: Only pre-existing nil coalescing and unused variable warnings
- Errors: None
- GoogleService-Info.plist: Added placeholder to fix build