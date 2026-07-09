import SwiftUI

/// Top-level auth gate: shows `AuthView` when signed out, `HomeTabView` once a session exists.
/// Because both branches are driven by `SessionStore`, no individual feature screen needs its own auth check.
///
/// `AuthViewModel` is owned here via `@StateObject`, created once in `init`. Building it inline as
/// `AuthView(viewModel: environment.makeAuthViewModel(session: session))` — passed to an
/// `@ObservedObject` — looks equivalent but isn't: `RootView.body` re-runs on *any* observed change,
/// and each run would call the factory again and hand `AuthView` a brand new `AuthViewModel`,
/// silently wiping whatever the user had typed. `@StateObject` is what makes "created once, reused
/// across re-renders" the actual behavior instead of an assumption.
struct RootView: View {
    @ObservedObject private var session: SessionStore
    @StateObject private var authViewModel: AuthViewModel
    let environment: AppEnvironment

    init(environment: AppEnvironment, session: SessionStore) {
        self.environment = environment
        self.session = session
        _authViewModel = StateObject(wrappedValue: environment.makeAuthViewModel(session: session))
    }

    var body: some View {
        Group {
            if session.currentUser != nil {
                HomeTabView(environment: environment, session: session)
            } else {
                AuthView(viewModel: authViewModel)
            }
        }
        .task {
            await session.restoreExistingSession()
        }
        .animation(Motion.standard, value: session.currentUser)
    }
}
