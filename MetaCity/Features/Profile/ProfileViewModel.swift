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

    /// Number of distinct cities the user has opened at least one district in.
    var visitedCityCount: Int {
        let visitedIds = preferences.visitedDistrictIds
        return CityManifest.shared.allCities.filter { city in
            city.districts.contains(where: { visitedIds.contains($0.id) })
        }.count
    }
}
