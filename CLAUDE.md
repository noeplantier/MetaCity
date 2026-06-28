# MetaCity

iOS SwiftUI app (Xcode project generated from `project.yml` via XcodeGen — never hand-edit
`MetaCity.xcodeproj`, run `xcodegen generate` after any `project.yml` change). Clean-ish
architecture: `Repositories/` protocols, `Services/` implementations (mock + real, chosen
automatically based on whether `GoogleService-Info.plist` is present), `@MainActor` ViewModels,
DI via the plain `AppEnvironment` container — no DI framework.

## Scope: Jakarta only, exactly 5 districts

As of 2026-06-28, MetaCity models **only Jakarta**, and only 5 real districts within it —
Bundaran HI, Kota Tua, Jalan Kemang Raya, Taman Suropati, Taman Impian Jaya Ancol (`ARLocation`).
Surabaya, Bandung, and the old per-city *artistic* skyline system (`RealBuilding.swift`,
`CityScene3DView.swift`, hand-placed boxes at a compressed scale) were **deleted outright** — not
hidden, not deprecated — per an explicit instruction to focus exclusively on real OSM-derived
content. `IndonesianCity` was kept as a type (rather than removed) but now has only `.jakarta`, so
`centerCoordinate`/`displayName` call sites didn't need to change. If a future request reintroduces
another city, that's the seam to extend; don't resurrect the deleted tier-1 files from git history
without a fresh reason — they were a deliberate worse fidelity tier, not just unused code.

`MockMapRepository` now serves exactly the 5 landmarks that anchor these districts — every
landmark has a `PlaceAnnotationItem.districtName`, so `LandmarkInspectorView` no longer has (or
needs) a fallback path for landmarks without curated 3D data.

## 3D/AR rendering: one real path, three presentations

All real, OpenStreetMap-derived building footprint polygons, road centerlines, and green spaces
(`DistrictFootprint.swift`, fetched by `tools/fetch_district_data.py`), rendered at **true 1:1
meters** via `SCNShape` extrusion — never boxes. One data source, one node-building implementation
(`SharedCityGeometry.swift`), three presentations that share both:

1. **Orbit inspector** (`DistrictScene3DView.swift`, reached from Explore) — aerial orbit camera,
   `allowsCameraControl` turntable, day/night + auto-rotate controls.
2. **Simulated ground-level AR** (`SimulatedARSceneView.swift`, used when
   `ARWorldTrackingConfiguration.isSupported` is `false` — i.e. always on the Simulator, which has
   no camera) — pedestrian eye-height, free-fly camera, full real-world scale.
3. **Real tabletop AR** (`ARSceneView.swift`, used on a physical device) — tap a detected
   horizontal plane to anchor a compressed-scale (~0.9m) miniature of the selected district, built
   from the exact same data, scaled via `SCNNode.scale` + a `pivot` re-centered on `district.center`.

All three start the camera/highlight focused on `ARLocation.focusBuildingName` — a real, named
building looked up by name in that district's own `buildings` array (not a hardcoded position), so
"visit Bundaran HI" means "stand in front of Menara BCA", not "look at an arithmetic midpoint".
**Honesty caveat baked into this feature**: OSM has no "this is the landmark" tag, so each focus
building was hand-picked as the tallest/most-recognizable *named* building actually in that
district's dataset — not necessarily the single most famous structure a Jakarta resident would
name. Bundaran HI's own Selamat Datang statue isn't `building=*`-tagged and isn't in this dataset
at all; Taman Suropati is itself a green space with no building, so its focus is the real colonial
church facing it. See `ARLocation.focusBuildingName`'s doc comment for the exact reasoning per
district — if a different building would read as more iconic, that's a one-line change there, not
a data or architecture problem.

Camera framing is fully generic off `District.boundingBox`/`center`/`extent`
(`DistrictFootprint.swift`) — orbit distance/height, fog distances, and LOD switch fraction are all
fractions of `extent`, so a new district needs no per-district camera tuning. **`boundingBox`
deliberately excludes `greenZones`**: Ancol's "Taman Impian Jaya Ancol" green-zone polygon is the
park's administrative boundary (spans ~3.7km), not a literal field, and including it skewed the
centroid ~1.3km off the actual building cluster and bloated the extent ~3x, pointing the camera at
empty space. If a future district's scene renders near-empty, check whether one of its green zones
is an oversized administrative boundary before assuming the data fetch failed.

`SharedCityGeometry` caches materials per `BuildingStyle`/road `kind` rather than allocating fresh
per node (`roadMaterialCache`, `greenZoneMaterial`) — both lower overhead and, in the tabletop AR
path, lets `SCNNode.flattenedClone()` batch same-material nodes into fewer draw calls. Building
materials are deliberately **not** shared across buildings of the same style: each building's
material carries a height-dependent `emission.contentsTransform` (window-row tiling scaled to that
specific building's height), so sharing one instance would make every building of a style render
with whichever building's height was processed last. If you want true per-style material sharing
later, that tiling needs to move to a shader-modifier uniform first — don't just dedupe the
`SCNMaterial` objects without addressing this, it's a silent visual regression, not a free win.

## Why SceneKit, not RealityKit / 3D Tiles / photogrammetry

Decided 2026-06-27 when asked to push district-level realism — full reasoning in
`~/.claude/plans/replicated-swimming-gosling.md`, summary:
- RealityKit's procedural-mesh API (`LowLevelMesh`) needs **iOS 18+**; this project targets 17.0.
  Rewriting ~900 lines of working, screenshot-verified SceneKit code for a engine swap that adds
  zero realism by itself wasn't worth it. Revisit only if there's a reason beyond visual fidelity.
- Cesium 3D Tiles has no native Swift/iOS binding (Unity/Unreal/Flutter only) — wrapping
  `cesium-native` (C++) would be a multi-week project on its own.
- Apple's Object Capture is single-object photogrammetry (cultural-heritage-object scale, <100
  photos) — not applicable to capturing a city block.

## The district data pipeline

`tools/fetch_district_data.py` (one-shot, not part of the iOS app target) queries the Overpass API
for a bounding box, projects lat/lon to local meters from an anchor point (flat equirectangular —
fine at district scale), simplifies footprint polygons (Douglas-Peucker), classifies each building
into a `BuildingStyle` from its OSM tags, estimates height where no `height`/`building:levels` tag
exists, and writes the curated JSON straight into `MetaCity/Resources/Districts/`.

**Real height data is rare in OSM** — Kota Tua's 407 buildings: 14 have `building:levels`, 0 have
`height`, and a small hand-maintained list (`KNOWN_HEIGHTS_METERS` in the script) covers named
landmarks the tags don't capture (museums are frequently mapped as a `node` point sitting on top of
an anonymous `building=yes` polygon — the script spatially matches them; see
`apply_named_point_landmarks`). Every estimated height is flagged `isHeightEstimated: true` in the
JSON — the app never silently presents a guess as measured fact.

**To refresh any of the 5 existing districts or add a new one beyond the targeted set**:
```
cd tools
python3 fetch_district_data.py \
  --name <Name> --bbox <south> <west> <north> <east> --anchor <lat> <lon> \
  --out ../MetaCity/Resources/Districts/<Name>.json --cache /tmp/<name>_raw.json
```
Pick `--anchor` as the district's main square/landmark — everything renders relative to it. Then
wire it into the app: add a case to `ARLocation` (`jsonResourceName`/`displayName`/
`focusBuildingName`) to make it pickable in the AR tab and orbit inspector, and a matching entry in
`MockMapRepository`/`PlaceAnnotationItem.districtName` if it should be reachable from a specific
Explore landmark. Given the current "Jakarta only, 5 districts" scope (see above), confirm this is
actually wanted before adding a 6th — it was a deliberate, explicit constraint, not an oversight.

## Performance

`MetaCityTests/DistrictScenePerformanceTests.swift` measures real scene-construction cost (wall
time + node counts) for all 5 districts via `XCTest`'s `measure`/`ContinuousClock` — no Simulator
UI involved, so it's fast and CI-friendly. As of 2026-06-28: all 5 districts combined (1938
buildings, ~5000 expanded road-segment nodes) build their full `SCNNode` graph in well under
100ms total on a dev Mac. Construction time is not the bottleneck for these districts; if a future
district feels slow in the orbit/AR views, look at draw calls/GPU first; this test would only
catch a regression in the *building* step itself (e.g. an accidental O(n²) pass).
`SharedCityGeometry`'s per-kind/per-style material caching (see above) and `SCNNode.flattenedClone()`
in the tabletop AR path are the two concrete draw-call-reduction levers already in place.

## What's real vs. estimated vs. stylistic, honestly

- Building footprints (shape) and road centerlines: real, from OpenStreetMap.
- Heights: real where OSM tags or the hand-curated landmark list provide them; heuristic-estimated
  (flagged) otherwise.
- Vegetation, street furniture, signage: **not from real per-item data** — OSM has essentially no
  coverage at that granularity for Jakarta. What exists is stylistic/atmospheric (ambient
  particles, a tinted green zone where OSM tags a literal park), not a claim of real placement.
- Materials/colors: stylistic but deliberate and consistent — one fixed material per
  `BuildingStyle`, never randomized per building (`SharedCityGeometry.materialForStyle`).

## Day/night and bloom

Both tiers use a restrained bloom (`bloomIntensity ~0.3`, `bloomThreshold ~0.85`) — a higher bloom
previously made every lit window bleed past its own building silhouette. If a future change makes
"lights shooting out of buildings" reappear, check those two values first.

## Known Simulator/test gotchas

See `~/.claude/projects/-Users-noeplantier-Orbital/memory/project_ios_simulator_quirks.md` (Claude
session memory) for: disk filling up fast during repeated `xcodebuild test` runs, XCUITest's
`.tap()` not registering on `Toggle`/`Switch` elements on this machine's iOS Simulator build (not
an app bug — confirmed with a bare isolated `@State` Toggle), and screenshot timing races when a
test screenshots immediately after a tap instead of waiting for the expected resulting content.
