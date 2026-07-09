import Foundation

@MainActor
final class PlacesViewModel: ObservableObject {
    @Published private(set) var places: [PlaceEntry] = []
    @Published var selectedType: PlaceType? = nil
    @Published private(set) var currentCityId: String = ""

    var featured: [PlaceEntry] { places.filter(\.isFeatured) }

    var filteredPlaces: [PlaceEntry] {
        guard let t = selectedType else { return places }
        return places.filter { $0.type == t }
    }

    var presentTypes: [PlaceType] {
        let used = Set(places.map(\.type))
        return PlaceType.allCases.filter { used.contains($0) }
    }

    init() {
        if let first = CityManifest.shared.allCities.first {
            loadPlaces(for: first)
        }
    }

    func loadPlaces(for city: CityEntry) {
        guard city.id != currentCityId || places.isEmpty else { return }
        currentCityId = city.id
        selectedType = nil
        places = CityPlaces.load(for: city.id)
    }
}
