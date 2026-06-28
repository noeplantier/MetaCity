import ARKit
import Combine
import Foundation

@MainActor
final class ARViewModel: ObservableObject {
    @Published var placedMarkerCount = 0
    /// Only consulted when `!isARSupported` — picks which of the 5 districts `SimulatedARSceneView` renders.
    @Published var selectedLocation: ARLocation = .kotaTua

    private var cancellables = Set<AnyCancellable>()

    /// Observes `AppSelectionStore` so Map's "View in AR" action (or any future entry point) can
    /// drive this screen's location without ARScreenView/ARViewModel knowing anything about Map —
    /// both only depend on the shared store.
    init(selectionStore: AppSelectionStore) {
        selectionStore.$selectedPlace
            .compactMap { $0 }
            .sink { [weak self] place in
                self?.placedMarkerCount = 0
                if let districtName = place.districtName, let location = ARLocation.matching(districtName: districtName) {
                    self?.selectedLocation = location
                }
            }
            .store(in: &cancellables)
    }

    /// `ARWorldTrackingConfiguration.isSupported` is false in the Simulator (no camera) and on a
    /// handful of older devices. Checking this up front means the screen can fall back to
    /// `SimulatedARSceneView` instead of silently starting a session that will never track anything.
    var isARSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }
}
