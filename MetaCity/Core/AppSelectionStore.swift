import Foundation

/// Cross-tab "what place is the user focused on right now" — the one piece of state genuinely
/// shared between features rather than owned by a single screen's ViewModel. Lets Map's "View in
/// 3D" action tell the Explore tab which place to show and request a tab switch, without Map and
/// Explore needing to know about each other directly.
///
/// `requestedTab` is a one-shot signal: `HomeTabView` consumes it and resets it to `nil`
/// immediately, so it never re-fires on an unrelated re-render.
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
