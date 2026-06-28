import SwiftUI

struct ProfileView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var isLoggingOut = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLocked {
                    lockedView
                } else {
                    content
                }
            }
            .background(Color.metacityBackground)
            .navigationTitle("Profile")
            .errorAlert($viewModel.presentedError)
        }
        .task { await viewModel.unlock() } // prompts immediately if locked; no-op otherwise
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                viewModel.lockIfEnabled()
            }
        }
    }

    private var content: some View {
        List {
            Section {
                profileRow
                summaryCards
                    .listRowInsets(EdgeInsets())
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.sm)
            }
            .listRowBackground(Color.metacitySurface)

            Section {
                avatarPicker
            } header: {
                SectionHeader(title: "Avatar")
            }
            .textCase(nil)
            .listRowBackground(Color.metacitySurface)

            Section {
                TextField("Add a short bio", text: bioBinding, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .font(.metacityBody)
                    .foregroundStyle(Color.metacityTextPrimary)
            } header: {
                SectionHeader(title: "Bio")
            }
            .textCase(nil)
            .listRowBackground(Color.metacitySurface)

            Section {
                Toggle("Public profile", isOn: publicProfileBinding)
                Toggle("Share my location", isOn: locationSharingBinding)
            } header: {
                SectionHeader(title: "Privacy")
            } footer: {
                Text("These control what MetaCity would show other people if it had any — there's no social feed yet, so today they're saved preferences without an audience.")
            }
            .textCase(nil)
            .tint(Color.metacityPrimary)
            .listRowBackground(Color.metacitySurface)

            Section {
                if viewModel.isBiometricAvailable {
                    Toggle("Require \(viewModel.biometryDisplayName)", isOn: biometricLockBinding)
                } else {
                    HStack {
                        Text("Require \(viewModel.biometryDisplayName)")
                            .foregroundStyle(Color.metacityTextSecondary)
                        Spacer()
                        Text("Unavailable")
                            .font(.metacityCaption)
                            .foregroundStyle(Color.metacityTextTertiary)
                    }
                }
            } header: {
                SectionHeader(title: "Security")
            } footer: {
                Text(viewModel.isBiometricAvailable
                     ? "When on, this tab re-locks every time you leave MetaCity and come back."
                     : "No biometric enrollment was found on this device/Simulator.")
            }
            .textCase(nil)
            .tint(Color.metacityPrimary)
            .listRowBackground(Color.metacitySurface)

            Section {
                ComingSoonRow(systemImage: "bell.badge.fill", title: "Push notifications")
                ComingSoonRow(systemImage: "chart.bar.fill", title: "Analytics")
                ComingSoonRow(systemImage: "icloud.fill", title: "Real backend (Firebase/Auth0)")
            } header: {
                // Extension points: each of these is added by introducing a new Domain protocol
                // + Data implementation + ViewModel, the same pattern as Auth/Map/Call.
                SectionHeader(title: "Coming soon")
            }
            .textCase(nil)
            .listRowBackground(Color.metacitySurface)

            Section {
                PrimaryButton(title: "Log Out", isLoading: isLoggingOut) {
                    Task {
                        isLoggingOut = true
                        await viewModel.logout()
                        isLoggingOut = false
                    }
                }
                .listRowInsets(EdgeInsets())
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var lockedView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: viewModel.biometryDisplayName == "Face ID" ? "faceid" : "touchid")
                .font(.system(size: 48))
                .foregroundStyle(Color.metacityPrimary)
            Text("Profile Locked")
                .font(.metacityTitle)
                .foregroundStyle(Color.metacityTextPrimary)
            Text("Unlock with \(viewModel.biometryDisplayName) to see your bio, privacy settings, and account details.")
                .font(.metacitySubheadline)
                .foregroundStyle(Color.metacityTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            PrimaryButton(title: "Unlock with \(viewModel.biometryDisplayName)", isLoading: false) {
                Task { await viewModel.unlock() }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var profileRow: some View {
        HStack(spacing: Spacing.md) {
            Avatar(
                name: viewModel.currentUser?.displayName ?? "Guest",
                size: 56,
                backgroundColor: viewModel.preferences.avatarColorName.color.opacity(0.25),
                systemImage: viewModel.preferences.avatarSymbol
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.currentUser?.displayName ?? "Guest")
                    .font(.metacityHeadline)
                    .foregroundStyle(Color.metacityTextPrimary)
                statusBadge
                Text(viewModel.currentUser?.email ?? "")
                    .font(.metacitySubheadline)
                    .foregroundStyle(Color.metacityTextSecondary)
                if !viewModel.preferences.bio.isEmpty {
                    Text(viewModel.preferences.bio)
                        .font(.metacityCaption)
                        .foregroundStyle(Color.metacityTextTertiary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        Label("Indonesia Explorer", systemImage: "checkmark.seal.fill")
            .font(.metacityCaption.weight(.semibold))
            .foregroundStyle(Color.metacityPrimary)
            .padding(.vertical, 1)
    }

    /// Real facts about the app's content, not fabricated personal analytics — there's no
    /// visited-places tracking yet, and a fake "12 places visited" counter would be exactly the
    /// kind of hollow stat this app avoids elsewhere. Buildings and roads both sum real OSM
    /// footprint/centerline counts across the 5 bundled districts (`District.totalReal...Count`)
    /// rather than repeating the district count under a different label. Deliberately not a "100%
    /// real" badge: building *heights* are partly estimated (flagged `isHeightEstimated`), so a
    /// blanket completeness claim would overstate what's actually measured vs. heuristic.
    private var summaryCards: some View {
        HStack(spacing: Spacing.sm) {
            StatCard(value: "\(ARLocation.allCases.count)", label: "Districts", systemImage: "building.2.fill")
            StatCard(value: "\(District.totalRealBuildingCount)", label: "Real buildings", systemImage: "building.2.crop.circle")
            StatCard(value: "\(District.totalRealRoadCount)", label: "Real roads", systemImage: "mappin.and.ellipse")
        }
    }

    private var avatarPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                ForEach(AvatarColorName.allCases, id: \.self) { colorName in
                    Circle()
                        .fill(colorName.color)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().strokeBorder(Color.metacityTextPrimary, lineWidth: viewModel.preferences.avatarColorName == colorName ? 2 : 0)
                        )
                        .onTapGesture {
                            viewModel.updatePreferences { $0.avatarColorName = colorName }
                        }
                        .accessibilityLabel("\(colorName.rawValue) avatar color")
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: Spacing.sm) {
                ForEach(UserPreferences.symbolChoices, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(Color.metacityTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(
                            viewModel.preferences.avatarSymbol == symbol ? Color.metacitySurfaceElevated : Color.clear,
                            in: Circle()
                        )
                        .onTapGesture {
                            viewModel.updatePreferences { $0.avatarSymbol = symbol }
                        }
                        .accessibilityLabel(symbol)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var bioBinding: Binding<String> {
        Binding(
            get: { viewModel.preferences.bio },
            set: { newValue in viewModel.updatePreferences { $0.bio = newValue } }
        )
    }

    private var publicProfileBinding: Binding<Bool> {
        Binding(
            get: { viewModel.preferences.isProfilePublic },
            set: { newValue in viewModel.updatePreferences { $0.isProfilePublic = newValue } }
        )
    }

    private var locationSharingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.preferences.isLocationSharingEnabled },
            set: { newValue in viewModel.updatePreferences { $0.isLocationSharingEnabled = newValue } }
        )
    }

    private var biometricLockBinding: Binding<Bool> {
        Binding(
            get: { viewModel.preferences.isBiometricLockEnabled },
            set: { newValue in viewModel.updatePreferences { $0.isBiometricLockEnabled = newValue } }
        )
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.metacityPrimary)
            Text(value)
                .font(.metacityTitle3)
                .foregroundStyle(Color.metacityTextPrimary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.metacityTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
        .background(Color.metacitySurfaceElevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

private struct ComingSoonRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(Color.metacityTextSecondary)
                .frame(width: 28)
            Text(title)
                .font(.metacityBody)
                .foregroundStyle(Color.metacityTextPrimary)
            Spacer()
            Text("Soon")
                .font(.metacityCaption)
                .foregroundStyle(Color.metacityTextTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ProfileView(viewModel: AppEnvironment().makeProfileViewModel(session: SessionStore(authRepository: MockAuthRepository())))
}
