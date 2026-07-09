import SwiftUI

/// Locally-persisted profile customization and privacy settings — see `UserPreferencesStore`.
///
/// Honest scope note: there's no backend for these fields (no Firestore/user-profile API in this
/// project — `User` itself is just Firebase Auth's id/email/displayName). `isProfilePublic` and
/// `isLocationSharingEnabled` are real, persisted user choices, but nothing in the app currently
/// has *other users* who could see this profile or its shared location — there's no social/
/// multiplayer feature yet. They're built as genuine preferences with real persistence, not wired
/// to a real audience, and the UI should not imply otherwise.
struct UserPreferences: Codable, Equatable {
    var avatarSymbol: String
    var avatarColorName: AvatarColorName
    var bio: String
    var isProfilePublic: Bool
    var isLocationSharingEnabled: Bool
    var isBiometricLockEnabled: Bool
    /// District IDs (matching `DistrictEntry.id`) the user has opened the 3D inspector for.
    /// Set by `DiscoverViewModel.selectDistrict` on every 3D open — persisted immediately
    /// (not debounced) since this is a rare, meaningful action. Shown as "passport stamps" on
    /// the Profile travel passport view.
    var visitedDistrictIds: Set<String>

    static let `default` = UserPreferences(
        avatarSymbol: "face.smiling",
        avatarColorName: .primary,
        bio: "",
        isProfilePublic: false,
        isLocationSharingEnabled: false,
        isBiometricLockEnabled: false,
        visitedDistrictIds: []
    )

    /// SF Symbols, not emoji — see `Avatar.systemImage`'s doc comment for why.
    static let symbolChoices = [
        "face.smiling", "sunglasses.fill", "airplane", "building.2.fill",
        "globe.asia.australia.fill", "mountain.2.fill", "camera.fill", "music.note",
        "flame.fill", "sparkles", "leaf.fill", "moon.stars.fill"
    ]
}

/// A small fixed palette (not a full color picker) — keeps every avatar visually consistent with
/// the rest of the anthracite design system instead of clashing arbitrary RGB values.
enum AvatarColorName: String, Codable, CaseIterable {
    case primary, secondary, success, warning, danger

    var color: Color {
        switch self {
        case .primary: .metacityPrimary
        case .secondary: .metacitySecondary
        case .success: .metacitySuccess
        case .warning: .metacityWarning
        case .danger: .metacityDanger
        }
    }
}
