import Foundation
import CoreLocation

// MARK: - Model

struct WeatherData: Sendable {
    let temperatureCelsius: Float
    let apparentTemperatureCelsius: Float
    let windSpeedKmh: Float
    let humidity: Int
    let precipitationMm: Float
    let weatherCode: Int

    /// WMO weather code → SF Symbol name
    var sfSymbol: String {
        switch weatherCode {
        case 0:           return "sun.max.fill"
        case 1:           return "sun.cloud.fill"
        case 2:           return "cloud.sun.fill"
        case 3:           return "cloud.fill"
        case 45, 48:      return "cloud.fog.fill"
        case 51...55:     return "cloud.drizzle.fill"
        case 61...65:     return "cloud.rain.fill"
        case 71...75:     return "cloud.snow.fill"
        case 80...82:     return "cloud.heavyrain.fill"
        case 85, 86:      return "cloud.snow.fill"
        case 95...99:     return "cloud.bolt.rain.fill"
        default:          return "cloud.fill"
        }
    }

    /// Short condition label (in French)
    var conditionLabel: String {
        switch weatherCode {
        case 0:           return "Ciel dégagé"
        case 1:           return "Peu nuageux"
        case 2:           return "Partiellement nuageux"
        case 3:           return "Couvert"
        case 45, 48:      return "Brouillard"
        case 51...55:     return "Bruine"
        case 61...65:     return "Pluie"
        case 71...75:     return "Neige"
        case 80...82:     return "Averses"
        case 85, 86:      return "Averses de neige"
        case 95...99:     return "Orage"
        default:          return "Nuageux"
        }
    }

    /// Accent color tint based on conditions (used by the weather widget)
    var accentColorHex: String {
        switch weatherCode {
        case 0, 1:        return "#FFD966"   // sunny gold
        case 2, 3:        return "#A0C4E8"   // cloudy blue-grey
        case 45, 48:      return "#C0BFB8"   // fog grey
        case 51...65:     return "#7EC8E3"   // rain blue
        case 71...86:     return "#D6EAF8"   // snow white-blue
        case 95...99:     return "#8B5CF6"   // storm purple
        default:          return "#A0C4E8"
        }
    }
}

// MARK: - Open-Meteo response shape

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature2m: Float
        let apparentTemperature: Float
        let weatherCode: Int
        let windSpeed10m: Float
        let relativeHumidity2m: Int
        let precipitation: Float

        enum CodingKeys: String, CodingKey {
            case temperature2m       = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case weatherCode         = "weather_code"
            case windSpeed10m        = "wind_speed_10m"
            case relativeHumidity2m  = "relative_humidity_2m"
            case precipitation
        }
    }
    let current: Current
}

// MARK: - Service

/// Fetches live weather from Open-Meteo (free, no API key) and caches per city for 30 minutes.
actor WeatherService {
    static let shared = WeatherService()
    private init() {}

    private struct Entry { let data: WeatherData; let expiresAt: Date }
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<WeatherData?, Never>] = [:]

    func weather(for city: CityEntry) async -> WeatherData? {
        if let hit = cache[city.id], hit.expiresAt > Date() { return hit.data }
        if let task = inFlight[city.id] { return await task.value }

        let task = Task<WeatherData?, Never> { await Self.fetch(lat: city.anchor.latitude,
                                                                lon: city.anchor.longitude) }
        inFlight[city.id] = task
        let result = await task.value
        inFlight.removeValue(forKey: city.id)
        if let result {
            cache[city.id] = Entry(data: result, expiresAt: Date().addingTimeInterval(30 * 60))
        }
        return result
    }

    private static func fetch(lat: Double, lon: Double) async -> WeatherData? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude",           value: String(format: "%.4f", lat)),
            .init(name: "longitude",          value: String(format: "%.4f", lon)),
            .init(name: "current",            value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m,precipitation"),
            .init(name: "timezone",           value: "auto"),
            .init(name: "wind_speed_unit",    value: "kmh"),
        ]
        guard let url = comps.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let resp = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data) else { return nil }
        let c = resp.current
        return WeatherData(
            temperatureCelsius:          c.temperature2m,
            apparentTemperatureCelsius:  c.apparentTemperature,
            windSpeedKmh:                c.windSpeed10m,
            humidity:                    c.relativeHumidity2m,
            precipitationMm:             c.precipitation,
            weatherCode:                 c.weatherCode
        )
    }
}
