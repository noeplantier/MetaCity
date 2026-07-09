import SwiftUI

struct HomeTabView: View {
    @StateObject private var discoverViewModel: DiscoverViewModel
    @StateObject private var placesViewModel: PlacesViewModel
    @StateObject private var activitiesViewModel: ActivitiesViewModel
    @StateObject private var contactsViewModel: ContactsViewModel
    @StateObject private var profileViewModel: ProfileViewModel
    @State private var selectedTab: AppTab = .discover

    init(environment: AppEnvironment, session: SessionStore) {
        _discoverViewModel = StateObject(wrappedValue: environment.makeDiscoverViewModel())
        _placesViewModel   = StateObject(wrappedValue: PlacesViewModel())
        _activitiesViewModel = StateObject(wrappedValue: ActivitiesViewModel())
        _contactsViewModel = StateObject(wrappedValue: ContactsViewModel())
        _profileViewModel  = StateObject(wrappedValue: environment.makeProfileViewModel(session: session))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView(viewModel: discoverViewModel)
                .tabItem { Label("Discover", systemImage: "globe.asia.australia.fill") }
                .tag(AppTab.discover)

            PlacesView(
                viewModel: placesViewModel,
                discoverViewModel: discoverViewModel,
                selectedTab: $selectedTab
            )
            .tabItem { Label("Places", systemImage: "map.fill") }
            .tag(AppTab.places)

            ActivitiesView(viewModel: activitiesViewModel)
                .tabItem { Label("Activités", systemImage: "ticket.fill") }
                .tag(AppTab.activities)

            ContactsView(viewModel: contactsViewModel)
                .tabItem { Label("Contacts", systemImage: "person.2.fill") }
                .tag(AppTab.contacts)

            ProfileView(viewModel: profileViewModel)
                .tabItem { Label("Profile", systemImage: "person.fill") }
                .tag(AppTab.profile)
        }
        .tint(Color.metacityPrimary)
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .activities, let city = discoverViewModel.focusedCity {
                activitiesViewModel.selectCity(city)
            }
            if newTab == .places, let city = discoverViewModel.focusedCity {
                placesViewModel.loadPlaces(for: city)
            }
            if newTab == .contacts, let city = discoverViewModel.focusedCity {
                contactsViewModel.selectCity(city.id)
            }
        }
        .onChange(of: discoverViewModel.selectedDistrict) { _, newDistrict in
            if let id = newDistrict?.id {
                profileViewModel.markVisited(id)
            }
        }
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if env["UITEST_OPEN_DISTRICT"] != nil || env["UITEST_OPEN_CITY"] != nil {
                selectedTab = .discover
            }
        }
    }
}

#Preview {
    HomeTabView(environment: AppEnvironment(), session: SessionStore(authRepository: MockAuthRepository()))
}
