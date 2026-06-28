import Foundation

/// Abstraction over where profile customization/privacy settings persist. `UserDefaultsPreferencesStore`
/// is the only implementation today (genuinely real, not a mock — UserDefaults *is* the real local
/// mechanism here, there's no backend to swap in later the way Auth/Map have mock vs. real).
protocol UserPreferencesStore {
    func load(for userID: String) -> UserPreferences
    func save(_ preferences: UserPreferences, for userID: String)
}
