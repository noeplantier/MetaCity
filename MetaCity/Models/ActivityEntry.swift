import Foundation

enum ActivityCategory: String, Codable, CaseIterable, Identifiable {
    // Original tourism categories
    case eat, stay, explore, nightlife, wellness, shopping, sport
    // Vitrine showcase categories — used for the 5 flagship districts
    case visiteGuidee       = "visiteGuidee"
    case experienceRA       = "experienceRA"
    case panorama           = "panorama"
    case immersionSensorielle = "immersionSensorielle"
    case lifestyle          = "lifestyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eat:                  return "Eat"
        case .stay:                 return "Stay"
        case .explore:              return "Explore"
        case .nightlife:            return "Nightlife"
        case .wellness:             return "Wellness"
        case .shopping:             return "Shopping"
        case .sport:                return "Sport"
        case .visiteGuidee:         return "Visite guidée"
        case .experienceRA:         return "Expérience RA"
        case .panorama:             return "Panorama"
        case .immersionSensorielle: return "Immersion"
        case .lifestyle:            return "Lifestyle"
        }
    }

    var icon: String {
        switch self {
        case .eat:                  return "fork.knife"
        case .stay:                 return "bed.double.fill"
        case .explore:              return "binoculars.fill"
        case .nightlife:            return "moon.stars.fill"
        case .wellness:             return "leaf.fill"
        case .shopping:             return "bag.fill"
        case .sport:                return "figure.run"
        case .visiteGuidee:         return "person.wave.2.fill"
        case .experienceRA:         return "arkit"
        case .panorama:             return "mountain.2.fill"
        case .immersionSensorielle: return "waveform"
        case .lifestyle:            return "sparkles"
        }
    }

    /// True for the five vitrine showcase categories — shown in the card-grid ActivitiesView.
    var isVitrine: Bool {
        switch self {
        case .visiteGuidee, .experienceRA, .panorama, .immersionSensorielle, .lifestyle:
            return true
        default:
            return false
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
    /// District ID to open when user taps "Voir en 3D". Nil = no 3D shortcut.
    let districtId: String?
    /// Key into Assets.xcassets/Fragments/<key> for `CityFragmentThumbnail`.
    /// Nil = use city-level gradient placeholder.
    let fragmentAssetKey: String?
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
