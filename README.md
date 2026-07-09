# MetaCity

A digital-twin app for 5 real Jakarta districts: SwiftUI + Clean Architecture (Core / Models / Repositories / Services / Features / DesignSystem), with working Auth (email/password + a mocked "Continue with Google"), real OpenStreetMap-derived 3D districts, a real ARKit module, audio/video calling, and an Explore tab — running on in-memory mocks where there's no backend yet. No API keys required to build and run today.

## Run it

```bash
xcodegen generate   # regenerates MetaCity.xcodeproj from project.yml — skip if you just cloned, it's already committed
open MetaCity.xcodeproj
```

In Xcode: pick an iOS 17+ simulator → `Cmd R`.

**Login:** `demo@metacity.app` / `password123`, or tap **Continue with Google** (signs in as a mocked identity — no real OAuth wired up yet, see Roadmap). Nothing is persisted; it all resets on relaunch.

## Requirements

- Xcode 15+ (full app, not just Command Line Tools — see Troubleshooting)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only if you change `project.yml` or add/remove files: `brew install xcodegen`
- A physical iPhone for *real-world tracking* AR (ARKit needs a camera) — the Simulator still gives you a full, real-content 3D experience of all 5 districts, just not real-world tracked (see below)

## What you get

| Tab | What it shows |
|---|---|
| **Explore** | Greeting, search-filtered list of the 5 Jakarta districts, tap one to open a real 3D preview |
| **Map** | The 5 district landmarks on a real Jakarta map, a route polyline, a 2D/3D camera toggle, tap a pin to recenter + jump to AR |
| **AR** | Pick any of the 5 districts; the camera starts focused on that district's real, named landmark building. On a physical device, tap a detected surface to place a true-to-scale miniature of the district (real ARKit world tracking). On the Simulator (no camera), explore the same district full-scale from a pedestrian's eye level instead |
| **Calls** | A lobby with a bot contact (audio/video, auto-answers) plus mock rooms; in-call screen has mute, speaker, camera, flip-camera, a live call timer, and full incoming/outgoing ringing states |
| **Profile** | Signed-in user, logout, real content stats (district/building/road counts), and a list of "coming soon" extension points |

Everything backend-shaped runs against mocks — [MockAuthRepository](MetaCity/Services/Auth/MockAuthRepository.swift), [MockMapRepository](MetaCity/Services/Map/MockMapRepository.swift), [MockCallService](MetaCity/Services/Call/MockCallService.swift) — behind protocols in [Repositories/](MetaCity/Repositories), so swapping in a real backend never touches a View or ViewModel. The UI follows a dynamic anthracite-dark / neutral-light design system that adapts to the system appearance.

## Project structure

```
MetaCity/
├── Core/            DI container, session state, @main entry point, use cases, error types
├── Models/          plain entities — zero framework imports
├── Repositories/    protocols only (the contracts: AuthRepository, MapRepository, CallService, ...)
├── Services/        concrete implementations of those protocols (mocks today, real backends later)
├── DesignSystem/     colors, typography, spacing, reusable components
└── Features/         Explore/ Map/ AR/ Calls/ Profile/ Auth/ Home/ — one folder per screen
```

## Tests

`Cmd U` in Xcode, or:

```bash
xcodebuild test -project MetaCity.xcodeproj -scheme MetaCity \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

(swap the simulator name for one you actually have: `xcrun simctl list devices available`)

## Roadmap (what's real vs. mocked vs. blocked)

This is being built in phases rather than all at once, since some of it genuinely needs infrastructure only you can provide:

1. **Foundation** (done) — rebrand, Core/Models/Repositories/Services/Features structure, 5-tab shell, Explore v1, real ARKit scaffold, Sign in with Apple-ready Auth.
2. **Explore + real-time presence** — nearby users, trending locations, glassmorphism visual pass.
3. **3D depth** — swap the placeholder cube for real USDZ landmark assets.
4. **Calls upgrade** — network quality indicator, messaging.
5. **Real backend** — your existing Firebase project (needs your `GoogleService-Info.plist` and exact bundle ID dropped in) plus a managed calling provider (Agora/Twilio/Stream — needs an API key).

One thing is worth knowing going in: **real-world ARKit tracking cannot be verified in the Simulator** (no camera) — the tabletop placement code is real (same district data/geometry as the rest of the app, anchored via `ARSCNView` raycasting) and will run on a physical device, but tracking quality itself needs hands-on testing there.

## Troubleshooting

- **Build fails immediately / "No such module 'MapKit'"** — you're on Command Line Tools, not full Xcode: `sudo xcode-select -s /Applications/Xcode.app`.
- **Xcode shows red/missing files** — the file tree and `.xcodeproj` are out of sync; run `xcodegen generate` again.
- **Map centers on the ocean / no pins nearby** — the simulator has no real GPS. Simulator menu → Features → Location → Custom Location (or pick a city).
- **AR tab places nothing when tapped on the Simulator** — expected; tap-to-place a district miniature only works on a physical device (no camera/world tracking in the Simulator). The Simulator shows the same district full-scale instead, no tap needed.
- **No camera/mic permission prompt in calls** — expected; the simulator has no real camera/mic, so video/audio in [InCallView](MetaCity/Features/Calls/InCallView.swift) are placeholders by design, not a bug.
