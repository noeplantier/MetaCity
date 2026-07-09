import FirebaseCore
import GoogleSignIn
import SwiftUI

@main
struct MetaCityApp: App {
    @StateObject private var session: SessionStore
    private let environment: AppEnvironment

    init() {
        // Guarded rather than unconditional: `FirebaseApp.configure()` crashes hard if
        // GoogleService-Info.plist isn't in the bundle, and that file is gitignored (see
        // .gitignore) since this repo is public. Anyone without it still gets a fully working
        // app on the in-memory mocks — see `AppEnvironment.defaultAuthRepository()`.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            // GoogleSignIn reuses the OAuth client ID Firebase already has from the plist, so
            // there's nothing Google-specific to configure by hand here.
            if let clientID = FirebaseApp.app()?.options.clientID {
                GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            }
        }
        let environment = AppEnvironment()
        self.environment = environment
        let session = SessionStore(authRepository: environment.authRepository)
        // Debug-only escape hatch from real Firebase Sign Up/Log In during UI testing — XCUITest
        // automation of the Sign Up screen's `.newPassword` SecureField has repeatedly proven
        // unreliable on this machine's Simulator (see project memory on Simulator quirks); this
        // sidesteps it entirely rather than fighting it again. Inert unless explicitly launched
        // with `-UITEST_SKIP_AUTH 1`, which nothing in the shipped app or its schemes does.
        if ProcessInfo.processInfo.environment["UITEST_SKIP_AUTH"] == "1" {
            session.handleSignedIn(User(id: "uitest-debug-user", email: "uitest@metacity.app", displayName: "UI Test"))
        }
        _session = StateObject(wrappedValue: session)
    }

    var body: some Scene {
        WindowGroup {
            // Passed explicitly rather than via `.environmentObject` so every screen's dependencies
            // are visible in its initializer — no hidden environment lookups to trace through.
            RootView(environment: environment, session: session)
                .task(priority: .background) {
                    // Pre-warm entity cache at startup (day mode only — night is cached on
                    // first toggle). Skips the four largest districts by building count:
                    // Malioboro (2,746 buildings), Kraton (2,922), Seminyak (1,939), Canggu
                    // (9,402 after bbox expansion 2026-07-06) — each produces 50–100K vertex
                    // buffer allocations on the main
                    // actor, causing multi-frame hitches during launch. Those load
                    // on-demand on first user visit. The remaining districts (Jakarta ×5,
                    // Bandung ×2, Kuta, Sanur) are small enough to prefetch without perceptible cost.
                    let heavyDistricts: Set<String> = ["Malioboro", "Kraton", "Seminyak", "Canggu", "Uluwatu"]
                    for district in CityManifest.shared.allDistricts
                        where district.dataBundled && !heavyDistricts.contains(district.id) {
                        _ = try? await DistrictRealityKit.loadDistrictEntity(
                            named: district.id, isNight: false, mood: district.mood)
                    }
                }
                .onOpenURL { url in
                    // Google's sign-in sheet redirects back into the app via this URL scheme
                    // (registered in project.yml from the plist's REVERSED_CLIENT_ID).
                    GIDSignIn.sharedInstance.handle(url)
                }
                // MetaCity's brand is the anthracite-on-white look, full stop — not "dark mode",
                // so it's forced regardless of the system appearance setting.
                .preferredColorScheme(.dark)
        }
    }
}
