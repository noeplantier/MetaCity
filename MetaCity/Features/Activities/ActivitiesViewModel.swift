import Foundation

@MainActor
final class ActivitiesViewModel: ObservableObject {
    // Available cities come from the manifest — only those with activity data are shown.
    let availableCities: [CityEntry]

    @Published var selectedCity: CityEntry
    @Published var selectedCategory: ActivityCategory?
    @Published var searchText: String = ""

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
        // Premium activities surface first within each category grouping.
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

    init(preselectedCity: CityEntry? = nil) {
        let manifest = CityManifest.shared
        let activityCityIDs: Set<String> = ["jakarta", "bandung", "denpasar", "yogyakarta", "canggu"]
        availableCities = manifest.allCities.filter { activityCityIDs.contains($0.id) }
        let fallback = availableCities.first ?? manifest.allCities[0]
        // If the caller passes a city that has activity data, jump straight to it —
        // used by HomeTabView to pre-select whichever city the user was viewing in Discover.
        let start: CityEntry
        if let city = preselectedCity, availableCities.contains(where: { $0.id == city.id }) {
            start = city
        } else {
            start = fallback
        }
        selectedCity = start
        loadActivities(for: start)
    }

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

    private func loadActivities(for city: CityEntry) {
        // City-level file first (e.g. activities_denpasar.json for Bali)
        var combined = CityActivities.load(for: city.id)
        // Then append district-level overrides (e.g. activities_canggu.json, activities_kuta.json).
        // District IDs in the manifest are PascalCase ("Canggu"); the file lookup lowercases them
        // to match the filename convention ("activities_canggu.json").
        for district in city.districts {
            let districtActivities = CityActivities.load(for: district.id.lowercased())
            // Avoid duplicates: only add if no existing activity shares the same id.
            let existingIds = Set(combined.map(\.id))
            combined += districtActivities.filter { !existingIds.contains($0.id) }
        }
        allActivities = combined
    }
}
