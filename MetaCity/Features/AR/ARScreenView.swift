import SwiftUI

struct ARScreenView: View {
    @ObservedObject var viewModel: ARViewModel

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if viewModel.isARSupported {
                    ARSceneView(location: viewModel.selectedLocation, placedCount: $viewModel.placedMarkerCount)
                        .ignoresSafeArea()
                } else {
                    SimulatedARSceneView(location: viewModel.selectedLocation, placedMarkerCount: $viewModel.placedMarkerCount)
                        .ignoresSafeArea()
                }

                VStack(spacing: Spacing.sm) {
                    locationPicker
                    statusBanner
                }
                .padding(.bottom, Spacing.xxl)
            }
            .navigationTitle("AR")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// All 5 districts in one row — the entire app's AR/3D content now, so there's no second tier
    /// of picker to fit alongside this one.
    private var locationPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(ARLocation.allCases) { location in
                    locationChip(location)
                }
            }
            .padding(.horizontal, Spacing.lg)
        }
    }

    private func locationChip(_ location: ARLocation) -> some View {
        let isSelected = viewModel.selectedLocation == location
        return Button {
            viewModel.selectedLocation = location
        } label: {
            Text(location.displayName)
                .font(.metacityCaption)
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(isSelected ? Color.white : Color.white.opacity(0.18), in: Capsule())
        }
    }

    private var statusBanner: some View {
        VStack(spacing: 2) {
            Text(bannerTitle)
                .font(.metacitySubheadline)
                .foregroundStyle(.white)
            Text("Focus building: \(viewModel.selectedLocation.focusBuildingName)")
                .font(.metacityCaption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var bannerTitle: String {
        if viewModel.isARSupported {
            viewModel.placedMarkerCount == 0
                ? "Tap a detected surface to place \(viewModel.selectedLocation.displayName)"
                : "Visiting \(viewModel.selectedLocation.displayName)"
        } else {
            "Visiting \(viewModel.selectedLocation.displayName) — Simulator has no camera"
        }
    }
}

#Preview {
    ARScreenView(viewModel: AppEnvironment().makeARViewModel())
}
