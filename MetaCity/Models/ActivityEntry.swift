import Foundation

enum ActivityCategory: String, Codable, CaseIterable, Identifiable {
    case eat, stay, explore, nightlife, wellness, shopping, sport

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eat:       return "Eat"
        case .stay:      return "Stay"
        case .explore:   return "Explore"
        case .nightlife: return "Nightlife"
        case .wellness:  return "Wellness"
        case .shopping:  return "Shopping"
        case .sport:     return "Sport"
        }
    }

    var icon: String {
        switch self {
        case .eat:       return "fork.knife"
        case .stay:      return "bed.double.fill"
        case .explore:   return "binoculars.fill"
        case .nightlife: return "moon.stars.fill"
        case .wellness:  return "leaf.fill"
        case .shopping:  return "bag.fill"
        case .sport:     return "figure.run"
        }
    }
}

/// City-level tier: activities from premium cities are visually differentiated.
enum CityTier: String, Codable {
    case premium, standard
}

/// One curated tourism activity — the base unit of the Activities tab.
struct ActivityEntry: Codable, Identifiable {
    let id: String
    let name: String
    let category: ActivityCategory
    let tier: CityTier
    let description: String
    /// The district or neighbourhood this activity is in, for sub-title display.
    let area: String
    /// Rough price range: "$", "$$", "$$$", "$$$$"
    let priceRange: String
    /// Suggested visit duration (e.g. "1–2h", "Half day")
    let duration: String
    let latitude: Double
    let longitude: Double
    /// Official website URL. Nil for activities where no authoritative URL was found.
    let officialURL: String?
}

/// Per-city activity bundle — one JSON file per city, keyed by `CityEntry.id`.
struct CityActivities: Codable {
    let cityId: String
    let activities: [ActivityEntry]

    static func load(for cityId: String) -> [ActivityEntry] {
        // Files are prefixed "activities_" to avoid collision with same-named district JSON.
        // XcodeGen flattens all resources to the bundle root, so no subdirectory lookup.
        guard let url = Bundle.main.url(forResource: "activities_\(cityId)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(CityActivities.self, from: data)
        else { return [] }
        return bundle.activities
    }
}
