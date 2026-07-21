import MapKit
import RealityKit
import SwiftUI

/// Unified spatial surface: Map → city focus → district 3D.
/// The `cityExplore` state (CityOverviewView + district list page) has been removed.
/// Districts are tappable directly from the map via `` annotations at any zoom.
/// State machine: worldMap ↔ cityFocused ↔ districtExplore.
struct DiscoverView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    /// Briefly flashes to black on district transitions for a "warp to location" travel feel.
    @State private var transitionFlash: Double = 0
    @StateObject private var speechManager = SpeechSearchManager()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            mapLayer
            sceneLayer
            // Travel flash overlay — brief white-flash (not black) on map→district transitions
            // Softer than the previous 0.82 black: a near-instant 0.22 opacity dip reads as
            // a "warp" cut without obscuring the 3D scene for a distracting half-second.
            Color.black
                .opacity(transitionFlash)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.18), value: transitionFlash)
            overlayLayer
        }
        .onChange(of: viewModel.showingMap) { _, isNowShowingMap in
            if !isNowShowingMap {
                // Soft warp flash — 0.22 opacity (down from 0.82), clears in 0.18s
                transitionFlash = 0.22
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.18)) { transitionFlash = 0 }
                }
            }
        }
    }

    // MARK: - Map layer

    private var mapLayer: some View {
        Map(position: $viewModel.cameraPosition) {
            // City pins
            ForEach(viewModel.visibleCities) { city in
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
                isAutoRotating: viewModel.isAutoRotating,
                rotationSpeed: viewModel.rotationSpeed,
                cameraResetToken: viewModel.cameraResetToken,
                buildingOrbitToken: viewModel.buildingOrbitToken,
                onZoomBack: { viewModel.back() },
                onBuildingSelected: { viewModel.selectBuilding($0) },
                onPOISelected: { viewModel.selectPOIById($0, districtId: district.id) },
                venueTargetPOIId: viewModel.venueTargetPOIId,
                searchFlyToken: viewModel.searchFlyToken,
                searchFlyCentroid: viewModel.searchFlyCentroid,
                poiFocusToken: viewModel.poiFocusToken,
                selectedBuilding: viewModel.selectedBuilding,
                activeViewPreset: viewModel.activeViewPreset,
                isNight: false
            )
            .id(district.id)    // forces coordinator recreation when district changes
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
            case .districtExplore(let city, let district):
                districtExploreOverlay(city: city, district: district)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - worldMap overlay

    private var worldMapOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MetaCity")
                        .font(.metacityLargeTitle)
                        .foregroundStyle(Color.metacityTextPrimary)
                    Text("\(viewModel.visibleCities.count) VILLES · \(viewModel.manifest.allDistricts.filter(\.dataBundled).count) QUARTIERS 3D")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.metacityPrimary.opacity(0.8))
                        .tracking(0.8)
                }
                Spacer()
                // Globe — returns to world map
                EarthGlobeButton(onTap: { viewModel.resetToWorldMap() })
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)

            globalSearchBar
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)

            if viewModel.isGlobalSearchActive && !viewModel.globalSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                GlobalSearchDropdown(
                    instantCities: viewModel.instantCityResults,
                    districtResults: viewModel.globalDistrictResults,
                    placeResults: viewModel.globalPlaceResults,
                    worldSuggestions: viewModel.worldCitySuggestions,
                    onSelect: { viewModel.selectGlobalSearchResult($0) },
                    onSelectSuggestion: { viewModel.selectWorldCitySuggestion($0) }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.top, 4)
            }

            Spacer()
        }
    }

    // MARK: - cityFocused overlay

    private func cityFocusedOverlay(city: CityEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Unified navbar — matches districtExploreOverlay layout
            HStack(spacing: Spacing.sm) {
                backButton
                globalSearchBar
                EarthGlobeButton(onTap: { viewModel.resetToWorldMap() })
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { ScanLineView() }

            if viewModel.isGlobalSearchActive && !viewModel.globalSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                GlobalSearchDropdown(
                    instantCities: viewModel.instantCityResults,
                    districtResults: viewModel.globalDistrictResults,
                    placeResults: viewModel.globalPlaceResults,
                    worldSuggestions: viewModel.worldCitySuggestions,
                    onSelect: { viewModel.selectGlobalSearchResult($0) },
                    onSelectSuggestion: { viewModel.selectWorldCitySuggestion($0) }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.top, 4)
            }

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

    // MARK: - Global search bar

    private var globalSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.metacityTextSecondary)

            TextField("Rechercher villes, quartiers, lieux…", text: $viewModel.globalSearchQuery)
                .font(.system(size: 14))
                .foregroundStyle(Color.metacityTextPrimary)
                .tint(Color.metacityPrimary)
                .onTapGesture { viewModel.isGlobalSearchActive = true }
                .onChange(of: viewModel.globalSearchQuery) { _, new in
                    if !new.isEmpty { viewModel.isGlobalSearchActive = true }
                }
                .submitLabel(.search)
                .onSubmit {
                    let results = viewModel.globalSearchResults()
                    if let first = results.first { viewModel.selectGlobalSearchResult(first) }
                }

            if viewModel.isListening {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.metacityPrimary)
                    .symbolEffect(.pulse)
            }

            if !viewModel.globalSearchQuery.isEmpty {
                Button {
                    viewModel.globalSearchQuery = ""
                    viewModel.isGlobalSearchActive = false
                    viewModel.isListening = false
                    speechManager.stopListening()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.metacityTextTertiary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if viewModel.isListening {
                        viewModel.isListening = false
                        speechManager.stopListening()
                    } else {
                        viewModel.isListening = true
                        viewModel.isGlobalSearchActive = true
                        speechManager.startListening(text: $viewModel.globalSearchQuery) {
                            viewModel.isListening = false
                        }
                    }
                } label: {
                    Image(systemName: viewModel.isListening ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(viewModel.isListening
                            ? Color.metacityPrimary
                            : Color.metacityTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    viewModel.isGlobalSearchActive
                        ? Color.metacityPrimary.opacity(0.45)
                        : Color.white.opacity(0.12),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .animation(.easeInOut(duration: 0.18), value: viewModel.isGlobalSearchActive)
    }

    // MARK: - districtExplore overlay

    private func districtExploreOverlay(city: CityEntry, district: DistrictEntry) -> some View {
        VStack(spacing: 0) {
            // Unified nav row: back | search bar | globe
            HStack(spacing: Spacing.sm) {
                backButton
                DistrictSearchBar(query: $viewModel.districtSearchQuery)
                EarthGlobeButton(onTap: { viewModel.resetToWorldMap() })
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { ScanLineView() }

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

            // Floating mini-map — hidden when a venue card is open
            let hasCard = viewModel.selectedVenuePOI != nil
            if !hasCard {
                HStack {
                    Spacer()
                    DistrictMiniMapView(
                        district: district,
                        activePreset: viewModel.activeViewPreset,
                        onPresetChange: { viewModel.setViewPreset($0) },
                        onPOISelected: { viewModel.selectPOIById($0, districtId: district.id) }
                    )
                    .padding(.trailing, Spacing.lg)
                    .padding(.bottom, Spacing.sm)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .animation(.easeInOut(duration: 0.22), value: hasCard)
            }

            // VenueCard
            if let poi = viewModel.selectedVenuePOI {
                HUDVenueCard(poi: poi, onDismiss: { viewModel.dismissVenue() })
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        }
    }

    // MARK: - Helpers

    private var districtPins: [DistrictPin] {
        viewModel.visibleCities.flatMap { city in
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

// MARK: - District tab bar

/// Horizontal scroll of bundled districts for the current city.
/// Each tab shows the district name, an active-indicator capsule, and a visited-status dot.
/// Tapping a district that is already selected is a no-op (prevent accidental reloads).
private struct DistrictTabBar: View {
    let city: CityEntry
    let selectedDistrictId: String
    let onSelect: (DistrictEntry) -> Void

    @State private var visitedIds: Set<String> = []

    private var bundled: [DistrictEntry] { city.districts.filter(\.dataBundled) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(bundled) { district in
                        Button {
                            guard district.id != selectedDistrictId else { return }
                            onSelect(district)
                        } label: {
                            let isActive  = district.id == selectedDistrictId
                            let isVisited = visitedIds.contains(district.id)
                            VStack(spacing: 2) {
                                // Visited dot — above the label, subtle
                                Circle()
                                    .fill(isVisited
                                          ? Color.metacityNeonCyan.opacity(isActive ? 1.0 : 0.55)
                                          : Color.white.opacity(0.18))
                                    .frame(width: 4, height: 4)
                                Text(district.displayName.uppercased())
                                    .font(.system(size: 10, weight: isActive ? .bold : .medium,
                                                  design: .monospaced))
                                    .foregroundStyle(isActive
                                        ? Color.metacityNeonCyan
                                        : Color.white.opacity(0.55))
                                    .tracking(0.6)
                                    .lineLimit(1)
                                // Active indicator bar
                                Capsule()
                                    .fill(isActive ? Color.metacityNeonCyan : Color.clear)
                                    .frame(height: 2)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .id(district.id)
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.18), value: selectedDistrictId)
                    }
                }
                .padding(.horizontal, Spacing.lg)
            }
            .background {
                Color.black.opacity(0.62)
                    .overlay(Color.metacityNeonCyan.opacity(0.03))
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.5)
            }
            .frame(height: 46)
            .onChange(of: selectedDistrictId) { _, newId in
                withAnimation { proxy.scrollTo(newId, anchor: .center) }
                refreshVisited()
            }
            .onAppear {
                proxy.scrollTo(selectedDistrictId, anchor: .center)
                refreshVisited()
            }
        }
    }

    private func refreshVisited() {
        var ids = Set<String>()
        for d in bundled where UserDefaults.standard.bool(forKey: "reveal_\(d.id)") {
            ids.insert(d.id)
        }
        visitedIds = ids
    }
}

// MARK: - District reveal overlay

/// Full-width bottom overlay that slides in on a district's first visit, showing
/// key stats for 3.5s then auto-dismisses. One-time per district (UserDefaults key).
private struct DistrictRevealOverlay: View {
    let context: DistrictRevealContext
    let onDismiss: () -> Void

    @State private var progress: CGFloat = 1.0   // drains 1→0 over 3.5s
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                // Mood-tinted drain bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.06)
                        moodAccentColor
                            .frame(width: geo.size.width * progress)
                            .shadow(color: moodAccentColor.opacity(0.5), radius: 4, y: 0)
                    }
                }
                .frame(height: 2)

                VStack(alignment: .leading, spacing: 12) {
                    // Header row: city tag + dismiss
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            // City name row with mood accent dot
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(moodAccentColor)
                                    .frame(width: 4, height: 4)
                                Text(context.city.displayName.uppercased())
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(moodAccentColor)
                                    .tracking(3)
                            }
                            Text(context.district.displayName)
                                .font(.system(size: 26, weight: .black, design: .default))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            // Architecture period tag
                            Text(architectureTag)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.42))
                                .tracking(1.2)
                        }
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.08), in: Circle())
                        }
                    }

                    // Stats row with mood-accented stat values
                    HStack(spacing: Spacing.lg) {
                        if context.buildingCount > 0 {
                            RevealStat(label: "BÂTIMENTS", value: "\(context.buildingCount)", accent: moodAccentColor)
                            RevealStat(label: "ROUTES",    value: "\(context.roadCount)",      accent: moodAccentColor)
                        }
                        RevealStat(label: "AMBIANCE", value: moodLabel, accent: moodAccentColor)
                        if context.activityCount > 0 {
                            RevealStat(label: "ACTIVITÉS", value: "\(context.activityCount)", accent: moodAccentColor)
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, 16)
                // Dark glassmorphism background: near-opaque black + material blur
                .background {
                    ZStack {
                        Color.black.opacity(0.82)
                        Rectangle().fill(.ultraThinMaterial).opacity(0.35)
                    }
                }
            }
            .offset(y: appeared ? 0 : 60)
            .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.80)) { appeared = true }
            withAnimation(.linear(duration: 3.5)) { progress = 0 }
        }
    }

    // MARK: - Mood accent color — per city/mood identity

    private var moodAccentColor: Color {
        switch context.district.moodKey {
        case "shibuyaNeon":        return Color(red: 0.00, green: 0.95, blue: 0.82)   // neon cyan — Tokyo
        case "nycDusk":            return Color(red: 0.68, green: 0.48, blue: 0.98)   // Manhattan purple
        case "parisianCore":       return Color(red: 0.92, green: 0.80, blue: 0.44)   // Parisian gold
        case "bordeauxWaterfront": return Color(red: 0.95, green: 0.56, blue: 0.22)   // Garonne amber
        case "rennesMedieval":     return Color(red: 0.58, green: 0.72, blue: 0.86)   // Breton slate blue
        case "londonSilver":       return Color(red: 0.68, green: 0.74, blue: 0.84)   // London silver
        case "madridAfternoon":    return Color(red: 0.98, green: 0.70, blue: 0.18)   // Iberian gold
        case "romanGoldenHour":    return Color(red: 0.98, green: 0.52, blue: 0.20)   // Roman sienna
        case "laSunset":           return Color(red: 1.00, green: 0.56, blue: 0.22)   // Pacific sunset
        case "vancouverCoastal":   return Color(red: 0.22, green: 0.76, blue: 0.90)   // Pacific teal
        case "sfMorning":          return Color(red: 0.96, green: 0.78, blue: 0.38)   // California morning
        case "skyscraperCorridor": return Color(red: 0.20, green: 0.66, blue: 1.00)   // SCBD neon blue
        case "beachResort":        return Color(red: 0.22, green: 0.92, blue: 0.74)   // tropical aqua
        case "sacredSite":         return Color(red: 0.88, green: 0.66, blue: 0.30)   // temple gold
        case "colonialSquare":     return Color(red: 0.88, green: 0.48, blue: 0.24)   // terracotta
        default:                   return Color.metacityPrimary
        }
    }

    // MARK: - Mood display label

    private var moodLabel: String {
        switch context.district.moodKey {
        case "skyscraperCorridor": return "SKYLINE"
        case "parisianCore":       return "PARIS"
        case "bordeauxWaterfront": return "WATERFRONT"
        case "londonSilver":       return "LONDON"
        case "madridAfternoon":    return "GOLDEN HR"
        case "romanGoldenHour":    return "ROME"
        case "shibuyaNeon":        return "NEON"
        case "laSunset":           return "SUNSET"
        case "nycDusk":            return "DUSK"
        case "vancouverCoastal":   return "COASTAL"
        case "sfMorning":          return "MORNING"
        case "beachResort":        return "RESORT"
        case "sacredSite":         return "SACRÉ"
        case "colonialSquare":     return "COLONIAL"
        case "rennesMedieval":     return "MÉDIÉVAL"
        default:                   return context.district.moodKey.uppercased()
        }
    }

    // MARK: - Architecture period string derived from mood key

    private var architectureTag: String {
        switch context.district.moodKey {
        case "parisianCore":       return "PIERRE DE LUTÈCE · HAUSSMANN 1853–1927"
        case "bordeauxWaterfront": return "CALCAIRE GIRONDIN · PORT DE LA LUNE XVIIIe"
        case "rennesMedieval":     return "MI-BOIS BRETON · XIIe–XVe SIÈCLE"
        case "londonSilver":       return "BRIQUE LONDONIENNE · ÈRE VICTORIENNE"
        case "madridAfternoon":    return "PIERRE ENSANCHE · 1860–1936"
        case "romanGoldenHour":    return "TUFFEAU ROMAIN · Ier–XVIIIe SIÈCLE"
        case "shibuyaNeon":        return "BÉTON & VERRE · POST-1964"
        case "laSunset":           return "BÉTON MODERNE · SOCAL 1950–"
        case "nycDusk":            return "BRIQUE PRÉ-GUERRE · 1890–1940"
        case "vancouverCoastal":   return "VERRE PACIFIQUE · POST-1980"
        case "sfMorning":          return "BÉTON FINANCIER · POST-1960"
        case "skyscraperCorridor": return "VERRE & ACIER · SCBD JAKARTA"
        case "beachResort":        return "PIERRE VOLCANIQUE · TRADITION BALINAISE"
        case "sacredSite":         return "PIERRE DE JAVA · TRADITION KRATON"
        case "colonialSquare":     return "COLONIAL NÉERLANDAIS · 1619–1942"
        default:                   return "DONNÉES OSM RÉELLES · METACITY"
        }
    }
}

private struct RevealStat: View {
    let label: String
    let value: String
    var accent: Color = Color.metacityPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.38))
                .tracking(1.5)
            Text(value)
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundStyle(accent)
        }
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
        case "parisianCore":       return Color(red: 0.62, green: 0.68, blue: 0.82)
        case "bordeauxWaterfront": return Color(red: 0.88, green: 0.64, blue: 0.28)
        case "rennesMedieval":     return Color(red: 0.50, green: 0.52, blue: 0.58)
        case "londonSilver":       return Color(red: 0.58, green: 0.62, blue: 0.72)
        case "madridAfternoon":    return Color(red: 0.92, green: 0.68, blue: 0.28)
        case "romanGoldenHour":    return Color(red: 0.88, green: 0.54, blue: 0.24)
        case "shibuyaNeon":        return Color(red: 0.10, green: 0.82, blue: 0.92)
        case "laSunset":           return Color(red: 0.96, green: 0.62, blue: 0.24)
        case "nycDusk":            return Color(red: 0.92, green: 0.56, blue: 0.18)
        case "vancouverCoastal":   return Color(red: 0.48, green: 0.72, blue: 0.90)
        case "sfMorning":          return Color(red: 0.90, green: 0.74, blue: 0.50)
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

// MARK: - Featured activities strip (inside CityCalloutCard)

private struct FeaturedActivitiesStrip: View {
    let activities: [ActivityEntry]

    private func icon(for category: ActivityCategory) -> String {
        switch category {
        case .panorama:           return "binoculars.fill"
        case .experienceRA:       return "arkit"
        case .immersionSensorielle: return "headphones"
        case .visiteGuidee:       return "map.fill"
        case .lifestyle:          return "sparkles"
        case .eat:                return "fork.knife"
        case .stay:               return "bed.double.fill"
        case .explore:            return "location.fill"
        case .nightlife:          return "moon.stars.fill"
        case .wellness:           return "heart.fill"
        case .shopping:           return "bag.fill"
        case .sport:              return "figure.run"
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(activities) { activity in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: activity.category))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.metacityPrimary)
                        Text(activity.name)
                            .font(.system(size: 11, weight: .medium, design: .default))
                            .foregroundStyle(Color.metacityTextPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.metacityPrimary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Top places strip (inside CityCalloutCard)

private struct TopPlacesStrip: View {
    let places: [PlaceEntry]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(places) { place in
                    HStack(spacing: 6) {
                        Image(systemName: place.type.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.metacityPrimary.opacity(0.80))
                        Text(place.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.metacityTextPrimary)
                            .lineLimit(1)
                        if let price = place.priceRange {
                            Text(price)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.metacityTextTertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.metacityPrimary.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.metacityPrimary.opacity(0.15), lineWidth: 0.5)
                            )
                    )
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - City callout card

private struct CityCalloutCard: View {
    let city: CityEntry
    let onSelectDistrict: (DistrictEntry) -> Void
    let onEnterCity: () -> Void
    let onDismiss: () -> Void

    @State private var featuredActivities: [ActivityEntry] = []
    @State private var featuredPlaces: [PlaceEntry] = []

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

            // Featured activities strip (premium, up to 3)
            if !featuredActivities.isEmpty {
                FeaturedActivitiesStrip(activities: featuredActivities)
                Divider().padding(.horizontal, Spacing.md)
            }

            // Featured places strip (up to 3 isFeatured places from static JSON)
            if !featuredPlaces.isEmpty {
                TopPlacesStrip(places: featuredPlaces)
                Divider().padding(.horizontal, Spacing.md)
            }

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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.metacityPrimary.opacity(0.20)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        .task(id: city.id) {
            // Load up to 3 premium activities for this city (city-level file + per-district files).
            var all = CityActivities.load(for: city.id)
            for district in city.districts {
                let extra = CityActivities.load(for: district.id.lowercased())
                let seen = Set(all.map(\.id))
                all += extra.filter { !seen.contains($0.id) }
            }
            featuredActivities = Array(all.filter { $0.tier == .premium }.prefix(3))
            // Load top 3 featured places from static bundle (no network needed).
            featuredPlaces = Array(CityPlaces.load(for: city.id).filter(\.isFeatured).prefix(3))
        }
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
        case "parisianCore":       return Color(red: 0.62, green: 0.68, blue: 0.82)
        case "bordeauxWaterfront": return Color(red: 0.88, green: 0.64, blue: 0.28)
        case "rennesMedieval":     return Color(red: 0.50, green: 0.52, blue: 0.58)
        case "londonSilver":       return Color(red: 0.58, green: 0.62, blue: 0.72)
        case "madridAfternoon":    return Color(red: 0.92, green: 0.68, blue: 0.28)
        case "romanGoldenHour":    return Color(red: 0.88, green: 0.54, blue: 0.24)
        case "shibuyaNeon":        return Color(red: 0.10, green: 0.82, blue: 0.92)
        case "laSunset":           return Color(red: 0.96, green: 0.62, blue: 0.24)
        case "nycDusk":            return Color(red: 0.92, green: 0.56, blue: 0.18)
        case "vancouverCoastal":   return Color(red: 0.48, green: 0.72, blue: 0.90)
        case "sfMorning":          return Color(red: 0.90, green: 0.74, blue: 0.50)
        default:                   return Color.metacityPrimary
        }
    }
}

// MARK: - HUD Building card (futuristic doc style)

private struct HUDBuildingCard: View {
    let building: BuildingFootprint
    let onDismiss: () -> Void
    let onOrbit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tag strip: style icon + label + era + dismiss
            HStack(spacing: 6) {
                Image(systemName: building.style.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(building.style.displayName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .tracking(1.2)
                Text("·")
                    .font(.system(size: 9, weight: .light, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.30))
                Text(architectureEra)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .tracking(0.6)
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
            .padding(.bottom, 5)

            // Building name
            Text(building.name ?? building.style.displayName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)

            // Material / style description line
            Text(styleDescription)
                .font(.system(size: 10, weight: .regular, design: .default))
                .foregroundStyle(Color.white.opacity(0.52))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 3)

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

            // Return to overview
            Divider()
                .padding(.horizontal, 14)
            Button(action: onOrbit) {
                HStack(spacing: 6) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("VUE QUARTIER")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                }
                .foregroundStyle(accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(accentColor.opacity(0.08))
            }
            .buttonStyle(.plain)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.80))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.22))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), accentColor.opacity(0.40)],
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
            .stroke(accentColor.opacity(0.60), lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .padding(6)
        }
        .shadow(color: accentColor.opacity(0.28), radius: 24, y: 8)
    }

    private var accentColor: Color {
        switch building.style {
        case .modernGlass:         return Color(red: 0.35, green: 0.75, blue: 1.0)
        case .modernConcrete:      return Color(red: 0.60, green: 0.65, blue: 0.70)
        case .colonial:            return Color(red: 0.95, green: 0.72, blue: 0.38)
        case .government:          return Color(red: 0.80, green: 0.80, blue: 0.88)
        case .religious:           return Color(red: 0.90, green: 0.85, blue: 0.40)
        case .balinese:            return Color(red: 0.90, green: 0.60, blue: 0.32)
        case .javanese:            return Color(red: 0.75, green: 0.55, blue: 0.30)
        case .haussmannien:        return Color(red: 0.92, green: 0.88, blue: 0.72)
        case .medieval:            return Color(red: 0.80, green: 0.72, blue: 0.58)
        case .bordelaisClassical:  return Color(red: 0.95, green: 0.80, blue: 0.42)
        case .londonBrick:         return Color(red: 0.76, green: 0.60, blue: 0.42)
        case .madrileño:           return Color(red: 0.88, green: 0.78, blue: 0.42)
        case .romanOchre:          return Color(red: 0.78, green: 0.58, blue: 0.32)
        case .nycBrick:            return Color(red: 0.72, green: 0.38, blue: 0.28)
        case .laStucco:            return Color(red: 0.92, green: 0.80, blue: 0.52)
        }
    }

    private var architectureEra: String {
        switch building.style {
        case .modernGlass:         return "XXe–XXIe"
        case .modernConcrete:      return "1950–2000"
        case .colonial:            return "1880–1942"
        case .government:          return "CIVIC"
        case .religious:           return "PATRIMOINE"
        case .balinese:            return "VERNACULAIRE"
        case .javanese:            return "VERNACULAIRE"
        case .haussmannien:        return "1853–1927"
        case .medieval:            return "XIe–XVe"
        case .bordelaisClassical:  return "XVIIe–XIXe"
        case .londonBrick:         return "1714–1914"
        case .madrileño:           return "1860–1930"
        case .romanOchre:          return "Ier–XVIIe"
        case .nycBrick:            return "1880–1940"
        case .laStucco:            return "1900–1960"
        }
    }

    private var styleDescription: String {
        switch building.style {
        case .modernGlass:         return "Rideau de verre · PBR clearcoat 0.28"
        case .modernConcrete:      return "Béton armé · voiles préfabriqués"
        case .colonial:            return "Enduit chaux · stijl colonial néerlandais"
        case .government:          return "Architecture civique · pierre de taille"
        case .religious:           return "Architecture sacrée · dôme / campanile"
        case .balinese:            return "Tuf volcanique · pierre de Paras"
        case .javanese:            return "Bois de teck · joglo traditionnel"
        case .haussmannien:        return "Calcaire lutetian · balcons Second Empire"
        case .medieval:            return "Granit breton · colombages plâtre"
        case .bordelaisClassical:  return "Calcaire à astéries · toiture canal"
        case .londonBrick:         return "London stock brick · ardoise galloise"
        case .madrileño:           return "Calcaire / grès Madrid · azotea plate"
        case .romanOchre:          return "Tuf / brique romaine · tuiles coppo"
        case .nycBrick:            return "Brique d'argile cuite · ardoise NY"
        case .laStucco:            return "Stuc Mission · tuile barrel espagnole"
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
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.80))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.22))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), tierAccent.opacity(0.40)],
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
        .overlay(alignment: .bottomTrailing) {
            Path { p in
                p.move(to: CGPoint(x: 16, y: 0))
                p.addLine(to: CGPoint(x: 16, y: 16))
                p.addLine(to: CGPoint(x: 0, y: 16))
            }
            .stroke(tierAccent.opacity(0.60), lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .padding(6)
        }
        .shadow(color: tierAccent.opacity(0.30), radius: 24, y: 8)
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

// MARK: - District mini-map widget

/// Interactive MapKit overview that floats bottom-right in the district explore view.
/// Shows satellite imagery of the district extent with a glowing anchor dot.
/// Hides automatically when a VenueCard or BuildingInfoCard is visible.
private struct DistrictMiniMapView: View {
    let district: DistrictEntry
    var activePreset: ViewPreset = .overview
    var onPresetChange: ((ViewPreset) -> Void)? = nil
    var onPOISelected: ((String) -> Void)? = nil

    @State private var camera: MapCameraPosition
    @State private var pulse: CGFloat = 0
    @State private var isExpanded: Bool = true   // open by default so presets are immediately visible

    init(district: DistrictEntry,
         activePreset: ViewPreset = .overview,
         onPresetChange: ((ViewPreset) -> Void)? = nil,
         onPOISelected: ((String) -> Void)? = nil) {
        self.district = district
        self.activePreset = activePreset
        self.onPresetChange = onPresetChange
        self.onPOISelected = onPOISelected
        let b = district.boundingBox
        let latSpan = b.north - b.south
        let lonSpan = b.east  - b.west
        let avgLat  = (b.north + b.south) / 2
        let metersLat = 111_320.0
        let metersLon = metersLat * cos(avgLat * .pi / 180)
        let span  = max(latSpan * metersLat, lonSpan * metersLon)
        let dist  = max(span * 1.5, 700)
        _camera = State(initialValue: .camera(
            MapCamera(centerCoordinate: district.anchor.clLocationCoordinate,
                      distance: dist, heading: 0, pitch: 0)
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top info bar: district name + mood label + expand toggle
            HStack(spacing: 5) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 4, height: 4)
                Text(district.displayName.uppercased())
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .tracking(1.0)
                    .lineLimit(1)
                Spacer()
                Text(moodLabel)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .tracking(0.8)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(accentColor.opacity(0.60))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.78))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.70)) {
                    isExpanded.toggle()
                }
            }

            // Body: POI list in POI mode, satellite map otherwise
            if activePreset == .focus {
                MiniPOIListView(
                    districtId: district.id,
                    accentColor: accentColor,
                    onPOISelected: onPOISelected
                )
                .frame(height: isExpanded ? 210 : 155)
            } else {
                Map(position: $camera) {
                    Annotation("", coordinate: district.anchor.clLocationCoordinate, anchor: .center) {
                        ZStack {
                            Circle()
                                .stroke(accentColor.opacity(0.35 * (1 - pulse)), lineWidth: 1.5)
                                .frame(width: 22 + pulse * 14, height: 22 + pulse * 14)
                            Circle()
                                .fill(accentColor.opacity(0.20))
                                .frame(width: 18, height: 18)
                            Circle()
                                .fill(accentColor)
                                .frame(width: 7, height: 7)
                                .shadow(color: accentColor, radius: 5)
                        }
                    }
                }
                .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
                .frame(height: isExpanded ? 210 : 155)
                .disabled(true)
            }

            // View preset chips — always visible (no expand required)
            HStack(spacing: 6) {
                ForEach(ViewPreset.allCases, id: \.self) { preset in
                    let isActive = preset == activePreset
                    Button {
                        onPresetChange?(preset)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 6, weight: .semibold))
                            Text(preset.label)
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                        }
                        .foregroundStyle(isActive ? Color.black : accentColor.opacity(0.70))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(isActive ? accentColor : accentColor.opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(accentColor.opacity(isActive ? 0 : 0.30), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.82))

            // Bottom GPS bar
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("LAT")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(accentColor.opacity(0.72))
                    Spacer()
                    Text(String(format: "%.4f°", district.anchor.latitude))
                        .font(.system(size: 7, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
                HStack(spacing: 4) {
                    Text("LON")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.32))
                    Spacer()
                    Text(String(format: "%.4f°", district.anchor.longitude))
                        .font(.system(size: 7, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.78))
        }
        .frame(width: 256)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [accentColor.opacity(0.80), accentColor.opacity(0.30)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        }
        .shadow(color: accentColor.opacity(0.38), radius: 20, y: 5)
        .shadow(color: .black.opacity(0.55), radius: 18, y: 7)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
    }

    private var moodLabel: String {
        switch district.moodKey {
        case "shibuyaNeon":        return "NEON"
        case "nycDusk":            return "DUSK"
        case "parisianCore":       return "PARIS"
        case "bordeauxWaterfront": return "BORDEAUX"
        case "rennesMedieval":     return "MÉDIÉVAL"
        case "londonSilver":       return "LONDON"
        case "madridAfternoon":    return "MADRID"
        case "romanGoldenHour":    return "ROME"
        case "laSunset":           return "LA"
        case "vancouverCoastal":   return "PACIFIC"
        case "sfMorning":          return "SF"
        case "beachResort":        return "BALI"
        case "sacredSite":         return "TEMPLE"
        case "skyscraperCorridor": return "SKYLINE"
        case "colonialSquare":     return "COLONIAL"
        case "highlandMorning":    return "BANDUNG"
        case "residentialDusk":    return "JAKARTA"
        case "parkDaylight":       return "MENTENG"
        case "coastalPark":        return "ANCOL"
        default:                   return "URBAN"
        }
    }

    private var accentColor: Color {
        switch district.moodKey {
        case "shibuyaNeon":        return Color(red: 0.00, green: 0.95, blue: 0.82)
        case "nycDusk":            return Color(red: 0.68, green: 0.48, blue: 0.98)
        case "parisianCore":       return Color(red: 0.92, green: 0.80, blue: 0.44)
        case "bordeauxWaterfront": return Color(red: 0.95, green: 0.56, blue: 0.22)
        case "rennesMedieval":     return Color(red: 0.58, green: 0.72, blue: 0.86)
        case "londonSilver":       return Color(red: 0.68, green: 0.74, blue: 0.84)
        case "madridAfternoon":    return Color(red: 0.98, green: 0.70, blue: 0.18)
        case "romanGoldenHour":    return Color(red: 0.98, green: 0.52, blue: 0.20)
        case "laSunset":           return Color(red: 1.00, green: 0.56, blue: 0.22)
        case "vancouverCoastal":   return Color(red: 0.22, green: 0.76, blue: 0.90)
        case "sfMorning":          return Color(red: 0.96, green: 0.78, blue: 0.38)
        case "beachResort":        return Color(red: 0.22, green: 0.92, blue: 0.74)
        case "sacredSite":         return Color(red: 0.88, green: 0.66, blue: 0.30)
        case "highlandMorning":    return Color(red: 0.48, green: 0.80, blue: 0.96)
        case "residentialDusk":    return Color(red: 0.95, green: 0.62, blue: 0.32)
        case "parkDaylight":       return Color(red: 0.40, green: 0.88, blue: 0.46)
        case "coastalPark":        return Color(red: 0.22, green: 0.80, blue: 0.88)
        case "colonialSquare":     return Color(red: 0.90, green: 0.74, blue: 0.42)
        default:                   return Color.metacityNeonCyan
        }
    }
}

// MARK: - Mini POI list (shown inside the mini-map widget when POI preset is active)

/// Compact scrollable list of district POIs shown in place of the satellite map when the user
/// activates the POI preset. Tapping a row calls `onPOISelected` → camera fly + HUDVenueCard.
private struct MiniPOIListView: View {
    let districtId: String
    let accentColor: Color
    var onPOISelected: ((String) -> Void)?

    private var pois: [CangguPOI] {
        CangguPOICollection.load(for: districtId)?.pois ?? []
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(pois) { poi in
                    Button {
                        onPOISelected?(poi.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: poi.tier == .featured
                                  ? "mappin.circle.fill" : "mappin.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(poi.tier == .featured
                                                 ? accentColor : accentColor.opacity(0.52))
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(poi.name)
                                    .font(.system(size: 9, weight: .semibold, design: .default))
                                    .foregroundStyle(Color.white.opacity(0.92))
                                    .lineLimit(1)
                                Text(poi.category.displayName.uppercased())
                                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                                    .foregroundStyle(accentColor.opacity(0.56))
                                    .tracking(0.5)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(accentColor.opacity(0.35))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.03))
                    }
                    .buttonStyle(.plain)

                    if poi.id != pois.last?.id {
                        Divider()
                            .background(accentColor.opacity(0.10))
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.70))
        .overlay(alignment: .top) {
            if pois.isEmpty {
                Text("Aucun POI disponible")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.top, 20)
            }
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

// MARK: - Global search dropdown

private struct GlobalSearchDropdown: View {
    /// Zero-latency city matches from the first character typed.
    let instantCities: [GlobalSearchResult]
    /// District matches from the first character — up to 5.
    let districtResults: [GlobalSearchResult]
    /// Building + POI matches from 2+ characters — up to 8.
    let placeResults: [GlobalSearchResult]
    let worldSuggestions: [WorldCitySuggestion]
    let onSelect: (GlobalSearchResult) -> Void
    let onSelectSuggestion: (WorldCitySuggestion) -> Void

    private var hasContent: Bool {
        !instantCities.isEmpty || !districtResults.isEmpty || !placeResults.isEmpty || !worldSuggestions.isEmpty
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 0) {
            // VILLES 3D — city results from first character, zero latency
            if !instantCities.isEmpty {
                sectionHeader("VILLES 3D", icon: "globe.europe.africa.fill", accent: Color(red: 0.20, green: 0.82, blue: 0.65))
                ForEach(instantCities) { result in
                    Button { onSelect(result) } label: { instantCityRow(result) }
                        .buttonStyle(.plain)
                    if result.id != instantCities.last?.id {
                        hairline
                    }
                }
                if !districtResults.isEmpty || !placeResults.isEmpty || !worldSuggestions.isEmpty { hairline }
            }

            // QUARTIERS — district matches from first character
            if !districtResults.isEmpty {
                sectionHeader("QUARTIERS", icon: "map.fill", accent: Color.metacityNeonCyan)
                ForEach(districtResults) { result in
                    Button { onSelect(result) } label: { resultRow(result) }
                        .buttonStyle(.plain)
                    if result.id != districtResults.last?.id { hairline }
                }
                if !placeResults.isEmpty || !worldSuggestions.isEmpty { hairline }
            }

            // LIEUX — building + POI matches from 2+ characters
            if !placeResults.isEmpty {
                sectionHeader("LIEUX", icon: "building.fill", accent: Color(red: 0.95, green: 0.72, blue: 0.30))
                ForEach(placeResults) { result in
                    Button { onSelect(result) } label: { resultRow(result) }
                        .buttonStyle(.plain)
                    if result.id != placeResults.last?.id { hairline }
                }
                if !worldSuggestions.isEmpty { hairline }
            }

            // VILLES DU MONDE — MKLocalSearchCompleter (2 chars + 180ms)
            if !worldSuggestions.isEmpty {
                sectionHeader("VILLES DU MONDE", icon: "globe", accent: Color.metacityTextTertiary)
                ForEach(worldSuggestions) { suggestion in
                    if suggestion.isVitrine {
                        Button { onSelectSuggestion(suggestion) } label: { worldSuggestionRow(suggestion) }
                            .buttonStyle(.plain)
                    } else {
                        worldSuggestionRow(suggestion).opacity(0.55)
                    }
                    if suggestion.id != worldSuggestions.last?.id { hairline }
                }
            }
        }
        }  // end ScrollView
        .frame(maxHeight: 360)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.18))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.metacityNeonCyan.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.metacityNeonCyan.opacity(0.08), radius: 18, y: 6)
        .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func resultRow(_ result: GlobalSearchResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor(for: result))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(iconColor(for: result).opacity(0.60))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func worldSuggestionRow(_ suggestion: WorldCitySuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(suggestion.isVitrine ? Color.metacityNeonCyan : Color.white.opacity(0.40))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(suggestion.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                    if suggestion.isVitrine {
                        Text("3D")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.metacityNeonCyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.metacityNeonCyan.opacity(0.14), in: Capsule())
                    }
                }
                Text(suggestion.isVitrine ? suggestion.subtitle : "Bientôt disponible en 3D")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func iconColor(for result: GlobalSearchResult) -> Color {
        switch result.kind {
        case .city:     return Color(red: 0.20, green: 0.82, blue: 0.65)
        case .district: return Color.metacityNeonCyan
        case .building: return Color(red: 0.95, green: 0.72, blue: 0.30)
        case .poi:      return Color(red: 0.95, green: 0.38, blue: 0.20)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accent.opacity(0.80))
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.80))
                .tracking(1.2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.04))
    }

    @ViewBuilder
    private func instantCityRow(_ result: GlobalSearchResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.20, green: 0.82, blue: 0.65))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(red: 0.20, green: 0.82, blue: 0.65).opacity(0.60))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

#Preview {
    DiscoverView(viewModel: DiscoverViewModel())
}
