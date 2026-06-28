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
        _session = StateObject(wrappedValue: SessionStore(authRepository: environment.authRepository))
    }

    var body: some Scene {
        WindowGroup {
            // Passed explicitly rather than via `.environmentObject` so every screen's dependencies
            // are visible in its initializer — no hidden environment lookups to trace through.
            RootView(environment: environment, session: session)
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
