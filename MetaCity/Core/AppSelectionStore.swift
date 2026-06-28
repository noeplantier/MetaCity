import Foundation

/// Cross-tab "what place is the user focused on right now" — the one piece of state genuinely
/// shared between features rather than owned by a single screen's ViewModel. Lets Map's "View in
/// AR" action tell the AR tab which place/district to load and request the tab switch, without Map
/// and AR knowing anything about each other directly (both only depend on this store).
///
/// `requestedTab` is a one-shot signal: `HomeTabView` consumes it (switches its own `@State`
/// selection) and resets it to `nil` immediately, so it never re-fires on an unrelated re-render.
@MainActor
final class AppSelectionStore: ObservableObject {
    @Published var selectedPlace: PlaceAnnotationItem?
    @Published var requestedTab: AppTab?

    func focus(on place: PlaceAnnotationItem, andSwitchTo tab: AppTab? = nil) {
        selectedPlace = place
        if let tab {
            requestedTab = tab
        }
    }
}
