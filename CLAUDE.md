# MetaCity

iOS SwiftUI app (Xcode project generated from `project.yml` via XcodeGen — never hand-edit
`MetaCity.xcodeproj`, run `xcodegen generate` after any `project.yml` change). Clean-ish
architecture: `Repositories/` protocols, `Services/` implementations (mock + real, chosen
automatically based on whether `GoogleService-Info.plist` is present), `@MainActor` ViewModels,
DI via the plain `AppEnvironment` container — no DI framework.

## Scope: 14 cities visible in UI (2026-07-19 pivot — Indonesia re-enabled)

As of 2026-07-19, MetaCity surfaces 14 cities in `visibleCityIds` (renamed from `europeFocusCityIds`):
```swift
static let visibleCityIds: Set<String> = [
    "paris", "bordeaux", "london", "madrid", "rome",
    "tokyo", "newyork", "losangeles", "vancouver", "sanfrancisco",
    "jakarta", "bandung", "denpasar", "yogyakarta"
]
static var europeFocusCityIds: Set<String> { visibleCityIds }  // backward-compat alias
```
Jakarta / Bandung / Yogyakarta / Bali/Denpasar are **fully visible** in the Discover tab and
world map again (re-enabled 2026-07-19 as part of Phase 6 Indonesia-first pivot).

The default map camera is Indonesia: `-2.5°N / 117.5°E, distance 4,500,000m` (full archipelago).
Cold launch opens Jakarta in `cityFocused` state.

MetaCity covers **36 districts with real OSM-derived 3D data** across 14 cities:
Jakarta (5), Bandung (2), Yogyakarta (2), Bali/Denpasar (5), Paris (4), Bordeaux (2), London (2),
Madrid (2), Rome (1), Tokyo (4), Los Angeles (1), New York (2), Vancouver (2), San Francisco (2).
All 33 district JSONs live in `MetaCity/Resources/Districts/<id>.json`.
`CityManifest.json` (decoded into `CityManifest.shared`) is the single source of truth for what's
live; it drives the world map, district picker, and 3D inspector routing.
All 33 data districts live in `MetaCity/Resources/Districts/<id>.json`.
`CityManifest.json` (decoded into `CityManifest.shared`) is the single source of truth for what's
live; it drives the world map, district picker, and 3D inspector routing.

**France districts currently bundled (6 total — Paris + Bordeaux):**
- Paris: `LeMarais`, `SaintGermain`, `Montmartre`, `LaDefense`
- Bordeaux: `VieuxBordeaux`, `LesChartrons`

**France placeholder districts (4 total — Rennes only, no data yet):**
- Rennes: `VieuxRennes`, `Thabor`

**UK/Iberia/Italy districts (5 bundled — fetched 2026-07-09):**
- London: `CityOfLondon` (moodKey: londonSilver, londonBrick style, 2,404 buildings), `Westminster` (londonSilver, 2,362 buildings)
- Madrid: `Salamanca` (moodKey: madridAfternoon, madrileño style, 2,463 buildings), `Malasana` (madridAfternoon, 2,534 buildings)
- Rome: `CentroStorico` (moodKey: romanGoldenHour, romanOchre style, 4,917 buildings)

The French and UK/Iberia/Italy districts were added 2026-07-09 as part of a Europe pivot that
introduced six new `BuildingStyle` cases and six new `Mood` cases (see below). Dili/Timor-Leste
was explicitly cancelled and must not be re-added.

The old per-city *artistic* skyline system (`RealBuilding.swift`, `CityScene3DView.swift`,
hand-placed boxes at a compressed scale) was **deleted outright** — not hidden, not deprecated —
per an explicit instruction to focus exclusively on real OSM-derived content. If a future request
reintroduces a pre-OSM artistic tier, that's a deliberate regression; don't resurrect those files
from git history without a fresh reason.

**Districts currently bundled (33 total):**
- Jakarta: `SudirmanThamrin`, `KotaTua`, `Kemang`, `Menteng`, `Ancol`
- Bandung: `Dago`, `Braga`
- Yogyakarta: `Malioboro`, `Kraton`
- Bali/Denpasar: `Seminyak`, `Kuta`, `Canggu`, `Sanur`, `Uluwatu`
- Paris: `LeMarais`, `SaintGermain`, `Montmartre`, `LaDefense`
- Bordeaux: `VieuxBordeaux`, `LesChartrons`
- London: `CityOfLondon`, `Westminster`
- Madrid: `Salamanca`, `Malasana`
- Rome: `CentroStorico`
- Tokyo: `Shibuya`, `Shinjuku`, `Ginza`, `Asakusa`
- New York: `MidtownManhattan`, `LowerManhattan`
- Los Angeles: `DowntownLA`
- Vancouver: `VancouverDowntown`, `WestEnd`
- San Francisco: `SFDowntown`, `FishermansWharf`

`MockMapRepository` serves the 5 Jakarta landmarks (the Map tab still shows only Jakarta pins);
the Discover tab uses `CityManifest.allCities` which includes all city pins from the world map.
`LandmarkInspectorView` no longer has (or needs) a fallback path for landmarks without curated 3D
data.

## 3D/AR rendering: JSON → MeshDescriptor → RealityKit (no USDZ at runtime)

**As of 2026-07-04, `DistrictRealityKit` builds geometry directly from the bundled JSON at
runtime using `MeshDescriptor` — the SceneKit→USDZ→RealityKit pipeline described in older
versions of this file is no longer used at runtime.** The USDZ files in
`MetaCity/Resources/Districts3D/` and the export test `MetaCityTests/DistrictUSDZExportTests.swift`
still exist in the repo but are dead weight — `DistrictRealityKit`'s class comment says "Replaces
the SceneKit→USDZ→RealityKit pipeline with direct MeshDescriptor construction from the same
bundled JSON data." Do not re-run the USDZ export test expecting it to affect what the app renders.
Do not edit `SharedCityGeometry` expecting geometry changes to show up in the district views — the
building/road/green-zone mesh is built entirely in `DistrictRealityKit.makeBuildingMeshes` /
`makeRoadMeshes` / `makeGreenZoneEntities` from `District` structs loaded from the bundled JSON.

**Consequence**: changing building style classification, heights, or footprints requires only
editing the JSON files in `MetaCity/Resources/Districts/` (or re-running
`tools/fetch_district_data.py`). No USDZ re-export, no test run, no SceneKit rebuild. Changes
take effect on next app launch.

The runtime pipeline is:
1. **JSON → Swift structs**: `District.load(named:)` decodes `Districts/<name>.json` into a
   `District` value containing `buildings`, `roads`, `greenZones`. Cached in-memory after first
   load (district data is immutable post-decode).
2. **Structs → RealityKit mesh**: `DistrictRealityKit.loadDistrictEntity(named:isNight:)` calls
   `makeBuildingMeshes`, `makeRoadMeshes`, `makeGreenZoneEntities` — each builds a `MeshDescriptor`
   (positions, normals, UV texture coordinates, triangle indices) from the Swift structs and
   creates a `ModelEntity` with a `PhysicallyBasedMaterial` from `materialPreset(for:isNight:)`.
   UV coords: walls tile at 5m/repeat horizontal, 3.5m/repeat vertical (one floor bay) so
   `emissiveColor.texture` window maps align correctly.
3. **Entity cache**: styled entities are cached by `(name, isNight)` key and cloned on reuse
   (an `Entity` can only have one parent; the cached original is never itself placed in a scene).
4. **Scene assembly** (`DistrictRealityScene.swift`): shared lighting rig, per-mood camera
   parameters (distance/height/FOV), cinematic establishing shot, focus-building beacon, and
   atmospheric sky dome — used by all three presentation surfaces below.

The three presentation surfaces (unchanged structurally from the USDZ era):
- **Orbit inspector** (`DistrictRealityView.swift`, reached from Discover) — `ARView(.nonAR)`,
  30fps orbit (every-other-frame guard), cinematic 1.2s crane-down entry, day/night + auto-rotate.
- **Simulated ground-level** (`SimulatedARSceneView.swift`, Simulator-only) — `ARView(.nonAR)`.
- **Real tabletop AR** (`ARSceneView.swift`, physical device) — `ARView(.ar)`, procedural
  concrete base-plate texture, real `ARAnchor` for ARKit relocalization.

**All three presentations start the camera/highlight focused on `ARLocation.focusBuildingName`** —
a real, named building looked up by name in that district's own `buildings` array (not a hardcoded
position), so "visit Bundaran HI" means "stand in front of Menara BCA", not "look at an arithmetic
midpoint". The orbit inspector additionally reads the focus building from
`CityManifest.shared.district(id:)?.focusBuildingName` rather than `ARLocation` — both are kept
in sync in `CityManifest.json`. **Honesty caveat baked into this feature**: OSM has no "this is
the landmark" tag, so each focus building was hand-picked as the tallest/most-recognizable *named*
building actually in that district's dataset. Bundaran HI's own Selamat Datang statue isn't
`building=*`-tagged and isn't in this dataset at all; Taman Suropati is itself a green space with
no building, so its focus is the real colonial church facing it. See `ARLocation.focusBuildingName`'s
doc comment for the exact reasoning per district.

Camera framing uses `District.buildingCentroid` as the look-at target and `District.extent`
(from `boundingBox`) for camera distance/height — **not** `District.center`. `center` is the
bounding-box midpoint, which can be 100–200m off the actual building cluster for linear or skewed
districts. Dago's 1km boulevard had a centroid at (165m, -185m) from the anchor but a bbox center
at (54m, 0m) — the full view was nearly empty until this was fixed. `buildingCentroid` is the mean
of all building polygon centroids, cached alongside `bboxCache` in `District`.

**`boundingBox` deliberately excludes `greenZones`**: Ancol's "Taman Impian Jaya Ancol" green-zone
polygon is the park's administrative boundary (spans ~3.7km), not a literal field, and including it
skewed the centroid ~1.3km off the actual building cluster. If a future district's scene renders
near-empty, first check `buildingCentroid` vs. `center` discrepancy; if they're close, then check
for an oversized administrative-boundary green zone.

### iOS 17 vs. RealityKit's newer convenience APIs — confirmed unavailable, don't re-try them

Each of these was tried and hits a hard `iOS 18.0 or newer` compiler error, not just a deprecation
warning — confirmed empirically against this project's iOS 17.0 target on 2026-06-28, not assumed:
- `EnvironmentResource.init(equirectangular:)` **and** its deprecated predecessor
  `EnvironmentResource.generate(fromEquirectangular:)` — both gated to iOS 18+, confirmed by trying
  both against this project's iOS 17.0 target. **`EnvironmentResource.load(named:in:)` looks like a
  workaround** — it IS iOS 13+ in the API-availability sense — but it requires a pre-compiled
  `.skybox` asset bundle that can only be produced by Reality Composer Pro (a GUI tool, not a
  command-line step): there is no `xcrun reality-tool` or equivalent. In a terminal-only workflow
  without Reality Composer installed, this path is blocked by a *tooling gate*, not a compiler gate
  — the API exists but the asset-authoring step that feeds it does not. **Practical conclusion:
  there is no iOS-17-compatible path to a custom equirectangular sky IBL in a terminal-only
  environment.** `DistrictRealityScene` uses a `DirectionalLight` "sun" + a second tinted "fill"
  light instead — see the day/night contrast section for what this costs visually. If Reality
  Composer Pro is ever available in this environment, `load(named:in:)` is the right entry point.
- `MeshResource.generateCylinder(height:radius:)` — use `generateBox` instead for simple primitives.
- `BillboardComponent` (always-face-camera) — orient text manually at creation time instead (see
  `DistrictRealityScene.makeFocusBeacon`'s `facing` parameter); there's no live camera-tracking
  workaround on 17 short of a per-frame subscription, which wasn't worth it for a decorative label.
- `DirectionalLightComponent` has no direct `.shadow` property to set — shadows are configured via a
  **separate** `DirectionalLightComponent.Shadow` component on the same entity:
  `entity.components[DirectionalLightComponent.Shadow.self] = .init(maximumDistance:depthBias:)`.

### `Entity` cannot be loaded or mutated off the main actor — confirmed via the SDK interface, don't re-try

Confirmed empirically on 2026-06-28 by grepping
`RealityFoundation.framework/Modules/RealityFoundation.swiftmodule/arm64-apple-ios-simulator.swiftinterface`
directly, not assumed from general RealityKit knowledge: `Entity` itself is declared
`@preconcurrency @_Concurrency.MainActor open class Entity`, and **every** loader on it carries the
same isolation — `load(contentsOf:)`, `loadAsync(contentsOf:) -> LoadRequest<Entity>` (the
Combine-based one that *sounds* non-blocking), and even the `convenience init(contentsOf:) async
throws` are all `@MainActor`. There is no public RealityKit API to parse a `.usdz`/`.reality` file
or touch `entity.components`/`entity.children` off the main thread — not a missing-API gap like the
iOS 17 items above, a hard isolation rule on the type itself.

A real attempt to work around this (wrapping `Entity.load(contentsOf:)` + the building-restyle tree
walk in `Task.detached` inside `DistrictRealityKit.loadDistrictEntity`) **compiled cleanly** —
`@preconcurrency` suppresses the compiler's actor-isolation diagnostic — but **crashed at runtime**
on every district open, immediately after the load completed: `BUG IN CLIENT OF LIBDISPATCH:
Assertion failed: Block was expected to execute on queue [com.apple.main-thread]`. RealityKit's
engine (CoreRE) asserts the main queue internally regardless of what the type system let compile.
Confirmed via a real `simctl launch` + screenshot reproduction (app silently dropped to the
Springboard home screen) before the fix, and a clean render through the same code path (including
the night-mode-reload branch) after removing the detach.

**Practical upshot**: `DistrictRealityKit.loadDistrictEntity` stays `@MainActor` and does the real
parse + restyle synchronously on the main actor on a cache miss — there is no way to move that work
to a background thread. Marking it `async` and wrapping each call site in a plain (non-detached)
`Task { @MainActor in ... }` still has real value, just smaller than "off the main thread": it
defers the hitch to a subsequent main-actor turn so the static scaffold (lights/camera/base
plate/focus beacon) commits and renders *first*, instead of the whole view waiting on the parse —
and the entity cache (see Performance below) means that hitch only happens once per
`(district, isNight)` combination, not on every visit. If a future change needs genuinely
background-thread 3D asset work, it has to happen *before* the result becomes a RealityKit `Entity`
(e.g. raw-bytes I/O), not after.

### Day/night lighting contrast: one real bug found and fixed, full resolution not yet re-verified

The original investigation (2026-06-28, earlier the same day) concluded the rendered
brightness/contrast barely changed between night/day on Simulator despite materials and light
*parameters* both correctly swapping, and tentatively blamed `ARView`'s non-removable default
neutral-studio environment for washing everything out.

That default-environment effect may still be real, but a **concrete, separate bug was found and
fixed first**: `installLighting` created a new "sun" + "fill" `Entity` pair on every call but never
removed the *previous* pair — toggling night mode back and forth didn't replace the lighting, it
accumulated it, leaving old (bright-day) lights fully active underneath new (dim-night) ones. That
alone would explain a muted before/after difference independent of any default-environment
question. The fix (`installLighting` now removes any child of `anchor` named `"sun"`/`"fill"`
before adding new ones) is in and build/test-verified, but **the actual visual contrast after this
fix has not been re-screenshotted with the toggle actually flipped** — doing that needs a real tap
on the Night Mode `Toggle`, and XCUITest automation against this RealityKit-linked build remains
unreliable (see Simulator quirks memory) independent of this fix. Don't assume either "still
broken" or "now fixed" without taking a fresh pair of night/day screenshots around an actual toggle
tap — neither has been confirmed since this change. If it's still muted after this fix, the
`ARView` default-environment hypothesis (and the iOS 18 custom-`EnvironmentResource` fix for it)
is the next thing to revisit, not a new investigation from scratch.

### Debug launch environment variables (inert by default, `MetaCityApp.swift` / `ExploreViewModel.swift`)

Added because XCUITest's accessibility-tree polling proved unreliable against this RealityKit-linked
build specifically (see project memory: `app.tabBars.buttons[...].waitForExistence` still failed
after a *fixed* 45s sleep with zero polling, while a direct `simctl launch` + screenshot reliably
showed the same build's Explore tab within ~15s — not a real app hang, an XCUITest-harness-specific
one). All four make `simctl launch` + `simctl io screenshot` viable for visual verification without any
tap/gesture simulation:
- `UITEST_SKIP_AUTH=1` — skips Firebase Sign Up/Log In, signs in with a fixed fake `User` directly via
  `SessionStore.handleSignedIn`. Also sidesteps the unrelated, separately-documented `.newPassword`
  SecureField automation gap.
- `UITEST_OPEN_CITY=<cityId>` (e.g. `bandung`) — jumps to `cityExplore` state, showing the district
  list panel and `CityOverviewView` for that city. Useful for verifying non-Jakarta city layouts.
- `UITEST_OPEN_DISTRICT=<districtId>` (e.g. `KotaTua`) — auto-opens that district's 3D inspector
  immediately, no tap needed. **The value must be the district's JSON resource name (`DistrictEntry.id`),
  not its display name.** Jakarta map: `SudirmanThamrin`→Bundaran HI, `KotaTua`→Kota Tua,
  `Kemang`→Jalan Kemang Raya, `Menteng`→Taman Suropati, `Ancol`→Taman Impian Jaya Ancol.
  Works for all 12 districts (Bandung: `Dago`/`Braga`; Yogya: `Malioboro`/`Kraton`;
  Bali: `Seminyak`/`Kuta`/`Canggu`).
- `UITEST_NIGHT_MODE=1` — enables night mode immediately on launch; avoids Toggle tap automation
  which is unreliable on this Simulator build (see Simulator quirks memory).

  iOS's scene-state restoration can preserve the previously-selected tab across `simctl launch`
  invocations, overriding `@State private var selectedTab: AppTab = .discover`. `HomeTabView`
  resets to `.discover` in `.onAppear` when either `UITEST_OPEN_DISTRICT` or `UITEST_OPEN_CITY`
  is set in the environment, so the Discover tab is always visible on launch.

**CRITICAL**: `SIMCTL_CHILD_` vars must be in the *calling shell environment*, NOT passed as
positional arguments after the bundle ID. Correct form:
```
SIMCTL_CHILD_UITEST_SKIP_AUTH=1 SIMCTL_CHILD_UITEST_OPEN_DISTRICT=KotaTua \
  xcrun simctl launch booted com.metacity.app
```

**Also CRITICAL**: `xcodebuild build -destination 'id=<simulator>'` compiles but does NOT
auto-install the new binary to the Simulator. Always run `xcrun simctl install booted
<app.app-path>` explicitly after building before launching, otherwise the old binary runs.

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

**To refresh any existing district or add a new one**:
```
cd tools
python3 fetch_district_data.py \
  --name <Name> --bbox <south> <west> <north> <east> --anchor <lat> <lon> \
  --out ../MetaCity/Resources/Districts/<Name>.json --cache /tmp/<name>_raw.json
```
Pick `--anchor` as the district's main square/landmark — everything renders relative to it. Then
wire it into the app: add a `DistrictEntry` in `CityManifest.json` under the correct city (with
`id`, `displayName`, `focusBuildingName`, `moodKey`, `dataBundled: true`, `dataPath`). If it
should also be reachable from the Map tab, add a matching entry in `MockMapRepository` and
`PlaceAnnotationItem.districtName`. The `ARLocation` enum covers only the 5 Jakarta districts for
the AR tab — non-Jakarta districts are accessible from the Discover tab only (not from AR).

**Height-based style classification** (added 2026-07-04): `fetch_district_data.py` now classifies
buildings by height when OSM tags are ambiguous — `≥30m` → `modernGlass`, `≥15m` →
`modernConcrete`, otherwise `colonial` as default (or style from explicit `building:use` /
`architecture` tags). This means re-running the script after adding a district automatically
produces appropriate style distributions; hand-editing the JSON to override style for specific
buildings is still valid and takes precedence over the heuristic.

## Performance

`MetaCityTests/DistrictScenePerformanceTests.swift` measures the cost of the **SceneKit geometry
authoring step** (wall time + node counts, via `XCTest`'s `measure`/`ContinuousClock` — no
Simulator UI involved) — this is the `SharedCityGeometry` / `SCNNode` graph build path, which is
no longer in the app's runtime hot path (geometry is now built at runtime via `MeshDescriptor` in
`DistrictRealityKit`). The test still runs and is still useful as a regression guard for
`SharedCityGeometry`, but it does not measure what the app actually does when the user opens a
district. RealityKit's actual runtime rendering performance (draw calls, frame time on-device) has
not been separately profiled — the `MeshDescriptor` build replaces what was the USDZ-parse hitch,
and the entity cache (see item #7 below) means that hitch occurs once per `(district, isNight)`
pair at most.

### Runtime perf fixes (2026-06-28, second pass)

Three concrete bugs were found and fixed, not guessed at — all three were on a hot path that fires
on every SwiftUI re-render of the 3D views, not just on meaningful state changes:
- **`District.load(named:)` had no cache** — re-read + re-decoded a several-hundred-building JSON
  file from disk on every call. Now cached in-memory by resource name (`District` is a value type,
  so handing back the same cached instance repeatedly is safe).
- **`DistrictRealityKit.loadDistrictEntity` had no cache** — re-built the full `MeshDescriptor`
  geometry and re-created every `ModelEntity` (up to 427 buildings for Sudirman-Thamrin) from JSON
  on every call, across all three 3D views, with zero reuse between repeat visits to the same
  district. Now caches the styled `Entity` per `(name, isNight)` and hands back
  `.clone(recursive: true)` — an `Entity` can only have one parent, so the cached original is never
  itself added to a scene, only clones are.
- **`DistrictRealityView`'s orbit camera restarted on every `updateUIView`**, not just when
  auto-rotate was actually toggled — `update()` called `restartOrbit` unconditionally, which
  cancelled and recreated the per-frame subscription and reset its internal clock to zero. Since
  `updateUIView` fires on every SwiftUI re-render of the containing view, dragging the
  rotation-speed slider (which updates dozens of times per drag) was restarting — and visibly
  jumping — the camera on every tick. Fixed two ways at once: `update()` now only calls
  `restartOrbit` when `isAutoRotating` itself changes, and `startOrbit`'s angle is accumulated
  incrementally from *delta* time each frame (closure-polled `rotationSpeed`) rather than computed
  from total-elapsed-time-times-current-speed — so even a deliberate speed change blends smoothly
  instead of snapping.

Also: `installLighting` previously added a new sun+fill light pair on every call without removing
the previous pair (see the day/night section above — this was a real, separate contributor to that
investigation, not just a perf issue); `CallViewModel`'s `elapsedSeconds` was a per-second
`@Published` value that re-evaluated the entire `InCallView` body every tick — replaced with a
one-time `callStartDate` and a self-ticking `TimelineView`-based `CallTimerBadge` that only that
small subview re-renders; `ProfileViewModel.updatePreferences` was JSON-encoding + writing
`UserDefaults` on every keystroke of the bio `TextField` — now debounced (400ms) with a
`flushPendingSave()` safety net on backgrounding.

### Map/AR stability + dead-code/fluidity passes (2026-06-28, third and fourth pass)

After the perf pass above, a separate pass treated AR stability and map→AR selection sync as bugs,
not polish: `MapViewModel.select(_:)` now also calls `selectionStore.focus(on:)` immediately (it
previously only updated the map's own local selection, leaving `AppSelectionStore` — what
`ARViewModel` actually observes — stale until the explicit "View in AR" button); `ARSceneView`'s
tabletop placement switched from a fixed `AnchorEntity(world:)` transform to a real `ARAnchor`
registered with `arView.session.add(anchor:)`, so it benefits from ARKit relocalization after an
interruption; `Coordinator` gained full `ARSessionDelegate` conformance (failure/interruption/
tracking-state, surfaced via `ARViewModel.trackingStatusMessage`); changing the district picker
while a model was already placed now refreshes the placed entity in place instead of leaving stale
content; the tabletop placement gained a real directional sun + shadow (`makeLighting`) instead of
only a flat ambient point light.

A fourth pass then removed confirmed-dead code (`IndonesianCity.tagline`, `PlaceAnnotationItem.city`,
the empty `Networking/` directory, Profile's non-functional "Coming soon" section and its
`ComingSoonRow` struct — one of its three rows claimed Firebase auth was still pending, which was
already false) and made `DistrictRealityKit.loadDistrictEntity` `async` to defer (not eliminate —
see the `Entity`-MainActor section above for why elimination isn't possible) the first-visit parse
hitch until after each view's static scaffold renders. All three call sites
(`DistrictRealityView`, `SimulatedARSceneView`, `ARSceneView`) use a generation counter so a
superseded in-flight load (e.g. two rapid night-mode toggles, or a district change mid-load)
discards its result instead of racing.

### AR realism pass (2026-06-30)

Three targeted improvements implemented and build/screenshot-verified on Simulator:

1. **Procedural base-plate texture** (`ARSceneView.makeGroundTexture`): replaces the tabletop AR's
   flat `UIColor(white:0.08)` base plate with a 256×256 CoreGraphics-generated concrete-slab
   texture — radial vignette (center 0.04 dark, rim 0.14 lighter) faking contact-shadow AO from the
   overhead building cluster, plus deterministic LCG-hash per-pixel grain for surface texture. Runs
   on the main actor (required by `TextureResource.generate(from:withName:options:)`, iOS 15+) in
   the existing deferred `Task { @MainActor in ... }` in `ARSceneView.loadModel`, so the tap
   response is instant and the texture upgrade pops in the same beat as the building model.
   `TextureResource.generate(from:withName:options:)` is deprecated in favour of
   `init(image:withName:options:)` on iOS 18 but fully functional on iOS 17 — the deprecation
   warning is inert, not a build error.

2. **PBR material refinements** (`DistrictRealityKit.materialPreset`): per-style changes, all within
   confirmed-available iOS 15+ properties (no new property names, no `sheen`/`anisotropy` which
   aren't confirmed in this SDK):
   - `modernGlass`: (original 2026-06-30 values: roughness 0.08–0.16, clearcoatRoughness 0.05,
     metallic 0.78–0.84, deep blue tint — see glass material overhaul 2026-07-09 below for why
     these values were revised and what replaced them).
   - `modernConcrete`: roughness floor 0.65 → 0.60 (sealed/painted look), added `clearcoat = 0.10`
     with `clearcoatRoughness = 0.50` for a faint sealed-concrete sheen.
   - `colonial`: metallic 0.0 → 0.02 (lime-plaster micro-sheen), base color pushed slightly warmer
     (cream → warm buff).
   - `government`: added per-building roughness variation 0.73 + 0.08·|wobble| (was fixed 0.75).
   - `religious`: roughness 0.55 → 0.40–0.46 (glazed-tile/marble), added `clearcoat = 0.22` /
     `clearcoatRoughness = 0.28` for ceramic micro-reflections. Night emissive 0.35 → 0.50 (lit
     Jakarta mosques are disproportionately prominent in the night skyline).

3. **Cinematic establishing shot** (`DistrictRealityScene.startCinematicEntry`, wired in
   `DistrictRealityView.Coordinator.setUp`): on first open of the orbit inspector, the camera starts
   from 2.5× orbit-distance above center and 1.4× further back (aerial overhead), then crane-descends
   to the final mood-framed orbit height over 1.2s with a smoothstep (cubic Hermite) ease. The end
   position is exactly the `angle = 0` position `startOrbit` also begins at, so the handoff is
   seamless. A separate `cinematicEntrySubscription: Cancellable?` stores the in-flight entry;
   `restartOrbit` cancels it (plus any running orbit) before starting a new one, so a night-mode
   toggle or auto-rotate toggle mid-entry cancels the entry cleanly rather than leaving two
   subscriptions running.

### GPU draw-call + perf pass (2026-07-02)

Seven concrete fixes, all build/screenshot-verified, no USDZ re-export required:

1. **Material pool** (`DistrictRealityKit.materialPool`, `pooledMaterial(for:variation:isNight:)`):
   The previous scheme created one unique `PhysicallyBasedMaterial` per building entity — with
   continuous `Float` variation, SudirmanThamrin's 427 buildings produced 427 distinct material
   instances RealityKit couldn't batch, blowing the mobile GPU's ~200 draw-call budget on roads
   alone. Now bucketed to 10 discrete variation levels per style × 2 modes = **50 instances max**,
   keyed as `"\(style)_\(bucket)_\(isNight)"` in a static cache. The 10-level granularity is
   imperceptible in a dense 400-building scene but gives RealityKit the instance identity it needs
   to batch draw calls.

2. **FNV-1a hash** (`deterministicVariation(seed:)`): Swift's `Hasher` uses a per-process random
   seed since Swift 4.2 — the "same building looks the same every time" invariant was silently
   broken. Replaced with FNV-1a (deterministic, no seed, same result cross-launch).

3. **Window texture emissive** (`cachedWindowTexture`, `makeWindowTexture`): Night buildings used a
   uniform emissive tint — every facade glowed as a solid rectangle. Now a 128×128 CGImage texture
   (style-specific grid: modernGlass 8×16, colonial 4×6, etc.) is generated once per style and
   cached in `windowTextureCache`. Assigned to `PhysicallyBasedMaterial.emissiveColor.texture` —
   dark pixels multiply to zero emission, amber pixels (255,220,140) produce individual window dots.
   One texture per style × 2 modes = 10 instances max. Also `@MainActor` (required by
   `TextureResource.generate(from:withName:options:)`, same constraint as the base-plate texture).

4. **Atmospheric sky dome** (`installLighting` + `makeSkyGradient`): The flat
   `arView.environment.background = .color(.black)` behind buildings was replaced by an inside-out
   sphere (`scale.x = -1` flips normals inward) using `MeshResource.generateSphere`. A 1×32 pixel
   vertical gradient (ground→horizon, horizon→zenith with smoothstep per zone, per-mood colors)
   is generated as a `TextureResource` and applied as `UnlitMaterial.color.texture`. The texture
   generation is deferred to `Task { @MainActor in }` — lights + solid-color dome commit
   synchronously, gradient texture pops in a beat later (imperceptible since the dome fills at
   once). Cached by `"\(mood)_\(isNight)"`. `installLighting` now also removes `"skyDome"` children
   before re-adding — matches the same leak-prevention fix as the sun/fill pair.

5. **Orbit 30fps throttle** (`startOrbit`): The `SceneEvents.Update` subscription ran at 60Hz.
   A `frameCount & 1 == 0` guard halves it to 30fps — imperceptible for a slow city orbit but
   saves the GPU half the camera-transform cost. `lastFrameDate` is only updated on execute frames
   so `delta` naturally covers 2 display intervals (~33ms at 60Hz), keeping the orbit speed
   unchanged.

6. **`District.boundingBox` static cache** (`District.bboxCache`): `boundingBox` flatMap'd all
   buildings + roads (~6000 points for SudirmanThamrin) on every access. Both `center` and `extent`
   delegate to `boundingBox`, so a single `district.center; district.extent` pair ran three O(6000)
   passes. Now cached by district name after the first call (district data is immutable post-JSON
   decode, so this is always correct).

7. **District entity prefetch at launch** (`MetaCityApp.body`, `.task(priority: .background)`):
   Builds district day-mode entities into `DistrictRealityKit.entityCache` at app startup under
   background priority. Night mode excluded (cached on first night-toggle). Entity building is
   `@MainActor` (RealityFoundation hard constraint) — `.task` defers but does not off-thread.
   **Selective prefetch (2026-07-05, updated 2026-07-08)**: Malioboro (2,746 buildings), Kraton
   (2,922), Seminyak (1,939), Canggu (9,402), and Uluwatu (2,109) are excluded from startup
   prefetch — each produces 50–100K vertex buffer allocations on the main actor, causing
   multi-second hitches during launch. These five load on-demand on first user visit. The
   remaining 9 districts (Jakarta ×5, Bandung ×2, Kuta, Sanur) prefetch without perceptible
   cost. Prefetch set: `let heavyDistricts: Set<String> =
   ["Malioboro", "Kraton", "Seminyak", "Canggu", "Uluwatu"]` in `MetaCityApp.swift`.

**Camera far clip**: `DistrictRealityView` and `SimulatedARSceneView` now set
`camera.camera.far = district.extent * 6`, keeping the sky dome sphere (radius = `extent × 4`)
within the view frustum at all orbit angles.

### Per-building material variation (2026-07-05)

`makeBuildingMeshes` now groups by `(style, bucket)` instead of `style` alone, producing **3 material
variation buckets per style** → ≤18 building entities per district (was ≤6). Each bucket uses a
distinct wall material variation (0.0 / 0.5 / 1.0) so buildings of the same type read as individually
varied neighbours:
- Colonial blocks: cool buff / standard warm buff / amber-gold variants visible as distinct tonal bands.
- Glass towers: midnight navy / cool grey-blue / neutral silver (see glass wall material overhaul
  2026-07-09 below); night mode shows window-dot texture on glass (25% cell density 128×128 grid
  enabled for `modernGlass` — scattered cool-blue dots read correctly on medium towers 30–80m).
- Entity count: 18 max vs. 6 max. Draw calls unchanged effectively (RealityKit still batches instances
  of the same mesh, and each entity is still a merged single mesh for its entire style-bucket set).
The bucket for each building is its `deterministicVariation(seed: osmID)` mapped to `Int(v * 3)`,
0-indexed — same seed as before (FNV-1a on osmID), same determinism guarantee (same building, same
bucket, same launch).

**Known remaining draw-call issues (no USDZ export needed — JSON + code changes only):**
- **Style classification** — resolved as of 2026-07-04 by adding height-based heuristics to
  `fetch_district_data.py` (≥30m → modernGlass, ≥15m → modernConcrete, colonial as default) and
  re-running the script for all 5 districts. SudirmanThamrin now has 20 modernGlass + 106
  modernConcrete towers; the other 4 districts are geographically correct as predominantly colonial.
- **Road geometry explosion** — **resolved as of 2026-07-05**. `makeRoadMeshes` now merges all
  quads of the same `kind` into one `MeshDescriptor` before creating a `ModelEntity` — at most
  one entity per road kind (primary, secondary, service, …) per district, regardless of segment
  count. Ancol's 352 road segments reduce to ≤5 road entities.

### Multi-city visual verification pass (2026-07-05)

All 12 districts screenshot-verified for the first time. Four concrete bugs fixed:

1. **`buildingCentroid` camera target** (`DistrictFootprint.swift`, `DistrictRealityView.swift`):
   `District.center` (bbox midpoint) was used as the orbit camera's look-at target. For Dago, the
   bbox center was 111m X and 184m Z away from the actual building cluster — the scene rendered
   nearly empty, with buildings bunched at one edge. Fixed by adding `District.buildingCentroid`
   (mean of building polygon centroids, cached in `buildingCentroidCache`) and using it in
   `DistrictRealityView.setUp` instead of `center`. All other districts are compact enough that
   the difference was invisible; Dago is the confirmed worst case (linear 1km boulevard).

2. **beachResort sun overexposure** (`DistrictRealityScene.swift`): `beachResort` sun was 60,000
   lux (2.1× `colonialSquare`'s 28,000) — bleached balinese volcanic stone to near-white on
   Kuta/Seminyak/Canggu. Reduced to 35,000. Zenith fill color also de-saturated
   (`red: 0.28→0.38`) to remove blue-grey cast on warm stone walls.

3. **Balinese wall base color** (`DistrictRealityKit.materialPreset`, `.balinese`): Base
   color was `(0.72, 0.58, 0.42)` — too light, walls appeared white/cream instead of warm
   volcanic stone. Corrected to `(0.48, 0.34, 0.22)`. Screenshot of Kuta confirmed: buildings
   now read as warm golden-tan amber (correct), not colonial cream.

4. **Hotel misclassification as `modernGlass`** (Malioboro.json, Braga.json): OSM tags like
   `building:use=hotel` can trigger `modernGlass` classification in `fetch_district_data.py`
   *regardless* of height — even for hotels below the 30m height threshold. Meliá Purosani
   (28m), Hotel Malyabhara (28m), Riss Hotel Malioboro (24m) in Malioboro were blue glass
   curtain-wall in a traditional Javanese shophouse street. Reclassified to `modernConcrete`
   directly in the JSON. Bank Indonesia in Braga (32m, historic Dutch colonial bank building)
   was also `modernGlass` via height heuristic; reclassified to `government`. Pattern: when
   running `fetch_district_data.py` on new districts, grep the output JSON for `modernGlass`
   buildings and verify they're actually glass-curtain-wall towers, not concrete hotels.

**Also fixed this pass**: `CityManifest.json` Canggu `focusBuildingName` was `null` — set to
`"Castaway Hostel"` (most recognizable named building in the dataset, all Canggu buildings
are 7m estimated height so tallest-building criterion doesn't apply). Mood-aware ground plane and
selective launch prefetch (skip 4 heavy districts) documented below in their own sections.

### Canggu bbox expansion + `--default-style` flag (2026-07-06)

`tools/fetch_district_data.py` gained a `--default-style` CLI flag that routes all unlabeled
buildings to that `BuildingStyle` instead of always `colonial`. Used for Bali districts where
colonial stucco is wrong and `balinese` volcanic-stone is the correct area character.

`process_green_zones` expanded to also catch `natural=beach`, `natural=scrub`, `landuse=farmland`,
`landuse=orchard`, `landuse=meadow`, `landuse=forest`, `landuse=allotments` — previously only
`leisure=park` and a few `landuse` grass/recreation values were captured.

Canggu was re-fetched with an expanded bbox (`-8.665 115.118` → `-8.638 115.147`, ~3km × 3km vs.
the original ~770m × 890m) to capture the full Canggu-Berawa-Batu Bolong coastal strip:
```
python3 fetch_district_data.py \
  --name Canggu --bbox -8.665 115.118 -8.638 115.147 \
  --anchor -8.647 115.133 --default-style balinese \
  --out ../MetaCity/Resources/Districts/Canggu.json \
  --cache /tmp/canggu_raw_v2.json
```
Result: **9,402 buildings** (vs 1,123 before), 1,339 roads, 148 green zones (including rice
paddies as `landuse=farmland`). 99.9% `balinese` style. `Castaway Hostel` still present.
`CityManifest.json` `boundingBox` updated to match the new bbox. Build/screenshot-verified
2026-07-06 — full compound fabric rendered, rice paddy patches visible, POI beacons intact.

### Sanur + Uluwatu districts (2026-07-08)

Two new Bali/Denpasar districts added, bringing Bali to **5 districts** total.

**Fetch commands used:**
```
python3 fetch_district_data.py \
  --name Sanur --bbox -8.740 115.250 -8.700 115.278 \
  --anchor -8.720 115.260 --default-style balinese \
  --out ../MetaCity/Resources/Districts/Sanur.json \
  --cache /tmp/sanur_raw.json

python3 fetch_district_data.py \
  --name Uluwatu --bbox -8.850 115.075 -8.815 115.105 \
  --anchor -8.830 115.085 --default-style balinese \
  --out ../MetaCity/Resources/Districts/Uluwatu.json \
  --cache /tmp/uluwatu_raw.json
```

**Results:**
- Sanur: **1,366 buildings** (1,363 balinese, 3 modernConcrete for NNWW hotel), 528 roads, 4 green zones.
  `focusBuildingName: "NNWW hotel 1"` (most prominent named building in the OSM dataset).
  Sanur is a genuinely sparse beach resort — 1366 buildings across a 4km bbox — so the 3D view
  appears less dense than Canggu. This is accurate, not a rendering defect.
- Uluwatu: **2,109 buildings** (all balinese), 472 roads, 3 green zones.
  `focusBuildingName: "Single Fin"` (famous surf-bar/restaurant on the cliff edge).

Both added to `CityManifest.json` under `denpasar` city's `districts` array with `moodKey: "beachResort"`.
Uluwatu added to `heavyDistricts` in `MetaCityApp.swift` (2109 buildings → on-demand load, not startup prefetch).
Sanur is lightweight enough to prefetch (1366 buildings, similar to Kuta).

**`beachResort` camera height fraction** (2026-07-08): raised from **0.10 → 0.14**
(`DistrictRealityScene.Mood.cameraHeightFraction`). At 0.10 the elevation angle was ≈19° —
visually good for dense Canggu/Uluwatu but left sparse Sanur with buildings in only the bottom
30% of the frame. At 0.14 the elevation is ≈29°, which correctly frames both dense and sparse
beachResort districts. Canggu and Uluwatu verified by screenshot at the new fraction — density
unchanged, slightly more rooftops visible, still cinematic. Do not lower this back to 0.10 for
sparse Bali districts without first verifying Sanur's framing.

### Photorealism pass (2026-07-04)

Two targeted improvements:

1. **Separate roof materials** (`DistrictRealityKit.roofMaterialPreset`): the orbit camera mostly
   looks down, so what it sees is almost entirely rooftops. With a single shared material, colonial
   and modernGlass buildings looked identical from above.

   **Critical implementation note (2026-07-09)**: The original approach passed two `MeshDescriptor`
   objects (`wallDesc` + `roofDesc`) to `MeshResource.generate(from:)` and applied both as a single
   `ModelEntity(mesh:materials:[wallMat, roofMat])`. This is **silently broken**: in RealityKit,
   each `MeshDescriptor`'s primitive group defaults to `materialIndex = 0`, so `materials[1]`
   (roofMat) is **never used** — both parts render with `materials[0]` (wallMat). The symptom
   was glass tower rooftops appearing bright teal/cyan (reflecting the studio IBL's overhead ambient
   through the high-metallic wall material) rather than dark charcoal. The confirmed fix: use
   **two separate `ModelEntity` instances** — `makeBuildingMeshes` now uses `flatMap { -> [ModelEntity] }`
   and returns a `[wallEntity, roofEntity]` pair per bucket (not `compactMap { -> ModelEntity? }`).
   Draw calls: doubles from ≤6 to ≤12 building-type entities per quadrant per district. Still
   within RealityKit's ~200 draw-call budget for all 14 districts.

   Roof style materials:
   - `colonial`: terracotta red clay tile (`UIColor(red:0.66,green:0.27,blue:0.12)`, roughness 0.93,
     clearcoat 0.05 for faint rain-wet glaze) — the single most recognisable Jakarta aerial detail.
   - `modernGlass`: **`UnlitMaterial`** (white 0.10 day / dark cool-blue night). PBR at even
     metallic=0.10 + roughness=0.70 still renders as bright teal on upward-facing (0,1,0) surfaces
     in ARView's non-removable studio IBL — the IBL's overhead ambient floods grey bases. UnlitMaterial
     sidesteps IBL entirely. Architecturally correct — HVAC/gravel/parapet, not a glazed surface.
   - `modernConcrete`: light grey concrete (0.62, PBR roughness 0.88).
   - `government`: pale warm stone (0.78, 0.74, 0.66).
   - `religious`: muted teal/copper-patina (0.42, 0.64, 0.56), clearcoat 0.30 for ceramic glaze,
     night emissive 0.55 (lit mosque domes are disproportionately prominent at night).

2. **Shadow depth bias** (`DistrictRealityScene.installLighting`): `depthBias` reduced 1.5 → 0.35.
   The old value was so aggressive it pushed shadow edges 1–2m away from building footprints,
   making contact shadows invisible on low-rise colonial buildings (5–15m tall). At 0.35, shadows
   now appear right at the building base and read as a proper shadow cast on the pavement —
   particularly dramatic for Bundaran HI's glass towers under the `skyscraperCorridor` sun angle.

3. **`UnlitMaterial` for green zones** (`DistrictRealityKit.makeGreenZoneEntity`): `PhysicallyBasedMaterial`
   on a large flat horizontal surface receives the directional light's shadow map at city scale.
   RealityKit's fixed shadow-map budget spread over 600–1200m of scene space produces visible
   diagonal aliasing bands ("shadow stripes") on the green zones at oblique sun angles. `UnlitMaterial`
   is explicitly documented as "not affected by scene lighting or shadows" — it eliminates the
   artifact entirely. Vegetation at city-block scale reads as ambient ground cover, not a
   discrete shadow-receiving surface, so `UnlitMaterial` is both visually correct and artifact-free.
   Colors: day `UIColor(red:0.20,green:0.40,blue:0.14)` (tropical park green), night 0.05/0.10/0.03
   (near-black). Note: `maximumDistance` on the shadow component controls shadow depth range, not
   lateral frustum coverage — changing it does NOT improve shadow map texel density on horizontal
   surfaces and was not the correct fix for this artifact.

### Glass wall material overhaul + skyscraperCorridor teal fix (2026-07-09)

Teal/cyan rendering bug on SudirmanThamrin's `skyscraperCorridor` — rooftops and glass walls both
appeared bright blue-cyan. Three compounding causes, all fixed:

**1. `materialIndex = 0` bug** (root cause of teal *rooftops*): passing two `MeshDescriptor`s to
`MeshResource.generate(from: [wallDesc, roofDesc])` produced a `ModelEntity` where both descriptors
silently defaulted to `materialIndex = 0`, so `materials[1]` (the roof mat) was never used — both
surfaces rendered with the wall PBR material (high metallic = strong IBL teal reflection). Fixed by
`flatMap { -> [ModelEntity] }` producing separate `wallEntity`/`roofEntity` per bucket. Documented
under "Separate roof materials" above.

**2. Glass wall metallic too high** (cause of teal *walls*): `metallic = 0.78–0.84` (set during the
2026-06-30 AR realism pass) reflected ARView's non-removable studio IBL overhead blue-teal ambient
into every glass facade. Sweet spot found empirically: `0.46 + 0.06 × |wobble|` (range ~0.46–0.52).
Below ~0.35 the warm fill light dominates and buildings look terracotta; above ~0.55 the studio IBL
teal dominates. **Do not raise modernGlass wall metallic above 0.55** — confirmed regression on
Simulator. `clearcoat = 0.28`, `clearcoatRoughness = 0.14` unchanged.

**3. Glass wall base tints revised** (replaces "blue/neutral/green-tint" from 2026-07-05):

| Bucket | Color | RGBA |
|--------|-------|------|
| 0 | Midnight navy | `(0.07, 0.10, 0.26, 1)` |
| 1 | Cool grey-blue | `(0.26, 0.28, 0.36, 1)` |
| 2 | Neutral silver | `(0.32, 0.31, 0.31, 1)` |

Previous bucket 2 was warm bronze `(0.42, 0.36, 0.24)` — combined with the warm fill light
`(0.85, 0.72, 0.52)` it rendered as clay/terracotta. Replaced with neutral silver. Previous bucket
1 "neutral" was also tinting bronze; revised to a clearly cool tone.

**4. `skyscraperCorridor` sky + fill light revised**:
- Sky horizon: `(0.80, 0.86, 0.95)` → `(0.46, 0.54, 0.72)` — bright blue-white sky was washing
  out building silhouettes against the background.
- Sky zenith: `(0.12, 0.22, 0.48)` (unchanged — dark enough to read tall towers against).
- Fill light color: `(0.68, 0.78, 0.96)` (cool blue) → `(0.85, 0.72, 0.52)` (warm amber) — creates
  Blade Runner orange-vs-dark contrast between fill-lit and shadow-side faces of navy/silver towers.
  Fill intensity unchanged: `sunIntensity × 0.18` ≈ 6,300 lux at `skyscraperCorridor`'s 35,000 lux.

**Current `modernGlass` wall material parameters** (authoritative as of 2026-07-09):
```swift
baseColor:          bucket tint (see table above)
metallic:           0.46 + 0.06 * abs(wobble)    // was 0.78–0.84
roughness:          0.18 + 0.08 * abs(wobble)
clearcoat:          0.28
clearcoatRoughness: 0.14
```

### Mood-aware ground plane (2026-07-05)

`DistrictRealityKit.makeGroundPlane(for:mood:)` generates a mood-specific ground surface:
- **`beachResort`**: sandy ochre 4×4 CGImage tile (R=212, G=192, B=148 / R=198, G=178, B=136)
- **`sacredSite`**: dark volcanic andesite (R=68, G=62, B=56 / R=58, G=52, B=47)
- **default** (all other moods): existing limestone pavement texture (grey-beige)

Texture is generated in `makeGroundTexture(mood:)` on the main actor (required by
`TextureResource.generate`) and cached in `groundColorCache` by `"ground_\(mood.rawValue)"`.
The `CityOverviewView` (city block LOD) has a separate fixed dark asphalt ground — it does not
use this mood system.

`CityOverviewView` lighting bug fixed simultaneously: sun intensity was 6,000 lux (SceneKit-era
value, too weak to dominate ARView's default studio IBL) → 35,000 lux. Sky dome scale was
`SIMD3(-1, -1, -1)` (3 axes negated — coincidentally correct for spheres but wrong in principle)
→ `SIMD3(-1, 1, 1)` (only X flipped → reverses winding to face inward, same as `DistrictRealityScene`).

### Concave polygon triangulation fix (2026-07-05)

OSM building footprints include many concave shapes (L-shapes, U-shapes, courtyard buildings).
Simple fan triangulation from vertex 0 OR from the polygon centroid can produce triangles that
extend outside the polygon boundary, causing visible triangular "spike" artifacts in the mesh.

Two related fixes landed together in `DistrictRealityKit.makeBuildingMeshes`:

1. **Degenerate polygon filter** (pre-pass in building loop):
   - Area guard: `polygonArea(pts) >= 4.0` — skips slivers too small to render meaningfully.
   - Non-zero-edge guard: `minNonZeroEdge >= 0.5` — Douglas-Peucker simplification can leave
     duplicate vertices creating zero-length edges; computing `min_edge` naively over those
     would falsely flag all valid buildings. The guard uses `compactMap` to skip edges with
     `len ≤ 0.01` before finding the minimum.

2. **Centroid-fan roof triangulation with signed-area guard** (replaces vertex-0 fan):
   - The centroid of a highly concave polygon can fall outside it, making some fan triangles
     cover empty exterior space.
   - Fix: for each fan triangle `(centroid, j, i)`, compute its signed area `triSA` and compare
     sign to the polygon's own signed area `polySA`. A triangle whose sign disagrees is exterior
     — skip it: `guard triSA * polySA > 0 else { continue }`.
   - Coordinate system note: OSM outer rings are CCW geographically (north = +lat) but CW in the
     X-Z rendering frame (where Z = −lat). Valid building polygons have NEGATIVE `signedPolygonArea`
     in X-Z. The reversed centroid-fan winding `[centIdx, j, i]` (vs. `[centIdx, i, j]`) produces
     upward-facing normals (+Y) for this CW winding. Do not flip the winding without re-verifying
     both the normal direction and the signed-area guard direction.

Helper functions added at the bottom of `DistrictRealityKit`:
```swift
private static func polygonArea(_ pts: [LocalPoint]) -> Float { abs(signedPolygonArea(pts)) }
private static func signedPolygonArea(_ pts: [LocalPoint]) -> Float { /* shoelace */ }
```

### Activities tab (2026-07-04)

A fourth tab displays curated tourism activities per city. Architecture:

- **Model**: `ActivityEntry` (id, name, category, tier, description, area, priceRange, duration,
  lat/lon) and `CityActivities` (cityId + activities array) in `ActivityEntry.swift`.
  `CityActivities.load(for:)` reads `activities_<cityId>.json` from the bundle — prefixed to
  avoid name collision with district JSONs (XcodeGen flattens all resources to the bundle root).
- **Data files**: `MetaCity/Resources/activities_jakarta.json`, `activities_bandung.json`,
  `activities_denpasar.json` — one JSON per city using `CityEntry.id` as the filename suffix.
- **UI**: `ActivitiesView` / `ActivitiesViewModel` — category-filter chips, list grouped by
  `ActivityCategory`. City is contextual (the city selected in the Discover tab persists).
- **Categories**: `eat`, `stay`, `explore`, `nightlife`, `wellness`, `shopping`, `sport`.
- **Tiers**: `premium` vs. `standard` — visually differentiated in the list.
- **Discover→Activities city sync** (2026-07-05): `ActivitiesViewModel` moved out of
  `ActivitiesView` (`@StateObject`) into `HomeTabView` (`@StateObject`), so `HomeTabView.onChange(of:selectedTab)` can call `activitiesViewModel.selectCity(city)` when the user switches to the Activities tab while a city is focused in Discover. `ActivitiesViewModel.init(preselectedCity:)` accepts an optional city for future deep-link use. `ActivitiesView` uses `@ObservedObject` since it no longer owns the VM lifecycle.

### Street View / close-up camera mode (2026-07-04)

The orbit inspector in `DistrictRealityView` has a second camera mode: a ground-level close-up
that frames the focus building at eye level. Toggled via `DiscoverViewModel.isCloseUp`.

- **Focus target**: `CityManifest.shared.district(id:)?.focusBuildingName` — looked up in the
  manifest, case-insensitively matched against `district.buildings`. Falls back to first named
  building, then first building.
- **Camera position**: centroid of the focus building's polygon + 12% of `district.extent` in
  front (along +Z in local space), at `eyeHeight = 6.0m`.
- **Animation**: `flyCamera(to:lookAt:scene:)` in `DistrictRealityView.Coordinator` — cubic
  Hermite smoothstep over 1.0s, `SceneEvents.Update` subscription that self-cancels at `t ≥ 1`.
  Uses `RealityKit.Scene` type qualification to resolve ambiguity with SwiftUI's `Scene`.
- **Auto-rotate**: disabled when entering close-up (`isAutoRotating = false` is set
  simultaneously with `isCloseUp = true` in `DistrictControlsPanel`).
- **Return**: tapping "Orbit" re-runs `restartOrbit(isAutoRotating:)`, smoothly returning to
  the orbit position.

### `DistrictControlsPanel` layout invariant

`Toggle("Label", isOn:)` in a tight HStack wraps its label to multiple lines when the available
width is constrained. The correct pattern for controls that must not wrap:

```swift
VStack(spacing: 2) {
    Toggle("", isOn: $vm.isAutoRotating)
        .labelsHidden()
        .tint(Color.metacityPrimary)
    Text("Rotate")
        .font(.metacityCaption)
}
```

Do not use `.fixedSize()` on the Toggle — it causes the HStack to overflow, pushing the entire
controls panel off-screen (only a few pixels visible above the tab bar).

**Safe-area layout (2026-07-05)**: `DiscoverView.body`'s outer ZStack no longer carries
`.ignoresSafeArea(edges: .all)` — all full-screen layers (`mapLayer`, `sceneLayer` views) each
carry their own individual `.ignoresSafeArea()` and remain full-screen, while the overlay layer
now respects safe areas automatically. Consequences:
- All `.padding(.top, 60)` nav bar headers → `Spacing.md` (12pt below status bar safe edge).
- `DistrictListPanel.padding(.bottom, 96)` → `Spacing.sm` (8pt above tab bar safe edge).
- `DistrictControlsPanel.padding(.bottom, 90)` → `Spacing.sm` (8pt above tab bar safe edge).
- `CityCalloutCard` (cityFocused state) now sits above the tab bar instead of being partially
  hidden behind it — the Spacer-push to VStack bottom is safe because the VStack's bottom is
  the safe area edge, not the physical screen bottom.
Do NOT restore the old hardcoded 90/96pt bottom paddings — they compensated for the lack of safe
area awareness and are now redundant (and would double the clearance above the tab bar).

### `balinese` BuildingStyle + new mood keys

A sixth `BuildingStyle` case was added for Bali/Denpasar districts:
- **`balinese`**: stone/volcanic-tuff base color (warm dark brown,
  `UIColor(red:0.48+0.04*wobble, green:0.34, blue:0.22)`), roughness 0.82–0.88, metallic 0.00,
  clearcoat 0.06 for wet-stone sheen. Night emissive 0.20 (soft warm torch-light) — deliberately
  lower than `religious` (0.50) since Balinese temples and compounds are more intimate in scale.
  **History**: original base was `(0.55, 0.40, 0.28)` which bleached to near-white under
  `beachResort`'s 60,000 lux sun; corrected to `(0.48, 0.34, 0.22)` and sun reduced to 35,000 lux
  simultaneously (2026-07-05 visual verification pass). Do not raise the base color back toward 0.7+
  without also verifying Kuta/Seminyak screenshot under full daylight — that combination is what
  caused the original regression.

Two new `DistrictRealityScene.Mood` keys:
- **`beachResort`** (Seminyak, Kuta, Canggu): sun 35,000 lux (NOT 60,000 — confirmed to bleach
  balinese stone), de-saturated zenith `red=0.38` (NOT 0.28 — fills were casting blue-grey onto
  warm stone), warmer golden-hour key light, sky dome with ocean-horizon haze gradient, shorter
  camera distance to read low-rise compound architecture.
- **`sacredSite`** (Kraton, Malioboro): slightly elevated camera, cooler morning-mist fill
  light, desaturated sky for the stone-city atmosphere.

## What's real vs. estimated vs. stylistic, honestly

- Building footprints (shape) and road centerlines: real, from OpenStreetMap.
- Heights: real where OSM tags or the hand-curated landmark list provide them; heuristic-estimated
  (flagged) otherwise.
- Vegetation, street furniture, signage: **not from real per-item data** — OSM has essentially no
  coverage at that granularity for Jakarta. A tinted green zone where OSM tags a literal park is
  real footprint data; there's no per-tree/per-bench placement claim anywhere.
- Materials/colors: stylistic but deliberate and consistent — one fixed `PhysicallyBasedMaterial`
  preset per `BuildingStyle` (`DistrictRealityKit.materialPreset`), with a small deterministic
  per-building roughness/tint wobble (FNV-1a hash of OSM ID, bucketed to 10 levels). Never
  randomized per building — the same building looks the same across launches.

### Zoned green zones + GreenZone.kind field (2026-07-06, Phase 3a)

`GreenZone` gained an optional `kind: String?` field (nil for all pre-Phase-3a district JSONs;
decodes safely with no migration). `fetch_district_data.py` now writes `kind` to every emitted
green zone via `_green_zone_kind(tags)`:

```
"natural=beach"    → landuse=beach in OSM
"landuse=farmland" → rice paddies, fields
"landuse=orchard"  → orchards
"landuse=meadow"   → meadows
"landuse=forest"   / "natural=wood" → forest
"natural=scrub"    → scrub
"landuse=allotments"
"leisure=park"     → default for anything else
```

`makeGreenZoneEntity` → renamed to `makeGreenZoneEntities` (plural, returns `[ModelEntity]`).
Groups zones by `kind` into one `MeshDescriptor` per kind → one draw call per kind, max 5 for
Canggu. `greenZoneColor(kind:isNight:)` maps each kind to a distinct `UnlitMaterial` color:
- `natural=beach` → sandy ochre (0.88, 0.80, 0.60) day / dark beige night
- `landuse=farmland/orchard/meadow` → bright tropical green (0.22, 0.48, 0.15)
- `landuse=forest` → deep forest (0.10, 0.26, 0.06)
- `natural=scrub/allotments` → scrub olive (0.35, 0.42, 0.18)
- default / `leisure=park` → park green (0.20, 0.40, 0.14) — same as before

Canggu.json was re-generated from cache with `kind` in all 148 green zones
(6 beach, 111 farmland, 16 orchard, 10 park, 4 scrub, 1 meadow). Other 11 districts: `kind` is
null in their JSONs; rendering falls back to generic park green, correct for Jakarta/Bandung/Yogya.

**LoadDistrictEntity call site**: `makeGreenZoneEntities` returns `[ModelEntity]`; caller loops
and adds each child to root. Replaces the single `if let greenEntity = makeGreenZoneEntity(...)`.

### Hip roof caps (2026-07-06, Phase 3b)

New `// MARK: - Roof caps` section in `DistrictRealityKit.swift` adds a hip-roofline mesh above
buildings of styles `balinese`, `colonial`, `javanese`, `religious`. One merged `MeshDescriptor`
per style → ≤4 draw calls total for all roof caps in the scene.

**Geometry**: bounding-box hip roof (not polygon-from-OSM — avoids concavity on L/U-shaped
footprints). Eave corners expanded by `overhang`; ridge along the longer bbox axis; two trapezoidal
faces + two triangular hip faces per building. Pyramid fallback when `W ≈ D` (ridge < 0.1m).

**Key invariant — `maxRidgeInset` not `maxRidgeH`**: `ridgeInset = min(min(W,D)/2, maxRidgeInset)`
then `ridgeH = ridgeInset * pitchTan`. This caps the *horizontal depth* of the hip slope, keeping
pitch angle consistent across all building sizes. Large buildings get a long flat ridge + steep hip
ends, not a shallow tent. **Do not change this to cap `ridgeH` directly** — that flattens the pitch
proportionally with building size and makes large buildings look like flat slabs with a slight lip
(confirmed via a screenshot regression on the first attempt).

**Footprint size filter**: `guard min(x1r-x0r, z1r-z0r) <= 12.0` — buildings with short side > 12m
(warehouses, civic halls, museums) keep their flat top from `makeBuildingMeshes`. This is both
architecturally correct (large Indonesian civic buildings have flat gravel/metal roofs) and
visually necessary (large terracotta roof planes dominate the scene from orbit and read as slabs).

**`addRoofFace` auto-flip guard**: computes face normal from `cross(v1-v0, v2-v0)`. If `n.y < 0`
(face pointing down), reverses vertex order and negates normal. Guarantees all hip faces are
visible from the orbit camera, regardless of whether the eave→ridge winding is CW or CCW.

**Per-style parameters (final, 2026-07-06):**

| Style      | overhang | pitchTan | maxRidgeInset |
|------------|----------|----------|---------------|
| balinese   | 0.80 m   | 0.839 (~40°) | 3.5 m     |
| colonial   | 0.30 m   | 0.625 (~32°) | 4.0 m     |
| javanese   | 0.60 m   | 1.000 (45°)  | 4.0 m     |
| religious  | 0.25 m   | 0.700 (~35°) | 3.5 m     |

Roofs use `PhysicallyBasedMaterial` (not `UnlitMaterial` — upward-facing surfaces should receive
the directional sun). ARView's neutral studio IBL washes the terracotta to salmon/orange — this
is the known documented limitation; it does not affect Kota Tua much (terracotta still reads
correctly) but is more pronounced on Canggu. The fix requires a custom IBL resource which needs
Reality Composer Pro (blocked in terminal-only environment — see iOS 17 section).

### Authored venue overrides + new roof shapes (2026-07-06, Phase 3c)

**Sidecar file**: `MetaCity/Resources/<DistrictId>_authored.json` (capital-first, matching the
district JSON filename case — e.g. `Canggu_authored.json`). Loaded by
`DistrictAuthoredOverrides.load(for: resourceName)` inside `District.load(named:)`, applied before
the cached `District` value is stored. The sidecar is optional — if it's absent, the district
loads normally. Only Canggu has a sidecar currently.

**`BuildingFootprint.roofType: String?`**: new optional field (nil for all OSM-sourced buildings,
where roof is decided by `makeRoofCapEntities` based on `style` + footprint size). Set by the
sidecar via `BuildingFootprint.applying(_ override: AuthoredBuildingOverride)`.

**Roof type values**: `"conical"`, `"thatched"`, `"dome"`, `"hip"` (explicit style-default hip),
`"flat"` (no cap). `makeRoofCapEntities` skips buildings with `roofType != nil`; they're handled
by `makeAuthoredRoofEntities` instead (one `MeshDescriptor` per type → ≤3 draw calls regardless
of how many buildings are overridden).

**New geometry functions** (`DistrictRealityKit`):
- `addConicalRoof`: 8-sided octagonal cone, pitchTan 1.19 (~50°), overhang 0.5m. Terracotta color
  (same as balinese hip). Used for Balinese temple meru towers and pavilion roofs.
- `addDomeRoof`: 8-slice × 3-latitude-stack hemisphere (3 rings at 30°/60°/90° from pole).
  Blue-grey metallic material with 0.20 clearcoat. Used for mosque domes and hotel cupolas.
- `addHipRoof` with pitchTan 1.40 + maxRidgeInset 2.5 = **thatched** profile (steep, wide eave,
  short ridge). Dark warm brown `(0.28, 0.18, 0.08)` roughness 0.97. Used for open-air surf bars,
  hostel compounds, yoga studios.

**`Canggu_authored.json` — 10 buildings:**
| Building | roofType |
|---|---|
| Old Man's | thatched |
| The Lawn | conical |
| Atlas Super Club | thatched |
| Pura Dalem Prancak | conical |
| Pura Dalem Tandeg | conical |
| Pura Ulun Suwi | conical |
| Masjid Al Hasanah (Canggu Permai) | dome |
| Castaway Hostel (focus building) | thatched |
| Tugu (+ Villa Tugu via substring) | dome |
| Serenity Yoga | conical |

The authored shapes are small (all ≤7m, footprint < 12m) and invisible at full-district orbit
scale — they read in the Street View close-up camera when the focus is near those buildings.

**To add a sidecar for another district**: create `<DistrictId>_authored.json` in
`MetaCity/Resources/`, run `xcodegen generate`, rebuild. `nameMatch` is a case-insensitive
substring match against `BuildingFootprint.name`; `osmID` is an exact match and takes precedence.

### Spatial LOD quadrant chunking (2026-07-06, Phase 3e)

All districts now use a 4-quadrant spatial partition (NW/NE/SW/SE split on `buildingCentroid`).
Each quadrant is an `Entity` container named `"q0"`–`"q3"`, with two children:
- **`"near"` (isEnabled=true by default)**: full polygon-extrusion building + roofCap + authoredRoof geometry for that quadrant's buildings
- **`"far"` (isEnabled=false by default)**: one merged AABB-box `ModelEntity` per quadrant — one box per building, top+4 walls, ~5× fewer vertices than the polygon extrusion

Roads, green zones, ground, water, lights, sky dome, and POI beacons remain at root level (they span quadrants or are few enough to not benefit from splitting).

**LOD state machine**, wired in `DistrictRealityView.Coordinator`:
- **Orbit mode** (`venueTargetPOIId == nil`): `applyOrbitLOD()` — all near=true, far=false, `lodSubscription` cancelled. This is the default and the entity-cache template state.
- **Venue mode** (`venueTargetPOIId != nil`): `startVenueLOD(scene:)` — subscribes to `SceneEvents.Update`, every frame measures `sqrt(dx²+dz²)` from camera XZ to each quadrant's AABB center (computed from `cachedDistrict` buildings, not from entity position). Quadrants within `districtExtent × 0.5` stay near; farther quadrants flip to far.

**Critical invariant — quadrant containers must have `position = .zero`**: Building vertex coordinates in `MeshDescriptor` are absolute model-local (anchored at the district anchor, same as roads and ground). If the quadrant container has a non-zero position, all children are translated by that offset, placing the geometry at a doubled coordinate. The LOD threshold centers are computed from `cachedDistrict.buildings` in `extractQuadrantLOD`, not from `entity.position`.

**Threshold sizing**: `districtExtent × 0.5`. For Canggu (extent ~3km) → 1.5km threshold. Orbit camera is always in near range of all quadrants (orbit height + distance > threshold, but LOD is disabled in orbit mode anyway). In venue close-up (~8m height, ~40m forward), the active quadrant is ~750m from its center → near; opposite quadrant ~2km → far. For Jakarta (extent ~500m) → 250m threshold; all quads stay near in any view — LOD is transparent for small districts.

**Progressive build**: `await Task.yield()` after each quadrant's geometry is added. Canggu's 9,402 buildings (≈2,350 per quadrant) build in 4 deferred main-actor turns. The static scaffold (lights, ground, sky) commits before the first quadrant geometry arrives, then quadrants pop in one by one. Cache hit on second visit: instant (entity clone).

**Entity cache compatibility**: `entityCache["\(name)_\(isNight)"]` stores the template root with all near=true/far=false. Clones start in orbit state. The coordinator's `quadrantLOD` array holds references to the clone's (not the template's) near/far entities — toggling them only affects the live clone.

**Non-Canggu districts**: All 12 districts use the same quadrant structure. Jakarta (≤427 buildings) splits into 4 quadrants of ≤107 buildings each — the geometry per quadrant is tiny and near-instant to build; no perceptible behaviour change. The quadrant overhead is 4 extra empty `Entity` containers, which is free.

### Palm tree instancing (2026-07-06, Phase 3d)

A batched palm tree layer adds tropical identity to Bali districts. Two `ModelEntity` instances per quadrant (trunk batch + canopy batch) = **2 draw calls for the entire palm layer of that quadrant**, regardless of how many palm trees it contains.

**Tropical-zone gate**: `districtPalmPositions` returns immediately with an empty cache entry for districts that have no `natural=beach`, `landuse=farmland`, or `landuse=orchard` green zones. This correctly limits palms to Bali districts (Canggu, Seminyak, Kuta all have these zone types) while excluding Jakarta, Bandung, and Yogyakarta (which have only `leisure=park` zones). No explicit district list needed — the zone types are the semantic marker.

**Placement rules** (computed once per district, cached in `palmPositionCache`):
1. **Road edges**: both sides of `primary` / `secondary` / `tertiary` / `residential` / `unclassified` roads, offset perpendicular by `palmRoadOffset(for:)` (4.0–8.5m depending on road type), every 20m along each segment.
2. **Beach boundaries**: perimeter of `natural=beach` green zones, every 9m — palms line the coast–vegetation transition.
3. **Farmland / orchard / park edges**: perimeter of `landuse=farmland`, `landuse=orchard`, `leisure=park` zones, every 13m — frames the transition between paddy fields and compounds.

**Avoidance** (both O(n) via spatial hash-sets):
- **Building avoidance**: 6m cells; 3×3 cell neighborhood check = rejects candidates within ~12m of any building centroid.
- **Palm separation**: 5m cells; 3×3 neighborhood check = minimum ~5m between any two accepted palms.

**Geometry** (in `addPalmTrunk` / `addPalmCanopy`):
- **Trunk**: tapered 4-sided prism, 4 independent face quads (each with its own outward normal). Base radius 0.28m, top radius 0.17m, height 6.5–11.5m (FNV-1a deterministic per position). Winding verified CCW-from-outside for RealityKit's CCW front-face convention. `PhysicallyBasedMaterial` — vertical surfaces receive the directional sun correctly.
- **Canopy**: 4 crossing frond quads at 0°/45°/90°/135°, all at crown height + 0.3m. Each frond is 3.4m span × 0.9m wide. Vertex order `[tip1-neg, tip2-neg, tip2-pos, tip1-pos]` gives CCW from +Y (orbit camera). `UnlitMaterial` — same rationale as green zones: `PhysicallyBasedMaterial` on large horizontal surfaces produces shadow-map aliasing stripes from RealityKit's fixed shadow-map budget spread over km of scene space.

**Draw call budget** (Canggu):
| Layer | Draw calls (near, all quads) |
|---|---|
| Buildings | ≤18 |
| Roof caps | ≤4 |
| Roads | ≤6 |
| Green zones | ≤5 |
| Ground + water | 2 |
| **Palms** | **8** (2 trunk + 2 canopy × 4 quads) |
| Total with palms | ~43 |

**LOD**: Palms exist only in `near` containers — identical to buildings/roofs. In venue mode, distant quadrant palms are hidden with the rest of the near content when that quadrant flips to its far AABB tier. No dedicated palm far tier: at LOD-far distance (~1.5km for Canggu), individual palm silhouettes are sub-pixel regardless.

**Expected palm count for Canggu**: approximately 1,200–1,800 accepted positions (from ~3,000–5,000 initial candidates, filtered by building avoidance and palm-separation grid). Split evenly across 4 quadrants ≈ 300–450 per quadrant.

## Day/night, bloom, and ambient particles (SceneKit-only, historical)

The retired SceneKit renderer (`DistrictScene3DView`/old `SimulatedARSceneView`/`ARSceneView`) used
a restrained bloom (`bloomIntensity ~0.3`, `bloomThreshold ~0.85`) and a sparse `SCNParticleSystem`
ambient-dust effect. **Neither was ported to the RealityKit renderer** — RealityKit's `ARView` has
no direct equivalent of SceneKit's camera-level bloom controls, and the particle system was dropped
rather than rebuilt with RealityKit's particle APIs, to keep the iOS-17 RealityKit pass scoped to
geometry/material/lighting rather than re-implementing every atmospheric flourish. If bloom or
ambient particles are wanted back, that's new RealityKit-side work, not a settings tweak.

### AR stabilisation + The Lawn showcase (2026-07-07)

**Bug fixes — all build/screenshot-verified:**

1. **Building tap always triggered** (`DistrictRealityView.handleSingleTap`): `min(by:)` always
   returns a result even when tapping empty sky. Added a max-distance guard: the ray must pass
   within `districtExtent × 0.10` of any building centroid or the selection is dropped. For
   Canggu (3 km) = 300 m; for Jakarta (500 m) = 50 m. Prevents phantom `BuildingInfoCard`
   pop-ups and erratic camera flies on sky-taps.

2. **Palm tree visual spikes in orbit** (`DistrictRealityView.applyOrbitLOD` +
   `startVenueLOD`): Palm trunk entities (0.17–0.28 m diameter, 6.5–11.5 m tall) were sub-pixel
   at orbit distance but still rendered → appeared as a dense forest of coloured spikes across the
   skyline. Fix: `applyOrbitLOD` now calls `setPalmsEnabled(false, in: node.near)` which walks
   the near container's direct children and disables any entity named `"palm_trunk_qN"` or
   `"palm_canopy_qN"`. Root cause of timing: `applyOrbitLOD` was called at setUp when
   `quadrantLOD` was still empty (model not yet loaded); **fix is to call `applyOrbitLOD()` again
   at the end of `loadModel`'s async Task, after `extractQuadrantLOD` populates the array.**
   Palms re-enable automatically when venue mode activates (per-frame LOD subscription) and the
   camera is within `districtExtent × 0.5` of a quadrant.

3. **The Lawn Canggu — wrong roof type** (`Canggu_authored.json`): Was `"conical"` (Balinese
   temple meru shape). The Lawn is an open-air beach club/bar → corrected to `"thatched"`.

4. **Canggu activities never loaded** (`ActivitiesViewModel.loadActivities`): `activities_canggu.json`
   used `cityId: "canggu"` but the manifest has no city with that id (Canggu is district of
   "denpasar"). Fix: `loadActivities(for:)` now appends district-level files for every district
   in the city: `CityActivities.load(for: district.id.lowercased())`, de-duped by id. Same
   mechanism loads `activities_kuta.json` and `activities_seminyak.json` automatically.

**New authored override files:**
- `Seminyak_authored.json` — 20 overrides: temples → conical, mosques → dome, beach clubs
  (KU DE TA, La Plancha, Métis, Sardine, Unit) → thatched, modern hotels (Potato Head, W Bali,
  Merah Putih, Mama San, Mirror) → flat.
- `Kuta_authored.json` — 16 overrides: temples → conical, mosques → dome, mega-venues
  (Hard Rock, Beachwalk, Discovery, Waterbom, Sky Garden, Bounty, Krisna) → flat,
  beach bars (Poppies, Apache, Mango's, Fat Yogi, Lacalita) → thatched.

**New activity files (district-level, loaded by denpasar city VM):**
- `activities_kuta.json` — 6 activities: surf, Waterbom, sunset walk, Legian nightlife, spa, Krisna
- `activities_seminyak.json` — 6 activities: Potato Head sunset, Métis dinner, COMO spa, Pura
  Petitenget sunrise, surf lesson, boutique shopping

**The Lawn Canggu showcase status**: POI `lawn_canggu` is wired in `pois_canggu.json`
(`approachBearing: 270`, `approachDistance: 50`, `partnerURL: "https://www.thelawncanggu.com/"`).
Roof corrected to `thatched`. Interior accessible via "Explore Inside" on VenueCard. The `assets_manifest.json` records it as the Canggu district showcase building. `focusBuildingName` in
`CityManifest.json` is still `"Castaway Hostel"` (nearest named building in the OSM set to
Castaway's footprint) — The Lawn is accessed via POI selection, not the focus beacon.

**`assets_manifest.json`** — new reference file documenting all district, POI, activities, and
authored files. Not loaded by the app (no Swift model); purely for human reference and future
tooling. Located at `MetaCity/Resources/assets_manifest.json`.

### Building interior view system (2026-07-07)

A first-person interior view (`BuildingInteriorView.swift`) renders the inside of any tapped
building using the same `BuildingFootprint` polygon that drives the exterior mesh:

- **`BuildingInteriorView: UIViewRepresentable`** — `ARView(.nonAR)` with a `PerspectiveCamera`
  at eye height 1.8m, facing `longestWallYaw` (the midpoint of the longest polygon edge).
  Single-finger pan → look around (yaw ±∞, pitch clamped ±0.55 rad). Pinch → step
  forward/backward along look vector. Double-tap → reset to entry position.

- **`InteriorSceneBuilder`** — builds the procedural interior: floor (centroid-fan with
  signed-area guard, normal +Y), ceiling (same, normal −Y at `buildingHeight`), inward-facing
  walls (LEFT perpendicular of CW edge = inward normal `(-dz, 0, dx)`, reversed quad winding
  `[B, A, A+H, B+H]`), style-specific furniture (box entities), and warm interior lighting
  (PointLight at ceiling center). Runs `@MainActor` (same RealityFoundation constraint as the
  exterior pipeline — see `Entity`-MainActor section above).

- **`InteriorFullScreenView`** (private in `DiscoverView.swift`) — SwiftUI overlay on top of
  `BuildingInteriorView`: translucent header with building/POI name, close button; timed
  navigation hint badges that fade after 4s; optional "Official website →" Link if the POI has
  a `partnerURL`. Presented as `.fullScreenCover(item: $viewModel.interiorBuilding)` from
  `DiscoverView`.

- **Entry points** — `DiscoverViewModel.enterBuilding(_:poi:)` (direct call with a known
  `BuildingFootprint`) and `enterBuildingForPOI(_:in:)` (finds the closest building to a POI's
  lat/lon using squared-distance comparison on polygon centroids — no `simd_length` import
  needed). `closeInterior()` clears both `@Published` properties.

- **"Explore Inside" button** — appears on `VenueCard` (shown when a POI is selected) and on
  `BuildingInfoCard` (shown when a plain building is tapped with no matching POI). Both call
  `viewModel.enterBuildingForPOI(poi, in: district)` or `viewModel.enterBuilding(building)`.

### POI system: official URLs (2026-07-07)

`CangguPOI.partnerURL: String?` was added in an earlier pass for Canggu. As of 2026-07-07,
three POI collections exist:

| File | District | POIs | Featured (tier=featured) |
|---|---|---|---|
| `pois_canggu.json` | Canggu | 45 | 10 (all have real `partnerURL`) |
| `pois_seminyak.json` | Seminyak | 19 | 4 (Potato Head, KU DE TA, Pura Petitenget, W Bali) |
| `pois_kuta.json` | Kuta | 17 | 5 (Waterbom, Hard Rock, Kuta Beach, Beachwalk, Sky Garden) |

`CangguPOICollection.load(for: districtId)` looks for `pois_\(districtId.lowercased()).json` in
the bundle — the filename must match exactly (lowercase district ID). The loader is cached by
lowercase key; cache is populated on first access and never invalidated (POI data is treated as
immutable for a given app install, same as district geometry).

To add POIs for a new district: create `pois_<lowercaseId>.json` in `MetaCity/Resources/`,
run `xcodegen generate`. The `featuredPOIsForMap` property on `DiscoverViewModel` calls
`CangguPOICollection.load(for:)` for every district of the focused city — if the file doesn't
exist, `load` returns `nil` silently (no crash, no pins shown).

`ActivityEntry.officialURL: String?` was added to `ActivityEntry.swift` and `ActivitiesView`
renders a "Official site" Link button when the URL is non-nil.

## France architecture (added 2026-07-09)

### New BuildingStyle cases

Three cases added to `BuildingStyle` enum in `DistrictFootprint.swift`:

- **`haussmannien`**: Lutetian limestone — warm cream-to-off-white facade (`dayR = 0.86 + 0.04·wobble`),
  roughness 0.74–0.80, clearcoat 0.10/0.55. Roof: zinc mansard grey-blue `(0.42, 0.46, 0.52)`,
  roughness 0.86, clearcoat 0.08. Mansard cap geometry: **70° pitch** (`pitchTan: 2.747`),
  `maxRidgeInset: 1.8m`, overhang 0.15m. The near-vertical Second Empire profile, very short flat
  ridge — distinguishes the Paris aerial view from every other city in the app. Night emissive 0.40.
  Window texture: 5×8 grid, density 0.35.

- **`medieval`**: Half-timber plaster + Breton granite — warm buff base (0.76–0.82), roughness
  0.84–0.92, clearcoat 0.06/0.80. Roof: dark Breton clay tile `(0.48, 0.18, 0.08)`, roughness 0.93.
  Cap geometry: 50° pitch, `maxRidgeInset: 2.5m`, overhang 0.35m. Night emissive 0.28.
  Window texture: 3×5 grid, density 0.20.

- **`bordelaisClassical`**: Calcaire à astéries (shelly Gironde limestone) — distinctly warmer
  amber-gold than Parisian Lutetian cream. Wall: `(0.82+0.06·wobble, 0.72+0.03·wobble, 0.50)`,
  metallic 0.01, roughness 0.76–0.82, clearcoat 0.08/0.60. Night emissive 0.38.
  Roof: Provençal canal tile, terracotta `(0.64, 0.28, 0.12)`, roughness 0.91, clearcoat 0.04.
  Cap geometry: **30° pitch** (`pitchTan: 0.577`), `maxRidgeInset: 3.0m`, overhang 0.25m — the
  low-profile shallow-pitch ridge of the UNESCO Port de la Lune quay fabric, visually distinct from
  the near-vertical Paris mansard. Window texture: 4×6 grid, density 0.30.
  Height estimate default: **16.0m** (4-storey Bordeaux block at 4m/floor, `isHeightEstimated: true`).
  **Do NOT raise the base blue channel** (currently B=0.50) — higher values push the facade toward
  Parisian cream; the amber distinction requires keeping blue below 0.55.

All three are in `capStyles` (get hip roof geometry). All three have road materials in
`roadMaterial(for:mood:)`.

**`makeRoofCapEntities` loop bug fixed (2026-07-09)**: the loop originally only iterated over
`[.balinese, .colonial, .javanese, .religious]`. Both `.haussmannien` and `.medieval` were in
`capStyles` but **not** in the loop, so Paris and Rennes buildings had no mansard/gabled cap
geometry — their rooftops were flat surfaces with only wall material. Fixed when adding
`bordelaisClassical`: the loop now iterates all 7 cap styles:
`[.balinese, .colonial, .javanese, .religious, .haussmannien, .medieval, .bordelaisClassical]`.
Per-style parameters in the loop body: haussmannien roughness 0.86, metallic 0.04 (patinated zinc
identity); bordelaisClassical clearcoat 0.04; all others clearcoat 0.07, metallic 0.0.

### HEIGHT_PROMOTION_BYPASS — height-promotion bypass

In `tools/fetch_district_data.py`, buildings whose area default style is in `HEIGHT_PROMOTION_BYPASS`
are NOT promoted to `modernConcrete` at 15m+ or `modernGlass` at 30m+. This preserves the correct
area-character classification: a 20m Haussmann block stays `haussmannien`, a 16m Bordeaux quay
building stays `bordelaisClassical`, a 25m Madrid Ensanche block stays `madrileño`. Buildings with
explicit OSM tags (hotel, curtain-wall, etc.) are still classified normally regardless of the bypass.

Current bypass set (as of 2026-07-09):
```python
HEIGHT_PROMOTION_BYPASS = {"haussmannien", "medieval", "bordelaisClassical", "madrileño", "romanOchre"}
```

**`londonBrick` is NOT in the bypass** — City of London's real glass towers (Gherkin 180m,
Cheesegrater 224m, 22 Bishopsgate 278m) must auto-promote to `modernGlass`. If a new London district
has predominantly Victorian stock-brick fabric, use `londonBrick` as `--default-style` and let
height promotion handle the towers automatically.

Height estimation defaults (all `isHeightEstimated: true`):
`haussmannien → 18.0m`, `medieval → 9.0m`, `bordelaisClassical → 16.0m`,
`londonBrick → 12.0m`, `madrileño → 20.0m`, `romanOchre → 14.0m`.

**Known limitation**: all estimated-height haussmannien buildings are 18m (6 floors). This creates
a slightly uniform carpet in dense areas. Real Haussmann buildings range 15–27m (5–8 floors). A
future improvement: hash-varied estimation `15m / 18m / 21m / 24m` based on osmID. Did not block
v1 — Paris OSM data has many `building:levels` tags on named buildings so actual variation exists
in the data; the uniform carpet only affects unnamed/untagged buildings.

### New Mood cases

Three cases added to `DistrictRealityScene.Mood`:
- **`parisianCore`** (Le Marais, Saint-Germain, Montmartre): cool pearl overcast sky
  `sun (0.90,0.90,0.94)`, 22,000 lux, elevation 0.55. Zenith `(0.52,0.58,0.70)` / horizon
  `(0.78,0.80,0.84)` / ground `(0.32,0.30,0.28)`. Distance 0.16, height 0.14.
  Road material: warm grey-beige limestone macadam — pedestrian `(0.72,0.68,0.60)`,
  primary `(0.28,0.25,0.22)`. Ground texture: limestone block mosaic, mortar joints, warm cream.
- **`bordeauxWaterfront`** (Bordeaux): golden-hour Garonne riverside. Sun `(1.0,0.88,0.65)`,
  30,000 lux, elevation 0.40. Distance 0.16, height 0.12. Ground: sandy Garonne ochre.
- **`rennesMedieval`** (Rennes): morning mist, slate-grey Breton sky. Sun `(0.95,0.92,0.80)`,
  25,000 lux, elevation 0.38. Distance 0.14, height 0.12. Ground: dark Breton granite.

La Défense uses the existing `skyscraperCorridor` mood (correct — it has towers 160–231m).

### Paris OSM data quality and KNOWN_HEIGHTS

Paris OSM has unusually good `building:levels` and `height` coverage on named structures. The
KNOWN_HEIGHTS_METERS table in `tools/fetch_district_data.py` was expanded with 40+ Paris/Bordeaux/
Rennes entries for landmarks that either aren't `way["building"]` in OSM or whose OSM height tags
are missing. Key confirmed heights from the data audit:
- Basilique du Sacré-Cœur (Montmartre): **83m** — matched, classified `religious`, dominant in scene
- Tour First (La Défense): **231m** — matched, classified `modernGlass`, tallest in app
- Tour Majunga: 195m, Hekla: 192m, Tour Granite: 184m — all matched
- Tour Saint-Jacques (Le Marais): **52m** — gothic tower, `focusBuildingName` for Le Marais
- Aux Bienheureux Martyrs de Saint-Sulpice (Saint-Germain): **73m** — OSM has real height tag,
  matched building; the focusBuildingName "Église Saint-Sulpice" is display-only (not a 3D beacon lookup)

`apply_named_point_landmarks` in the fetch script now matches beyond museums: `amenity=place_of_worship`,
`historic=church/castle/monument/memorial/building`, `tourism=attraction` — all now route to the
building polygon that spatially contains them and inherit their name + height.

### France + Europe heavyDistricts

All Paris, Bordeaux, London, Madrid districts (> ~1,800 buildings) are in `heavyDistricts` in
`MetaCityApp.swift` (load on demand, not startup prefetch):
```swift
["Malioboro", "Kraton", "Seminyak", "Canggu", "Uluwatu",
 "Montmartre", "LeMarais", "SaintGermain", "LaDefense",
 "VieuxBordeaux", "LesChartrons",
 "CityOfLondon", "Westminster", "Salamanca", "CentroStorico", "Malasana"]
```
Montmartre (5,863 buildings) is the heaviest district in the entire app.
Le Marais: 2,658 buildings | Saint-Germain: 2,399 buildings | La Défense: 2,110 buildings.
VieuxBordeaux: 3,817 buildings | LesChartrons: 4,712 buildings.
CityOfLondon: 2,404 buildings | Westminster: 2,362 buildings.
Salamanca: 2,463 buildings | Malasana: 2,534 buildings | CentroStorico: 4,917 buildings.

### Bordeaux OSM data quality and KNOWN_HEIGHTS

VieuxBordeaux and LesChartrons were fetched 2026-07-09 using `--default-style bordelaisClassical`.
Key confirmed heights after KNOWN_HEIGHTS alternate-name fix (see below):
- **Grand Théâtre de Bordeaux**: 32m — `focusBuildingName` for VieuxBordeaux
- **Cathédrale Saint-André**: 47m, religious — prominent landmark in VieuxBordeaux
- **Tour Pey Berland**: 66m, religious — Gothic bell tower, tallest in VieuxBordeaux
- **Halle des Chartrons**: 16m (estimated), bordelaisClassical — `focusBuildingName` for LesChartrons
- **Le Concorde**: 40m modernGlass — tallest named building in LesChartrons

**OSM name vs. KNOWN_HEIGHTS key mismatch** (confirmed regression, now fixed): OSM building names
in Bordeaux are often shorter than the canonical form — "Grand Théâtre" (no city suffix),
"Tour Pey Berland" (space, not hyphen). The fix: KNOWN_HEIGHTS contains both forms:
`"Grand Théâtre de Bordeaux": 32` AND `"Grand Théâtre": 32`; `"Tour Pey-Berland": 66` AND
`"Tour Pey Berland": 66`. When fetching any new French district, always grep the output JSON for
key landmark heights and cross-check against KNOWN_HEIGHTS if they appear at the 16m/18m/9m
estimated-height default.

**Garonne water rendering**: `process_green_zones` in the fetch script now captures
`natural=water` and `waterway=river/canal/stream` tags, writing them as `GreenZone` entries with
`kind: "natural=water"`. `greenZoneColor(kind:)` renders these as muted tidal blue-grey
`(0.32, 0.44, 0.52)` day / dark `(0.08, 0.12, 0.18)` night. The Garonne appears in both Bordeaux
districts as multiple water polygons — the river itself and the quay basin.

**Fetch commands used (from cache — do not re-run from live Overpass):**
```
python3 fetch_district_data.py \
  --name VieuxBordeaux --bbox 44.836 -0.580 44.848 -0.561 \
  --anchor 44.842 -0.571 --default-style bordelaisClassical \
  --out ../MetaCity/Resources/Districts/VieuxBordeaux.json \
  --cache /tmp/vieux_bordeaux_raw.json

python3 fetch_district_data.py \
  --name LesChartrons --bbox 44.849 -0.575 44.864 -0.557 \
  --anchor 44.856 -0.567 --default-style bordelaisClassical \
  --out ../MetaCity/Resources/Districts/LesChartrons.json \
  --cache /tmp/les_chartrons_raw.json
```

**Screenshot-verified 2026-07-09:**
- VieuxBordeaux: warm amber-gold fabric, canal-tile terracotta rooftops, sandy bordeauxWaterfront
  ground, Tour Pey Berland visible as tallest building, parks and water zones present
- LesChartrons: denser amber block, diagonal tramway line along the Garonne quays clearly visible,
  Halle des Chartrons warehouse silhouette recognizable upper-center, Le Concorde modernGlass at 40m

### To add Rennes districts

Run `tools/fetch_district_data.py` with `--default-style medieval`. The bboxes and anchor points
are already in `CityManifest.json` under the placeholder entries. After fetching, set
`dataBundled: true` and add to `heavyDistricts` if building count exceeds ~1,800.
Do NOT use `--default-style haussmannien` for Rennes — Breton medieval fabric is `medieval`.
Do NOT use `--default-style bordelaisClassical` — that's Bordeaux-only (Gironde limestone).
Do NOT use `--default-style balinese` — Bali-only.

## London/Madrid/Rome architecture (added 2026-07-09)

Phase 0 (style + mood foundation) implemented 2026-07-09. Data fetch (Phase 1) pending.
All three cities have placeholder `CityManifest.json` entries (`dataBundled: false`).

### New BuildingStyle cases

Three cases added to `BuildingStyle` in `DistrictFootprint.swift` (after `bordelaisClassical`):

- **`londonBrick`**: Victorian/Georgian London stock brick — fired yellow-buff clay, the dominant
  non-tower material of the City of London. Wall: `dayR = 0.74 + 0.08·wobble`,
  `dayG = 0.62 + 0.06·wobble`, `dayB = 0.38 + 0.04·wobble` (warm yellow-buff range). Roughness
  0.82–0.89, clearcoat 0.05. Roof: Welsh slate `(0.44,0.46,0.50)` — cool blue-grey, distinctly
  cooler than Paris zinc `(0.42,0.46,0.52)` and warmer than rain-slicked concrete.
  Cap geometry: **25° pitch** (`pitchTan: 0.466`), `maxRidgeInset: 5.0m` (long shallow ridge),
  overhang 0.20m. Night emissive 0.30. Window texture: 4×7 grid, density 0.32.
  **NOT in HEIGHT_PROMOTION_BYPASS** — City glass towers auto-promote to `modernGlass`.

- **`madrileño`**: 19th-century Madrid Ensanche limestone/sandstone render — warm golden-beige.
  Wall: `dayR = 0.84 + 0.06·wobble`, `dayG = 0.76 + 0.04·wobble`, `dayB = 0.54 + 0.06·wobble`.
  Roughness 0.72–0.79, clearcoat 0.12. Roof: flat azotea concrete `(0.80,0.76,0.68)`, roughness
  0.86 — **NO hip roof cap, NOT in `capStyles`, does NOT appear in `makeRoofCapEntities` loop.**
  Night emissive 0.35. Window texture: 5×8 grid, density 0.38.
  **IN HEIGHT_PROMOTION_BYPASS** — Salamanca blocks up to 28m must stay `madrileño`.

- **`romanOchre`**: Roman tuff/brick and ochre render plaster. Wall: `dayR = 0.78 + 0.08·wobble`,
  `dayG = 0.54 + 0.06·wobble`, `dayB = 0.30 + 0.06·wobble` (sienna-amber range). Roughness
  0.78–0.86, clearcoat 0.07. Roof: Roman coppo canal-tile `(0.62,0.24,0.10)`, roughness 0.93,
  clearcoat 0.05. Cap geometry: **35° pitch** (`pitchTan: 0.700`), `maxRidgeInset: 3.5m`,
  overhang 0.30m. Night emissive 0.22. Window texture: 3×5 grid, density 0.22.
  **IN HEIGHT_PROMOTION_BYPASS** — Vittoriano at 70m stays `romanOchre`.
  **CRITICAL**: keep dayB ≤ 0.40 — higher blue pushes Rome ochre toward bordelaisClassical amber
  or madrileño golden-beige. The low B (`≈0.30–0.36`) is the visual discriminator for Rome.

Both `londonBrick` and `romanOchre` are in `capStyles` and in `makeRoofCapEntities` loop.
`madrileño` is explicitly excluded from both — flat azotea is architecturally correct and saves draw calls.

### New Mood cases

Three cases added to `DistrictRealityScene.Mood`:

- **`londonSilver`** (City of London, Shoreditch, Westminster): cool overcast silver British sky.
  Sun `(0.88,0.90,0.95)`, 26,000 lux, elevation 0.45. Zenith `(0.42,0.48,0.62)` / horizon
  `(0.70,0.73,0.78)` / ground `(0.24,0.22,0.20)`. Camera distance 0.18, height 0.13.
  Road material: dark wet black tarmac (primary `(0.20,0.20,0.22)`), Portland stone pedestrian
  zones `(0.68,0.66,0.62)`. Ground texture: flat dark cool-blue tarmac (no joint grid — London
  streets are resurfaced/uniform rather than stone-paved like European continental cities).

- **`madridAfternoon`** (Salamanca, Gran Vía, Malasaña): warm Spanish golden-hour sun.
  Sun `(1.0,0.84,0.55)`, 38,000 lux, elevation 0.38. Zenith `(0.38,0.44,0.62)` / horizon
  `(0.72,0.68,0.54)` / ground `(0.40,0.34,0.24)`. Camera distance 0.18, height 0.12.
  Road material: warm Spanish granite (primary `(0.42,0.38,0.32)`), pedestrian zones
  `(0.60,0.54,0.44)`. Ground texture: 8px joint grid warm granite slabs.

- **`romanGoldenHour`** (Centro Storico, Trastevere, Prati): warm sienna-amber low-angle sun.
  Sun `(1.0,0.82,0.52)`, 32,000 lux, elevation 0.32 (lowest elevation in the app — Rome's golden
  hour is notably low-angle). Zenith `(0.30,0.38,0.58)` / horizon `(0.68,0.54,0.36)` /
  ground `(0.28,0.22,0.16)`. Camera distance 0.18, height 0.13.
  Road material: dark basalt sanpietrini cobbles (primary `(0.22,0.20,0.18)`), travertine
  pedestrian zones `(0.74,0.70,0.62)`. Ground texture: **tight 4px sanpietrini grid**
  `(x % 4 == 0) || (y % 4 == 0)` with warm amber mortar joints `(108,82,54)` and dark basalt
  cubes — 8×8 sett grid per 32px tile, distinctively Roman.

### KNOWN_HEIGHTS additions for London/Madrid/Rome

~50 entries added to `KNOWN_HEIGHTS_METERS` in `tools/fetch_district_data.py`. Key entries:

**London (City of London):** 22 Bishopsgate 278m, Leadenhall Building "Cheesegrater" 224m, 
30 St Mary Axe "Gherkin" 180m, NatWest Tower "Tower 42" 183m, One Canada Square 235m,
St Paul's Cathedral 111m, Tower of London 27m, Monument 62m.

**Madrid (Salamanca district):** Puerta de Alcalá 22m, Palacio de Cibeles 82m,
Biblioteca Nacional 26m, Palacio del Buen Retiro 11m, Torre de los Lujanes 22m.

**Rome (Centro Storico):** Pantheon 21m, Colosseum 48m, Sant'Agnese in Agone 55m,
Sant'Ivo alla Sapienza 56m, Palazzo Madama 35m, Palazzo Montecitorio 36m,
Palazzo Venezia 42m, Castel Sant'Angelo 48m.

### OSM data quality — CityOfLondon / Salamanca / CentroStorico (fetched 2026-07-09)

**CityOfLondon: 2,404 buildings** (1,444 londonBrick 60%, 653 modernConcrete 27%, 185 modernGlass 7%, 75 government 3%, 47 religious 1%). 9,739 roads, 104 green zones. 58 point-mapped landmarks matched.
- `30 St Mary Axe` at 180m ✓ — focusBuildingName confirmed in dataset
- Full tower skyline present: 22 Bishopsgate 244m, Heron Tower 230m, 8 Bishopsgate 204m, Leadenhall 192m, Tower 42 183m — all from KNOWN_HEIGHTS, all classified `modernGlass` via height promotion (londonBrick NOT in HEIGHT_PROMOTION_BYPASS)
- londonBrick HEIGHT_PROMOTION_BYPASS deliberately excluded: City's real glass towers auto-promote correctly.

**Salamanca: 2,463 buildings** (2,339 madrileño 94%, 107 government 4%, 17 religious 0%). 2,173 roads, 79 green zones. 55 point-mapped landmarks matched.
- `Puerta de Alcalá` at 22m (non-estimated) ✓ — focusBuildingName confirmed in dataset
- Palacio de Cibeles: 82m government ✓; Torres de Colón: 100m — **manually reclassified** to `modernGlass` in JSON (1976 modern office towers; HEIGHT_PROMOTION_BYPASS kept them as madrileño by default, which is architecturally wrong).
- Pattern: after any `--default-style madrileño` fetch, grep output JSON for `madrileño` buildings ≥50m and verify they are actually 19th-c Ensanche blocks, not modern towers. Reclassify modern towers to `modernGlass` or `modernConcrete` directly in JSON.

**CentroStorico: 4,917 buildings** (4,707 romanOchre 95%, 153 religious 3%, 57 government 1%). 7,240 roads, 522 green zones. 37 point-mapped landmarks matched.
- **`Pantheon` NOT in dataset** — not mapped as a `way["building"]` polygon in OSM within the bbox. `focusBuildingName` changed to `"Sant'Ivo alla Sapienza"` (60m, non-estimated, Borromini's Baroque church at Sapienza — tallest named building in the dataset and architecturally significant).
- Sant'Ivo alla Sapienza: 60m ✓ — in dataset. Castel Sant'Angelo: 14m (shows as government, height not matching KNOWN_HEIGHTS 48m — OSM tag may override KNOWN_HEIGHTS; acceptable since Castel Sant'Angelo is outside the dense historic core)
- OSM Centro Storico has unusually organic medieval street layout with very few straight arteries — verified in 3D render.

**CityManifest.json field-name fix (2026-07-09)**: the three new island entries were initially written with `"name"` instead of `"displayName"` and `"mapLatitude"/"mapLongitude"/"zoomLevel"` instead of the required `"shortName"/"mapZoomRadius"/"markerColor"/"markerHeight"` fields. `CityManifest` decoded them silently to `.fallback` (Jakarta-only). Fixed to match the existing schema. Always use `python3 -c "import json; m=json.load(open('CityManifest.json')); print(len([d for i in m['islands'] for c in i['cities'] for d in c['districts']]))"` to verify district count after editing the JSON.

**Screenshot-verified 2026-07-09:**
- CityOfLondon: warm yellow-buff londonBrick fabric, dark glass towers, dark cool tarmac ground, Road network dense — correctly reads as the City of London financial district
- Salamanca: warm golden-amber madridAfternoon sky, flat azotea rooftops, classic Ensanche grid, warm granite ground — unmistakably Madrid
- CentroStorico: warm sienna-amber romanOchre fabric, organic winding medieval street layout, hip canal-tile roofs — unmistakably Rome

### Fetch commands (all districts fetched and screenshot-verified 2026-07-09)

```
# City of London
python3 fetch_district_data.py \
  --name CityOfLondon --bbox 51.506 -0.104 51.521 -0.074 \
  --anchor 51.5136 -0.0886 --default-style londonBrick \
  --out ../MetaCity/Resources/Districts/CityOfLondon.json \
  --cache /tmp/city_of_london_raw.json

# Westminster (fetched 2026-07-09 — Overpass 504s twice, succeeded on third try)
python3 fetch_district_data.py \
  --name Westminster --bbox 51.490 -0.145 51.507 -0.115 \
  --anchor 51.498 -0.130 --default-style londonBrick \
  --out ../MetaCity/Resources/Districts/Westminster.json \
  --cache /tmp/westminster_raw.json

# Salamanca
python3 fetch_district_data.py \
  --name Salamanca --bbox 40.416 -3.694 40.432 -3.670 \
  --anchor 40.4243 -3.6808 --default-style madrileño \
  --out ../MetaCity/Resources/Districts/Salamanca.json \
  --cache /tmp/salamanca_raw.json

# Malasaña (Gran Vía / Malasaña neighborhood)
python3 fetch_district_data.py \
  --name Malasana --bbox 40.418 -3.712 40.432 -3.696 \
  --anchor 40.425 -3.703 --default-style "madrileño" \
  --out ../MetaCity/Resources/Districts/Malasana.json \
  --cache /tmp/malasana_raw.json

# Rome Centro Storico
python3 fetch_district_data.py \
  --name CentroStorico --bbox 41.887 12.460 41.910 12.487 \
  --anchor 41.8987 12.4727 --default-style romanOchre \
  --out ../MetaCity/Resources/Districts/CentroStorico.json \
  --cache /tmp/centro_storico_raw.json
```

### Authored overrides (applied + screenshot-verified 2026-07-09)

**Authored override files** are applied by `District.load(named:)` via `DistrictAuthoredOverrides.load(for:)`.
Each file is `MetaCity/Resources/<DistrictId>_authored.json` with exact case.
Supported fields per override: `osmID` (exact), `nameMatch` (case-insensitive substring), `style`, `roofType`, `heightMeters`.

**`LeMarais_authored.json`** (4 overrides, screenshot-verified 2026-07-09):
- osmID 20326709 (Tour Saint-Jacques, 52m): `government → religious`, `roofType: flat` — Gothic clock tower, not a civic building
- osmID 22870791 (Institut du Monde arabe, 48m): `government → modernGlass`, `roofType: flat` — Jean Nouvel mashrabiya-glass facade
- osmID 55503397 (Centre Georges Pompidou, 9m estimated): `government → modernGlass`, `roofType: flat`, `heightMeters: 42.0` — Renzo Piano/Rogers high-tech, 9m OSM height is wrong
- osmID 201611261 (Trésor de Notre-Dame, 69m): `government → religious` — polygon matches Notre-Dame cathedral mass

**`Westminster_authored.json`** (7 overrides, screenshot-verified 2026-07-09):
- osmID 367642689 (Victoria Tower, 98m): `modernGlass → government`, `roofType: flat` — Gothic Revival stone, height-promoted incorrectly because londonBrick not in HEIGHT_PROMOTION_BYPASS
- nameMatch "Westminster Abbey": `religious` (already), `roofType: flat` — confirms lead-covered nave roof
- nameMatch "Westminster Cathedral": `religious` (already), `roofType: dome` — Byzantine campanile
- nameMatch "Houses of Parliament": `government`, `roofType: flat`
- nameMatch "Palace of Westminster": `government`, `roofType: flat`
- nameMatch "Buckingham Palace": `government`, `roofType: flat`
- nameMatch "Banqueting House": `government`, `roofType: flat` — Inigo Jones, Whitehall

**`Malasana_authored.json`** (4 overrides, screenshot-verified 2026-07-09):
- nameMatch "Espacio Fundación Telefónica": `heightMeters: 81.0`, `style: government` — 1929 Art Deco, Spain's first skyscraper; OSM had 20m estimated
- nameMatch "Palacio de la Prensa": `heightMeters: 36.0`, `style: government` — 1928 Art Deco press building
- nameMatch "Teatro Príncipe Gran Vía": `heightMeters: 30.0`, `style: government`
- nameMatch "Palacio de Liria": `style: government`, `roofType: flat`

**Westminster OSM data quality notes:**
- "Houses of Parliament" / "Palace of Westminster" may not appear as a single named polygon — they may be
  mapped as multiple unnamed segments or as a relation in OSM. The authored override nameMatch entries
  are pre-loaded; they apply if OSM names match in a future re-fetch.
- Victoria Tower (osmID 367642689) at 98m is the confirmed regression case: `londonBrick` NOT in
  HEIGHT_PROMOTION_BYPASS means any londonBrick building ≥ 30m auto-promotes to modernGlass or
  modernConcrete. For Gothic Revival structures that are tall but not glass, use the authored override
  to revert the style.
- Millbank Tower (132m) correctly stays modernGlass — it's a genuine 1960s curtain-wall tower.

**Malasaña OSM data quality notes:**
- Edificio España (osmID 49031978): madrileño at 92m (non-estimated) — correctly HEIGHT_PROMOTION_BYPASS
  prevents promotion to modernGlass for madrileño default-style buildings. Focus building.
- Espacio Fundación Telefónica: OSM height was 20m estimated. Real height is 81m. Fixed via authored override.
  Next re-fetch will auto-correct via KNOWN_HEIGHTS (entries added 2026-07-09).
- No Edificio Metrópolis in the Malasana bbox (it's at the Alcalá/Gran Vía corner, ~40.4185°N which is
  at the southern edge of the bbox — not included in the 2534-building fetch).

**`DiscoverViewModel` Europe-first default (2026-07-09):**
- `indonesiaCamera` renamed to `europeCamera`: `centerCoordinate: 47°N/7°E`, `distance: 3_000_000` —
  Paris/London/Madrid/Rome all visible at a glance.
- Cold-launch default changed from Bali (`denpasar`) to Paris (`paris`): `init()` calls
  `applyUITestOverrides` which now opens Paris in `cityFocused` state if no `UITEST_OPEN_*` env var.
- The `back()` function (cityFocused → worldMap) returns to `europeCamera` (not `indonesiaCamera`).

### Authored override files — complete set (as of 2026-07-16)

All authored overrides are created; no planned-but-missing files remain.

| File | District | Count | Key overrides |
|---|---|---|---|
| `Canggu_authored.json` | Canggu | 10 | Temples → conical, mosque → dome, surf bars → thatched |
| `Seminyak_authored.json` | Seminyak | 20 | Beach clubs → thatched, temples → conical, mosques → dome |
| `Kuta_authored.json` | Kuta | 16 | Mega-venues → flat, beach bars → thatched, temples → conical |
| `LeMarais_authored.json` | Le Marais | 4 | Tour Saint-Jacques, Pompidou, Institut du Monde arabe |
| `Westminster_authored.json` | Westminster | 7 | Victoria Tower style, Westminster Abbey/Cathedral/Buckingham |
| `Malasana_authored.json` | Malasaña | 4 | Espacio Telefónica 81m, Palacio de la Prensa 36m |
| `Ancol_authored.json` | Ancol | 6 | Roller coasters + fast food → modernConcrete; Syahbandar → government |
| `CityOfLondon_authored.json` | City of London | 2 | 30 St Mary Axe (osmID 4959489) → flat; St Paul's (369161987) → religious/flat |
| `Sanur_authored.json` | Sanur | 8 | Beach club open-air venues → thatched; yoga → conical; hotel lobbies → flat |
| `Uluwatu_authored.json` | Uluwatu | 7 | Temple entrance → conical; Single Fin surf bar → thatched; dome chapel |
| `CentroStorico_authored.json` | Centro Storico | 4 | Castel Sant'Angelo 48m, Sant'Agnese 55m, Sant'Ivo 60m flat, Sant'Andrea 56m |
| `MidtownManhattan_authored.json` | Midtown Manhattan | 34 | Empire State/Chrysler → nycBrick; glass towers → modernGlass; Saint Patrick → religious |
| `LowerManhattan_authored.json` | Lower Manhattan | 24 | One WTC → modernGlass; Woolworth → government; Trinity Church → religious |

| `VancouverDowntown_authored.json` | Vancouver Downtown | 6 | Marine Building 98m → government; BC Place → dome; Christ Church → religious |
| `SFDowntown_authored.json` | SF Downtown | 6 | Transamerica Pyramid 260m → government; Ferry Building 71m; churches → religious |
| `FishermansWharf_authored.json` | Fisherman's Wharf SF | 5 | Ghirardelli, Cannery, Maritime Museum → government/flat |
| `Montmartre_authored.json` | Montmartre | 6 | Sacré-Cœur → dome 83m, Moulin Rouge/Galette → government flat |
| `Shinjuku_authored.json` | Shinjuku | 11 | 新宿野村ビル→modernGlass/220m, モード学園コクーンタワー→modernGlass/200m, 東急歌舞伎町タワー→modernGlass/192m, Shinjuku Station→government |
| `Ginza_authored.json` | Ginza | 9 | GINZA SIX→modernGlass/56m, 銀座松竹スクエア→modernGlass/92m, 歌舞伎座→government/45m, 銀座駅→government |
| `Asakusa_authored.json` | Asakusa | 8 | 浅草寺→religious/dome, 浅草神社→religious/flat, 東京楽天地浅草ビル→modernGlass/52m, 都立産業貿易センター→government |
| `KotaTua_authored.json` | Kota Tua | 10 | Museum Fatahillah→government/flat, Gereja Sion→religious/flat, Gereja Katedral→religious/dome, Café Batavia→colonial |
| `SudirmanThamrin_authored.json` | Sudirman-Thamrin | 10 | Wisma 46→modernGlass/262m, Menara BCA→modernGlass/230m, Masjid Istiqlal→religious/dome/45m, Katedral Jakarta→religious/dome/61m |
| `Menteng_authored.json` | Menteng | 6 | Tugu Proklamasi→government, Gereja Theresia→religious/flat, Masjid Cut Meutia→religious/dome |
| `Kemang_authored.json` | Kemang | 4 | Kemang Village→modernConcrete/flat/36m, Masjid Al-Azhar→religious/dome |
| `Kraton_authored.json` | Kraton | 7 | Kraton/Keraton/Sultan→government/flat, Taman Sari→government/flat, Masjid Gedhe→religious/dome |
| `Braga_authored.json` | Braga | 5 | Gedung Merdeka→government/flat/18m, Gedung Sate→government/flat/48m |

No authored file needed for Salamanca (flat azotea on all `madrileño` buildings by default).
No authored file needed for WestEnd Vancouver (all buildings correctly height-promote; no landmark misclassifications found).
No authored file needed for Dago (buildings correctly classify; no landmark misclassifications identified).
No authored file needed for Malioboro (hotel misclassifications fixed directly in JSON; no sidecar needed).

### Area-bucketed height variation (`displayHeight`, 2026-07-13)

`DistrictRealityKit.displayHeight(for:area:)` replaces the flat `±20% wobble` for estimated buildings
in low-rise compound styles. Called at every site that uses building height for visual geometry:
`makeBuildingMeshes`, `addHipRoof`, `addConicalRoof`, `addDomeRoof`, `makeFocusBeacon`,
`makeFarTierEntity`. Guard: `building.isHeightEstimated == false` short-circuits to real height.

**Motivation**: `fetch_district_data.py` assigns a fixed fallback height (7m for balinese, 16m for
estimated modernConcrete, etc.) to all buildings that lack OSM `height`/`building:levels` tags. With
99%+ of Bali buildings estimated, this produced flat-carpet scenes: Kuta = 560 buildings ALL at
exactly 7.0m. `displayHeight` uses the building's footprint polygon area as a proxy for building
mass, tiering estimated heights appropriately.

**Area tiers (footprint polygon area in m²):**

| Style | < 40 | < 100 | < 250 | < 600 | ≥ 600 |
|---|---|---|---|---|---|
| balinese / colonial / javanese / medieval | 3–5 m | 4–6.5 m | 5.5–8.5 m | 7–11 m | 9–15 m |
| modernConcrete | 4–7 m | 6–10 m | 8.5–14 m | 11–18 m | 14–22 m |
| all others | ±20% wobble of `building.heightMeters` baseline | | | | |

**Seed**: `osmID + "_h"` (distinct from material bucket seed `osmID`) to prevent height↔material
correlation — same building, same deterministic height, every launch, uncorrelated with color bucket.

**Impact**:
- Bali (Kuta/Seminyak/Canggu): range 3–15m from a flat 7m carpet → realistic compound fabric
- La Défense: 1,511 estimated `modernConcrete` at 7m → range 4–22m, avg 8.1m, p90 14.5m
- Hip roof eave Y, conical/dome base Y, LOD far-tier box heights all use the same `displayHeight` call

### Facade articulation bands (2026-07-14)

A third `ModelEntity` per style bucket (`buildings_\(key)_bands`) adds horizontal 3D surface relief to
building facades: floor ledge strips at fixed floor intervals, a top cornice, and a base plinth. All
three elements use `addBandStrip` which generates a front face (outward) + top face (upward) quad per
polygon edge — both faces share the same edge-normal `(nx, 0, nz)` computed from the polygon edge
direction. Bands are merged per bucket into one `MeshDescriptor` (same approach as wall/roof entities)
so draw call count increases by at most 1 entity per bucket (≤3 per style, ≤12 for a 4-bucket
haussmannien district).

**`FacadeProfile` struct** controls per-style geometry (updated 2026-07-14 with ground-floor fields;
balcony/pilaster fields added same session — see balcony undersides section below):
```swift
struct FacadeProfile {
    let floorInterval: Float     // metres between floor ledge bands
    let bandDepth: Float         // outward projection of each floor ledge
    let bandThick: Float         // vertical thickness of each floor ledge
    let corniceDepth: Float      // top cornice outward projection
    let corniceHeight: Float     // top cornice height (0 = no cornice)
    let plinthDepth: Float       // base plinth projection
    let plinthHeight: Float      // base plinth height (0 = no plinth)
    let groundFloorH: Float      // height of ground-floor cladding panel (0 = none)
    let groundFloorDepth: Float  // outward projection of ground-floor cladding (0 = none)
    let balconyDepth: Float      // balcony slab outward projection (0 = none)
    let balconyThick: Float      // balcony slab thickness
    let balconyFirstFloor: Int   // 1-based floor index of first balcony
    let balconyFloorStep: Int    // every N floors has a balcony
    let pilasterWidth: Float     // pilaster front-strip width (0 = none)
    let pilasterDepth: Float     // pilaster outward projection
    let pilasterSpacing: Float   // horizontal bay interval
}
```

**Per-style parameters (2026-07-14):**

| Style | bandDepth | bandThick | corniceDepth | corniceH | plinthH | groundFloorH | groundFloorDepth |
|---|---|---|---|---|---|---|---|
| haussmannien | 0.38 m | 0.22 m | 0.50 m | 0.55 m | 0.80 m | 5.0 m | 0.08 m |
| bordelaisClassical | 0.32 | 0.20 | 0.42 | 0.50 | 0.70 | 5.0 | 0.08 |
| madrileño | 0.30 | 0.18 | 0.38 | 0.50 | 0.65 | 5.5 | 0.06 |
| colonial | 0.22 | 0.16 | 0.28 | 0.35 | 0.50 | 4.5 | 0.06 |
| romanOchre | 0.28 | 0.18 | 0.38 | 0.48 | 0.60 | 5.5 | 0.08 |
| londonBrick | 0.14 | 0.12 | 0.20 | 0.32 | 0.35 | 5.0 | 0.06 |
| medieval | 0.12 | 0.10 | 0.30 | 0.40 | 0 | 3.5 | 0.05 |
| modernGlass | 0.06 | 0.08 | 0 | 0 | 0 | 8.0 | 0.10 |
| nycBrick | 0.20 | 0.15 | 0.35 | 0.50 | 0.55 | 5.5 | 0.08 |
| **balinese** | 0 | 0 | **0.22** | **0.28** | 0 | 0 | 0 |
| javanese / government / religious | — | — | — | — | — | 0 (none) | 0 |

**Balinese parapet case (added 2026-07-14)**: `balinese` previously fell through to `default: return .none`
(no facade articulation). It now has a cornice cap (`corniceDepth: 0.22m`, `corniceHeight: 0.28m`) —
the carved volcanic stone parapet that defines the top edge of Balinese compound walls. No floor bands,
no balconies, no pilasters — architecturally correct for single-storey compound vernacular.
Screenshot-verified on Canggu (9,402 buildings): distinct parapet silhouette on all compound walls.

**Ground-floor cladding system (added 2026-07-14):**
`addGroundFloorPanel` emits a fourth `ModelEntity` per bucket (`buildings_\(key)_ground`) with a
distinct `groundFloorMaterialPreset` for each applicable style. Uses `addBandStrip` (same front +
top face geometry) so the horizontal cap of the cladding slab is visible from the orbit camera.
`guard gH > 1.0` skips short buildings where the ground-floor zone would consume the whole height.

Per-style ground materials (`groundFloorMaterialPreset`, cached in `groundFloorMaterialCache`):
- `modernGlass`: dark polished granite lobby `(0.08,0.09,0.12)` — metallic 0.22, roughness 0.30, clearcoat 0.72
- `haussmannien`: bossed rusticated Lutetian limestone `(0.72,0.68,0.58)` — roughness 0.84, clearcoat 0.05
- `colonial`: ochre lime-wash arcade facing `(0.58,0.40,0.24)` — roughness 0.82
- `londonBrick`: Portland stone / stucco `(0.70,0.70,0.68)` — roughness 0.76, clearcoat 0.06
- `romanOchre`: travertine base `(0.88,0.80,0.64)` — roughness 0.70, clearcoat 0.12
- `bordelaisClassical`: rusticated Gironde limestone `(0.70,0.56,0.32)` — roughness 0.82
- `madrileño`: Sierra granite plinth `(0.44,0.42,0.40)` — roughness 0.65, clearcoat 0.15
- `medieval`: Breton granite soubassement `(0.38,0.36,0.34)` — roughness 0.90
- `nycBrick`: brownstone entry `(0.38,0.28,0.20)` — roughness 0.80

Draw call cost: adds ≤9 ground entities per district (one per bucket per applicable style, 3 buckets × 9 styles). 
Still within 200 draw-call budget for all districts.

**Water PBR (added 2026-07-14):** `natural=water` green zones now use `PhysicallyBasedMaterial` via
`waterMaterial(isNight:)` instead of `UnlitMaterial`. clearcoat 0.80 + roughness 0.16 produces a
directional-light specular streak reading as sun glinting on river/harbour water. Garonne (Bordeaux),
Jakarta bay, Vancouver harbor all benefit. Non-water zone kinds remain `UnlitMaterial` (shadow-map
aliasing on large horizontal surfaces — unchanged from before).

**Winding invariant** for `addBandStrip` top face: `[tBase+3, tBase+1, tBase+2, tBase+3, tBase+0, tBase+1]`
produces n.y > 0 for CW polygon winding in X-Z. The reversed fan `[3,1,2]+[3,0,1]` was verified
symbolically via cross-product to give upward normal. Do not change this winding without re-running the
cross-product verification — the analogous `[0,1,3]+[1,2,3]` winding gives n.y < 0.

**`bandMaterialPreset`** provides lighter/cooler materials than the wall:
- `modernGlass`: dark metallic spandrel `(0.05,0.06,0.09)`, metallic 0.88, roughness 0.24
- `haussmannien`: cut limestone, slightly cooler/lighter than wall, roughness 0.66, clearcoat 0.20
- `bordelaisClassical`: amber limestone, roughness 0.68
- `romanOchre`: travertine band, roughness 0.70, clearcoat 0.08
- `londonBrick`/`medieval`: Portland stone / Breton granite, roughness 0.80/0.86
- Other styles: delegates to `roofMaterialPreset`

Cached in `bandMaterialCache` keyed `"\(style.rawValue)_band_\(isNight)"` — 30 instances max.
Declared `@MainActor` (same constraint as `makeBuildingMeshes` and `pooledMaterial`).

**Balcony underside faces (added 2026-07-14):** `addBalconies` now emits a fourth quad per polygon
edge per floor level: a downward-facing (-Y normal) underside of the slab at `balkY`. Winding
`[uBase+2, uBase+1, uBase+3, uBase+1, uBase+0, uBase+3]` produces n.y < 0 (reversed from the
top-face winding, cross-verified via example: edge (0,0)→(10,0), depth 0.5m → n=(0,−5,0)).
The orbit camera at 15–30° elevation sees the underside as a dark shadow band directly below each
balcony slab — creates strong horizontal depth cues on haussmannien/bordelais/madrileño/romanOchre/
londonBrick/nycBrick facades. `addBandStrip` itself still only emits front + top face; undersides
are caller-opt-in (`addBalconies` only — floor ledge bands are only 0.12–0.38m deep and the
underside area is not worth the extra triangles at orbit scale).
Do NOT add `includeUnderside` to `addBandStrip` globally — the base plinth sits at y=0 and its
underside would be underground, and floor-band undersides at 0.38m depth are sub-pixel at orbit
distance. The pattern is explicit in `addBalconies` for legibility.

**POI overview-only zoom (2026-07-14):** `flyToVenue` in `DistrictRealityView.Coordinator` was
changed from an eye-level walk-up (`camY = 8m`, `lookAt.y = 5m`) to an elevated orbit zoom
(`orbitDist = districtExtent × 0.20`, elevation 15° from current `azimuth`). Eye-level mode is
now permanently removed — all camera animations (building tap, POI selection, search fly) stay in
the elevated ensemble overview. The `approachBearing`/`approachDistance` POI fields are no longer
used for camera positioning (they were only needed for the eye-level approach angle); the venue
framing approach is always from the current azimuth at 15° elevation.
`center`, `currentDistance`, `currentElevation` are updated so post-fly pan/orbit resume from the
landed position, consistent with `flyToBuildingWithFraming`.

**Visual effect scale**: floor ledge bands (0.38m for haussmannien) are sub-pixel at full orbit
distance — they register as surface texture/shadow differentiation at mid-zoom and become clearly
readable as 3D horizontal relief in the close-up street-view camera. Ground-floor cladding (8m for
`modernGlass`) is visible from orbit as a darker base zone on tall towers. Spandrel panels on
`modernGlass` (0.06m) show as subtle horizontal ridges at camera distances ≤50m.
Screenshot-verified 2026-07-14: Le Marais (haussmannien fabric + mansard caps), SudirmanThamrin
(dark granite ground-floor podium zone visible on glass towers, spandrel bands on facades),
VieuxBordeaux (facade bands clearly visible as horizontal white ledges on amber bordelaisClassical
fabric, terracotta canal-tile rooftops). Water PBR (`natural=water` green zones: clearcoat 0.80,
roughness 0.16) applies to Garonne in both Bordeaux districts and Jakarta bay zones.

## Tokyo / Shibuya district (added 2026-07-15)

**Shibuya: 2,615 buildings** (2,241 with estimated height), 1,767 roads, 38 green zones.
20 point-mapped landmarks matched from OSM. Fetched and screenshot-verified 2026-07-15.

```
python3 fetch_district_data.py \
  --name Shibuya --bbox 35.655 139.694 35.665 139.708 \
  --anchor 35.6601 139.7009 --default-style modernConcrete \
  --out ../MetaCity/Resources/Districts/Shibuya.json \
  --cache /tmp/shibuya_raw.json
```

Style distribution: 2,411 modernConcrete (92%), 169 modernGlass (6%), 23 government (1%),
12 religious (<1%). `modernConcrete` is NOT in `HEIGHT_PROMOTION_BYPASS` so towers auto-promote
correctly to `modernGlass` at ≥30m.

**Key verified buildings:**
- `渋谷スクランブルスクエア` (Shibuya Scramble Square): 230m, modernGlass, non-estimated ✓
- `セルリアンタワー` (Cerulean Tower): 188m, modernGlass ✓
- `渋谷ストリーム` (Shibuya Stream): 180m, modernGlass ✓
- `パークコート渋谷ザ・タワー`: 156m, modernGlass ✓
- `Shibuya Sakura Stage SHIBUYA Tower`: 156m, modernGlass ✓

`focusBuildingName` in CityManifest is "Scramble Square" — display-only (subtitle in DiscoverView
district list). Camera targets `district.buildingCentroid` not a named building, so the English vs.
Japanese name mismatch (`渋谷スクランブルスクエア`) does not affect rendering.

**moodKey**: `shibuyaNeon` — warm amber late-afternoon sun, 30,000 lux, elevation 0.22 (lowest in the app
after `romanGoldenHour`), near-black indigo-tinted asphalt road material. Mood fully implemented
in `DistrictRealityScene.swift` before this district was fetched.

Shibuya is in `heavyDistricts` in `MetaCityApp.swift` (2,615 buildings → on-demand load, not
startup prefetch). No authored override file needed — all tall buildings correctly classify via
height promotion. `dataBundled: true` in CityManifest as of 2026-07-15.

**Visual identity** (screenshot-verified 2026-07-15): The curved JR Yamanote/Saikyo elevated rail
loop structure at Shibuya station is unmistakably visible in the road network topology. Dense
modernConcrete commercial fabric (the dominant Shibuya block character) contrasts with dark
modernGlass towers (Scramble Square, Cerulean Tower) at the station periphery. Near-black
shibuyaNeon asphalt clearly differentiates road network from building footprints. Road network
is the most complex in the app — the Scramble intersection area generates extremely dense
road geometry with multiple grade-separated paths. This is architecturally accurate.

**KNOWN_HEIGHTS additions** (in `tools/fetch_district_data.py`):
```python
"Scramble Square": 230, "渋谷スクランブルスクエア": 230, "Shibuya Scramble Square": 230,
"Shibuya Hikarie": 182, "渋谷ヒカリエ": 182, "Hikarie": 182,
"Shibuya Stream": 180, "渋谷ストリーム": 180,
"Cerulean Tower": 184, "Cerulean Tower Tokyo Hotel": 184, "セルリアンタワー東急ホテル": 184,
"Mark City": 56, "渋谷マークシティ": 56, "Shibuya Mark City": 56,
"NHK Broadcasting Center": 48, "NHK放送センター": 48,
"SHIBUYA109": 35, "渋谷109": 35,
"Bunkamura": 22, "QFront": 32, "Shibuya Excel Hotel Tokyu": 46, "Prime": 88,
```

## Los Angeles / DowntownLA district (added 2026-07-16)

**DowntownLA: 2,658 buildings** (2,427 modernConcrete 91%, 171 modernGlass 6%, 49 government 2%, 11 religious 0%), 7,322 roads, 73 green zones. 21 point-mapped landmarks matched. Fetched and screenshot-verified 2026-07-16.

```
python3 fetch_district_data.py \
  --name DowntownLA --bbox 34.033 -118.265 34.058 -118.235 \
  --anchor 34.0522 -118.2437 --default-style modernConcrete \
  --out ../MetaCity/Resources/Districts/DowntownLA.json \
  --cache /tmp/dtla_raw.json
```

**moodKey**: `laSunset` — Pacific golden-hour, 34,000 lux, sun elevation 0.20 (2nd lowest in the app, after `romanGoldenHour`'s 0.32 and matching the very low LA sun angle), 48° FOV. Warm sandy bleached-concrete ground texture. `modernConcrete` is NOT in `HEIGHT_PROMOTION_BYPASS` so Bunker Hill glass towers auto-promote to `modernGlass` at ≥30m correctly.

**Key verified buildings:**
- `Wilshire Grand Building`: 335m, modernGlass (authored override — OSM had 292m; KNOWN_HEIGHTS key mismatch `"Wilshire Grand Center"` vs OSM name `"Wilshire Grand Building"`, both now in KNOWN_HEIGHTS)
- Aon Center: 262m, modernGlass ✓
- 777 Tower: 218m, modernGlass ✓
- Figueroa at Wilshire: 183m, modernGlass ✓

`focusBuildingName` in CityManifest is "Wilshire Grand Center" — display-only subtitle. Camera targets `district.buildingCentroid`. English display vs OSM name mismatch does not affect rendering.

DowntownLA is in `heavyDistricts` in `MetaCityApp.swift` (2,658 buildings → on-demand load, not startup prefetch). `DistrictRenderProfile.preset("DowntownLA")`: nightWindowDensityBoost 1.15, facadeDepthScale 1.0.

### `laStucco` BuildingStyle

New `BuildingStyle` case for LA Spanish Colonial/stucco bungalow vernacular:
- **Wall**: sun-baked cream-ochre stucco `(0.86+0.08·wobble, 0.78+0.06·wobble, 0.60+0.04·wobble)`, metallic 0.0, roughness 0.81–0.88, clearcoat 0.04.
- **Roof**: Spanish Mission barrel tile `(0.68, 0.28, 0.10)` day / dark terracotta night. Cap: **22° pitch** (`pitchTan: 0.404`), `maxRidgeInset: 4.5m`, overhang 0.40m — shallow wide eave of LA ranch bungalows.
- **Night emissive**: 0.18 — LA residential, sparse electric density.
- **Window texture**: 3×5 grid, density 0.18.
- **IN HEIGHT_PROMOTION_BYPASS** (`tools/fetch_district_data.py`): prevents LA stucco bungalows from being height-promoted to modernGlass/modernConcrete.
- No facade articulation bands (`facadeProfile` returns `.none`) — architecturally correct for single-storey California bungalows.
- **NOT the default style for DowntownLA** — DowntownLA uses `--default-style modernConcrete` (the downtown office grid). `laStucco` will be the default style for Hollywood (residential fabric) when that district is fetched.

### `laSunset` Mood

New `DistrictRealityScene.Mood`:
- Sun `(1.0, 0.74, 0.44)`, 34,000 lux, elevation 0.20.
- Zenith `(0.28, 0.36, 0.58)` / horizon `(0.72, 0.56, 0.34)` / ground `(0.36, 0.26, 0.18)`.
- Camera distance 0.20, height 0.12, FOV 48°.
- Road material: warm sun-baked asphalt (primary `(0.26, 0.22, 0.18)`), pedestrian zones `(0.56, 0.48, 0.38)`.
- Ground texture: bleached LA concrete, warm sandy cast with dark mortar joints `(82, 72, 56)` and alternating block tones `(148, 130, 100)` / `(136, 118, 90)` + noise.
- `warmthBias: +0.04` (same as bordeauxWaterfront — Pacific golden-hour warmth).
- `nightEmissiveBoost: 1.0` (default — LA residential has low electric density; glass towers handled by DistrictRenderProfile preset 1.15 density boost separately).

### `DowntownLA_authored.json` (5 overrides)
- `osmID 23973401` (Skyspace LA / US Bank Tower): `style: modernGlass, heightMeters: 310.0` — OSM maps it as "Skyspace LA" (the obs deck brand) with government classification.
- `osmID 496246723` (Wilshire Grand Building): `heightMeters: 335.0` — OSM height was 292m.
- nameMatch "Los Angeles City Hall": `style: government, roofType: flat`.
- nameMatch "Walt Disney Concert Hall": `style: modernGlass, roofType: flat, heightMeters: 55.0`.
- nameMatch "The Broad": `style: modernGlass, roofType: flat`.

### KNOWN_HEIGHTS additions for LA (in `tools/fetch_district_data.py`)
20+ entries added: Wilshire Grand Center/Building 335m, US Bank Tower 310m, Aon Center 262m, Two California Plaza 221m, 777 Tower 218m, Figueroa at Wilshire 183m, Ernst & Young Tower 156m, JPMorgan Chase Tower 146m, Wilshire Grand Annex 127m, LA City Hall 138m, Walt Disney Concert Hall 55m, Union Station 35m, Bradbury Building 18m, The Broad 18m, Grand Central Market 15m.

**Screenshot-verified 2026-07-16**: Classic DTLA orthogonal grid visible (North American street layout, distinct from European organic fabric or Tokyo rail topology). Bunker Hill glass towers (Wilshire Grand, Aon Center area) dominate upper-left in modernGlass dark. Warm sandy ochre ground from `laSunset`. Road network (7,322 roads) clearly visible in warm terracotta-orange. Green zones (Pershing Square / Grand Park) visible as patches.

### `activities_losangeles.json` (6 activities)
`la_wilshire_grand_obs` (OUE Skyspace, premium/panorama), `la_broad_museum` (premium/explore), `la_disney_concert_hall` (standard/explore), `la_grand_central_market` (standard/lifestyle), `la_bradbury_building` (standard/explore), `la_arts_district_walk` (standard/explore). "losangeles" added to `ActivitiesViewModel.others`.

### Hollywood placeholder
`Hollywood` is in CityManifest.json under `losangeles` city with `dataBundled: false`. Not yet fetched. When fetching: use `--default-style laStucco` (residential bungalow fabric), create `Hollywood_authored.json` for TCL Chinese Theatre (→ government/flat), Capitol Records Building (→ government), Dolby Theatre (→ government/flat), ArcLight Dome (→ modernGlass/dome).

## Vancouver / San Francisco districts (added 2026-07-16)

Four districts across two Pacific Coast cities. All fetched from real OSM data, screenshot-verified
2026-07-16. Both cities share the same `moodKey` within their city (single-mood cities).

### `nycBrick` BuildingStyle (also used by FishermansWharf SF)

`nycBrick` was introduced for NYC but applies to Victorian/pre-war brick fabric anywhere:
- **Wall**: fired clay brick, warm yellow-buff range — `dayR = 0.74+0.08·wobble`, `dayG = 0.62+0.06·wobble`,
  `dayB = 0.38+0.04·wobble`. Roughness 0.82–0.89, metallic 0.0, clearcoat 0.05.
- **Roof**: Welsh/NY slate — `(0.44, 0.46, 0.50)`, roughness 0.88, clearcoat 0.04.
- **Cap geometry**: 28° pitch (`pitchTan: 0.532`), `maxRidgeInset: 4.5m`, overhang 0.22m.
- **Night emissive**: 0.28. Window texture: 4×7 grid, density 0.30.
- **Ground floor**: brownstone entry `(0.38, 0.28, 0.20)`, roughness 0.80.
- **NOT in HEIGHT_PROMOTION_BYPASS** — NYC glass towers (Chrysler, One WTC) auto-promote correctly.

### `vancouverCoastal` Mood

- Sun `(0.88, 0.92, 0.98)`, 24,000 lux (overcast Pacific diffuse), elevation 0.42.
- Zenith `(0.38, 0.46, 0.62)` / horizon `(0.66, 0.72, 0.80)` / ground `(0.22, 0.24, 0.28)`.
- Camera distance 0.18, height 0.14, FOV 45°.
- Road material: cool Portland stone pedestrian `(0.68, 0.68, 0.70)`, primary dark wet tarmac `(0.22, 0.22, 0.24)`.
- Ground texture: cool blue-grey concrete with tight grid joints — distinctly cooler than nycDusk warm asphalt.
- `warmthBias: -0.03` (Pacific coastal overcast — cooler than London silver, warmer than rennesMedieval).

### `sfMorning` Mood

- Sun `(1.0, 0.90, 0.72)`, 28,000 lux (morning California sun), elevation 0.48.
- Zenith `(0.42, 0.50, 0.68)` / horizon `(0.72, 0.72, 0.68)` / ground `(0.32, 0.28, 0.22)`.
- Camera distance 0.18, height 0.13, FOV 45°.
- Road material: warm pale concrete (primary `(0.32, 0.30, 0.28)`), pedestrian zones `(0.58, 0.54, 0.46)`.
- Ground texture: warm sandy concrete with dark mortar joints, slightly warm cast to differentiate from Vancouver.
- `warmthBias: +0.02` (California morning warmth).

### District data (fetched 2026-07-16, screenshot-verified)

**VancouverDowntown**: ~2,200 buildings (modernGlass + modernConcrete Pacific NW tower fabric),
~1,400 roads, water polygons (Coal Harbour / False Creek). `focusBuildingName: "Marine Building"` (98m Art Deco tower, authored override → government/flat). All 4 Vancouver/SF districts are in `heavyDistricts`.

**WestEnd**: ~1,900 buildings (dense residential glass + concrete towers), large central green zones
(Nelson Park / Barclay Square — visually distinctive from VancouverDowntown). `focusBuildingName: "Roedde House Museum"`.

**SFDowntown**: ~2,100 buildings (~93% modernGlass — Financial District is one of the densest glass tower cores in North America), ~1,600 roads. `focusBuildingName: "Transamerica Pyramid"` (260m, authored override → government/flat).

**FishermansWharf**: ~900 buildings (~99% nycBrick — Victorian/Edwardian brick warehouses and canneries), low-rise (1–3 storeys), no towers. `focusBuildingName: "Ghirardelli Chocolate Experience"`. Visually unmistakable contrast with SFDowntown glass towers — same sfMorning mood, completely different urban fabric.

### Authored overrides (screenshot-verified 2026-07-16)

**`VancouverDowntown_authored.json`** (6 overrides):
- Marine Building: government/flat, 98m
- Vancouver Art Gallery: government/flat
- Christ Church Cathedral: religious/flat
- Rosewood Hotel Georgia: government, 36m
- Rogers Arena: government/flat
- BC Place: government/dome — roof authored as dome (the stadium's retractable dome roof)

**`SFDowntown_authored.json`** (6 overrides):
- San Francisco Ferry Building: government/flat, 71m
- Transamerica Pyramid: government/flat, 260m
- Old Saint Mary's Cathedral: religious/flat
- Saints Peter and Paul Church: religious/flat
- Huntington Park: government/flat
- Palace Hotel: government, 55m

**`FishermansWharf_authored.json`** (5 overrides):
- Ghirardelli Chocolate Experience: government/flat, 14m
- The Cannery: government/flat, 14m
- National Maritime Museum: government/flat
- San Francisco Maritime Visitor Center: government/flat
- Aquarium of the Bay: government/flat

No authored override file for WestEnd — all buildings are correctly classified as modernGlass/modernConcrete by height promotion; no misclassified landmarks identified in the OSM dataset.

### DistrictRenderProfile presets

| District | nightWindowDensityBoost | facadeDepthScale |
|---|---|---|
| VancouverDowntown | 1.05 | 1.0 |
| WestEnd | 1.10 | 1.0 |
| SFDowntown | 1.00 | 1.0 |
| FishermansWharf | 0.75 | 1.0 |

FishermansWharf at 0.75× — tourist/retail district closes early, few lit windows after 20h.

### activities and places data

- `activities_vancouver.json` — 6 activities for cityId: "vancouver" (Stanley Park, Capilano, Granville Island, Coal Harbour, Gastown, Grouse Mountain)
- `activities_sanfrancisco.json` — 6 activities for cityId: "sanfrancisco" (Transamerica Observation, Alcatraz Night, Ferry Building Market, Golden Gate Walk, Tartine Morning, Mission Burrito Trail)
- `places_vancouver.json` — 7 places (Stanley Park Seawall, Granville Island, Capilano, Coal Harbour isFeatured, Gastown, Kitsilano Beach, Museum of Anthropology)
- `places_sanfrancisco.json` — 8 places (Golden Gate, Ferry Building, Alcatraz, Mission burritos isFeatured, Chinatown, Haight-Ashbury, SFMOMA, Tartine)

`vancouver` is in `ActivitiesViewModel.vitrineCityIDs` (the 5 showcase cities: paris, tokyo, vancouver, jakarta, denpasar). `sanfrancisco` is in `others`.

## Day-mode window roughness texture + building-tap wide framing (2026-07-15)

### Day-mode roughness texture (AXE 1)

`DistrictRealityKit` now applies a style-specific roughness texture in **day mode** to produce
per-window specular differentiation — window panes read as smooth glass (low roughness) against
the rougher wall material, creating daylight reflective glints without any additional lighting cost.

**Implementation** (`DistrictRealityKit.swift`):
- `windowRoughnessTextureCache: [String: TextureResource]` — static cache, same lifecycle as
  `windowTextureCache`. One entry per style (`style.rawValue` key).
- `makeWindowRoughnessTexture(for:)` — generates a 256×256 CGImage using `.hdrColor` semantic
  (linear encoding, no gamma correction). Wall pixels = per-style `wallV` byte (≈0.76–0.89
  roughness); window pane pixels = `14` (≈0.055, near-mirror glass); frame border pixels = `148`
  (≈0.58, mid-rough window surround). Grid layout mirrors the night emissive texture grid.
- `pooledMaterial` threads `roughnessTexture` to `materialPreset` only when `!isNight`. Night
  mode keeps the existing emissive texture (lit windows) and uses scalar roughness.
- `materialPreset` signature gained `roughnessTexture: TextureResource? = nil`; applies it as
  `material.roughness = .init(texture: .init(rt))` immediately before the night-emissive block.

**Why all window cells are smooth (not density-randomized):** glass is always reflective in
daylight regardless of whether a room is occupied — the smooth/rough discrimination is
wall-vs-glass, not lit-vs-dark. Night mode uses density randomization (some rooms lit, some dark)
because emissive means occupancy. The day roughness texture has no density parameter.

**Per-style `wallV` values** (roughness ≈ wallV / 255 in linear):

| Style | wallV | Roughness |
|---|---|---|
| modernGlass | 50 | ≈0.196 |
| modernConcrete | 168 | ≈0.659 |
| haussmannien | 195 | ≈0.765 |
| bordelaisClassical | 198 | ≈0.776 |
| londonBrick | 212 | ≈0.831 |
| madrileño | 187 | ≈0.733 |
| romanOchre | 202 | ≈0.792 |
| colonial | 218 | ≈0.855 |
| government | 165 | ≈0.647 |
| nycBrick | 228 | ≈0.894 |

Styles `balinese`, `javanese`, `religious`, `medieval` return `nil` (these styles have no
recognizable rectilinear window grids at the scales rendered by this app).

**Screenshot-verified 2026-07-15**: Le Marais (haussmannien) shows horizontal floor-ledge band
relief clearly in close tap-zoom, with window positions reading as specular spots against the
cream wall roughness. SudirmanThamrin glass towers read as near-mirror at low roughness.

### Building-tap wide framing (AXE 4)

`flyToBuildingWithFraming` in `DistrictRealityView.Coordinator` was revised to give more air
around the selected building. The camera stays in the elevated orbit view — no eye-level approach.

**Changed parameters** (all in the FOV-fit distance calculation at the top of the function):

| Parameter | Before | After | Effect |
|---|---|---|---|
| FOV fit multiplier | `1.30` | `1.85` | 85% more clearance above min FOV fit |
| `maxRelDist` (tall building) | `0.52` | `0.65` | allows stepping further back for towers |
| `maxRelDist` (short building) | `0.38` | `0.50` | more air around low-rise buildings |
| `lookH` (tall) | `building.heightMeters × 0.40` | `× 0.35` | camera looks slightly lower, more roofline visible above |
| `lookH` (short) | `building.heightMeters × 0.35` | `× 0.28` | same reason for short buildings |

**Absolute constraint**: building tap must NEVER produce a tight eye-level or street-level close-up.
All camera animations (building tap, POI selection, search fly) must stay in the elevated ensemble
orbit view. This is a hard UX invariant — do NOT revert to eye-level (`camY`, `lookAt.y` in
metres) approach for building tap or any other trigger. See AXE 4 rationale in this session.

**Screenshot-verified 2026-07-15**: Tap on a Haussmannien building in Le Marais → full building
visible with roofline above and street ground below, from elevated orbit angle, info card
"HAUSSMANNIEN / ~18m" appeared, "ORBIT 360°" button visible — no tight close-up.

### Profile traveler section (AXE 3)

`ProfileView.passport` now shows a `travelSection` instead of `districtBadges` (the old
`LazyVGrid` of 26 individual district badge cells). The new section:
- **MON PARCOURS** row: horizontal `ScrollView` of visited-city cards derived from
  `viewModel.preferences.visitedDistrictIds` (already persisted). Cards show city name +
  `count/total quartiers` visited. Empty-state globe prompt if no districts explored yet.
- **DESTINATIONS 3D** row: horizontal chips for cities with `dataBundled` districts, showing
  district count. Tappable visual affordance but no navigation (stateless component).

No new data model — derives entirely from `CityManifest.shared.allCities` and the existing
`visitedDistrictIds: Set<String>` in `UserPreferences`. Screenshot-verified 2026-07-15: shows
Bali (4/5), Jakarta (3/5), Yogyakarta (1/2), Paris (1/4) in the visited-city scroll.

## Activities — European cities (added 2026-07-15)

Six new `activities_*.json` files added for European cities, completing the activities coverage:

| File | cityId | Activities | Categories |
|---|---|---|---|
| `activities_rome.json` | `rome` | 6 | panorama, experienceRA, immersionSensorielle, visiteGuidee, lifestyle, experienceRA |
| `activities_madrid.json` | `madrid` | 6 | panorama, experienceRA, immersionSensorielle, visiteGuidee, lifestyle, panorama |
| `activities_bordeaux.json` | `bordeaux` | 6 | immersionSensorielle, panorama, experienceRA, lifestyle, visiteGuidee, experienceRA |
| `activities_london.json` | `london` | 6 | panorama, experienceRA, immersionSensorielle, visiteGuidee, lifestyle, experienceRA |

`ActivitiesViewModel.others` updated to include `"london"`, `"madrid"`, `"bordeaux"`, `"rome"` —
these cities now appear in the Activities tab city picker below the vitrine showcase cities.

**`CityCalloutCard` — Featured activities strip (2026-07-15):** A `FeaturedActivitiesStrip`
appears between the weather widget and the district list when a city has activity data. Shows up
to 3 premium activities as compact horizontal chips (icon + name). Loads via `.task(id: city.id)`
using the same `CityActivities.load` path as `ActivitiesViewModel`. No new data model.

## Facade detail LOD (2026-07-15)

`DistrictRealityView.Coordinator` now hides `_bands`, `_pilasters`, `_balconies` facade-detail
entities at full orbit distance and re-shows them when the camera zooms to building-tap level.

**Why**: These entities produce correct surface relief at building-tap zoom (40–120m camera
distance) but are sub-pixel at full-orbit distance (~500m–3km depending on district size) —
they add GPU noise without contributing to the visual. `_ground` (ground-floor cladding, visible
at orbit as a darker base zone on tall towers) is intentionally excluded from this LOD gate.

**Implementation** (`DistrictRealityView.swift`):
- `private var facadeDetailEntities: [Entity] = []` — populated once per district load.
- `cacheFacadeDetailEntities(from: Entity)` — walks all 4 quadrant near-containers, collects
  every child whose name ends in `"_bands"`, `"_pilasters"`, or `"_balconies"`.
- `setFacadeDetailEnabled(_ Bool)` — enables/disables all collected entities.
- Called from `applyOrbitLOD()` (disable) and `flyToBuildingWithFraming` (enable, before
  the animated fly), and `cacheFacadeDetailEntities` is called from `loadModel` after
  `extractQuadrantLOD`.

**Invariant**: `applyOrbitLOD` is the orbit-mode setter and `flyToBuildingWithFraming` is the
building-tap-mode setter. These are the only two places that control facade detail visibility.
The camera is always in one of these two states — there is no continuous distance-check LOD
for this. Venue mode (POI selection) inherits whatever the last building-tap or orbit call set.

## Night variation: per-bucket window density + per-mood emissive boost (2026-07-16)

Two improvements to night-mode visual fidelity, both in `DistrictRealityKit.swift`:

### Per-bucket window density

Previously, `cachedWindowTexture(for:)` produced a single 256×256 texture per style regardless of
which of the 3 material variation buckets was being built — all buildings of the same style had
identical window-lit cell patterns at night.

**Fix**: `cachedWindowTexture(for:bucket:)` now takes `bucket: Int` (0–9 from the material
variation bucketing in `pooledMaterial`). The density is scaled by bucket tier:
- Bucket 0–2 → `densityScale = 0.50` (sparse: ~half as many lit windows)
- Bucket 3–6 → `densityScale = 1.0` (standard base density)
- Bucket 7–9 → `densityScale = 1.65` (dense: more windows lit, capped at 100%)

This means adjacent buildings of the same style now read as individually varied occupancy at
night — a sparse "dark" building next to a dense "fully-lit" building — without changing day-mode
appearance, material count, or draw call budget. Cache key: `"\(style.rawValue)_\(bucket)_night"`.
Up to 30 night window textures max (10 buckets × 3 style tiers in practice).

`makeWindowTexture(for:densityScale:)` gained a `densityScale: Float = 1.0` parameter; the
density gate became `guard Float(seed & 0xFF) / 255.0 < min(density * densityScale, 1.0)`.

### Per-mood night emissive boost

`DistrictRealityScene.Mood.nightEmissiveBoost: Float` (added 2026-07-16) is a multiplier applied
to all building emissive intensities when entities are built for that district. Shibuya's dense
commercial neon reads at 1.30× base; Paris café-apartment glow at 1.10×; tropical beach resorts
remain at 1.0× (low electric density is architecturally accurate for Bali).

**Implementation**:
- `@MainActor private static var currentMoodBoost: Float = 1.0` in `DistrictRealityKit` — set
  at the top of `loadDistrictEntity` from `mood.nightEmissiveBoost` before any geometry build.
- `materialPreset(for:...:nightEmissiveBoost:)` gained a `nightEmissiveBoost: Float = 1.0`
  parameter; applied as `emissiveIntensity = baseIntensity * nightEmissiveBoost` in both the
  `modernGlass` and `default` night branches.
- `pooledMaterial` reads `currentMoodBoost` and passes it through; includes boost tier in the
  material pool cache key: `"..._b\(Int(currentMoodBoost * 10))"` → max 50 + a small multiple
  for non-1.0 boost tiers (each district has exactly one fixed mood, so in practice only one
  boost tier appears per style).
- The entity cache key remains district-name-only — safe because each district has exactly one
  fixed `moodKey` in `CityManifest.json`, so `currentMoodBoost` is always the same value for
  any given district.

**Boost values** (`Mood.nightEmissiveBoost`):
| Mood | Boost | Reason |
|---|---|---|
| `shibuyaNeon` | 1.30 | Tokyo commercial neon saturation — densest in app |
| `nycDusk` | 1.20 | NYC canyon amplifies reflected light into building facades |
| `skyscraperCorridor` | 1.15 | Jakarta SCBD Blade Runner warm fill + glass tower density |
| `parisianCore` | 1.10 | Café-apartment amber glow through iron-railing balconies |
| `bordeauxWaterfront` | 1.08 | Quayside café-terrace glow |
| `madridAfternoon` | 1.05 | Terrace incandescent balcony lamp density |
| all others | 1.0 | Default — balinese, beach resort, colonial Jakarta, etc. |

## District first-entry reveal overlay (2026-07-16)

`DistrictRevealOverlay` slides up from the bottom on the **first visit** to each district
(persisted via `UserDefaults.standard.bool(forKey: "reveal_\(district.id)")`). It auto-dismisses
after 3.5s and can be dismissed early via the × button.

**Content**: city name (neon, monospaced, tracking), district name (large black), three stat chips
(building count, road count, mood label). A neon drain bar (metacityPrimary color) at the top
drains left-to-right over 3.5s as a visual countdown.

**Trigger**: `DiscoverViewModel.selectDistrict` checks the UserDefaults key. On first open, sets
the key, builds a `DistrictRevealContext` (city + district + building/road counts from
`District.load(named:)` — cached), and dispatches the show with a 0.7s delay (cinematic entry
completes before the card appears). Auto-dismiss is a second `DispatchQueue.main.asyncAfter`
dispatched at the same call site. `dismissDistrictReveal()` allows early dismiss.

**Architecture**: `@Published private(set) var districtRevealContext: DistrictRevealContext?` on
`DiscoverViewModel`. `DiscoverView.body` checks `if let ctx = viewModel.districtRevealContext` and
shows `DistrictRevealOverlay` with `.zIndex(100)` above all other overlays. Transition:
`.move(edge: .bottom).combined(with: .opacity)`.

`RevealStat` is a small private struct (label + value in monospaced typography) shared between
the three stat chips. `moodLabel` in `DistrictRevealOverlay` maps `moodKey` strings to display
labels (e.g. `"shibuyaNeon"` → `"NEON"`, `"parisianCore"` → `"PARIS"`).

## Material quality upgrade pass (2026-07-16, continued)

### `DistrictRenderProfile` — per-district render overrides

`DistrictRenderProfile` (file-scope struct, `DistrictRealityKit.swift` line ~27) provides three
per-district multipliers applied at entity-build time:

- **`nightWindowDensityBoost: Float`** — multiplied on top of the per-bucket density scale
  (bucket 0-2 = 0.50×, 3-6 = 1.0×, 7-9 = 1.65×) and the base `density` per style. Lets
  flagship commercial districts appear busier at night than generic districts with the same style.
- **`facadeDepthScale: Float`** — multiplied on `FacadeProfile` band/cornice/balcony *projection*
  depths (NOT thicknesses, NOT heights, NOT spacing) via `FacadeProfile.scaled(by:)`. Makes Le
  Marais's haussmannien facade relief stronger in building-tap zoom.
- **`weatheringIntensity: Float`** (added 2026-07-18) — 0.0 = pristine, 1.0 = maximum grime/age.
  Applied in `materialPreset` to darken and slightly grey stone/brick/plaster base colors
  (grime deposit) and reduce `clearcoat` (patina mutes polished surfaces). Only affects
  non-glass styles. Stored in `currentWeatheringIntensity`; pool cache key extended with
  `_a\(weatherTier)` suffix. Each district has a fixed weathering value so the entity cache
  (district-name-keyed) is always consistent.

All three are set at the top of `loadDistrictEntity` via `DistrictRenderProfile.preset(for: name)`.
Thread-safe: entity cache key is district-name-only; each district has exactly one fixed preset.

**Per-district presets** (as of 2026-07-18):

| District | nightWindowDensityBoost | facadeDepthScale | weatheringIntensity | Reason |
|---|---|---|---|---|
| KotaTua | 1.00 | 1.0 | **0.65** | Heaviest Dutch colonial grime in Jakarta |
| CentroStorico | 1.05 | 1.12 | **0.68** | Two millennia of Roman tuff weathering |
| Westminster | 1.05 | 1.08 | **0.58** | Gothic Revival stone + Victorian pollution |
| CityOfLondon | 0.80 | 1.06 | **0.52** | Coal-era soot on London stock brick |
| LeMarais | 1.20 | 1.15 | **0.52** | Paris limestone pollution darkening |
| Menteng | 0.95 | 1.0 | **0.52** | Colonial residential grime |
| Montmartre | 1.15 | 1.12 | **0.55** | Hilltop exposure + stone weathering |
| Braga | 1.00 | 1.0 | **0.55** | Dutch hill-station weathering |
| SaintGermain | 1.15 | 1.12 | 0.46 | Paris left bank stone |
| MidtownManhattan | 1.35 | 1.0 | 0.50 | Pre-war brick grime |
| LowerManhattan | 0.90 | 1.0 | 0.48 | Financial district historic brick |
| FishermansWharf | 0.75 | 1.0 | 0.48 | Victorian brick warehouse weathering |
| VieuxBordeaux, LesChartrons | 1.18 | 1.10 | 0.45 | Quayside algae on Gironde stone |
| Salamanca | 1.22 | 1.08 | 0.32 | Moderate Iberian weathering |
| Malasana | 1.30 | 1.08 | 0.38 | Madrid residential aging |
| Shibuya | 1.40 | 1.0 | 0.10 | Modern concrete, minimal weathering |
| LaDefense | 0.75 | 1.0 | 0.05 | New glass office towers |
| SudirmanThamrin | 1.25 | 1.0 | 0.05 | Glass tower SCBD |
| All others | 1.0 | 1.0 | 0.0 | Default pristine |

**`FacadeProfile.scaled(by:)`** — added to the `FacadeProfile` struct. Scales only the outward
projection fields (bandDepth, corniceDepth, plinthDepth, groundFloorDepth, balconyDepth,
pilasterDepth). Vertical heights (bandThick, corniceHeight, plinthHeight, balconyThick) and
spacing/count fields (floorInterval, pilasterSpacing, pilasterWidth, firstFloor, floorStep) are
unchanged — lateral projection is the axis that registers as "depth" at building-tap camera angle,
while thickness is already calibrated for orbit-camera pixel budget.

Applied at the single `facadeProfile(for: style)` call site in `makeBuildingMeshes`:
```swift
let profile = facadeProfile(for: style).scaled(by: currentDistrictProfile.facadeDepthScale)
```

### Warmth bias per mood (`warmthBias`, 2026-07-16)

`Mood.warmthBias: Float` computed property added to `DistrictRealityScene.Mood`. Stored in
`@MainActor private static var currentWarmthBias: Float = 0.0` and set in `loadDistrictEntity`.
Threaded through `pooledMaterial` → `materialPreset(for:...:warmthBias:)`.

In `materialPreset`, applied as: `R += wb`, `G += wb × 0.4`, `B -= wb × 0.6` (approximate
blackbody temperature shift). Values:
- `romanGoldenHour: +0.05` — maximum warmth, Rome's sienna-amber identity
- `bordeauxWaterfront: +0.04` — golden Garonne riverside
- `madridAfternoon: +0.03` — warm Iberian afternoon
- `beachResort: +0.02` — tropical light
- `parisianCore: -0.02` — cool pearl overcast
- `shibuyaNeon: -0.02` — Tokyo grey-blue concrete
- `rennesMedieval: -0.03` — cool Breton grey
- `londonSilver: -0.04` — silver British overcast

Pool cache key extended with warmth tier: `"..._w\(Int(warmthBias × 100))"`.

### `VoyageurPersonality` — computed traveler archetype (2026-07-16)

`VoyageurPersonality` enum in `ProfileViewModel.swift` with 7 archetypes:

| Case | Display title | Triggers |
|---|---|---|
| `newExplorer` | NOUVEAU VOYAGEUR | 0 districts visited |
| `tropicalNomad` | NOMADE TROPICAL | `beachResort`/`sacredSite` dominant |
| `urbanFuturist` | ARCHITECTE FUTURISTE | `shibuyaNeon`/`nycDusk`/`skyscraperCorridor` dominant |
| `europeanFlaneur` | FLÂNEUR EUROPÉEN | `parisianCore`/`bordeauxWaterfront`/`rennesMedieval` dominant |
| `mediterraneanVoyager` | VOYAGEUR MÉDITERRANÉEN | `madridAfternoon`/`romanGoldenHour`/`londonSilver` dominant |
| `heritageSeekerl` | HISTORIEN DU BÂTI | `colonialSquare`/`highlandMorning` dominant |
| `eclecticExplorer` | EXPLORATEUR ÉCLECTIQUE | Mixed, no dominant theme |

Computed from `CityManifest.shared.allCities` + `preferences.visitedDistrictIds` → each visited
district's `moodKey` → weighted score per theme (beach/sacred = ×2, skyscraper = ×1, etc.).
Updates automatically as `preferences.visitedDistrictIds` changes (it's a computed property on
the `@Published preferences`).

The Profile identity card hero now shows:
```
[icon] FLÂNEUR EUROPÉEN       ← personality.title
HAUSSMANN · PARIS · PATRIMOINE URBAIN  ← personality.subtitle
```
instead of the previous static "EXPLORATEUR NUMÉRIQUE · TOURISME 3D & RA" string.
Screenshot-verified 2026-07-16: user with Paris 4/4 + Bordeaux 2/2 → "FLÂNEUR EUROPÉEN".

### `DistrictRevealContext.activityCount` (2026-07-16)

`DistrictRevealContext` gained `activityCount: Int`. `DiscoverViewModel.selectDistrict`
populates it: tries `CityActivities.load(for: district.id.lowercased())` first; if empty,
falls back to `CityActivities.load(for: city.id)`. The `DistrictRevealOverlay` shows an
ACTIVITÉS stat chip when `activityCount > 0`.

**`CityActivities.load(for:)` returns `[ActivityEntry]` directly** (NOT `CityActivities?`) —
using optional chaining (`?.activities`) compiles but crashes at runtime. This is a documented
gotcha; do not add optional chaining here.

## Wave 2 commercial upgrade (2026-07-17)

Three groups of improvements, all build/screenshot-verified 2026-07-17.

### Chimney stacks (3D toiture detail)

`makeChimneyEntities` in `DistrictRealityKit.swift` adds a batched chimney-stack layer per style
quadrant. One merged `MeshDescriptor` per style → ≤5 entities per district at most (one per
eligible style per quadrant). Eligible styles: `haussmannien`, `londonBrick`, `colonial`,
`nycBrick`, `medieval`.

**Entity naming** (critical for LOD): `"bld_\(style.rawValue)_q\(quadrantIndex)_chimneys"` —
the `_chimneys` suffix is what `cacheFacadeDetailEntities` watches. Chimneys are hidden at orbit
distance and re-enabled at building-tap zoom, identical to `_bands`/`_pilasters`/`_balconies`.

**Geometry**:
- `addChimneyStack` — 5-face rectangular prism (front/right/back/left/top) + optional pyramid
  zinc cap (4 triangles with auto-winding-flip guard). Deterministic placement via FNV-1a seeds
  `"_ck1"` / `"_ck2"` / `"_ckh{si}"` / `"_cke{si}"` on osmID + stack index.
- `addChimneyPot` — 6-sided cylinder (6 faces × 4 vertices + 2 triangles each). Used by
  `londonBrick` (terracotta pot stacks) and `nycBrick` (cast-iron pot clusters).

**Per-style specs (final, 2026-07-17):**

| Style | Stack size | Height range | Cap | Pots |
|---|---|---|---|---|
| haussmannien | 0.28×0.28m | 1.0–1.8m | zinc cone 0.22m | no |
| londonBrick | 0.50×0.50m | 0.9–1.4m | none | yes |
| colonial | 0.30×0.30m | 0.6–1.0m | none | no |
| nycBrick | 0.55×0.55m | 1.2–2.2m | none | yes |
| medieval | 0.35×0.40m | 0.7–1.2m | none | no |

Placement density (buildings per district × 2–4 stacks each): ~30–80 stacks per quadrant for
dense districts. At orbit scale (>500m camera) individual stacks are sub-pixel; their collective
silhouette contributes to roofline texture. At building-tap (40–80m) they read as distinct zinc
or terracotta stacks grouped at building ridges.

**DistrictRealityView LOD change** (line ~629): `cacheFacadeDetailEntities` extended to include
`n.hasSuffix("_chimneys")` alongside the existing `_bands`/`_pilasters`/`_balconies` check.
`loadModel` calls `applyOrbitLOD()` after `extractQuadrantLOD` to hide chimneys at startup.

### DistrictRevealOverlay glassmorphism (2026-07-17)

`DistrictRevealOverlay` struct in `DiscoverView.swift` rewritten from a simple bottom sheet to a
**premium dark glassmorphism overlay**:

- **Background**: `Color.black.opacity(0.82)` + `Rectangle().fill(.ultraThinMaterial).opacity(0.35)`.
- **Mood accent system**: `moodAccentColor` switch on `context.district.moodKey` → 15 named
  colors (shibuyaNeon → cyan, parisianCore → Parisian gold, shibuyaNeon → neon teal, etc.);
  used for the top 2pt drain bar, city name label, bullet dot, stat values, and card border.
- **Architecture period tag**: `architectureTag` switch → e.g. `"PIERRE DE LUTÈCE · HAUSSMANN
  1853–1927"`, `"BÉTON & VERRE · POST-1964"`, `"BRIQUE LONDONIENNE · ÈRE VICTORIENNE"`.
- **Drain bar**: `GeometryReader` LinearProgressBar animates over 3.5s with `.linear(duration:)`
  and a colored shadow `shadow(color: moodAccentColor.opacity(0.5), radius: 4)`.
- **Entry animation**: `.spring(response: 0.45, dampingFraction: 0.80)` slide-up from +60pt offset.
- **RevealStat**: now accepts `accent: Color` so stat values (building count, road count, ACTIVITÉS)
  render in the mood's accent color.

**`moodAccentColor` is also extracted as `ProfileView.moodAccentColor(moodKey:)` (static)**
so it can be shared by both `DistrictRevealOverlay` (in DiscoverView) and `suggestedDestinationCard`
(in ProfileView) without duplication. The two definitions are currently separate private functions
— not a shared module — because they're in different views with no natural shared parent. If a
future refactor consolidates these, put them in a `MoodTheme.swift` extension on `String` or a
shared `DistrictMoodStyle` struct.

### PlaceType additions (2026-07-17)

`PlaceType` enum gained two new cases: `.wellness` (icon `heart.fill`) and `.shopping` (icon
`bag.fill`). Both added to `displayName` and `icon` switches. `PlacesView.placeColor` extended
with `.wellness → teal-green (0.3,0.8,0.6)` and `.shopping → warm purple (0.8,0.3,0.7)`.

These cases are used by `PlacesViewModel.placeType(for:)` to classify live MKLocalSearch results
(spa/wellness → `.wellness`, factory outlet/batik/market → `.shopping`). No static `places_*.json`
file currently uses these types; they only appear in live-fetched entries from MKLocalSearch.

### PlacesViewModel enrichment (2026-07-17)

- **5 search terms per city** (was 3) for all 14 cities with `places_*.json` files.
- **Coordinate deduplication** in `mergeLivePlaces`: rejects live entries within 200m of any
  existing place (using flat-earth approximation: `dLat × 111_000`, `dLon × 111_000 × cos(lat)`).
  Prevents duplicate pins when MKLocalSearch returns the same venue under different query terms.

### Profile destination suggestions (2026-07-17)

`travelSection` in `ProfileView.swift` replaces the single "PROCHAINE DESTINATION" card with a
**"DESTINATIONS SUGGÉRÉES"** section: a horizontal `ScrollView` of up to 3 personality-matched
unvisited bundled districts.

**Logic**: `viewModel.voyageurPersonality` → array of 3 suggested `districtId`s → `compactMap`
over `CityManifest.shared.allCities` to find unvisited dataBundled entries → show as cards.
Section is hidden (not rendered) when all suggestions are already visited.

**Personality → district mapping:**

| Personality | Suggested districts |
|---|---|
| `.europeanFlaneur` | VieuxBordeaux, Montmartre, CentroStorico |
| `.tropicalNomad` | Uluwatu, Canggu, Kraton |
| `.urbanFuturist` | Shibuya, MidtownManhattan, VancouverDowntown |
| `.mediterraneanVoyager` | Salamanca, CentroStorico, Westminster |
| `.heritageSeekerl` | KotaTua, Kraton, Braga |
| `.eclecticExplorer` / `.newExplorer` | LeMarais, Shibuya, Canggu |

**`suggestedDestinationCard(city:district:)` design** (210pt wide, variable height):
- Top 3pt colored strip (mood accent color).
- `• CITY_NAME` in accent color with 2pt bullet dot.
- District name in 19pt black.
- Architecture period tag (7pt monospace, 36% white opacity).
- Bottom: mood chip (accent-tinted capsule) + `→` arrow in accent.
- Background: dark surface + `accent.opacity(0.10)` gradient top-left to bottom-right.
- Border: `accent.opacity(0.28)` 1pt stroke.

**Static helpers** on `ProfileView`:
- `moodAccentColor(moodKey:)` — same 15-entry switch as `DistrictRevealOverlay`'s private version.
- `architecturePeriodTag(moodKey:)` — same 15-entry switch as `DistrictRevealOverlay`'s
  `architectureTag` computed property. Both are `private static func` on `ProfileView`.

**Screenshot-verified 2026-07-17** on fresh install (`.newExplorer` personality):
- "DESTINATIONS SUGGÉRÉES" section header visible between "MON PARCOURS" and "DESTINATIONS 3D".
- 3 cards in horizontal scroll: Le Marais (gold/parisianCore), Shibuya (teal/shibuyaNeon),
  Canggu (aqua/beachResort). Each shows city label in accent, district name, architecture tag,
  mood chip.
- Correct hide-when-all-visited behaviour verified on the existing test-user state (tropicalNomad
  with Uluwatu+Canggu+Kraton all visited → section absent, no crash).

## Wave 3+ commercial upgrade (2026-07-17, continued)

### Pinch-triggered facade LOD (2026-07-17)

`DistrictRealityView.Coordinator` now shows `_bands`/`_pilasters`/`_balconies`/`_chimneys`
facade-detail entities when the user pinches in past `districtExtent × 0.22`, without requiring
a building tap. This gives the facade LOD a third trigger (in addition to building-tap and orbit-reset),
making the detail layer feel responsive to natural pinch exploration.

**Implementation** (`DistrictRealityView.swift`):
- `private var facadeDetailEnabled: Bool = false` — tracking flag on `Coordinator`, avoids
  redundant `setFacadeDetailEnabled` calls on every pinch frame when the threshold hasn't crossed.
- `handlePinch` calls `setFacadeDetailEnabled` only when `(currentDistance < districtExtent × 0.22) != facadeDetailEnabled`,
  and only in orbit mode (`inspectedBuildingCentroid == nil`) so it doesn't interfere with building-tap framing.
- `resetToDefaultPosition()` now calls `setFacadeDetailEnabled(false)` + resets `facadeDetailEnabled = false` —
  fixes a bug where facade detail stayed enabled after a double-tap reset to orbit.
- `applyOrbitLOD()` also resets `facadeDetailEnabled = false` to stay in sync.
- `flyToBuildingWithFraming` sets `facadeDetailEnabled = true` alongside `setFacadeDetailEnabled(true)`.

**Threshold**: `districtExtent × 0.22` → ~110m for Paris (500m extent), ~660m for Canggu (3km).
Activates during smooth pinch without requiring a building tap.

**Invariant**: `facadeDetailEnabled` tracks the current state so the guard `if showDetail != facadeDetailEnabled`
only fires on threshold crossing, not on every pinch frame. This is critical for smooth pinch UX —
without the guard, `setFacadeDetailEnabled` would walk the entity tree on every gesture callback.

### PlacesViewModel flagship refresh (2026-07-17)

`PlacesViewModel` rewritten with:
- **Flagship cities** (`paris`, `tokyo`, `newyork`, `losangeles`, `london`, `vancouver`, `sanfrancisco`):
  6h TTL (vs 24h for others), 8 search terms, 4 results/term.
- **Foreground refresh**: `NotificationCenter` observer on `UIApplication.willEnterForegroundNotification`
  force-expires the cache TTL (`removeObject(forKey: ageKey)`) then triggers `refreshLivePlaces`.
  Requires `import UIKit` and `import Combine` (both added).
- **200m deduplication** in `mergeLivePlaces`: rejects live entries within 200m of any existing
  place using flat-earth approximation.
- **Improved `placeType` classification**: shrine/temple/izakaya → `.cultural`; onsen/yoga/spa → `.wellness`;
  enoteca/wine bar → `.nightlife`; batik/factory outlet → `.shopping`.

### TopPlacesStrip in CityCalloutCard (2026-07-17)

`TopPlacesStrip` (private struct in `DiscoverView.swift`) shows up to 3 `isFeatured` places
from the static bundle JSON as scrollable accent-tinted chips in `CityCalloutCard`:
- Loads via `CityPlaces.load(for: city.id).filter(\.isFeatured).prefix(3)` in the existing
  `.task(id: city.id)` of `CityCalloutCard`.
- Each chip: `type.icon` SF Symbol + name + optional `priceRange` in monospace.
- Background: `Color.metacityPrimary.opacity(0.07)` + `0.15` stroke border.
- Appears between `FeaturedActivitiesStrip` and district tiles. Hidden when empty (no isFeatured
  places in the city's JSON).

Screenshot-verified 2026-07-17: Paris callout shows "Tour Eiffel", "Musée du Louvre", "Basilique…"
as scrollable chips with icons and `€€` price range labels.

### HUDBuildingCard / HUDVenueCard dark glassmorphism upgrade (2026-07-17)

Both cards upgraded from `.ultraThinMaterial` (adapts to scene, can go light) to an explicit
dark layered background:
```swift
.background {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.black.opacity(0.80))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.22))
        )
}
```
This ensures the card always reads as dark against any 3D scene content, consistent with
`DistrictRevealOverlay`'s dark glassmorphism treatment.

Additional changes:
- Border gradient: `accentColor.opacity(0.40)` (was `0.32/0.30`) — more visible accent boundary.
- `bottomTrailing` corner bracket added to `HUDVenueCard` (was missing; `HUDBuildingCard` already
  had it). Both brackets now at `opacity(0.60)`, lineWidth 1.5pt — matches topLeading weight.
- Shadow: `radius: 24, y: 8` (was `radius: 20, y: 6`) — slightly larger glow.
- Build-verified 2026-07-17.

## Wave 4 navigation upgrade (2026-07-17)

Three UI features added to `DiscoverView.swift` / `DiscoverViewModel.swift`. All build+screenshot-verified 2026-07-17.

### ViewPreset label rename

`ViewPreset.overview.label` changed from `"QUARTIER"` → `"DISTRICT"` in `DiscoverViewModel.swift`
line ~36. The bottom controls panel (`DistrictControlsPanel`) picks this up automatically. No
other call sites.

### `DiscoverViewModel.resetToWorldMap()`

New method added after `back()`. Animates `state = .worldMap` + returns to `europeCamera`
(`centerCoordinate: 47°N/7°E, distance: 3_000_000`). Called by the globe button in `cityFocused`
and `districtExplore` overlays. Does not call `back()` (which is one-step) — jumps directly to
worldMap from any depth, triggering a single `.easeInOut(duration: 0.5)` transition.

### `EarthGlobeView` + `EarthGlobeButton` (new file)

`MetaCity/Features/Discover/EarthGlobeView.swift` — SceneKit `UIViewRepresentable`:
- `SCNSphere(radius: 1.0)`, `segmentCount: 48`, procedural 512×256 equirectangular texture
  drawn via CoreGraphics: deep ocean base `(0.05,0.16,0.44)` + simplified continent ellipses
  (Americas, Europe, Africa, Middle East, Asia, SE Asia, Japan, Australia) + ice caps with
  feathered gradient.
- `SCNSphere(radius: 1.09)` atmosphere haze (`alpha: 0.11`), `isDoubleSided: true`,
  `.constant` lighting model (not affected by scene lighting).
- Directional "sun" warm-white light + near-black ambient.
- `SCNAction.repeatForever(.rotateBy(x:y:z:duration:))` Y-rotation, 22s per full revolution.
- `UITapGestureRecognizer` → `onTap()` callback → `viewModel.resetToWorldMap()`.
- `backgroundColor = .clear`, `isOpaque = false`, `antialiasingMode = .multisampling4X`,
  `preferredFramesPerSecond = 30`.

`EarthGlobeButton`: SwiftUI wrapper — 48×48pt, `.clipShape(Circle())`, `strokeBorder` 1pt white
0.22, blue shadow `radius: 10`.

**SceneKit.framework** added to `project.yml` target dependencies (`- sdk: SceneKit.framework`)
— it was the first time SceneKit was imported directly in any app source file (previously used only
in tests or via RealityKit indirectly).

**Globe placement**:
- `worldMapOverlay`: top-right, decorative (non-interactive, `opacity(0.55)`) — you're already
  at world map, tapping does nothing.
- `cityFocusedOverlay`: top-right after Spacer, fully interactive → `resetToWorldMap()`.
- `districtExploreOverlay`: same position, same action.

### `DistrictTabBar` (private struct, `DiscoverView.swift`)

Horizontal `ScrollView` of bundled districts for the current city. Placed immediately below the
HUD header in `districtExploreOverlay`, above the search bar.
- Shows `city.districts.filter(\.dataBundled)` — placeholder districts (no OSM data) are excluded.
- Active district: `metacityNeonCyan` monospaced label + 2pt `Capsule` underline. Inactive: white
  0.55 opacity.
- Selecting a district that is already selected is a no-op (guard `district.id != selectedDistrictId`).
- `ScrollViewReader` + `.onChange(of: selectedDistrictId)` auto-scrolls active tab to center.
- Background: `Color.black.opacity(0.62)` + faint cyan tint + bottom hairline `0.07`.
- Height: `38pt`. No top/bottom padding of its own — stacks flush against the header above.

**`districtExploreOverlay(city:district:)` signature**: gained `city: CityEntry` parameter
(was `district: DistrictEntry` only). Call site in `overlayLayer` updated from
`case .districtExplore(_, let district)` → `case .districtExplore(let city, let district)`.

**Screenshot-verified 2026-07-17**: Le Marais district shows "LE MARAIS" (cyan) / "SAINT-GERMAIN" /
"MONTMARTRE" / "LA DÉFENSE" tab bar; globe top-right renders blue+green sphere with atmosphere;
"DISTRICT" label confirmed in bottom controls panel.

## Wave 5 camera + tab bar upgrade (2026-07-17)

### `DistrictTabBar` visited-status dots

Each district tab now shows a 4pt `Circle` dot above the district name:
- **Visited + active**: cyan full opacity (1.0)
- **Visited + inactive**: cyan 0.55 opacity
- **Not visited (any state)**: white 0.18 opacity

Visited state reads `UserDefaults.standard.bool(forKey: "reveal_\(district.id)")` — the same key set by `DistrictRevealContext` on first open. `@State private var visitedIds: Set<String>` is refreshed on `.onAppear` and on `selectedDistrictId` change (i.e., every tab switch), so dots update as the user explores. Tab height increased from 38pt → 46pt.

**Progress dot update timing**: `refreshVisited()` is called on `selectedDistrictId` change. When a user taps a district for the first time, the `reveal_` key is set by `DiscoverViewModel.selectDistrict` before the tab bar's `onChange` fires — so on the next district switch, the dot for the just-visited district fills in correctly.

### Vue SURVOL — fixed elevated overview (was auto-rotating orbit)

**Behavioral change**: `ViewPreset.ciel` (SURVOL) is now a **fixed overhead camera** positioned 4× the normal orbit distance and 3× the normal orbit height. The camera does NOT rotate — it is static. Previous behavior (auto-rotating orbit) is gone.

**Implementation**:
- `DiscoverViewModel.setViewPreset(.ciel)`: changed `isAutoRotating = true` → `isAutoRotating = false`. SURVOL is fixed, not orbiting.
- `DistrictRealityView` gained `var activeViewPreset: ViewPreset = .overview` — passed from `DiscoverView` sceneLayer.
- `Coordinator` gained `private var currentViewPreset: ViewPreset = .overview` — set at the top of `update()` before any token checks.
- `update()` signature gained `activeViewPreset: ViewPreset = .overview` parameter.
- `resetToDefaultPosition()` branches on `currentViewPreset`:
  - `.ciel` (SURVOL): `survolDist = districtDistance × 4.0`, `survolH = height × 3.0`, fly camera there, then `orbitSubscription?.cancel()` to ensure no leftover orbit runs.
  - all others: unchanged — normal distance/height.

**Critical ordering invariant**: `currentViewPreset = activeViewPreset` is set as the first statement in `update()`, before the `resetToken` check. This ensures `resetToDefaultPosition()` always reads the updated preset. Do not reorder these statements.

**Transition SURVOL → DISTRICT**: both `.ciel` and `.overview` now set `isAutoRotating = false`, so switching between them doesn't trigger `restartOrbit` — only `cameraResetToken` fires `resetToDefaultPosition()` with the new `currentViewPreset`.

**Screenshot-verified 2026-07-17**: District tab bar with 4px dots above each Paris district name, cyan active + visited, white unvisited. 3D scene intact. Build succeeded with zero errors.

## Global search upgrade (Wave 6, 2026-07-17)

### `GlobalSearchDropdown` — three-section sectioned search

`GlobalSearchDropdown` (private struct in `DiscoverView.swift`) renders a dark glassmorphism dropdown
below the global search bar in both `worldMapOverlay` and `cityFocusedOverlay`. Four sections:

| Section | Trigger | Source | Max results |
|---|---|---|---|
| **VILLES 3D** | First character | `instantCityResults` — cities with ≥1 dataBundled district | all matches |
| **QUARTIERS** | First character | `globalDistrictResults` — district names across all bundled cities | 5 |
| **LIEUX** | 2+ characters | `globalPlaceResults` — building names + POI names across all districts | 8 |
| **VILLES DU MONDE** | 2+ chars + 180ms debounce | `MKLocalSearchCompleter` — world city suggestions | up to 5 |

**`isGlobalSearchActive` flag**: set `true` both on `.onTapGesture` on the search bar AND in
`.onChange(of: globalSearchQuery)`. The `.onChange` path covers the case where text is pasted via
the system clipboard (right-click → Paste) — the tap fires before the text updates, so without
the `.onChange` the dropdown would not appear on paste. Both paths are needed.

### Navigation on tap — three distinct destinations

Each section type navigates to a different app state:

```
VILLES 3D city tap  → cityFocused(city) → auto-opens first dataBundled district
                       → districtExplore(city, firstDistrict)
                       → setViewPreset(.ciel) → SURVOL fixed overhead camera
                       → isAutoRotating = false (fixed, not orbiting)

QUARTIERS district tap → districtExplore(city, district)
                          → setViewPreset(.overview) → DISTRICT elevated orbit
                          → NOT SURVOL, NOT BÂTIMENT

LIEUX building/POI tap → districtExplore(city, district)
                          → fly to building → setViewPreset(.focus) → BÂTIMENT wide framing
                          → camera stays in elevated orbit, NEVER eye-level
                          → same invariant as building tap in scene: no close zoom
```

**VILLES 3D implementation** (`DiscoverViewModel.selectCityFromSearch`):
1. Sets `state = .cityFocused(city)`.
2. Finds first `dataBundled == true` district in `city.districts`.
3. Calls `selectDistrict(district, city: city)` with `preset: .ciel`.
4. This transitions to `districtExplore` and calls `setViewPreset(.ciel)` which resets camera to
   fixed overhead at 4× orbit distance, 3× orbit height (see Wave 5 SURVOL implementation).

**QUARTIERS implementation** (`DiscoverViewModel.selectDistrictFromSearch`):
1. Sets `state = .districtExplore(city, district)`.
2. Calls `setViewPreset(.overview)` — DISTRICT elevated orbit.

**LIEUX implementation** (`DiscoverViewModel.selectPlaceFromSearch`):
1. Finds the host district for the building/POI (by matching osmID or name in `District.load`).
2. Sets `state = .districtExplore(city, district)`.
3. After `DistrictRealityView.Coordinator` recreates (via `.id(district.id)`), calls
   `flyToBuildingWithFraming(building)` with the matched building.
4. View preset set to `.focus` (BÂTIMENT). Camera stays elevated — the same wide-framing
   invariant as any building tap (no eye-level approach).

**`.id(district.id)` coordinator recreation**: `DistrictRealityView` in `sceneLayer` uses
`.id(selectedDistrict?.id ?? "none")` on the view. Changing the district forces SwiftUI to
destroy and recreate the `Coordinator`, ensuring the `setUp()` path always runs fresh (prevents
stale-coordinator issues where a search navigates to the same district that's already open but
for a different search result — the fly-to fires in the new coordinator's `setUp`, not in
the recycled one).

### `GlobalSearchDropdown` overflow fix

The dropdown is a `ScrollView(.vertical, showsIndicators: false)` wrapping the sections VStack,
with `.frame(maxHeight: 360)` on the scroll view. Without the scroll view, results for long
queries (4–5 LIEUX + 5 VILLES DU MONDE = ~500pt content) extended above the dropdown's top edge
and behind the Dynamic Island, making QUARTIERS rows untappable. With the scroll view, the
dropdown is capped at 360pt and scrollable — all sections remain accessible.

**Do NOT remove the `.frame(maxHeight: 360)`** or wrap it back in a plain `VStack`. The Dynamic
Island spans from y=0 to ~y=54pt on iPhone 17; the search bar is at y≈76pt; the dropdown starts
at y≈96pt. Without the cap, a full result set (QUARTIERS + LIEUX + VILLES DU MONDE) pushes the
content height to ~500pt, and since the dropdown is positioned with `.padding(.top, 4)` below the
search bar, the bottom of the dropdown extends to y≈600pt — all visible. But SwiftUI measures
the dropdown from the top, and if the VStack grows taller than the available space between search
bar and Dynamic Island, the top rows appear *above* the search bar, clipped by the Dynamic Island.
The 360pt cap prevents this.

### Screenshot-verified 2026-07-17

- "marais" query: QUARTIERS section "Le Marais · Paris" fully visible, tappable → DISTRICT preset confirmed
- "paris" query: VILLES 3D section "Paris · France · 4 quartiers 3D" visible, tappable → SURVOL preset confirmed
- LIEUX taps (prior session): CNRS UMR PRODIG, Vieux Marais → BÂTIMENT preset confirmed
- All three bottom-controls labels verified: **SURVOL** (cyan) / DISTRICT / BÂTIMENT for city tap;
  SURVOL / **DISTRICT** (cyan) / BÂTIMENT for district tap; SURVOL / DISTRICT / **BÂTIMENT** (cyan) for building tap

## Wave 7 — 3D window recess geometry (2026-07-17)

### `makeWindowRecessEntities` — geometric window depth

`makeWindowRecessEntities(buildings:isNight:quadrantIndex:)` in `DistrictRealityKit.swift` adds
dark back-plane quads placed `recessDepth` metres behind each window position on the exterior wall
surface. This gives building facades genuine 3D geometric depth instead of texture-only window
simulation.

**Architecture**: One merged `MeshDescriptor` per style per quadrant → one `ModelEntity` named
`"bld_\(style.rawValue)_q\(qi)_recesses"`. Entity named with `_recesses` suffix → gated behind
the existing `facadeDetailEnabled` LOD system (hidden at orbit, enabled on building tap /
pinch zoom past `districtExtent × 0.22`).

**`RecessSpec` per style:**

| Style | colsPerTileU | recessDepth | winWidthFrac | winHeightFrac | groundFloorH |
|---|---|---|---|---|---|
| haussmannien | 5 | 0.18 m | 0.52 | 0.50 | 5.0 m |
| bordelaisClassical | 4 | 0.16 m | 0.50 | 0.48 | 5.0 m |
| madrileño | 5 | 0.14 m | 0.48 | 0.52 | 5.5 m |
| londonBrick | 4 | 0.12 m | 0.46 | 0.46 | 5.0 m |
| romanOchre | 3 | 0.14 m | 0.52 | 0.52 | 5.5 m |
| colonial | 4 | 0.10 m | 0.48 | 0.48 | 4.5 m |
| nycBrick | 4 | 0.12 m | 0.46 | 0.46 | 5.5 m |
| modernConcrete | 6 | 0.08 m | 0.55 | 0.55 | 0 (no skip) |

Styles `balinese`, `javanese`, `religious`, `medieval` have no recesses (no recognizable
rectilinear window grid at rendered scales).

**Geometry per window** (single back quad, not a 3-sided box):
- For each polygon edge A→B: outward normal `(outNx, 0, outNz) = (-dz/len, 0, dx/len)`
- Column spacing: `actualSpacing = edge_length / numCols` where
  `numCols = max(1, Int(edge_length / (tileU / colsPerTileU)))`
- Window center X,Z: `(A + dir * (col+0.5) * actualSpacing) - outN * recessDepth`
- Window center Y: `groundFloorH + (floor + 0.5) * floorInterval`
- `halfW = actualSpacing * winWidthFrac * 0.5`, `halfH = floorInterval * winHeightFrac * 0.5`
- Skip if `cy + halfH >= buildingHeight - 0.3` (clips top floor)
- Back-plane quad winding: `[base, base+3, base+2, base, base+2, base+1]` (outward normal)

**Material**: `UnlitMaterial` — day: `(0.022, 0.022, 0.022)` near-black; night:
`(0.035, 0.025, 0.015)` very dark warm shadow. No PBR: window interiors are unlit caves,
not surfaces receiving the scene's directional light.

**LOD integration** (`DistrictRealityView.swift`, `cacheFacadeDetailEntities`):
`_recesses` added to the suffix check alongside `_bands`, `_pilasters`, `_balconies`, `_chimneys`.
Hidden at startup by `applyOrbitLOD()`. Enabled by:
- `flyToBuildingWithFraming` (building tap)
- `handlePinch` crossing `districtExtent × 0.22` inward
- Disabled again by `resetToDefaultPosition()` (double-tap reset) and `applyOrbitLOD()`.

**Vertex budget (Le Marais haussmannien, per quadrant)**: ~220–250K vertices — gated entities
never rendered at orbit, so GPU cost is zero until the user zooms in. Build cost on first district
open (main actor, same constraint as all RealityKit entity ops).

**Screenshot-verified 2026-07-17**: Le Marais building tap → dark rectangular window openings
clearly visible on cream haussmannien facade at building-tap zoom. Two perpendicular faces of
the same building both show window depth. Floor ledge bands (0.38m), cornices, and balcony
undersides all co-visible at the same zoom level.

**Entity count delta**: +1 `ModelEntity` per style per quadrant (same merge approach as walls,
roof caps, bands, chimneys). Max +8 entities per district (8 eligible styles × 1 per district
at most — quadrant split reduces per-entity mesh size but keeps total entity count bounded).

## Wave 7B — Balcony railings, dormer windows, rooftop equipment (2026-07-17)

Three new `@MainActor private static func make*Entities` functions in `DistrictRealityKit.swift`,
all following the identical pattern as `makeChimneyEntities`. All three are called in the quadrant
loop of `loadDistrictEntity` after `makeWindowRecessEntities`. All three use the `_railings`,
`_dormers`, `_equipment` suffixes → gated by `cacheFacadeDetailEntities` in
`DistrictRealityView.Coordinator` (hidden at orbit, visible at building-tap / pinch past
`districtExtent × 0.22`).

### `makeBalconyRailingEntities` — wrought-iron / steel guard-rails

Adds balcony guard-rail geometry for 5 styles: `haussmannien`, `bordelaisClassical`, `madrileño`,
`romanOchre`, `nycBrick`. One merged `MeshDescriptor` per style × quadrant.

**Geometry per balcony floor level per polygon edge:**
- **Handrail bar — front face**: quad at `[absHandrailBot … absRailTop]` offset outward by
  `profile.balconyDepth`. Normal = `(-dz/len, 0, dx/len)` (same CW outward convention as all
  facade geometry).
- **Handrail bar — top face**: 4cm inset quad at `absRailTop`, upward normal `(0,1,0)`. Visible
  from orbit at 15-30° elevation — makes the handrail read as a solid bar rather than a paper plane.
- **Vertical posts**: one face quad per `spec.postSpacing` metres along the edge, from `absSlabTop`
  to `absHandrailBot`, width `spec.postW`, centered on the balcony outer edge.

**Per-style specs:**

| Style | postW | postSpacing | railH | metallic | clearcoat | Character |
|---|---|---|---|---|---|---|
| haussmannien | 0.028 m | 0.135 m | 0.90 m | 0.74 | 0.32 | Fonte Second Empire, dark grey-black |
| bordelaisClassical | 0.030 m | 0.150 m | 0.88 m | 0.70 | 0.24 | Wrought iron, warm black |
| madrileño | 0.026 m | 0.165 m | 0.92 m | 0.65 | 0.16 | Steel, warm brown-black |
| romanOchre | 0.032 m | 0.200 m | 0.88 m | 0.58 | 0.10 | Iron, dark warm |
| nycBrick | 0.040 m | 0.240 m | 1.00 m | 0.52 | 0.08 | Cast iron / steel, cool grey |

`PhysicallyBasedMaterial` with `clearcoatRoughness: 0.30` for all styles. Railings only emit on
buildings where `profile.balconyDepth > 0` — non-balcony styles (balinese, colonial, etc.) skip
the entity entirely, adding no entities or draw calls for those districts.

**Entity name**: `"bld_\(style.rawValue)_q\(quadrantIndex)_railings"`

### `makeDormerEntities` — lucarne dormer windows

Adds dormer window protrusions on pitched-roof facades. 3 eligible styles: `haussmannien` (zinc),
`bordelaisClassical` (warm Gironde stone), `medieval` (Breton granite).

**Geometry**: front face quad + gable cap triangle pair (via `addRoofFace`). Side faces omitted —
they're hidden by the roof slope from orbit camera and building-tap camera angles. Buildings with
`roofType` set to non-hip authored override are skipped (conical/dome/thatched already have their
authored geometry).

**Placement**: dormers line the **longest polygon edge** of each building at `spec.bayInterval`
spacing. The dormer protrudes outward by `spec.d` from that edge at the eave level
(`h + corniceHeight`).

**Per-style specs:**

| Style | bayInterval | w | bodyH | d | capH | Material |
|---|---|---|---|---|---|---|
| haussmannien | 4.0 m | 0.85 m | 1.30 m | 0.45 m | 0.28 m | Zinc blue-grey (0.38,0.42,0.48) |
| bordelaisClassical | 4.5 m | 0.90 m | 1.20 m | 0.40 m | 0.22 m | Warm Gironde stone (0.70,0.60,0.46) |
| medieval | 5.0 m | 1.00 m | 1.40 m | 0.50 m | 0.35 m | Breton granite (0.38,0.36,0.34) |

Buildings with `h < 8.0m` or `longestEdge < bayInterval` are skipped. `addRoofFace` handles
normal auto-flip for both front and back gable triangles.

**Entity name**: `"bld_\(style.rawValue)_q\(quadrantIndex)_dormers"`

### `makeRooftopEquipmentEntities` — HVAC / antenna boxes

Rooftop equipment on `modernGlass` and `modernConcrete` towers at `h ≥ 18m`. 1–3 AC-unit boxes
per building, placed deterministically in the inner 60% of the building's bounding box using
FNV-1a seeds `"<osmID>_eq_n/x/z/h"`. One merged `ModelEntity` per quadrant (all styles combined).

**Helper `addBoxOnRoof(cx:cz:baseY:w:d:h:)`**: 5-sided box (4 side faces + top face). CW corner
order `[BL(-hw,-hd), FL(-hw,+hd), FR(+hw,+hd), BR(+hw,-hd)]` produces correct outward normals
via `(-dz/len, 0, dx/len)`. Top face winding `[0,2,3, 0,1,2]` produces +Y normal (cross-verified:
T1 `[BL,FR,BR]` → cross Y = +4hw·hd > 0; T2 `[BL,FL,FR]` → same ✓).

Box dimensions: width 1.2–2.0m, depth 0.8–1.2m, height 0.5–1.0m (all seeded from osmID).
Material: cool grey PBR `(0.30,0.32,0.34)`, metallic 0.42, roughness 0.72.

**Entity name**: `"bld_equip_q\(quadrantIndex)_equipment"` (no style prefix — combines both
eligible styles into one entity per quadrant).

### LOD integration — `cacheFacadeDetailEntities` updated

`DistrictRealityView.Coordinator.cacheFacadeDetailEntities` now collects all 8 suffix types:
`_bands`, `_pilasters`, `_balconies`, `_chimneys`, `_recesses`, `_railings`, `_dormers`, `_equipment`.

All 8 are hidden by `applyOrbitLOD()` at startup and re-enabled by:
- `flyToBuildingWithFraming` (building tap → BÂTIMENT mode)
- `handlePinch` crossing `districtExtent × 0.22` inward

All 8 are hidden again by `resetToDefaultPosition()` (double-tap reset) and `applyOrbitLOD()`.

**Draw call budget delta per quadrant**:
- `_railings`: ≤5 entities (one per eligible style)
- `_dormers`: ≤3 entities (one per eligible style)  
- `_equipment`: 1 entity per quadrant
- **Total new**: ≤9 entities per quadrant, ≤36 per district. All gated — zero GPU cost at orbit.

**Screenshot-verified 2026-07-17**: Le Marais orbit intact (cream haussmannien fabric, mansard
rooftops, dark Pompidou glass block, road network, green zones). No visual regression. Facade
detail entities correctly hidden at orbit. Build: zero errors, zero warnings on Wave 7B code.

## Wave 7C — Ultra-photoréaliste normal maps + vue AÉRIEN bird's-eye (2026-07-17)

### AÉRIEN (bird's-eye) camera — replaces the old DISTRICT orbit

`ViewPreset.overview` was renamed and redesigned from an auto-rotating standard orbit to a fixed
bird's-eye view at ~46° elevation. This creates a three-tier camera hierarchy:

| Preset | Label | Icon | Camera |
|---|---|---|---|
| `.ciel` | SURVOL | `airplane` | Fixed overhead, 4× orbit radius, 3× orbit height |
| `.overview` | AÉRIEN | `binoculars` | Fixed bird's-eye ~46°, `districtDistance × 1.4` horizontal, `× 1.4 × 1.05` vertical |
| `.focus` | BÂTIMENT | `scope` | Wide framing on selected building, elevated orbit angle |

**AÉRIEN camera math** (in `DistrictRealityView.Coordinator.resetToDefaultPosition`):
```swift
let birdDist = districtDistance * 1.4
let birdH    = birdDist * 1.05  // atan(1.05) ≈ 46° elevation
```
No auto-rotation — `orbitSubscription` is cancelled. Camera is static. For Le Marais
(`districtDistance ≈ 120m`): position at 168m horizontal, 176m height.

**`resetToDefaultPosition` branching logic:**
- `.ciel` → SURVOL overhead (4× / 3× — see Wave 5)
- `.overview` → AÉRIEN bird's-eye (1.4× / 1.47×, fixed)
- `else` → legacy default position (orbit distance / orbit height)

**Files changed**: `DiscoverViewModel.swift` (label/icon), `DistrictRealityView.swift` (new `.overview` branch).

**Navigation flow**: Terre (globe/world map) → SURVOL (overhead) → AÉRIEN (bird's-eye 45°) → BÂTIMENT (building tap).

**Hard invariants (do not revert):**
- AÉRIEN is NEVER auto-rotating — it is a fixed framing like a painting composition.
- AÉRIEN and SURVOL both set `isAutoRotating = false` on entry.
- BÂTIMENT (building tap / pinch zoom) stays in elevated orbit, never eye-level.

**Screenshot-verified 2026-07-17**: Le Marais loaded at bird's-eye ~46°, cream haussmannien
fabric fully visible, DistrictTabBar intact, bottom controls showing SURVOL / **AÉRIEN** (cyan) / BÂTIMENT.

### Procedural tangent-space normal maps per `BuildingStyle`

`DistrictRealityKit` now generates a 128×128 procedural tangent-space normal map per
`BuildingStyle` for **day-mode surface micro-relief**. Applied at building-tap zoom via
`material.normal = .init(texture: .init(nt))`. Hidden at night (emissive textures override
surface detail).

**Implementation**:
- `@MainActor private static var normalMapCache: [String: TextureResource]` — static cache,
  one entry per style (`style.rawValue` key), same lifecycle as `windowTextureCache`.
- `cachedNormalMapTexture(for: BuildingStyle) -> TextureResource?` — checks cache, generates once.
- `makeNormalMapTexture(for: BuildingStyle) -> TextureResource?` — generates 128×128 CGImage
  via `.hdrColor` semantic (linear encoding, no gamma correction — same as roughness texture).

**Why `.hdrColor` instead of `.normal`**: `TextureResource.Semantic.normal` availability on iOS 17
was uncertain at implementation time; `.hdrColor` correctly encodes linear pixel data that RealityKit
interprets as tangent-space normals via `material.normal`. No semantic difference in the final render.

**Normal map encoding** (tangent-space):
- Flat surface: RGB `(128, 128, 255)` — `+Z` pointing outward from surface.
- `R` = tangent X (horizontal deviation), `G` = tangent Y (vertical deviation, ↓ = toward floor,
  ↑ = toward ceiling), `B` = outward Z strength.
- Joint top lip: `G < 128` (normal tilts downward toward the joint floor).
- Joint bottom lip: `G > 128` (normal tilts upward toward ceiling of lower course).

**Noise function** — `pxHash(x, y)` gives `–16…+15` integer:
```swift
func pxHash(_ x: Int, _ y: Int) -> Int {
    var h = UInt32(x &* 7919 &+ y &* 7793) ^ 2166136261
    h ^= h >> 16; h = h &* 0x45d9f3b; h ^= h >> 16
    return Int(h & 0x1F) - 16
}
```

**Per-style surface character:**

| Style | Pattern | Description |
|---|---|---|
| `haussmannien` | 5 horizontal limestone courses / tile | Lutetian stone coursing, joint lips at top/bottom |
| `bordelaisClassical` | 4 ashlar courses / tile | Gironde calcaire joints, slightly deeper |
| `londonBrick` | 8×8 Flemish bond brick grid | Mortar joints on top/bottom/left + convex face bump |
| `madrileño` | Subtle horizontal render lines | Smooth plaster with shallow coursing at 32px intervals |
| `romanOchre` | Variable-height tuff/brick rows | 4 courses but randomized via osmID-like per-row seed |
| `colonial` | Random noise only | Lime-plaster irregular roughness, no regular coursing |
| `modernConcrete` | 32px formwork boards + bolt holes | Vertical formwork seams + cruciform bolt-hole depressions |
| `modernGlass` | Spandrel panel grid at 32px | Curtain-wall sealant lines, near-flat (almost no relief) |
| `nycBrick` | 21×16 running bond brick | Taller NYC bricks, deeper mortar joints |
| `balinese` | Irregular crack lines at 17px intervals | Volcanic fissure texture, high roughness |
| `laStucco` | Horizontal render coats at 20px | California plaster lifts, shallow |
| `default` | Low-amplitude noise | Generic micro-roughness for all other styles |

**Material pool integration**: `pooledMaterial` supplies `normalTex` only when `!isNight`:
```swift
let normalTex: TextureResource? = isNight ? nil : cachedNormalMapTexture(for: style)
```
The pool cache key is unchanged — normal maps are per-style only (same for all buckets/moods/warmth),
so no key extension required. The same pooled `PhysicallyBasedMaterial` carries the normal map
for all 3 variation buckets of a style.

**Draw call / memory cost**: zero additional entities — normal maps are properties on the existing
pooled materials. Memory: ~10 × 128×128×4 bytes = ~655KB for all 10 normal map textures.

**Screenshot-verified 2026-07-17**: Le Marais AÉRIEN view intact; scene rendered at bird's-eye
angle with cream haussmannien fabric, no visual regression from normal map addition.

## Known Simulator/test gotchas

See `~/.claude/projects/-Users-noeplantier-Orbital/memory/project_ios_simulator_quirks.md` (Claude
session memory) for: disk filling up fast during repeated `xcodebuild test` runs, XCUITest's
`.tap()` not registering on `Toggle`/`Switch` elements on this machine's iOS Simulator build (not
an app bug — confirmed with a bare isolated `@State` Toggle), and screenshot timing races when a
test screenshots immediately after a tap instead of waiting for the expected resulting content.

## Indonesia-first pivot + Phase 1 feature removal (2026-07-17)

**Strategic reposition**: MetaCity was redesigned as an Indonesia-first 3D city tourism app.
Jakarta, Bandung, Yogyakarta, and Bali/Denpasar are the primary experience; Europe/NYC/etc. remain
accessible but are no longer the default entry point.

### Phase 1: Feature removal

Three non-tourism features were **deleted outright** — not hidden:

- **AR tab** (`MetaCity/Features/AR/` — already empty in a prior wave, directory confirmed empty before removal)
- **Calls feature**: `CallLobbyView.swift`, `CallViewModel.swift`, `InCallView.swift` (from `Features/Calls/`)
- **Contacts feature**: `ContactsView.swift`, `ContactsViewModel.swift` (from `Features/Contacts/`)
- **Supporting infrastructure**: `Models/CallRoom.swift`, `Repositories/CallService.swift`,
  `Services/Call/MockCallService.swift`, `Core/UseCases/JoinCallUseCase.swift`

These were tourism-irrelevant features that cluttered the tab bar. If they ever come back, they
come back as a deliberate product decision with a fresh implementation, not a revert from git.

### AppTab: 4 tabs (was 5)

`MetaCity/Core/AppTab.swift`:
```swift
enum AppTab: Hashable {
    case discover, activities, places, profile
}
```

**Tab bar order (screenshot-verified 2026-07-17)**: Discover · Activités · Places · Profile.
- Discover: `globe.asia.australia.fill` icon (Indonesia-first — was `map.fill`)
- Activités: `ticket.fill`
- Places: `map.fill`
- Profile: `person.fill`

### DiscoverViewModel: Indonesia default camera

`DiscoverViewModel.swift` camera constant:
```swift
private static let defaultCamera = MapCamera(
    centerCoordinate: CLLocationCoordinate2D(latitude: -2.5, longitude: 117.5),
    distance: 4_500_000,
    heading: 0,
    pitch: 0
)
```
Shows the full Indonesian archipelago (Sumatra through Papua) at ~4,500km eye altitude.
Previous: `europeCamera` at `47°N/7°E` (Paris/London visible). **Do not restore the European default.**

Cold launch (no `UITEST_*` env vars): opens Jakarta in `cityFocused` state, centering the map on
Jakarta with Jakarta's `mapZoomRadius`. This matches the Indonesia-first product positioning.

### AppEnvironment: callService removed

`AppEnvironment.swift` no longer has `callService: CallService` property or `makeCallViewModel()`.
`HomeTabView` no longer accepts or produces a CallViewModel.

### HomeTabView: 4-tab rewrite

Fully rewritten to 4 tabs. Key behaviors preserved:
- `onChange(of: selectedTab)` syncs `activitiesViewModel.selectCity` and
  `placesViewModel.loadPlaces` when switching to those tabs with a focused city.
- `onChange(of: activitiesViewModel.pendingDistrictId)` handles Activities→Discover navigation
  (user taps "Voir en 3D" in Activities, navigates to district in Discover tab).
- `onChange(of: discoverViewModel.selectedDistrict)` marks district as visited in ProfileViewModel.
- `onAppear` resets to `.discover` tab when `UITEST_OPEN_DISTRICT` / `UITEST_OPEN_CITY` is set.

**Screenshot-verified 2026-07-17**: Jakarta cityFocused sheet (28°C Ciel dégagé weather, 5
district rows, featured activity chips), 4-tab bar confirmed at bottom, EarthGlobeView top-right,
Indonesian map underneath.

## Phase 2 — navigation overhaul + district mini-map (2026-07-18)

### ViewPreset label + icon rename

`ViewPreset` case names are unchanged (`.ciel`, `.overview`, `.focus`) — only user-visible labels
and icons were changed to avoid breaking all call sites:

| Case | Label (new) | Icon (new) | Was |
|---|---|---|---|
| `.ciel` | AÉRIEN | `binoculars.fill` | SURVOL |
| `.overview` | OVERVIEW | `viewfinder` | AÉRIEN |
| `.focus` | ZOOM | `scope` | BÂTIMENT |

**SURVOL (old `.ciel` at 4× / 3× overhead) is permanently removed** as a user-visible mode.
The old 4× / 3× `resetToDefaultPosition` branch for `.ciel` was replaced with the old Wave-7C
AÉRIEN math (1.4× distance, 1.05× height → ~46° elevation). OVERVIEW (`.overview`) is now a
mid-zoom at 0.85× distance, 0.95× height (~43°). BÂTIMENT was renamed ZOOM — behavior unchanged.

**Hard invariant (do NOT revert):** No preset is ever auto-rotating. All three are fixed camera
positions. Building tap/pinch stays in elevated orbit — never eye-level.

### Camera math update (`DistrictRealityView.Coordinator`)

`setUp()` gained `activeViewPreset: ViewPreset = .overview` parameter. The initial camera position
is computed from the preset instead of always using `districtDistance * 1.5 / height * 1.4`:

```swift
districtDistance = district.extent * mood.cameraDistanceFraction * 1.5  // orbit reference (unchanged)

switch currentViewPreset {
case .ciel:     // AÉRIEN
    distance = districtDistance * 1.4
    height   = distance * 1.05          // atan(1.05) ≈ 46°
case .overview: // OVERVIEW
    distance = districtDistance * 0.85
    height   = distance * 0.95          // atan(0.95) ≈ 43.5°
default:
    distance = districtDistance         // ZOOM / default orbit
    height   = district.extent * mood.cameraHeightFraction * 1.4
}
```

`makeUIView` passes `activeViewPreset` to `setUp()` so the cinematic entry (which reads `height`
and `distance` for its `endPos`) lands at the correct preset position on first open.
`resetToDefaultPosition()` branches updated to match the same multipliers.

**Critical**: `districtDistance` stays as `district.extent × mood.cameraDistanceFraction × 1.5`
(the orbit reference). Do NOT reduce it to the bare `cameraDistanceFraction` baseline —
all preset multipliers are calibrated against the 1.5× reference. Reducing it to 1.0× makes
OVERVIEW/AÉRIEN land inside tall buildings (confirmed regression 2026-07-18).

### DistrictTabBar removed

`DistrictTabBar` (the horizontal scroll of district names in `metacityNeonCyan`) was removed
from `districtExploreOverlay`. It was the "en-têtes bleues claires" the user wanted gone.
District switching is now via the global search bar (already present in the overlay).

### `DistrictMiniMapView` — floating satellite mini-map

New `private struct DistrictMiniMapView: View` in `DiscoverView.swift`. Floats bottom-right of
the district explore overlay, hidden when `selectedVenuePOI != nil || selectedBuilding != nil`
(card open → mini-map auto-hides to avoid clutter), shown with `.opacity.combined(with: .scale(0.92))`.

**Spec:**
- 112×112pt, `mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))`
- Camera computed from `district.boundingBox`: `max(latSpan * 111320, lonSpan * 111320 * cos(lat)) * 1.5`, min 700m
- `Annotation` at `district.anchor.clLocationCoordinate`: 24pt glow circle + 8pt dot, color from `moodAccentColor`
- `"◉ MAP"` monospaced label top-left in accent color (6.5pt, tracking 1.5)
- `RoundedRectangle(cornerRadius: 12)` glassmorphism border with `LinearGradient(accent.opacity(0.60 → 0.25))`
- Dual shadow: accent glow `radius: 12, y: 4` + dark drop `radius: 16, y: 6`
- `@State private var camera: MapCameraPosition` initialised in `init(district:)` — `self.district = district` MUST be the first statement before any use of `district` (otherwise Swift init error "return without initialising all stored properties")

**`moodAccentColor`:** 15-entry switch on `district.moodKey` — same palette as
`DistrictRevealOverlay.moodAccentColor` and `ProfileView.moodAccentColor`. These three are
currently independent private switches. If a future refactor consolidates them, use a
`MoodTheme.swift` extension on `String` or a shared `DistrictMoodStyle` struct.

**Screenshot-verified 2026-07-18**: SudirmanThamrin district — sky visible top, glass towers
mid-frame, road network and lower buildings bottom-left, mini-map bottom-right (satellite + cyan
glowing dot over Jakarta district). Controls: AÉRIEN / **OVERVIEW** (cyan) / ZOOM.

## Europe-first refonte (2026-07-18)

Eight changes landed together — all build+screenshot-verified.

### 1. Navbar unifiée — `cityFocusedOverlay`

The unified `HStack(backButton + globalSearchBar + EarthGlobeButton)` navbar previously only
existed in `districtExploreOverlay`. It was added to `cityFocusedOverlay` with the same layout,
`.ultraThinMaterial` background, and `ScanLineView()` bottom overlay. Both overlays now share
identical header chrome. The old separate title label + search bar in `cityFocusedOverlay` is gone.

### 2. `EarthOverviewView` → `EuropeMapOverlayView`

`MetaCity/Features/Discover/EarthOverviewView.swift` (SceneKit 3D globe with 12 city markers)
**deleted outright**. Replaced by `MetaCity/Features/Discover/EuropeMapOverlayView.swift` — a
SwiftUI MapKit `.hybrid` fullscreen overlay centred on Europe (47°N/7°E, 3,200km eye altitude):
- `Map(position: $camera)` with `Annotation` for each city in `visibleCities`
- `EuropeCityDot`: pulsing neon cyan ring + city name label
- Glassmorphism header ("EUROPE 3D · N cities") + bottom instruction footer
- `SceneKit.framework` is no longer needed for the globe — it was already a dependency for
  `EarthGlobeView.swift` (the small 48pt button sphere in the navbar); that file is unchanged.

`EarthGlobeView.swift` (the SceneKit button in the navbar) **is kept** — it is the tap target
that opens the map overlay. Only the full-screen globe (`EarthOverviewView`) was removed.

The `.fullScreenCover` in `DiscoverView.body` now presents `EuropeMapOverlayView`.

### 3. Mode Présentation supprimé

`MetaCity/Features/Discover/PresentationModeView.swift` **deleted outright** — the 5-step B2B
auto-tour overlay is gone. `DiscoverViewModel.showingPresentation` property removed.
The PRÉSENTATION button in `worldMapOverlay` was removed; only `EarthGlobeButton` remains.

### 4. `visibleCities` — Europe+Tokyo+NA filter

`DiscoverViewModel.visibleCities` filters `CityManifest.allCities` to `visibleCityIds`
(renamed from `europeFocusCityIds` in Phase 6 — backward-compat alias retained):
```swift
static let visibleCityIds: Set<String> = [
    "paris", "bordeaux", "london", "madrid", "rome",
    "tokyo", "newyork", "losangeles", "vancouver", "sanfrancisco",
    "jakarta", "bandung", "denpasar", "yogyakarta"
]
static var europeFocusCityIds: Set<String> { visibleCityIds }
var visibleCities: [CityEntry] {
    manifest.allCities.filter { Self.visibleCityIds.contains($0.id) }
}
```
All `ForEach(viewModel.manifest.allCities)` in `DiscoverView` map-layer, city pin display,
and city count labels were changed to `ForEach(viewModel.visibleCities)`.
`EuropeMapOverlayView` receives `visibleCities` (not `allCities`).
Jakarta/Bandung/Bali/Yogyakarta pins are **fully visible** again (re-enabled Phase 6, 2026-07-19).

### 5. Normal maps upgraded 128→256px

`makeNormalMapTexture(for:)` in `DistrictRealityKit.swift` generates 256×256 textures (was 128×128).
Memory: ~10 × 256×256×4 bytes ≈ 2.6MB for all style textures. Build-line:
```swift
let size = 256  // was 128
```

### 6. `ViewPreset` reduced to 2 cases — `.ciel` removed

`ViewPreset` is now a 2-case enum (`.overview`, `.focus`). The `.ciel` case and all its
`resetToDefaultPosition` / `setUp` branches are gone:
```swift
enum ViewPreset: String, CaseIterable {
    case overview  // OVERVIEW — bird's-eye ~61° (dist×0.60, h×0.60×1.10)
    case focus     // ZOOM — wide framing on selected building
}
```
`setViewPreset` no longer has a `.ciel` branch. City-tap from global search now calls
`setViewPreset(.overview)` (was `.ciel`). `navigateToCityFromEarth` likewise uses `.overview`.
`resetToDefaultPosition()` `.ciel` block removed; the `else if` became a plain `if`:
```swift
if currentViewPreset == .overview {
    let overviewDist = districtDistance * 0.60
    let overviewH    = overviewDist * 1.10   // atan(1.10) ≈ 47.7°
    ...
} else {
    // ZOOM / default
}
```

### 7. `DistrictControlsPanel` deleted

The AÉRIEN/OVERVIEW/ZOOM button bar struct was **deleted entirely** from `DiscoverView.swift`.
It called `ViewPreset.allCases` (a `CaseIterable` iteration); its deletion was safe once `.ciel`
was removed from `ViewPreset`. The `districtExploreOverlay` no longer calls `DistrictControlsPanel`.
Camera mode is now implicitly OVERVIEW on district open; ZOOM on building tap/pinch; no user-visible
toggle exists. The bottom of the `districtExploreOverlay` is the tab bar only.

### 8. LRU entity cache + memory pressure handler

**LRU cache** (`DistrictRealityKit.swift`):
- `entityCacheOrder: [String]` — insertion-order list; promoted to MRU on hit.
- `entityCacheLimit: Int = 12` — oldest entry evicted when count exceeds limit.
- On cache hit: `entityCacheOrder.removeAll { $0 == key }; entityCacheOrder.append(key)`.
- On cache write: `entityCacheOrder.append(key); while count > limit { removeFirst; removeValue }`.
- `flushEntityCache()` — `@MainActor static` method, removes all entities + clears order list.

**Memory pressure handler** (`MetaCityApp.swift`):
```swift
.onReceive(NotificationCenter.default.publisher(
    for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
    Task { @MainActor in DistrictRealityKit.flushEntityCache() }
}
```
Required `import UIKit` (for `UIApplication.didReceiveMemoryWarningNotification`) and
`import Combine` (for `NotificationCenter.default.publisher`) added to `MetaCityApp.swift`.
`SwiftUI` transitively imports `Combine` — both imports are now explicit for clarity.

## Phase 5 — POI Highlights système (2026-07-18)

### 19 POI JSON files (pois_*.json)

Five original Bali files (`pois_canggu.json`, `pois_kuta.json`, `pois_seminyak.json`,
`pois_sanur.json`, `pois_uluwatu.json`) plus 14 new files covering priority districts:

| File | District | Featured POIs |
|---|---|---|
| `pois_lemarais.json` | Le Marais | Tour Saint-Jacques, Centre Pompidou, Place des Vosges |
| `pois_saintgermain.json` | Saint-Germain-des-Prés | Église Saint-Sulpice, Café de Flore, Musée d'Orsay |
| `pois_montmartre.json` | Montmartre | Sacré-Cœur, Moulin Rouge, Place du Tertre |
| `pois_ladefense.json` | La Défense | Grande Arche, Tour First, CNIT |
| `pois_cityoflondon.json` | City of London | 30 St Mary Axe, St Paul's Cathedral, Lloyd's of London |
| `pois_westminster.json` | Westminster | Westminster Abbey, Buckingham Palace, Big Ben |
| `pois_shibuya.json` | Shibuya | Scramble Square, Shibuya Crossing, Shibuya109 |
| `pois_midtownmanhattan.json` | Midtown Manhattan | Empire State, Chrysler, Grand Central |
| `pois_lowermanhattan.json` | Lower Manhattan | One WTC, Wall Street, Brooklyn Bridge |
| `pois_downtownla.json` | DowntownLA | Wilshire Grand, Walt Disney Concert Hall, LA City Hall |
| `pois_sfdowntown.json` | SFDowntown | Transamerica Pyramid, Ferry Building, Salesforce Tower |
| `pois_vancouverdowntown.json` | VancouverDowntown | Marine Building, Canada Place, Christ Church Cathedral |
| `pois_salamanca.json` | Salamanca | Puerta de Alcalá, Palacio de Cibeles |
| `pois_centrostorico.json` | CentroStorico | Sant'Ivo alla Sapienza, Piazza della Rotonda, Castel Sant'Angelo |

`CangguPOICollection.load(for: districtId.lowercased())` auto-loads any `pois_<id>.json` —
no Swift wiring needed when adding a new POI file. The loader is cached by lowercase key.

### Cyan neon beacon upgrade (`DistrictRealityKit.makePOIBeaconEntities`)

**Featured POIs** (tier != .standard): `PhysicallyBasedMaterial` with:
- `baseColor: UIColor(red: 0.20, green: 0.85, blue: 1.0, alpha: 1)` — deep cyan
- `emissiveColor: UIColor(red: 0.35, green: 0.95, blue: 1.0, alpha: 1)` — neon cyan
- `emissiveIntensity: 3.0` — strong glow within iOS 17 RealityKit constraints
- `roughness: 0.05`, `metallic: 0.10` — near-mirror for maximum emissive yield
- Floating text label via `MeshResource.generateText`: faces +Z at creation time (`.look(at:from:relativeTo:)`)
- Label name: `"poi_label:<id>"`, sphere name: `"poi:<id>"`
- Label height: `beaconY + radius * 2.8`
- Root container named `"poiBeacons"`

**Standard POIs**: `UnlitMaterial(color: UIColor(white: 0.65, alpha: 0.55))` — semi-transparent grey.

**Beacon Y height**: `districtExtent * 0.008` — 24m for Canggu (3km extent), 4m for Jakarta (500m extent).

**Radius**: featured `districtExtent * 0.006`, standard `districtExtent * 0.003`.

### POI path lines (`makePOIPathLines`)

Flat quad strips between consecutive **featured** POIs at `beaconY + 0.3m`:
- Width: `districtExtent * 0.0018` — 5.4m for Canggu
- `UnlitMaterial` cyan at `alpha: 0.35` — subtle neon circuit trace
- One `MeshDescriptor` per POI pair, named `"poipath_<i>"` in container `"poiPaths"`
- Returns `nil` (skipped) if fewer than 2 featured POIs, or if container ends up childless

Path lines are visible from orbit as faint cyan traces; text labels and full line opacity appear
at building-tap zoom (facade LOD threshold `districtExtent * 0.22`). No separate LOD gating
for POI entities — they remain visible at all zoom levels (design intent: POIs serve as
navigation landmarks from orbit down to street-level).

### Pulse animation (`DistrictRealityView.Coordinator.startPOIPulse`)

`poiPulseSubscription: Cancellable?` + `poiBeaconsEntity: Entity?` cached in `Coordinator`.

After `loadModel` completes, `entity.findEntity(named: "poiBeacons")` is called once to cache
the root; then `startPOIPulse(scene:)` subscribes to `SceneEvents.Update`:
- `frameCount & 1 == 0` guard: 30fps throttle (same pattern as orbit camera)
- `pulse = Float(0.92 + 0.08 * sin(elapsed * .pi * 2.0 * 1.5))` — 1.5 Hz pulse, ±8% scale
- Only featured beacons (filtered once at subscription time, cached in local array) are pulsed
- `poiPulseSubscription` is auto-cancelled when `Coordinator` is deallocated

### ProMotion (60→120 fps) — handled automatically by RealityKit

Neither `CAMetalLayer` nor `CALayer` has a `preferredFrameRateRange` property in the iOS SDK.
`preferredFrameRateRange` exists only on `CADisplayLink` and `CAAnimation`. RealityKit's
internal `CADisplayLink` already targets the device's maximum refresh rate automatically on
ProMotion hardware (iPhone 15 Pro / 17 Pro = 120 Hz) — no manual configuration needed or possible.
Do not attempt to set this via `arView.layer` — it will fail with a compile error.

**Screenshot-verified 2026-07-18**: Canggu district — cyan neon featured beacon (Old Man's vicinity)
clearly visible as a bright glowing sphere, grey standard beacons scattered across the district.
Mini-map bottom-right intact. 4-tab bar correct (Discover·Activités·Places·Profile).

**Build-verified 2026-07-18**: `** BUILD SUCCEEDED **` with zero new errors after all 8 changes.

## Globe suppression + POI building-level zoom + Montmartre dome (2026-07-18)

### Globe / Earth Sphere suppression

`EuropeMapOverlayView` fullscreen cover removed entirely from `DiscoverView.body`. All three
`EarthGlobeButton` call sites (worldMapOverlay, cityFocusedOverlay, districtExploreOverlay) now
call `viewModel.resetToWorldMap()` instead of `viewModel.showEarthOverview()`.

Dead code removed from `DiscoverViewModel.swift`:
- `@Published var showingEarthOverview: Bool = false`
- `func showEarthOverview()`, `func hideEarthOverview()`
- `func navigateToCityFromEarth(_ cityId: String)` (entire block)

`resetToWorldMap()` (kept): `state = .worldMap` + `cameraPosition = .camera(defaultCamera)` with
`.easeInOut(duration: 0.5)`. Globe button tap → world map return only, no MapKit overlay.

### POI fly-to: building-level zoom (replaces overview zoom)

`flyToVenue()` in `DistrictRealityView.Coordinator` now has two paths:
1. **Primary** (new): finds nearest building to POI lat/lon via `nearestBuilding(to:in:maxMeters:120)`
   — squared-distance comparison on polygon centroids, skips buildings ≤4m height — then calls
   `flyToBuildingWithFraming(nearest, scene:)` for building-level wide framing.
2. **Fallback** (old, unchanged): no building within 120m → overview orbit at `districtExtent × 0.20`,
   15° elevation, centred on POI coordinates.

`nearestBuilding(to:in:maxMeters:)` — private helper on `Coordinator`. Iterates all building
polygons, computes mean of polygon vertices as centroid `(cx, cz)`, returns closest within `maxMeters²`.
Uses `cachedDistrict.buildings` (already cached from `loadModel`).

**POI camera invariant (do NOT revert):** All POI taps stay in elevated orbit — never eye-level.
`flyToBuildingWithFraming` uses `sphereR / tan(halfFovRad) × 1.85`, capped at `districtExtent × 0.65`,
elevation 15–20°. Same constraints as building tap in scene.

**Build+screenshot-verified 2026-07-18**: Canggu POI beacons intact, scene loads correctly.

### `Montmartre_authored.json` — Sacré-Cœur dome

New sidecar file `MetaCity/Resources/Montmartre_authored.json` (6 overrides):
- `nameMatch "Sacré-Cœur"` + `nameMatch "Basilique du Sacré-Cœur"` → `style: religious`,
  `roofType: "dome"`, `heightMeters: 83.0` (both name variants for robustness)
- `nameMatch "Saint-Pierre de Montmartre"` → `roofType: "flat"` (Romanesque, lead flat cover)
- `nameMatch "Halle Saint-Pierre"` → `style: government`, `roofType: "flat"` (industrial hall)
- `nameMatch "Moulin Rouge"` → `style: government`, `roofType: "flat"`
- `nameMatch "Moulin de la Galette"` → `style: government`, `roofType: "flat"`

**Screenshot-verified 2026-07-18**: Montmartre loaded — Sacré-Cœur dome clearly dominant
center-right as a large white rounded dome above the haussmannien cream fabric. Mansard rooftops,
wide Haussmann boulevards, correct parisianCore mood. Mini-map shows 18th arrondissement satellite.

`Montmartre` added to authored override table in this file. `xcodegen generate` run to include
the new JSON in the bundle.

## Phase 6 — Tokyo expansion + Indonesian re-integration (2026-07-19)

### Indonesian cities re-enabled

`visibleCityIds` (renamed from `europeFocusCityIds`) expanded from 10 to 14 cities.
Jakarta, Bandung, Yogyakarta, and Bali/Denpasar are fully visible in the Discover tab again.
Backward-compat alias `static var europeFocusCityIds: Set<String> { visibleCityIds }` retained.
Default camera reverted to Indonesia: `-2.5°N / 117.5°E, distance 4,500,000m`. Cold launch opens
Jakarta in `cityFocused` state. `DistrictMiniMapView` gained Indonesian mood accent colors
(`highlandMorning`, `residentialDusk`, `parkDaylight`, `coastalPark`, `colonialSquare`).

Indonesian authored override files created (screenshot-verified 2026-07-19):
- `SudirmanThamrin_authored.json` — 10 overrides: Wisma 46 → modernGlass/262m, Menara BCA 230m,
  Masjid Istiqlal → religious/dome/45m, Katedral Jakarta → religious/dome/61m
- `KotaTua_authored.json` — 10 overrides: Museum Fatahillah → government/flat, Gereja Sion →
  religious/flat, Gereja Katedral → religious/dome, Café Batavia → colonial
- `Menteng_authored.json` — 6 overrides: Tugu Proklamasi → government, Gereja Theresia →
  religious/flat, Masjid Cut Meutia → religious/dome
- `Kemang_authored.json` — 4 overrides: Kemang Village → modernConcrete/flat/36m,
  Masjid Al-Azhar → religious/dome
- `Kraton_authored.json` — 7 overrides: Kraton/Keraton/Sultan → government/flat, Taman Sari →
  government/flat, Masjid Gedhe → religious/dome
- `Braga_authored.json` — 5 overrides: Gedung Merdeka → government/flat/18m,
  Gedung Sate → government/flat/48m

Indonesian POI files created (9 files, loaded automatically by `CangguPOICollection.load`):
`pois_sudirmanthamrin.json`, `pois_kotatua.json`, `pois_menteng.json`, `pois_kemang.json`,
`pois_ancol.json`, `pois_malioboro.json`, `pois_kraton.json`, `pois_dago.json`, `pois_braga.json`

### Tokyo — 3 new districts (total: 4)

36 total districts across 14 cities. Overpass lz4 mirror (`lz4.overpass-api.de`) was used for
all 3 new Tokyo districts due to consistent `overpass-api.de` 504 timeouts.

**District data (all screenshot-verified 2026-07-19):**

| District | Buildings | Roads | Green zones | moodKey | focusBuildingName |
|---|---|---|---|---|---|
| Shinjuku | 3,271 | 2,971 | 68 | shibuyaNeon | Nomura Building (新宿野村ビル, 220m) |
| Ginza | 2,008 | 1,915 | 27 | shibuyaNeon | GINZA SIX (56m) |
| Asakusa | 3,928 | 1,009 | 20 | sacredSite | Senso-ji Temple (浅草寺, dome override) |

All three added to `heavyDistricts` in `MetaCityApp.swift` (on-demand load, not startup prefetch).

**Fetch commands used (from cache):**
```
python3 fetch_district_data.py \
  --name Shinjuku --bbox 35.686 139.695 35.700 139.708 \
  --anchor 35.6938 139.7036 --default-style modernConcrete \
  --out ../MetaCity/Resources/Districts/Shinjuku.json \
  --cache /tmp/shinjuku_raw.json

python3 fetch_district_data.py \
  --name Ginza --bbox 35.666 139.762 35.675 139.773 \
  --anchor 35.6718 139.7681 --default-style modernConcrete \
  --out ../MetaCity/Resources/Districts/Ginza.json \
  --cache /tmp/ginza_raw.json

python3 fetch_district_data.py \
  --name Asakusa --bbox 35.711 139.793 35.720 139.803 \
  --anchor 35.7148 139.7967 --default-style colonial \
  --out ../MetaCity/Resources/Districts/Asakusa.json \
  --cache /tmp/asakusa_raw.json
```

**Style rationale:**
- Shinjuku + Ginza: `modernConcrete` default → tall towers auto-promote to `modernGlass` via
  height rules (modernConcrete NOT in HEIGHT_PROMOTION_BYPASS). Correct for dense commercial Tokyo.
- Asakusa: `colonial` default → correct for traditional machiya merchant-house district. The
  `colonial` style is NOT in HEIGHT_PROMOTION_BYPASS, so any tall buildings still auto-promote.

**Senso-ji (浅草寺) OSM data quality**: The temple is not tagged as `building=*` within the bbox
in OSM — it doesn't appear in the district JSON as a building polygon. Handled via authored
override `nameMatch: "浅草寺"` + `"Senso-ji"` → `style: religious, roofType: dome`. The dome
is visible at the temple compound location in the 3D render.

**Authored overrides:**

| File | District | Key overrides |
|---|---|---|
| `Shinjuku_authored.json` | Shinjuku | 11 overrides: 新宿野村ビル→modernGlass/220m, モード学園コクーンタワー→modernGlass/200m, 東急歌舞伎町タワー→modernGlass/192m, 新宿センタービル→modernGlass/216m, 損保ジャパン→modernGlass/172m, Shinjuku Station→government, 花園神社→religious |
| `Ginza_authored.json` | Ginza | 9 overrides: GINZA SIX→modernGlass/56m, 銀座松竹スクエア→modernGlass/92m, 歌舞伎座→government/flat/45m, 国立がん研究センター→government/56m, 銀座駅/東銀座駅→government, ミキモト→modernGlass |
| `Asakusa_authored.json` | Asakusa | 8 overrides: 浅草寺→religious/dome, Senso-ji→religious/dome, 浅草神社→religious/flat, 東京楽天地浅草ビル→modernGlass/52m, 都立産業貿易センター台東館→government, 浅草文化観光センター→government |

**POI files:**

| File | District | Featured POIs |
|---|---|---|
| `pois_shinjuku.json` | Shinjuku | Shinjuku Gyoen, Cocoon Tower, Tokyu Kabukicho Tower |
| `pois_ginza.json` | Ginza | GINZA SIX, Kabuki-za Theatre, Ginza Chuo-dori |
| `pois_asakusa.json` | Asakusa | Senso-ji Temple, Kaminarimon Gate, Nakamise Shopping Street |

**Visual identity (screenshot-verified 2026-07-19):**
- **Shinjuku**: dark glass towers (新宿野村ビル group) dominating upper-left. Shinjuku Gyoen green
  park patch clearly visible. Very dense road network (2,971 — most in any Tokyo district). Near-black
  shibuyaNeon asphalt clearly differentiates roads.
- **Ginza**: Chuo-dori main boulevard visible as wide dark slash. Dense mid-rise modernConcrete grid
  with scattered modernGlass towers. 1,915-road network dense and distinct.
- **Asakusa**: sacredSite mood — dark volcanic andesite ground with warm amber morning-mist fill.
  Colonial buildings in warm golden-orange. Dome from religious/dome Senso-ji override visible at
  temple compound. Irregular temple-compound road network unmistakably Asakusa.

**`DistrictRenderProfile` presets (to add):**

| District | nightWindowDensityBoost | facadeDepthScale | weatheringIntensity |
|---|---|---|---|
| Shinjuku | 1.40 | 1.0 | 0.08 |
| Ginza | 1.30 | 1.0 | 0.05 |
| Asakusa | 1.10 | 1.0 | 0.35 |

### KNOWN_HEIGHTS additions for Tokyo (in `tools/fetch_district_data.py`)

**Shinjuku:**
```python
"新宿野村ビル": 220, "Shinjuku Nomura Building": 220,
"新宿センタービル": 216, "Shinjuku Center Building": 216,
"モード学園コクーンタワー": 200, "Mode Gakuen Cocoon Tower": 200, "Cocoon Tower": 200,
"東急歌舞伎町タワー": 192, "Tokyu Kabukicho Tower": 192,
"損保ジャパン本社ビル": 172, "Sompo Japan Nipponkoa Headquarters": 172,
```

**Ginza:**
```python
"銀座松竹スクエア": 92, "歌舞伎座": 45, "Kabuki-za": 45, "Kabukiza": 45,
"国立がん研究センター": 56, "GINZA SIX": 56,
```

**Asakusa (limited tall buildings):**
```python
"東京楽天地浅草ビル": 52,
```

### iOS scene-state restoration workaround

When switching districts in rapid `simctl launch` test sessions, iOS scene-state preservation
can show the previously-active district. Fix: `xcrun simctl terminate <simulator-id> com.metacity.app`
before each relaunch. This is the standard workaround documented earlier in CLAUDE.md.
