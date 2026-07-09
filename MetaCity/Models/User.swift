import Foundation

/// Core domain model representing an authenticated person.
/// Contains no framework types so it is identical regardless of which auth backend supplies it.
struct User: Identifiable, Equatable, Codable {
    let id: String
    let email: String
    let displayName: String
}
