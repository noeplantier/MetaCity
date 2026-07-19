import Foundation
import UIKit
import MapKit
import Combine

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

    // Cities that deserve fresher data and broader search coverage.
    private static let flagshipCities: Set<String> = [
        "paris", "tokyo", "newyork", "losangeles", "london", "vancouver", "sanfrancisco"
    ]

    private var foregroundObserver: AnyCancellable?

    init() {
        // Refresh live places whenever the app returns to the foreground.
        foregroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.currentCityId.isEmpty,
                      let city = CityManifest.shared.allCities.first(where: { $0.id == self.currentCityId })
                else { return }
                // Force-expire TTL so foreground entry triggers a fresh fetch.
                let ageKey = "live_places_age_\(city.id)"
                UserDefaults.standard.removeObject(forKey: ageKey)
                Task { await self.refreshLivePlaces(for: city) }
            }

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

    func refreshLivePlaces(for city: CityEntry) async {
        let cacheKey = "live_places_\(city.id)"
        let ageKey = "live_places_age_\(city.id)"
        // Flagship cities get a 6h TTL; other cities get 24h.
        let ttl: TimeInterval = Self.flagshipCities.contains(city.id) ? 6 * 3600 : 86400

        if let cached = UserDefaults.standard.data(forKey: cacheKey),
           let age = UserDefaults.standard.object(forKey: ageKey) as? Date,
           Date().timeIntervalSince(age) < ttl,
           let decoded = try? JSONDecoder().decode([PlaceEntry].self, from: cached) {
            mergeLivePlaces(decoded, cityId: city.id)
            return
        }

        let searchTerms = liveSearchTerms(for: city)
        // Flagship cities fetch up to 4 results per term for broader coverage.
        let resultsPerTerm = Self.flagshipCities.contains(city.id) ? 4 : 3
        var fetched: [PlaceEntry] = []

        for term in searchTerms {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = term
            request.region = MKCoordinateRegion(
                center: city.anchor.clLocationCoordinate,
                latitudinalMeters: city.mapZoomRadius * 2,
                longitudinalMeters: city.mapZoomRadius * 2
            )
            guard let response = try? await MKLocalSearch(request: request).start() else { continue }
            let entries = response.mapItems.prefix(resultsPerTerm).compactMap { item -> PlaceEntry? in
                guard let name = item.name,
                      let lat = item.placemark.location?.coordinate.latitude,
                      let lon = item.placemark.location?.coordinate.longitude else { return nil }
                let id = "live_\(city.id)_\(name.lowercased().replacingOccurrences(of: " ", with: "_").prefix(30))"
                return PlaceEntry(
                    id: id,
                    name: name,
                    type: placeType(for: term),
                    cityId: city.id,
                    districtId: nil,
                    coordinate: GeoCoord(latitude: lat, longitude: lon),
                    description: item.url?.absoluteString ?? "",
                    highlights: [],
                    category: .explore,
                    tags: ["live"],
                    isFeatured: false,
                    priceRange: nil
                )
            }
            fetched.append(contentsOf: entries)
        }

        if !fetched.isEmpty {
            if let encoded = try? JSONEncoder().encode(fetched) {
                UserDefaults.standard.set(encoded, forKey: cacheKey)
                UserDefaults.standard.set(Date(), forKey: ageKey)
            }
            mergeLivePlaces(fetched, cityId: city.id)
        }
    }

    private func mergeLivePlaces(_ live: [PlaceEntry], cityId: String) {
        guard cityId == currentCityId else { return }
        let existingIds   = Set(places.map(\.id))
        let existingNames = Set(places.map { $0.name.lowercased() })
        let novel = live.filter { entry in
            guard !existingIds.contains(entry.id),
                  !existingNames.contains(entry.name.lowercased()) else { return false }
            // Coordinate deduplication: reject if within 200m of any existing place.
            let eLat = entry.coordinate.latitude, eLon = entry.coordinate.longitude
            return !places.contains(where: { p in
                let dLat = (p.coordinate.latitude  - eLat) * 111_000
                let dLon = (p.coordinate.longitude - eLon) * 111_000 * cos(eLat * .pi / 180)
                return sqrt(dLat * dLat + dLon * dLon) < 200
            })
        }
        places.append(contentsOf: novel)
    }

    private func liveSearchTerms(for city: CityEntry) -> [String] {
        switch city.id {
        case "paris":
            return ["restaurant gastronomique Paris", "musée Paris", "café de spécialité Paris",
                    "boulangerie Paris Marais", "bar à vin Paris", "terrasse café Paris",
                    "galerie d'art Paris", "marché gourmet Paris"]
        case "tokyo":
            return ["ramen Shibuya Tokyo", "izakaya Shinjuku Tokyo", "omakase sushi Tokyo",
                    "coffee specialty Shibuya", "yakitori Shibuya", "onsen Shinjuku",
                    "shrine Harajuku Tokyo", "cocktail bar Shibuya"]
        case "london":
            return ["restaurant City of London", "museum London", "pub London",
                    "market Borough London", "cocktail bar London", "café specialty London",
                    "theatre West End London", "wine bar London"]
        case "newyork":
            return ["restaurant midtown Manhattan", "museum New York", "cocktail bar New York",
                    "rooftop bar Manhattan", "brunch New York", "deli New York",
                    "jazz club New York", "gallery Chelsea New York"]
        case "losangeles":
            return ["restaurant Downtown Los Angeles", "art gallery Los Angeles", "rooftop bar DTLA",
                    "coffee Los Angeles", "taco DTLA", "cocktail bar LA",
                    "brunch Los Angeles", "jazz club Los Angeles"]
        case "madrid":
            return ["restaurante Madrid centro", "museo Prado Madrid", "tapas Madrid Malasaña",
                    "bar de copas Madrid", "mercado San Miguel Madrid",
                    "taberna Madrid", "coctelería Madrid"]
        case "rome":
            return ["ristorante Roma centro storico", "enoteca Roma", "trattoria Roma",
                    "gelato Roma", "aperitivo Roma", "caffe storico Roma"]
        case "vancouver":
            return ["restaurant Vancouver Downtown", "café specialty Vancouver", "seafood Vancouver",
                    "market Granville Vancouver", "cocktail bar Vancouver",
                    "izakaya Vancouver", "brunch Vancouver"]
        case "sanfrancisco":
            return ["restaurant San Francisco Financial District", "café specialty SF",
                    "wine bar San Francisco", "oyster bar SF",
                    "brunch Mission San Francisco", "cocktail bar SF"]
        case "bordeaux":
            return ["restaurant Bordeaux", "cave à vin Bordeaux", "brasserie Bordeaux",
                    "bar à vin Chartrons Bordeaux", "marché des Capucins Bordeaux"]
        case "jakarta":
            return ["restoran fine dining Jakarta Sudirman", "wisata Kota Tua Jakarta",
                    "café specialty Kemang Jakarta", "rooftop bar Jakarta Sudirman",
                    "kuliner halal Jakarta"]
        case "denpasar":
            return ["beach club Seminyak Bali", "restaurant Seminyak Bali", "warung Canggu",
                    "spa Bali Seminyak", "sunset bar Canggu", "yoga Canggu Bali"]
        case "bandung":
            return ["café Dago Bandung", "restoran heritage Braga Bandung",
                    "factory outlet Bandung", "wisata kuliner Bandung", "angkringan Bandung"]
        case "yogyakarta":
            return ["restoran Malioboro Yogyakarta", "café Kraton Yogyakarta",
                    "gudeg Yogyakarta", "batik workshop Yogyakarta", "wisata budaya Jogja"]
        default:
            return ["restaurant \(city.displayName)", "café \(city.displayName)",
                    "museum \(city.displayName)"]
        }
    }

    private func placeType(for searchTerm: String) -> PlaceType {
        let t = searchTerm.lowercased()
        if t.contains("museum") || t.contains("musée") || t.contains("museo") ||
           t.contains("gallery") || t.contains("galerie") || t.contains("theatre") ||
           t.contains("théâtre") || t.contains("jazz club") || t.contains("kota tua") ||
           t.contains("wisata budaya") || t.contains("shrine") || t.contains("temple") ||
           t.contains("izakaya") { return .cultural }
        if t.contains("beach club") || t.contains("sunset bar") || t.contains("rooftop bar") ||
           t.contains("cocktail bar") || t.contains("bar de copas") || t.contains("coctelería") ||
           t.contains("bar à vin") || t.contains("enoteca") || t.contains("wine bar") ||
           t.contains("pub") || t.contains("aperitivo") { return .nightlife }
        if t.contains("spa") || t.contains("wellness") || t.contains("yoga") ||
           t.contains("onsen") { return .wellness }
        if t.contains("market") || t.contains("marché") || t.contains("mercado") ||
           t.contains("factory outlet") || t.contains("batik") { return .shopping }
        if t.contains("musée") || t.contains("musée") || t.contains("wisata") ||
           t.contains("batik workshop") { return .heritage }
        return .culinary
    }
}
