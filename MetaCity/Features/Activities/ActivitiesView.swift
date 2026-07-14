import SwiftUI

struct ActivitiesView: View {
    @ObservedObject var viewModel: ActivitiesViewModel
    @State private var selectedActivity: ActivityEntry? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.metacityBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    cityPicker
                    categoryBar
                    Divider().background(Color.metacityBorder)
                    activityGrid
                }
            }
            .navigationTitle("Activités")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $viewModel.searchText, prompt: "Rechercher une activité…")
            .sheet(item: $selectedActivity) { activity in
                ActivityDetailSheet(activity: activity) { districtId in
                    selectedActivity = nil
                    viewModel.requestNavigation(to: districtId)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    // MARK: - City picker

    private var cityPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.availableCities) { city in
                    VitrineCityChip(
                        city: city,
                        isSelected: viewModel.selectedCity.id == city.id
                    ) { viewModel.selectCity(city) }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Category filter bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.presentCategories) { category in
                    CategoryChip(
                        category: category,
                        isSelected: viewModel.selectedCategory == category
                    ) { viewModel.selectCategory(category) }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Card grid

    private var activityGrid: some View {
        Group {
            if viewModel.filteredActivities.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: Spacing.md),
                            GridItem(.flexible(), spacing: Spacing.md)
                        ],
                        spacing: Spacing.md
                    ) {
                        ForEach(viewModel.filteredActivities) { activity in
                            ActivityCard(
                                activity: activity,
                                cityId: viewModel.selectedCity.id
                            ) { selectedActivity = activity }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, Spacing.xl)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "map.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.metacityTextTertiary)
            Text("Aucune activité")
                .font(.headline)
                .foregroundStyle(Color.metacityTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Vitrine city chip (with gradient accent)

private struct VitrineCityChip: View {
    let city: CityEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isSelected {
                    Circle()
                        .fill(Color.metacityNeonCyan)
                        .frame(width: 5, height: 5)
                }
                Text(city.displayName)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.metacityNeonCyan : Color.metacityTextSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
                    .fill(isSelected
                          ? Color.metacityNeonCyan.opacity(0.10)
                          : Color.metacitySurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.metacityNeonCyan.opacity(0.55) : Color.metacityBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}

// MARK: - Category chip

private struct CategoryChip: View {
    let category: ActivityCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: category.icon)
                    .font(.caption.weight(.semibold))
                Text(category.displayName)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.white : Color.metacityTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.metacitySecondary : Color.metacitySurface)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.metacityBorder, lineWidth: isSelected ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}

// MARK: - Activity card (2-col grid)

private struct ActivityCard: View {
    let activity: ActivityEntry
    let cityId: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Illustration header
                CityFragmentThumbnail(cityId: cityId)
                    .frame(height: 72)

                // Content body
                VStack(alignment: .leading, spacing: 4) {
                    // Category tag
                    HStack(spacing: 4) {
                        Image(systemName: activity.category.icon)
                            .font(.system(size: 8, weight: .bold))
                        Text(activity.category.displayName.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.8)
                    }
                    .foregroundStyle(categoryAccent)
                    .padding(.top, 8)

                    // Title
                    Text(activity.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.metacityTextPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    // Footer: duration + premium badge
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.metacityTextTertiary)
                        Text(activity.duration)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.metacityTextTertiary)
                        Spacer(minLength: 0)
                        if activity.tier == .premium {
                            Image(systemName: "sparkle")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.metacityNeonCyan)
                        }
                    }
                    .padding(.bottom, 10)
                }
                .padding(.horizontal, 10)
            }
            .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.metacityBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        }
        .buttonStyle(PressableScaleStyle())
    }

    private var categoryAccent: Color {
        switch activity.category {
        case .panorama:             return Color.metacityNeonCyan
        case .experienceRA:         return Color(red: 0.35, green: 0.75, blue: 1.00)
        case .visiteGuidee:         return Color.metacityPrimary
        case .immersionSensorielle: return Color.metacitySecondary
        case .lifestyle:            return Color.metacitySuccess
        default:                    return Color.metacityTextSecondary
        }
    }
}

// MARK: - Activity detail sheet

private struct ActivityDetailSheet: View {
    let activity: ActivityEntry
    let onSeeIn3D: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(categoryAccent.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: activity.category.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(categoryAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.category.displayName.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(categoryAccent)
                        .tracking(1.2)
                    Text(activity.name)
                        .font(.metacityTitle3)
                        .foregroundStyle(Color.metacityTextPrimary)
                }
                Spacer()
                if activity.tier == .premium {
                    VStack(spacing: 2) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.metacityNeonCyan)
                        Text("PREMIUM")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.metacityNeonCyan.opacity(0.75))
                            .tracking(0.8)
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)

            Divider().padding(.horizontal, Spacing.lg)

            // Meta row
            HStack(spacing: Spacing.xl) {
                metaItem(icon: "mappin.circle.fill", text: activity.area)
                metaItem(icon: "clock", text: activity.duration)
                metaItem(icon: "yensign.circle", text: activity.priceRange)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)

            Divider().padding(.horizontal, Spacing.lg)

            // Description
            ScrollView {
                Text(activity.description)
                    .font(.metacityBody)
                    .foregroundStyle(Color.metacityTextSecondary)
                    .lineSpacing(4)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
            }

            Spacer(minLength: 0)

            // CTA footer
            VStack(spacing: Spacing.sm) {
                Divider()
                if let districtId = activity.districtId,
                   let district = CityManifest.shared.district(id: districtId),
                   district.dataBundled {
                    Button {
                        onSeeIn3D(districtId)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "cube.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Voir \(activity.area) en 3D")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Color.metacityHUDBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.metacityNeonCyan, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.lg)
                } else if activity.districtId != nil {
                    // District exists but no 3D data yet
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.xmark")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.metacityTextTertiary)
                        Text("3D disponible prochainement")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.metacityTextTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .padding(.horizontal, Spacing.lg)
                }
                if let urlString = activity.officialURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                                .font(.system(size: 13, weight: .medium))
                            Text("Site officiel")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Color.metacityPrimary)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.bottom, Spacing.xl)
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.metacityTextTertiary)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.metacityTextSecondary)
        }
    }

    private var categoryAccent: Color {
        switch activity.category {
        case .panorama:             return Color.metacityNeonCyan
        case .experienceRA:         return Color(red: 0.35, green: 0.75, blue: 1.00)
        case .visiteGuidee:         return Color.metacityPrimary
        case .immersionSensorielle: return Color.metacitySecondary
        case .lifestyle:            return Color.metacitySuccess
        default:                    return Color.metacityPrimary
        }
    }
}

#Preview {
    ActivitiesView(viewModel: ActivitiesViewModel())
        .preferredColorScheme(.dark)
}
