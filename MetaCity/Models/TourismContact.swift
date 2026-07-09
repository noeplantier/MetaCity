import Foundation

/// A real Indonesian tourism contact — visitor centres, heritage boards, and cultural guides
/// reachable by phone or WhatsApp. Distinct from `CallContact` (which drives the in-app mock call
/// flow): tourism contacts open the native phone / WhatsApp app rather than entering the app's
/// own call state machine.
struct TourismContact: Codable, Identifiable {
    let id: String
    let name: String
    let role: String
    let organization: String
    let cityId: String
    let phone: String?
    /// E.164 format without '+', e.g. "6281234567890". Used to build the wa.me deep-link.
    let whatsappNumber: String?
    let description: String
    let avatarEmoji: String
    /// Short specialty tag, e.g. "Heritage & Culture" or "Eco-Tourism"
    let specialty: String?
    /// ISO 639-1 codes, e.g. ["id", "en", "fr"]
    let languages: [String]?
    /// Human-readable office hours, e.g. "Lun–Sam 09h–17h"
    let availability: String?
    /// 0–5 rating, one decimal, nil when not rated
    let rating: Float?

    /// Opens WhatsApp chat with this contact. Uses the universal wa.me link (works even without
    /// WhatsApp installed on the Simulator — opens App Store or web fallback).
    var whatsappURL: URL? {
        guard let wa = whatsappNumber else { return nil }
        return URL(string: "https://wa.me/\(wa)")
    }

    var phoneURL: URL? {
        guard let p = phone else { return nil }
        let digits = p.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return URL(string: "tel:+\(digits)")
    }

    static func load(for cityId: String) -> [TourismContact] {
        guard let url = Bundle.main.url(forResource: "contacts_\(cityId)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let contacts = try? JSONDecoder().decode([TourismContact].self, from: data)
        else { return [] }
        return contacts
    }
}
