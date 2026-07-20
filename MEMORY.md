# MetaCity Memory — Tokyo 3D Max Implementation

## 2026-07-20 — Tokyo District Expansion

### What Was Implemented

Added 3 new Tokyo districts to the existing Tokyo 3D showcase:

1. **Akihabara** — Electric Town, anime/electronics culture
2. **Roppongi** — Nightlife, Mori Art Museum, Tokyo Tower
3. **Odaiba** — Waterfront, Gundam statue, teamLab, Tokyo Big Sight

Plus POI data for all 3 districts with 5 POIs each (featured + standard tiers).

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

### Next Steps for Tokyo 3D Max

1. Replace placeholder district JSON with real OSM building footprints
2. Add district-specific authored JSON files for custom landmarks
3. Tune DistrictRenderProfile for Akihabara, Roppongi, Odaiba
4. Add district-specific normal maps (2048×2048 for key landmarks)
5. Photogrammetry textures for Gundam, Tokyo Tower, etc.
6. Re-activate POI beacons if desired
7. Visual verification on device (night mode, 3D quality, performance)

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