import Foundation

/// Namespaces each user's preferences by id so switching accounts on the same device (e.g. log
/// out, sign in as someone else) never leaks one person's bio/avatar/privacy choices into another's.
final class UserDefaultsPreferencesStore: UserPreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for userID: String) -> UserPreferences {
        guard let data = defaults.data(forKey: key(for: userID)),
              let preferences = try? JSONDecoder().decode(UserPreferences.self, from: data)
        else {
            return .default
        }
        return preferences
    }

    func save(_ preferences: UserPreferences, for userID: String) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key(for: userID))
    }

    private func key(for userID: String) -> String {
        "com.metacity.userPreferences.\(userID)"
    }
}
