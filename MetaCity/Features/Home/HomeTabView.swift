import SwiftUI

/// Single place where every feature tab is assembled and wired to its dependencies — adding a new
/// tab means adding one `@StateObject` here and one `make...ViewModel()` in `AppEnvironment`.
///
/// Every ViewModel is created once via `@StateObject` in `init`, not inline as `@ObservedObject`
/// arguments — see the note in `RootView` for why that distinction matters (it's what keeps the map
/// camera, the in-call state, etc. from resetting whenever this view's body re-evaluates).
struct HomeTabView: View {
    @ObservedObject private var session: SessionStore
    @ObservedObject private var selectionStore: AppSelectionStore
    @StateObject private var exploreViewModel: ExploreViewModel
    @StateObject private var mapViewModel: MapViewModel
    @StateObject private var arViewModel: ARViewModel
    @StateObject private var callViewModel: CallViewModel
    @StateObject private var profileViewModel: ProfileViewModel
    @State private var selectedTab: AppTab = .explore

    init(environment: AppEnvironment, session: SessionStore) {
        self.session = session
        self.selectionStore = environment.selectionStore
        _exploreViewModel = StateObject(wrappedValue: environment.makeExploreViewModel(session: session))
        _mapViewModel = StateObject(wrappedValue: environment.makeMapViewModel())
        _arViewModel = StateObject(wrappedValue: environment.makeARViewModel())
        _callViewModel = StateObject(wrappedValue: environment.makeCallViewModel())
        _profileViewModel = StateObject(wrappedValue: environment.makeProfileViewModel(session: session))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ExploreScreenView(viewModel: exploreViewModel)
                .tabItem { Label("Explore", systemImage: "safari.fill") }
                .tag(AppTab.explore)

            MapScreenView(viewModel: mapViewModel)
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(AppTab.map)

            ARScreenView(viewModel: arViewModel)
                .tabItem { Label("AR", systemImage: "arkit") }
                .tag(AppTab.ar)

            CallLobbyView(viewModel: callViewModel)
                .tabItem { Label("Calls", systemImage: "phone.fill") }
                .tag(AppTab.calls)

            ProfileView(viewModel: profileViewModel)
                .tabItem { Label("Profile", systemImage: "person.fill") }
                .tag(AppTab.profile)
        }
        .tint(Color.metacityPrimary)
        // One-shot signal: Map's "View in AR" (or any future entry point) sets `requestedTab` on
        // the shared store; consuming it here and resetting to nil stops it from re-firing on an
        // unrelated re-render, and keeps Map/AR from needing to know about each other or about
        // this tab view directly.
        .onChange(of: selectionStore.requestedTab) { _, requestedTab in
            guard let requestedTab else { return }
            selectedTab = requestedTab
            selectionStore.requestedTab = nil
        }
    }
}

#Preview {
    let environment = AppEnvironment()
    HomeTabView(environment: environment, session: SessionStore(authRepository: MockAuthRepository()))
}
