import Foundation

/// Identifies each tab in `HomeTabView`'s `TabView`, so other code (see `AppSelectionStore`) can
/// request a programmatic tab switch — e.g. Map's "View in AR" button jumping to the AR tab —
/// without `HomeTabView` needing to know *why* it's switching.
enum AppTab: Hashable {
    case explore, map, ar, calls, profile
}
