# MetaCity

iOS SwiftUI app (Xcode project generated from `project.yml` via XcodeGen — never hand-edit
`MetaCity.xcodeproj`, run `xcodegen generate` after any `project.yml` change). Clean-ish
architecture: `Repositories/` protocols, `Services/` implementations (mock + real, chosen
automatically based on whether `GoogleService-Info.plist` is present), `@MainActor` ViewModels,
DI via the plain `AppEnvironment` container — no DI framework.

## Scope: multi-city Indonesia, 14 districts with real data

As of 2026-07-08, MetaCity covers **4 cities with real OSM-derived 3D district data** — Jakarta (5
districts), Bandung (2), Yogyakarta (2), and Bali/Denpasar (5) — plus 6 placeholder cities with
no district data yet (Surabaya, Semarang, Medan, Palembang, Makassar, Balikpapan). All 14 data
districts live in `MetaCity/Resources/Districts/<id>.json`. `CityManifest.json` (decoded into
`CityManifest.shared`) is the single source of truth for what's live; it drives the world map,
district picker, and 3D inspector routing.

The old per-city *artistic* skyline system (`RealBuilding.swift`, `CityScene3DView.swift`,
hand-placed boxes at a compressed scale) was **deleted outright** — not hidden, not deprecated —
per an explicit instruction to focus exclusively on real OSM-derived content. If a future request
reintroduces a pre-OSM artistic tier, that's a deliberate regression; don't resurrect those files
from git history without a fresh reason.

**Districts currently bundled (14 total):**
- Jakarta: `SudirmanThamrin`, `KotaTua`, `Kemang`, `Menteng`, `Ancol`
- Bandung: `Dago`, `Braga`
- Yogyakarta: `Malioboro`, `Kraton`
- Bali/Denpasar: `Seminyak`, `Kuta`, `Canggu`, `Sanur`, `Uluwatu`

`MockMapRepository` serves the 5 Jakarta landmarks (the Map tab still shows only Jakarta pins);
the Discover tab uses `CityManifest.allCities` which includes all 10 city pins from the world map.
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

## Known Simulator/test gotchas

See `~/.claude/projects/-Users-noeplantier-Orbital/memory/project_ios_simulator_quirks.md` (Claude
session memory) for: disk filling up fast during repeated `xcodebuild test` runs, XCUITest's
`.tap()` not registering on `Toggle`/`Switch` elements on this machine's iOS Simulator build (not
an app bug — confirmed with a bare isolated `@State` Toggle), and screenshot timing races when a
test screenshots immediately after a tap instead of waiting for the expected resulting content.
