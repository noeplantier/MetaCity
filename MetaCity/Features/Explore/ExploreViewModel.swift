import Foundation

/// Explore is intentionally minimal in this pass: a real, working "nearby landmarks" search backed
/// by the existing `MapRepository` mock. Nearby-user presence, trending locations, and the
/// glassmorphism treatment are the next layer — see the architecture notes for why this is a
/// deliberate v1 rather than a placeholder.
@MainActor
final class ExploreViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published private(set) var landmarks: [PlaceAnnotationItem] = []
    @Published var isLoading = false
    @Published var presentedError: IdentifiableError?
    @Published var selectedLandmark: PlaceAnnotationItem?

    let greetingName: String

    private let mapRepository: MapRepository
    private let exploreCenter = IndonesianCity.jakarta.centerCoordinate

    init(mapRepository: MapRepository, currentUserName: String?) {
        self.mapRepository = mapRepository
        self.greetingName = currentUserName ?? "Explorer"
    }

    var filteredLandmarks: [PlaceAnnotationItem] {
        guard !searchText.isEmpty else { return landmarks }
        return landmarks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    func loadLandmarks() async {
        isLoading = true
        defer { isLoading = false }
        do {
            landmarks = try await mapRepository.fetchNearbyPlaces(around: exploreCenter, radiusMeters: 2000)
        } catch {
            presentedError = IdentifiableError(underlyingError: error)
        }
    }

    func select(_ landmark: PlaceAnnotationItem) {
        selectedLandmark = landmark
    }
}
