import SwiftUI

struct ActivitiesView: View {
    @ObservedObject var viewModel: ActivitiesViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color.metacityBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    cityPicker
                    categoryBar
                    Divider().background(Color.metacityBorder)
                    activityList
                }
            }
            .navigationTitle("Activités")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $viewModel.searchText, prompt: "Search activities…")
        }
    }

    // MARK: - City picker

    private var cityPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.availableCities) { city in
                    CityChip(
                        title: city.shortName,
                        isSelected: viewModel.selectedCity.id == city.id
                    ) { viewModel.selectCity(city) }
                }
            }
            .padding(.horizontal, 16)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Activity list

    private var activityList: some View {
        Group {
            if viewModel.filteredActivities.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.filteredActivities) { activity in
                        ActivityRow(activity: activity)
                            .listRowBackground(Color.metacitySurface)
                            .listRowSeparatorTint(Color.metacityBorder)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "map.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.metacityTextTertiary)
            Text("No activities found")
                .font(.headline)
                .foregroundStyle(Color.metacityTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - City chip

private struct CityChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.metacityTextSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.metacityPrimary : Color.metacitySurface)
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

// MARK: - Activity row

private struct ActivityRow: View {
    let activity: ActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                // Category icon bubble
                Image(systemName: activity.category.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.metacityPrimary)
                    .frame(width: 28, height: 28)
                    .background(Color.metacityPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(activity.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.metacityTextPrimary)
                        if activity.tier == .premium {
                            PremiumBadge()
                        }
                        Spacer(minLength: 4)
                        Text(activity.priceRange)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.metacityTextTertiary)
                            .monospacedDigit()
                    }
                    Text(activity.area)
                        .font(.caption)
                        .foregroundStyle(Color.metacityTextTertiary)
                }
            }

            Text(activity.description)
                .font(.footnote)
                .foregroundStyle(Color.metacityTextSecondary)
                .lineLimit(3)

            HStack(spacing: Spacing.md) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(Color.metacityTextTertiary)
                    Text(activity.duration)
                        .font(.caption2)
                        .foregroundStyle(Color.metacityTextTertiary)
                }
                if let urlString = activity.officialURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Image(systemName: "safari")
                                .font(.caption2.weight(.semibold))
                            Text("Official site")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Color.metacityPrimary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Premium badge

private struct PremiumBadge: View {
    var body: some View {
        Text("PREMIUM")
            .font(.system(size: 8, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Color.metacityWarning)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.metacityWarning.opacity(0.14), in: Capsule())
    }
}

#Preview {
    ActivitiesView(viewModel: ActivitiesViewModel())
        .preferredColorScheme(.dark)
}
