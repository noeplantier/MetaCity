import Foundation
import SwiftUI

@MainActor
final class ContactsViewModel: ObservableObject {

    // MARK: - Emergency strip

    struct EmergencyNumber: Identifiable {
        let id: String
        let label: String
        let number: String
        let icon: String
        let color: Color
        var phoneURL: URL? { URL(string: "tel:\(number.filter { $0.isNumber || $0 == "+" })") }
    }

    let emergencyNumbers: [EmergencyNumber] = [
        EmergencyNumber(id: "police",    label: "Police",         number: "110",              icon: "shield.fill",              color: Color(red: 0.20, green: 0.50, blue: 0.90)),
        EmergencyNumber(id: "ambulance", label: "Ambulance",      number: "118",              icon: "cross.fill",               color: Color(red: 0.85, green: 0.20, blue: 0.25)),
        EmergencyNumber(id: "fire",      label: "Pompiers",       number: "113",              icon: "flame.fill",               color: Color(red: 0.95, green: 0.45, blue: 0.10)),
        EmergencyNumber(id: "sar",       label: "Secours mer",    number: "115",              icon: "water.waves",              color: Color(red: 0.10, green: 0.65, blue: 0.80)),
        EmergencyNumber(id: "tourism",   label: "Tourisme",       number: "+622157043600",    icon: "person.fill.questionmark", color: Color(red: 0.52, green: 0.35, blue: 0.88)),
        EmergencyNumber(id: "kbri",      label: "Ambassade FR",   number: "+622123551400",    icon: "flag.fill",                color: Color(red: 0.80, green: 0.10, blue: 0.15)),
    ]

    // MARK: - City tabs

    struct CityTab: Identifiable, Equatable {
        let id: String
        let displayName: String
        let emoji: String
    }

    let cityTabs: [CityTab] = [
        CityTab(id: "jakarta",    displayName: "Jakarta",    emoji: "🏙"),
        CityTab(id: "denpasar",   displayName: "Bali",       emoji: "🌺"),
        CityTab(id: "bandung",    displayName: "Bandung",    emoji: "🌿"),
        CityTab(id: "yogyakarta", displayName: "Yogyakarta", emoji: "🛕"),
    ]

    @Published var selectedCityId: String = "jakarta"
    @Published private(set) var contacts: [TourismContact] = []
    @Published var searchQuery: String = ""

    var filteredContacts: [TourismContact] {
        guard !searchQuery.isEmpty else { return contacts }
        let q = searchQuery.lowercased()
        return contacts.filter {
            $0.name.lowercased().contains(q) ||
            $0.role.lowercased().contains(q) ||
            $0.organization.lowercased().contains(q) ||
            $0.description.lowercased().contains(q)
        }
    }

    init() {
        contacts = TourismContact.load(for: "jakarta")
    }

    func selectCity(_ cityId: String) {
        guard cityId != selectedCityId else { return }
        selectedCityId = cityId
        searchQuery = ""
        contacts = TourismContact.load(for: cityId)
    }
}
