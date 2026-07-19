import Foundation

enum PlaceType: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }
    case neighborhood, beach, mountain, cultural, culinary, religious, nature, nightlife, heritage,
         wellness, shopping

    var displayName: String {
        switch self {
        case .neighborhood: return "Neighborhood"
        case .beach:        return "Beach"
        case .mountain:     return "Mountain"
        case .cultural:     return "Cultural"
        case .culinary:     return "Culinary"
        case .religious:    return "Sacred Site"
        case .nature:       return "Nature"
        case .nightlife:    return "Nightlife"
        case .heritage:     return "Heritage"
        case .wellness:     return "Wellness"
        case .shopping:     return "Shopping"
        }
    }

    var icon: String {
        switch self {
        case .neighborhood: return "building.2.fill"
        case .beach:        return "water.waves"
        case .mountain:     return "mountain.2.fill"
        case .cultural:     return "theatermasks.fill"
        case .culinary:     return "fork.knife"
        case .religious:    return "sparkles"
        case .nature:       return "leaf.fill"
        case .nightlife:    return "moon.stars.fill"
        case .heritage:     return "building.columns.fill"
        case .wellness:     return "heart.fill"
        case .shopping:     return "bag.fill"
        }
    }
}

struct PlaceEntry: Codable, Identifiable {
    let id: String
    let name: String
    let type: PlaceType
    let cityId: String
    /// Matches a `DistrictEntry.id` — when set, enables "Explore in 3D" in `PlaceDetailView`.
    let districtId: String?
    let coordinate: GeoCoord
    let description: String
    let highlights: [String]
    let category: ActivityCategory
    let tags: [String]
    let isFeatured: Bool
    let priceRange: String?
}

struct CityPlaces: Codable {
    let cityId: String
    let places: [PlaceEntry]

    static func load(for cityId: String) -> [PlaceEntry] {
        guard let url = Bundle.main.url(forResource: "places_\(cityId)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(CityPlaces.self, from: data)
        else { return [] }
        return bundle.places
    }
}
