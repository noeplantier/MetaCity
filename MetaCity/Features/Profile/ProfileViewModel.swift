import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published private(set) var currentUser: User?
    @Published var presentedError: IdentifiableError?
    @Published var preferences: UserPreferences
    /// Whether the Profile tab's content is currently hidden behind a biometric prompt. Starts
    /// `true` whenever the lock setting is on, so a fresh launch (or a fresh `ProfileViewModel`)
    /// never shows private details before the device owner has actually proven who they are.
    @Published private(set) var isLocked: Bool

    let biometryDisplayName: String
    let isBiometricAvailable: Bool
    /// Computed once here rather than as computed properties read directly from `ProfileView`'s
    /// body — `District.totalRealBuildingCount`/`totalRealRoadCount` each sum across all 5
    /// bundled districts, and the view's body re-evaluates on every preference change (e.g. every
    /// bio keystroke), which was redoing that summation every time for a number that never
    /// actually changes during the life of this screen.
    let districtCount: Int
    let realBuildingCount: Int
    let realRoadCount: Int

    private let authRepository: AuthRepository
    private let session: SessionStore
    private let preferencesStore: UserPreferencesStore
    private let biometricAuthenticator: BiometricAuthenticator
    private var saveTask: Task<Void, Never>?

    init(
        authRepository: AuthRepository,
        session: SessionStore,
        preferencesStore: UserPreferencesStore,
        biometricAuthenticator: BiometricAuthenticator
    ) {
        self.authRepository = authRepository
        self.session = session
        self.preferencesStore = preferencesStore
        self.biometricAuthenticator = biometricAuthenticator
        self.currentUser = session.currentUser
        self.biometryDisplayName = biometricAuthenticator.biometryDisplayName
        self.isBiometricAvailable = biometricAuthenticator.isAvailable
        self.districtCount = CityManifest.shared.allDistricts.count
        self.realBuildingCount = District.totalRealBuildingCount
        self.realRoadCount = District.totalRealRoadCount

        let loaded = session.currentUser.map { preferencesStore.load(for: $0.id) } ?? .default
        self.preferences = loaded
        self.isLocked = loaded.isBiometricLockEnabled
    }

    func logout() async {
        await authRepository.logout()
        session.handleSignedOut()
    }

    /// Every preference write goes through here so a save to disk is never forgotten on a new
    /// field. The in-memory `preferences` update is always immediate (the UI reflects it
    /// instantly); the disk write is debounced, since this is also what the bio `TextField` calls
    /// on every keystroke — without debouncing, typing a sentence was a JSON-encode +
    /// `UserDefaults.set` per character. `flushPendingSave()` covers the case where the app
    /// backgrounds mid-debounce.
    func updatePreferences(_ mutate: (inout UserPreferences) -> Void) {
        mutate(&preferences)
        guard let userID = currentUser?.id else { return }
        saveTask?.cancel()
        let snapshot = preferences
        saveTask = Task { [preferencesStore] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            preferencesStore.save(snapshot, for: userID)
        }
    }

    /// Persists immediately, bypassing the debounce — call this whenever the app might be about to
    /// stop running (background, this ViewModel going away) so a pending edit is never lost.
    func flushPendingSave() {
        guard saveTask != nil, let userID = currentUser?.id else { return }
        saveTask?.cancel()
        saveTask = nil
        preferencesStore.save(preferences, for: userID)
    }

    func unlock() async {
        guard isLocked else { return }
        guard await biometricAuthenticator.authenticate(reason: "Unlock your MetaCity profile") else { return }
        isLocked = false
    }

    /// Called when the app backgrounds (see `ProfileView`'s `scenePhase` observation) — re-arms
    /// the lock so leaving and returning to the app re-prompts, not just the very first open.
    func lockIfEnabled() {
        guard preferences.isBiometricLockEnabled else { return }
        isLocked = true
    }

    /// Called by `HomeTabView.onChange(of: discoverViewModel.selectedDistrict)` when the user
    /// opens a district's 3D inspector. Persists immediately — this is a rare, meaningful action,
    /// not a keystroke, so there's no reason to debounce.
    func markVisited(_ districtId: String) {
        guard !preferences.visitedDistrictIds.contains(districtId),
              let userID = currentUser?.id else { return }
        preferences.visitedDistrictIds.insert(districtId)
        preferencesStore.save(preferences, for: userID)
    }

    /// Rough virtual distance covered: ~4 km per district explored (district average footprint).
    var virtualKm: Int { preferences.visitedDistrictIds.count * 4 }

    /// Number of distinct cities the user has opened at least one district in.
    var visitedCityCount: Int {
        let visitedIds = preferences.visitedDistrictIds
        return CityManifest.shared.allCities.filter { city in
            city.districts.contains(where: { visitedIds.contains($0.id) })
        }.count
    }

    // MARK: - Voyageur personality

    /// Computed personality archetype from visited district mood keys.
    /// Updates automatically as `preferences.visitedDistrictIds` changes.
    var voyageurPersonality: VoyageurPersonality {
        let visitedIds = preferences.visitedDistrictIds
        guard !visitedIds.isEmpty else { return .newExplorer }

        // Tally mood theme counts from manifest district entries
        var tropical = 0, futurist = 0, european = 0, mediterranean = 0, heritage = 0
        for city in CityManifest.shared.allCities {
            for d in city.districts where visitedIds.contains(d.id) {
                switch d.moodKey {
                case "beachResort", "sacredSite": tropical += 2
                case "shibuyaNeon", "nycDusk", "laSunset": futurist += 2
                case "skyscraperCorridor":         futurist += 1
                case "parisianCore", "rennesMedieval", "bordeauxWaterfront": european += 2
                case "madridAfternoon", "romanGoldenHour": mediterranean += 2
                case "londonSilver":               mediterranean += 1
                case "colonialSquare":             heritage += 2
                case "highlandMorning":            heritage += 1
                default: break
                }
            }
        }

        let scores = [
            (tropical, VoyageurPersonality.tropicalNomad),
            (futurist, .urbanFuturist),
            (european, .europeanFlaneur),
            (mediterranean, .mediterraneanVoyager),
            (heritage, .heritageSeekerl)
        ]
        // Dominant theme wins; tie → europeenFlaneur as default for this app's audience
        if let top = scores.max(by: { $0.0 < $1.0 }), top.0 > 0 { return top.1 }
        return .eclecticExplorer
    }
}

// MARK: - VoyageurPersonality

enum VoyageurPersonality {
    case newExplorer        // 0 districts visited
    case tropicalNomad      // beach/Bali dominant
    case urbanFuturist      // glass towers / Shibuya / NYC dominant
    case europeanFlaneur    // Paris / Bordeaux / Rennes dominant
    case mediterraneanVoyager // Madrid / Rome / London dominant
    case heritageSeekerl    // Colonial Jakarta / Javanese dominant
    case eclecticExplorer   // mixed, all low

    var title: String {
        switch self {
        case .newExplorer:         return "NOUVEAU VOYAGEUR"
        case .tropicalNomad:       return "NOMADE TROPICAL"
        case .urbanFuturist:       return "ARCHITECTE FUTURISTE"
        case .europeanFlaneur:     return "FLÂNEUR EUROPÉEN"
        case .mediterraneanVoyager:return "VOYAGEUR MÉDITERRANÉEN"
        case .heritageSeekerl:     return "HISTORIEN DU BÂTI"
        case .eclecticExplorer:    return "EXPLORATEUR ÉCLECTIQUE"
        }
    }

    var subtitle: String {
        switch self {
        case .newExplorer:         return "TOURISME 3D & RA · PRÊT À EXPLORER"
        case .tropicalNomad:       return "BALI · NATURE · ARCHITECTURE VERNACULAIRE"
        case .urbanFuturist:       return "VERRE · ACIER · SKYLINES DU FUTUR"
        case .europeanFlaneur:     return "HAUSSMANN · PARIS · PATRIMOINE URBAIN"
        case .mediterraneanVoyager:return "SIENNA · OCRE · LUMIÈRE DU SUD"
        case .heritageSeekerl:     return "COLONIALE · JAVA · MÉMOIRE ARCHITECTURALE"
        case .eclecticExplorer:    return "EXPLORER SANS FRONTIÈRES · TOURISME 3D"
        }
    }

    var icon: String {
        switch self {
        case .newExplorer:         return "globe.europe.africa.fill"
        case .tropicalNomad:       return "sun.max.fill"
        case .urbanFuturist:       return "building.2.crop.circle.fill"
        case .europeanFlaneur:     return "archivebox.fill"
        case .mediterraneanVoyager:return "water.waves"
        case .heritageSeekerl:     return "building.columns.fill"
        case .eclecticExplorer:    return "map.fill"
        }
    }
}
