import MapKit
import RealityKit
import SwiftUI

/// Unified spatial surface: Map → city focus → district 3D.
/// The `cityExplore` state (CityOverviewView + district list page) has been removed.
/// Districts are tappable directly from the map via `DistrictPinView` annotations at any zoom.
/// State machine: worldMap ↔ cityFocused ↔ districtExplore.
struct DiscoverView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    /// Briefly flashes to black on district transitions for a "warp to location" travel feel.
    @State private var transitionFlash: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            mapLayer
            sceneLayer
            // Travel flash overlay — fades in then out on map→district transitions
            Color.black
                .opacity(transitionFlash)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.28), value: transitionFlash)
            overlayLayer
        }
        .onChange(of: viewModel.showingMap) { _, isNowShowingMap in
            if !isNowShowingMap {
                // Transitioning into district — brief black flash, then clear
                transitionFlash = 0.82
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeOut(duration: 0.32)) { transitionFlash = 0 }
                }
            }
        }
    }

    // MARK: - Map layer

    private var mapLayer: some View {
        Map(position: $viewModel.cameraPosition) {
            // City pins
            ForEach(viewModel.manifest.allCities) { city in
                Annotation("", coordinate: city.anchor.clLocationCoordinate) {
                    CityPinView(
                        city: city,
                        isSelected: viewModel.focusedCity?.id == city.id
                    ) { viewModel.selectCity(city) }
                }
                .annotationTitles(.hidden)
            }
            // District pins — always on map, tappable at any zoom level
            ForEach(districtPins) { pin in
                Annotation("", coordinate: pin.district.anchor.clLocationCoordinate) {
                    DistrictPinView(district: pin.district) {
                        viewModel.selectDistrict(pin.district, in: pin.city)
                    }
                }
                .annotationTitles(.hidden)
            }
            // Featured venue POI pins (cityFocused state only)
            ForEach(viewModel.featuredPOIsForMap) { pin in
                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: pin.poi.latitude, longitude: pin.poi.longitude)) {
                    VenueMapPinView(poi: pin.poi) {
                        viewModel.selectVenuePOI(pin.poi, in: pin.district, city: pin.city)
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls { MapCompass(); MapScaleView() }
        .ignoresSafeArea()
        .opacity(viewModel.showingMap ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: viewModel.showingMap)
        .allowsHitTesting(viewModel.showingMap)
    }

    // MARK: - 3D scene layer

    @ViewBuilder
    private var sceneLayer: some View {
        if let district = viewModel.selectedDistrict {
            DistrictRealityView(
                districtName: district.id,
                mood: district.mood,
                isNightMode: viewModel.isNightMode,
                isAutoRotating: viewModel.isAutoRotating,
                rotationSpeed: viewModel.rotationSpeed,
                cameraResetToken: viewModel.cameraResetToken,
                onZoomBack: { viewModel.back() },
                onBuildingSelected: { viewModel.selectBuilding($0) },
                onPOISelected: { viewModel.selectPOIById($0, districtId: district.id) },
                venueTargetPOIId: viewModel.venueTargetPOIId,
                searchFlyToken: viewModel.searchFlyToken,
                searchFlyCentroid: viewModel.searchFlyCentroid,
                isElevated: viewModel.isElevated
            )
            .ignoresSafeArea()
            .opacity(viewModel.showingMap ? 0 : 1)
            .animation(.easeInOut(duration: 0.35), value: viewModel.showingMap)
            .allowsHitTesting(!viewModel.showingMap)
        }
    }

    // MARK: - Overlay layer

    private var overlayLayer: some View {
        Group {
            switch viewModel.state {
            case .worldMap:
                worldMapOverlay
            case .cityFocused(let city):
                cityFocusedOverlay(city: city)
            case .districtExplore(_, let district):
                districtExploreOverlay(district: district)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - worldMap overlay

    private var worldMapOverlay: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MetaCity")
                        .font(.metacityLargeTitle)
                        .foregroundStyle(Color.metacityTextPrimary)
                    Text("INDONESIA · \(viewModel.manifest.allCities.count) VILLES · \(viewModel.manifest.allDistricts.count) QUARTIERS 3D")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.metacityPrimary.opacity(0.8))
                        .tracking(0.8)
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            Spacer()
        }
    }

    // MARK: - cityFocused overlay

    private func cityFocusedOverlay(city: CityEntry) -> some View {
        VStack(alignment: .leading) {
            backButton
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
            Spacer()
            CityCalloutCard(
                city: city,
                onSelectDistrict: { district in viewModel.selectDistrict(district, in: city) },
                onEnterCity: { viewModel.enterCity(city) },
                onDismiss: { viewModel.back() }
            )
            .padding(Spacing.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - districtExplore overlay

    private func districtExploreOverlay(district: DistrictEntry) -> some View {
        VStack(spacing: 0) {
            // HUD header
            HStack {
                backButton
                Spacer()
                VStack(spacing: 1) {
                    Text(district.displayName.uppercased())
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(0.8)
                    Text(district.moodKey.uppercased())
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.metacityPrimary.opacity(0.8))
                        .tracking(1.2)
                }
                Spacer()
                Image(systemName: "arrow.left").opacity(0).frame(width: 36, height: 36)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { ScanLineView() }

            // Search bar
            DistrictSearchBar(query: $viewModel.districtSearchQuery)
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)

            // Autocomplete dropdown
            let results = viewModel.searchResults(in: district)
            if !viewModel.districtSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                DistrictSearchDropdown(results: results) { result in
                    viewModel.selectSearchResult(result)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, 4)
            }

            Spacer()

            // VenueCard
            if let poi = viewModel.selectedVenuePOI {
                HUDVenueCard(poi: poi, onDismiss: { viewModel.dismissVenue() })
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // BuildingInfoCard
            if let building = viewModel.selectedBuilding {
                HUDBuildingCard(building: building, onDismiss: { viewModel.clearSelectedBuilding() })
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            DistrictControlsPanel(viewModel: viewModel, district: district)
        }
    }

    // MARK: - Helpers

    private var districtPins: [DistrictPin] {
        viewModel.manifest.allCities.flatMap { city in
            city.districts.map { DistrictPin(city: city, district: $0) }
        }
    }

    private var backButton: some View {
        Button(action: viewModel.back) {
            Image(systemName: "arrow.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.metacityTextPrimary)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Back")
    }
}

// MARK: - City pin

private struct CityPinView: View {
    let city: CityEntry
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Image(uiImage: CityMarkerRenderer.image(for: city))
            .resizable()
            .frame(width: 44, height: 52)
            .scaleEffect(isSelected ? 1.25 : 1.0)
            .elevation(isSelected ? .raised : .soft)
            .onTapGesture(perform: onTap)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            .accessibilityLabel(city.displayName)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - District pin (map)

private struct DistrictPin: Identifiable {
    let city: CityEntry
    let district: DistrictEntry
    var id: String { district.id }
}

private struct DistrictPinView: View {
    let district: DistrictEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(moodColor.opacity(0.88))
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                Image(systemName: "building.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(district.displayName)
        .accessibilityAddTraits(.isButton)
    }

    private var moodColor: Color {
        switch district.moodKey {
        case "skyscraperCorridor": return Color(red: 0.20, green: 0.50, blue: 0.90)
        case "colonialSquare":     return Color(red: 0.85, green: 0.55, blue: 0.20)
        case "residentialDusk":    return Color(red: 0.80, green: 0.40, blue: 0.20)
        case "parkDaylight":       return Color(red: 0.20, green: 0.65, blue: 0.30)
        case "coastalPark":        return Color(red: 0.15, green: 0.65, blue: 0.70)
        case "beachResort":        return Color(red: 0.85, green: 0.65, blue: 0.25)
        case "sacredSite":         return Color(red: 0.55, green: 0.42, blue: 0.30)
        case "highlandMorning":    return Color(red: 0.40, green: 0.65, blue: 0.55)
        default:                   return Color.metacityPrimary
        }
    }
}

// MARK: - Venue map pin

private struct VenueMapPinView: View {
    let poi: CangguPOI
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(tierColor)
                    .frame(width: 24, height: 24)
                    .shadow(color: tierColor.opacity(0.55), radius: 3, y: 1)
                Image(systemName: poi.category.icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(poi.name) — open in 3D")
        .accessibilityAddTraits(.isButton)
    }

    private var tierColor: Color {
        poi.tier == .partner
            ? Color.metacityPrimary
            : Color(red: 0.95, green: 0.28, blue: 0.05)
    }
}

// MARK: - City map thumbnail (satellite cover image)

private struct CityMapThumbnailView: View {
    let city: CityEntry
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                // Placeholder gradient while snapshot loads
                LinearGradient(
                    colors: [
                        Color(UIColor(hex: city.markerColor) ?? .systemBlue).opacity(0.55),
                        Color.black.opacity(0.70)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            // Bottom gradient overlay so text on top is always readable
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: 100)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: Radius.card,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: Radius.card
        ))
        .task(id: city.id) {
            image = await CityThumbnailCache.shared.thumbnail(for: city)
        }
    }
}

// MARK: - City weather widget (compact live-data bar)

private struct CityWeatherWidget: View {
    let city: CityEntry
    @State private var weather: WeatherData? = nil

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let w = weather {
                Image(systemName: w.sfSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(UIColor(hex: w.accentColorHex) ?? .systemBlue))
                Text("\(Int(w.temperatureCelsius))°")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.metacityTextPrimary)
                Text(w.conditionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.metacityTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "wind")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.metacityTextTertiary)
                Text("\(Int(w.windSpeedKmh)) km/h")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.metacityTextSecondary)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.metacityTextTertiary.opacity(0.45))
                Image(systemName: "drop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.45, green: 0.70, blue: 1.0))
                Text("\(w.humidity)%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.metacityTextSecondary)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.metacityPrimary)
                Text("Météo en cours…")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.metacityTextTertiary)
                Spacer()
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 7)
        .background(Color.metacityPrimary.opacity(0.04))
        .task(id: city.id) {
            weather = await WeatherService.shared.weather(for: city)
        }
    }
}

// MARK: - City callout card (cityFocused — now shows district list inline)

private struct CityCalloutCard: View {
    let city: CityEntry
    let onSelectDistrict: (DistrictEntry) -> Void
    let onEnterCity: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Satellite cover thumbnail
            ZStack(alignment: .bottomLeading) {
                CityMapThumbnailView(city: city)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(city.displayName)
                            .font(.metacityTitle)
                            .foregroundStyle(.white)
                        Text(city.districts.isEmpty
                             ? "Données 3D en préparation"
                             : "\(city.districts.count) quartiers en 3D")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(city.districts.isEmpty
                                             ? .white.opacity(0.55)
                                             : Color.metacityPrimary)
                            .tracking(0.5)
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
                .padding(Spacing.md)
            }

            // Live weather strip
            CityWeatherWidget(city: city)
            Divider().padding(.horizontal, Spacing.md)

            if city.districts.isEmpty {
                // No 3D data yet
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(Color.metacityTextTertiary)
                    Text("3D disponible pour Jakarta, Bandung, Yogyakarta et Bali.")
                        .font(.metacityCaption)
                        .foregroundStyle(Color.metacityTextSecondary)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)
            } else {
                // District tiles — tap any to jump straight to 3D
                Divider().padding(.horizontal, Spacing.md)
                ForEach(city.districts) { district in
                    Button {
                        onSelectDistrict(district)
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Circle()
                                .fill(moodColor(for: district).opacity(0.80))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(district.displayName)
                                    .font(.metacityHeadline)
                                    .foregroundStyle(Color.metacityTextPrimary)
                                if let focus = district.focusBuildingName {
                                    Text(focus)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.metacityTextTertiary)
                                }
                            }
                            Spacer()
                            Image(systemName: "cube.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.metacityPrimary)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableScaleStyle())
                    if district.id != city.districts.last?.id {
                        Divider().padding(.horizontal, Spacing.md)
                    }
                }

                // "Voir tous" zooms in so district pins are visible
                Button(action: onEnterCity) {
                    HStack {
                        Image(systemName: "map.fill")
                            .font(.system(size: 12))
                        Text("Zoom sur les quartiers")
                            .font(.metacityCaption.weight(.semibold))
                    }
                    .foregroundStyle(Color.metacityPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.metacityPrimary.opacity(0.08))
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.metacityBorder, lineWidth: 1)
        )
        .elevation(.raised)
    }

    private func moodColor(for district: DistrictEntry) -> Color {
        switch district.moodKey {
        case "skyscraperCorridor": return Color(red: 0.20, green: 0.50, blue: 0.90)
        case "colonialSquare":     return Color(red: 0.85, green: 0.55, blue: 0.20)
        case "residentialDusk":    return Color(red: 0.80, green: 0.40, blue: 0.20)
        case "parkDaylight":       return Color(red: 0.20, green: 0.65, blue: 0.30)
        case "coastalPark":        return Color(red: 0.15, green: 0.65, blue: 0.70)
        case "beachResort":        return Color(red: 0.85, green: 0.65, blue: 0.25)
        case "sacredSite":         return Color(red: 0.55, green: 0.42, blue: 0.30)
        case "highlandMorning":    return Color(red: 0.40, green: 0.65, blue: 0.55)
        default:                   return Color.metacityPrimary
        }
    }
}

// MARK: - District controls panel

private struct DistrictControlsPanel: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let district: DistrictEntry

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            VStack(spacing: 2) {
                Toggle("", isOn: $viewModel.isNightMode)
                    .labelsHidden()
                    .tint(Color.metacityPrimary)
                Text("Night")
                    .font(.metacityCaption)
                    .foregroundStyle(Color.metacityTextSecondary)
            }

            VStack(spacing: 2) {
                Toggle("", isOn: $viewModel.isAutoRotating)
                    .labelsHidden()
                    .tint(Color.metacityPrimary)
                Text("Rotate")
                    .font(.metacityCaption)
                    .foregroundStyle(Color.metacityTextSecondary)
            }

            Spacer()

            Button { viewModel.isElevated.toggle() } label: {
                Label(viewModel.isElevated ? "Close" : "Overview",
                      systemImage: viewModel.isElevated ? "location.viewfinder" : "eye")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(viewModel.isElevated ? Color.metacityPrimary : Color.metacityTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        (viewModel.isElevated ? Color.metacityPrimary.opacity(0.12) : Color.metacitySurface.opacity(0.8)),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isElevated)

            Button { viewModel.resetCamera() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(Color.metacityTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.metacitySurface.opacity(0.8), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.metacitySeparator).frame(height: 1)
        }
    }
}

// MARK: - HUD Building card (futuristic doc style)

private struct HUDBuildingCard: View {
    let building: BuildingFootprint
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tag line
            HStack(spacing: 6) {
                Image(systemName: building.style.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(building.style.displayName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .tracking(1.2)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.metacityTextTertiary)
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Name
            Text(building.name ?? building.style.displayName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)

            // Data grid
            HStack(spacing: 0) {
                dataCell(label: "HAUTEUR", value: building.isHeightEstimated
                         ? "~\(Int(building.heightMeters))m" : "\(Int(building.heightMeters))m")
                dataDivider
                dataCell(label: "STATUT", value: building.isHeightEstimated ? "ESTIMÉ" : "RÉEL")
                dataDivider
                dataCell(label: "OSM ID", value: String(building.osmID.prefix(8)))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)

        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.26), accentColor.opacity(0.32)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 16))
                p.addLine(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 16, y: 0))
            }
            .stroke(accentColor, lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            Path { p in
                p.move(to: CGPoint(x: 16, y: 0))
                p.addLine(to: CGPoint(x: 16, y: 16))
                p.addLine(to: CGPoint(x: 0, y: 16))
            }
            .stroke(accentColor.opacity(0.5), lineWidth: 1)
            .frame(width: 16, height: 16)
            .padding(6)
        }
        .shadow(color: accentColor.opacity(0.22), radius: 20, y: 6)
    }

    private var accentColor: Color {
        switch building.style {
        case .modernGlass:    return Color(red: 0.35, green: 0.75, blue: 1.0)
        case .modernConcrete: return Color(red: 0.60, green: 0.65, blue: 0.70)
        case .colonial:       return Color(red: 0.95, green: 0.72, blue: 0.38)
        case .government:     return Color(red: 0.80, green: 0.80, blue: 0.88)
        case .religious:      return Color(red: 0.90, green: 0.85, blue: 0.40)
        case .balinese:       return Color(red: 0.90, green: 0.60, blue: 0.32)
        case .javanese:       return Color(red: 0.75, green: 0.55, blue: 0.30)
        }
    }

    @ViewBuilder
    private func dataCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.40))
                .tracking(0.8)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dataDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 4)
    }
}

// MARK: - HUD Venue card (futuristic POI doc)

private struct HUDVenueCard: View {
    let poi: CangguPOI
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tag strip
            HStack(spacing: 6) {
                Image(systemName: poi.category.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tierAccent)
                Text(poi.category.displayName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(tierAccent)
                    .tracking(1.2)
                if poi.tier == .featured {
                    Text("·")
                        .foregroundStyle(Color.white.opacity(0.30))
                    Text("FEATURED")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(tierAccent)
                        .tracking(1.0)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.metacityTextTertiary)
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Name
            Text(poi.name)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)

            // Description
            Text(poi.description)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.60))
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 10)

            if let url = poi.partnerURL, let dest = URL(string: url) {
                Link(destination: dest) {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                            .font(.system(size: 11))
                        Text("SITE OFFICIEL")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                    }
                    .foregroundStyle(tierAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(tierAccent.opacity(0.10))
                }
                .buttonStyle(.plain)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), tierAccent.opacity(0.30)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 16))
                p.addLine(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 16, y: 0))
            }
            .stroke(tierAccent, lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .padding(6)
        }
        .shadow(color: tierAccent.opacity(0.25), radius: 20, y: 6)
    }

    private var tierAccent: Color {
        switch poi.tier {
        case .standard: return Color(red: 0.95, green: 0.75, blue: 0.20)
        case .featured: return Color(red: 0.20, green: 0.82, blue: 0.65)
        case .partner:  return Color.metacityPrimary
        }
    }
}

// MARK: - District search bar (Liquid Glass style)

private struct DistrictSearchBar: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(isFocused ? 0.9 : 0.55))

            TextField("", text: $query, prompt: Text("Rechercher un bâtiment ou lieu…")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.45))
            )
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.white)
            .autocorrectionDisabled()
            .focused($isFocused)
            .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                    isFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            isFocused
                                ? Color.metacityPrimary.opacity(0.6)
                                : Color.white.opacity(0.15),
                            lineWidth: 1
                        )
                )
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
    }
}

private struct DistrictSearchDropdown: View {
    let results: [DistrictSearchResult]
    let onSelect: (DistrictSearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Aucun résultat")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.vertical, Spacing.sm)
                .padding(.horizontal, Spacing.md)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                    if idx > 0 {
                        Divider()
                            .background(Color.white.opacity(0.10))
                            .padding(.leading, 44)
                    }
                    Button { onSelect(result) } label: {
                        HStack(spacing: Spacing.sm) {
                            ZStack {
                                Circle()
                                    .fill(iconColor(for: result).opacity(0.18))
                                    .frame(width: 28, height: 28)
                                Image(systemName: iconName(for: result))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(iconColor(for: result))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let sub = result.subtitle {
                                    Text(sub)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.30))
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, Spacing.md)
                    }
                    .buttonStyle(PressableScaleStyle())
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.18), value: results.count)
    }

    private func iconName(for result: DistrictSearchResult) -> String {
        switch result.kind {
        case .building: return "cube.fill"
        case .poi: return "mappin.fill"
        }
    }

    private func iconColor(for result: DistrictSearchResult) -> Color {
        switch result.kind {
        case .building: return Color.metacityPrimary
        case .poi: return Color.orange
        }
    }
}

// MARK: - HUD scan-line effect

/// Sweeping translucent cyan stripe that crosses the district HUD header left→right every 3.5s.
/// Drawn via `TimelineView` at 20fps so it's animated without burning GPU time at 60fps.
private struct ScanLineView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { tl in
            GeometryReader { geo in
                let period: Double = 3.5
                let t    = CGFloat(tl.date.timeIntervalSinceReferenceDate
                                        .truncatingRemainder(dividingBy: period) / period)
                let barW = geo.size.width * 0.28
                let x    = t * (geo.size.width + barW) - barW
                LinearGradient(
                    colors: [.clear,
                             Color(red: 0.20, green: 0.88, blue: 1.00).opacity(0.16),
                             .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: barW, height: geo.size.height)
                .offset(x: x)
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }
}

#Preview {
    DiscoverView(viewModel: DiscoverViewModel())
}
