import SwiftUI

@MainActor
final class LandmarkInspectorViewModel: ObservableObject {
    @Published var rotationSpeed: Double = 1.0
    @Published var isAutoRotating = true
    @Published var isNightMode = true
}
