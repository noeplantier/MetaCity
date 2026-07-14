import Foundation

@MainActor
final class ActivitiesViewModel: ObservableObject {

    // MARK: - City selection

    /// The 5 vitrine showcase cities — always shown as chips regardless of the focused Discover city.
    static let vitrineCityIDs: [String] = ["paris", "tokyo", "vancouver", "jakarta", "denpasar"]

    let availableCities: [CityEntry]

    @Published var selectedCity: CityEntry
    @Published var selectedCategory: ActivityCategory?
    @Published var searchText: String = ""

    /// Set by `requestNavigation(to:)` when the user taps "Voir en 3D".
    /// `HomeTabView` observes this and routes to the Discover tab with the right district.
    /// Cleared by `clearPendingNavigation()` after the route is executed.
    @Published private(set) var pendingDistrictId: String? = nil

    private var allActivities: [ActivityEntry] = []

    var filteredActivities: [ActivityEntry] {
        var result = allActivities
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            result = result.filter {
                $0.name.lowercased().contains(q)
                    || $0.description.lowercased().contains(q)
                    || $0.area.lowercased().contains(q)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.tier == .premium, rhs.tier != .premium { return true }
            if lhs.tier != .premium, rhs.tier == .premium { return false }
            return lhs.name < rhs.name
        }
    }

    /// All categories that have at least one activity in the current city.
    var presentCategories: [ActivityCategory] {
        let used = Set(allActivities.map(\.category))
        return ActivityCategory.allCases.filter { used.contains($0) }
    }

    // MARK: - Init

    init(preselectedCity: CityEntry? = nil) {
        let manifest = CityManifest.shared
        let vitrineIDs = Set(Self.vitrineCityIDs)
        // Preserve ordering: vitrine cities first, then any other cities with activity data.
        let vitrine = Self.vitrineCityIDs.compactMap { manifest.city(id: $0) }
        let others = manifest.allCities.filter {
            !vitrineIDs.contains($0.id)
            && ["bandung", "yogyakarta"].contains($0.id)
        }
        availableCities = vitrine + others

        let fallback = availableCities.first ?? manifest.allCities[0]
        if let city = preselectedCity, availableCities.contains(where: { $0.id == city.id }) {
            selectedCity = city
        } else {
            selectedCity = fallback
        }
        loadActivities(for: selectedCity)
    }

    // MARK: - Selection

    func selectCity(_ city: CityEntry) {
        guard city.id != selectedCity.id else { return }
        selectedCity = city
        selectedCategory = nil
        searchText = ""
        loadActivities(for: city)
    }

    func selectCategory(_ category: ActivityCategory?) {
        selectedCategory = (selectedCategory == category) ? nil : category
    }

    // MARK: - 3D Navigation

    /// Called when user taps "Voir en 3D" on an activity card.
    func requestNavigation(to districtId: String) {
        pendingDistrictId = districtId
    }

    /// Called by `HomeTabView` after it has acted on `pendingDistrictId`.
    func clearPendingNavigation() {
        pendingDistrictId = nil
    }

    // MARK: - Data loading

    private func loadActivities(for city: CityEntry) {
        var combined = CityActivities.load(for: city.id)
        for district in city.districts {
            let districtActivities = CityActivities.load(for: district.id.lowercased())
            let existingIds = Set(combined.map(\.id))
            combined += districtActivities.filter { !existingIds.contains($0.id) }
        }
        allActivities = combined
    }
}
