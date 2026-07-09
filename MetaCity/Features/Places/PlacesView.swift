import MapKit
import SwiftUI

struct PlacesView: View {
    @ObservedObject var viewModel: PlacesViewModel
    @ObservedObject var discoverViewModel: DiscoverViewModel
    @Binding var selectedTab: AppTab
    @State private var selectedPlace: PlaceEntry? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.metacityBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    typeFilterBar
                    Divider().background(Color.metacityBorder)
                    placesList
                }
            }
            .navigationTitle(discoverViewModel.focusedCity.map { "\($0.displayName)" } ?? "Places")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $selectedPlace) { place in
                PlaceDetailView(
                    place: place,
                    discoverViewModel: discoverViewModel,
                    selectedTab: $selectedTab
                )
            }
        }
    }

    private var typeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PlaceTypeChip(label: "All", icon: "square.grid.2x2.fill", isSelected: viewModel.selectedType == nil) {
                    viewModel.selectedType = nil
                }
                ForEach(viewModel.presentTypes) { type in
                    PlaceTypeChip(label: type.displayName, icon: type.icon, isSelected: viewModel.selectedType == type) {
                        viewModel.selectedType = (viewModel.selectedType == type) ? nil : type
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
        }
    }

    private var placesList: some View {
        Group {
            if viewModel.filteredPlaces.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.sm) {
                        let featured = viewModel.filteredPlaces.filter(\.isFeatured)
                        if !featured.isEmpty {
                            sectionHeader("Featured")
                            ForEach(featured) { place in
                                PlaceCard(place: place) { selectedPlace = place }
                                    .padding(.horizontal, Spacing.lg)
                            }
                        }
                        let rest = viewModel.filteredPlaces.filter { !$0.isFeatured }
                        if !rest.isEmpty {
                            sectionHeader(featured.isEmpty ? "Places" : "More Places")
                            ForEach(rest) { place in
                                PlaceCard(place: place) { selectedPlace = place }
                                    .padding(.horizontal, Spacing.lg)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.md)
                    .padding(.bottom, Spacing.xl)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.metacityTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "map.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.metacityTextTertiary)
            Text("No places yet")
                .font(.headline)
                .foregroundStyle(Color.metacityTextSecondary)
            Text("Explore a city in Discover to load its places.")
                .font(.footnote)
                .foregroundStyle(Color.metacityTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Type filter chip

private struct PlaceTypeChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption.weight(.semibold))
                Text(label).font(.caption.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.white : Color.metacityTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(isSelected ? Color.metacityPrimary : Color.metacitySurface))
            .overlay(Capsule().strokeBorder(Color.metacityBorder, lineWidth: isSelected ? 0 : 1))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}

// MARK: - Place card

private struct PlaceCard: View {
    let place: PlaceEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(placeColor.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: place.type.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(placeColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(place.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.metacityTextPrimary)
                        if place.isFeatured {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.metacityWarning)
                        }
                        Spacer(minLength: 4)
                        if place.districtId != nil {
                            Label("3D", systemImage: "cube.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.metacityPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.metacityPrimary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(place.type.displayName)
                        .font(.caption)
                        .foregroundStyle(Color.metacityTextTertiary)
                    Text(place.description)
                        .font(.footnote)
                        .foregroundStyle(Color.metacityTextSecondary)
                        .lineLimit(2)
                }
            }
            .padding(Spacing.md)
            .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.metacityBorder, lineWidth: 1)
            )
        }
        .buttonStyle(PressableScaleStyle())
    }

    private var placeColor: Color {
        switch place.type {
        case .beach:        return .teal
        case .mountain:     return .blue
        case .cultural:     return .purple
        case .culinary:     return Color(red: 0.9, green: 0.5, blue: 0.1)
        case .religious:    return .yellow
        case .nature:       return .green
        case .nightlife:    return .indigo
        case .heritage:     return Color(red: 0.6, green: 0.4, blue: 0.2)
        case .neighborhood: return Color.metacityPrimary
        }
    }
}

// MARK: - Place detail sheet

struct PlaceDetailView: View {
    let place: PlaceEntry
    @ObservedObject var discoverViewModel: DiscoverViewModel
    @Binding var selectedTab: AppTab
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Description
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(place.type.displayName.uppercased())
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(Color.metacityTextTertiary)
                        Text(place.description)
                            .font(.body)
                            .foregroundStyle(Color.metacityTextPrimary)
                    }
                    .padding(.horizontal, Spacing.lg)

                    // Highlights
                    if !place.highlights.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("Why visit")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.metacityTextPrimary)
                                .padding(.horizontal, Spacing.lg)
                            ForEach(place.highlights, id: \.self) { highlight in
                                HStack(alignment: .top, spacing: Spacing.sm) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(Color.metacityPrimary)
                                    Text(highlight)
                                        .font(.footnote)
                                        .foregroundStyle(Color.metacityTextSecondary)
                                }
                                .padding(.horizontal, Spacing.lg)
                            }
                        }
                    }

                    // Mini map
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: place.coordinate.clLocationCoordinate,
                        latitudinalMeters: 2500,
                        longitudinalMeters: 2500
                    ))) {
                        Marker(place.name, coordinate: place.coordinate.clLocationCoordinate)
                            .tint(Color.metacityPrimary)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .padding(.horizontal, Spacing.lg)

                    // Explore in 3D
                    if let districtId = place.districtId,
                       let district = CityManifest.shared.district(id: districtId),
                       let city = CityManifest.shared.allCities.first(where: { $0.districts.contains(where: { $0.id == districtId }) }) {
                        Button {
                            dismiss()
                            discoverViewModel.selectDistrict(district, in: city)
                            selectedTab = .discover
                        } label: {
                            Label("Explore in 3D", systemImage: "cube.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.metacityPrimary)
                        .padding(.horizontal, Spacing.lg)
                    }
                }
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(Color.metacityBackground.ignoresSafeArea())
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.metacityPrimary)
                }
            }
        }
    }
}

#Preview {
    PlacesView(
        viewModel: PlacesViewModel(),
        discoverViewModel: DiscoverViewModel(),
        selectedTab: .constant(.places)
    )
    .preferredColorScheme(.dark)
}
