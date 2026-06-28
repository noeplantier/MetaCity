import SwiftUI

struct ExploreScreenView: View {
    @ObservedObject var viewModel: ExploreViewModel
    @StateObject private var inspectorViewModel = LandmarkInspectorViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    header
                    searchField
                    landmarksSection
                }
                .padding(Spacing.lg)
            }
            .background(Color.metacityBackground)
            .navigationTitle("Explore")
            .task { await viewModel.loadLandmarks() }
            .errorAlert($viewModel.presentedError)
            .sheet(item: $viewModel.selectedLandmark) { landmark in
                if let districtName = landmark.districtName {
                    LandmarkInspectorView(
                        viewModel: inspectorViewModel,
                        landmarkTitle: landmark.title,
                        districtName: districtName
                    )
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Hi, \(viewModel.greetingName)")
                .font(.metacityLargeTitle)
                .foregroundStyle(Color.metacityTextPrimary)
            Text("Here's what's around you right now.")
                .font(.metacitySubheadline)
                .foregroundStyle(Color.metacityTextSecondary)
        }
    }

    private var searchField: some View {
        TextField("Search landmarks", text: $viewModel.searchText)
            .appTextFieldStyle(icon: "magnifyingglass", isFocused: false)
            .accessibilityLabel("Search landmarks")
    }

    private var landmarksSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Nearby landmarks")

            if viewModel.isLoading {
                LoadingStateView()
                    .frame(height: 160)
            } else if viewModel.filteredLandmarks.isEmpty {
                EmptyStateView(
                    systemImage: "binoculars",
                    title: viewModel.searchText.isEmpty ? "Nothing nearby yet" : "No matches",
                    message: viewModel.searchText.isEmpty
                        ? "We couldn't find landmarks around you right now."
                        : "Try a different search term."
                )
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(viewModel.filteredLandmarks) { landmark in
                        LandmarkRow(landmark: landmark) {
                            viewModel.select(landmark)
                        }
                    }
                }
            }
        }
    }
}

private struct LandmarkRow: View {
    let landmark: PlaceAnnotationItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.md) {
                Image(systemName: landmark.category.systemImage)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(landmark.category.tintColor, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(landmark.title)
                        .font(.metacityHeadline)
                        .foregroundStyle(Color.metacityTextPrimary)
                    Text(landmark.subtitle)
                        .font(.metacityCaption)
                        .foregroundStyle(Color.metacityTextSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.metacityTextTertiary)
            }
            .padding(Spacing.md)
            .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.metacityBorder, lineWidth: 1)
            )
        }
        .buttonStyle(PressableScaleStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens a 3D preview")
    }
}

#Preview {
    ExploreScreenView(viewModel: ExploreViewModel(mapRepository: MockMapRepository(), currentUserName: "Noé"))
}
