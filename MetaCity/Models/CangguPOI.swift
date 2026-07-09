import Foundation

enum POICategory: String, Codable, CaseIterable {
    case surf, beach, temple, cafe, restaurant, hotel, villa,
         wellness, shop, nightlife, attraction, sport

    var displayName: String {
        switch self {
        case .surf:        "Surf"
        case .beach:       "Beach"
        case .temple:      "Temple"
        case .cafe:        "Café"
        case .restaurant:  "Restaurant"
        case .hotel:       "Hotel"
        case .villa:       "Villa"
        case .wellness:    "Wellness"
        case .shop:        "Shop"
        case .nightlife:   "Nightlife"
        case .attraction:  "Attraction"
        case .sport:       "Sport"
        }
    }

    var icon: String {
        switch self {
        case .surf:        "water.waves"
        case .beach:       "beach.umbrella.fill"
        case .temple:      "building.columns.fill"
        case .cafe:        "cup.and.saucer.fill"
        case .restaurant:  "fork.knife"
        case .hotel:       "building.2.fill"
        case .villa:       "house.fill"
        case .wellness:    "heart.fill"
        case .shop:        "bag.fill"
        case .nightlife:   "moon.stars.fill"
        case .attraction:  "star.fill"
        case .sport:       "figure.run"
        }
    }
}

enum POITier: String, Codable {
    case standard
    case featured
    case partner
}

struct CangguPOI: Codable, Identifiable {
    let id: String
    let name: String
    let category: POICategory
    let tier: POITier
    let latitude: Double
    let longitude: Double
    let description: String
    /// Compass bearing (degrees, 0 = N, 90 = E, 180 = S, 270 = W) of the approach vector.
    /// The camera is placed `approachDistance` metres in this direction FROM the venue centroid,
    /// looking back at the venue. Nil → defaults to 180° (approach from north).
    let approachBearing: Double?
    /// How far in front of the venue centroid the approach camera stands, in scene metres.
    /// Nil → defaults to 40m.
    let approachDistance: Float?
    let partnerURL: String?

    var isFeatured: Bool { tier != .standard }
}

struct CangguPOICollection: Codable {
    let districtId: String
    let pois: [CangguPOI]

    // Accessed exclusively from @MainActor callers (DistrictRealityKit + DiscoverViewModel).
    private static var cache: [String: CangguPOICollection] = [:]

    static func load(for districtId: String) -> CangguPOICollection? {
        let key = districtId.lowercased()
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: "pois_\(key)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(CangguPOICollection.self, from: data)
        else { return nil }
        cache[key] = result
        return result
    }
}
