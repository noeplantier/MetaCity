import SwiftUI

struct ProfileView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var isLoggingOut = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if viewModel.isLocked {
                lockedView
            } else {
                passport
            }
        }
        .background(Color.metacityBackground)
        .task { await viewModel.unlock() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                viewModel.flushPendingSave()
                viewModel.lockIfEnabled()
            }
        }
        .errorAlert($viewModel.presentedError)
    }

    // MARK: - Travel passport

    private var passport: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                statsSection
                stampGrid
                if showSettings { settingsSection }
                settingsToggle
                logoutSection
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [
                    viewModel.preferences.avatarColorName.color.opacity(0.55),
                    Color.metacityBackground
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 220)

            VStack(spacing: Spacing.sm) {
                Avatar(
                    name: viewModel.currentUser?.displayName ?? "Explorer",
                    size: 76,
                    backgroundColor: viewModel.preferences.avatarColorName.color.opacity(0.30),
                    systemImage: viewModel.preferences.avatarSymbol
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

                VStack(spacing: 4) {
                    Text(viewModel.currentUser?.displayName ?? "Explorer")
                        .font(.metacityTitle3)
                        .foregroundStyle(Color.metacityTextPrimary)

                    Label("Indonesia Explorer", systemImage: "checkmark.seal.fill")
                        .font(.metacityCaption.weight(.semibold))
                        .foregroundStyle(viewModel.preferences.avatarColorName.color)

                    if !viewModel.preferences.bio.isEmpty {
                        Text(viewModel.preferences.bio)
                            .font(.metacitySubheadline)
                            .foregroundStyle(Color.metacityTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.xl)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.bottom, Spacing.lg)
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: Spacing.sm) {
            PassportStat(
                value: "\(viewModel.preferences.visitedDistrictIds.count)",
                total: viewModel.districtCount,
                label: "Districts",
                icon: "building.2.fill",
                color: viewModel.preferences.avatarColorName.color
            )
            PassportStat(
                value: "\(viewModel.visitedCityCount)",
                total: CityManifest.shared.allCities.count,
                label: "Cities",
                icon: "globe.asia.australia.fill",
                color: viewModel.preferences.avatarColorName.color
            )
            PassportStat(
                value: "\(viewModel.realBuildingCount)",
                total: nil,
                label: "Real bldgs",
                icon: "building.2.crop.circle",
                color: .metacityTextSecondary
            )
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Passport stamps

    private var stampGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("PASSPORT STAMPS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.metacityTextTertiary)
                .tracking(1.5)
                .padding(.horizontal, Spacing.md)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 3),
                spacing: Spacing.sm
            ) {
                ForEach(CityManifest.shared.allDistricts) { district in
                    let visited = viewModel.preferences.visitedDistrictIds.contains(district.id)
                    DistrictStamp(district: district, visited: visited,
                                  accentColor: viewModel.preferences.avatarColorName.color)
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
    }

    // MARK: - Settings (collapsible)

    private var settingsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { showSettings.toggle() }
        } label: {
            HStack {
                Text(showSettings ? "Hide Settings" : "Settings")
                    .font(.metacitySubheadline.weight(.medium))
                    .foregroundStyle(Color.metacityTextSecondary)
                Spacer()
                Image(systemName: showSettings ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.metacityTextTertiary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .padding(.horizontal, Spacing.md)
        }
        .buttonStyle(.plain)
        .padding(.bottom, showSettings ? 0 : Spacing.xl)
    }

    private var settingsSection: some View {
        VStack(spacing: Spacing.md) {
            // Avatar picker
            VStack(alignment: .leading, spacing: Spacing.sm) {
                settingsSectionHeader("Avatar")
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(AvatarColorName.allCases, id: \.self) { colorName in
                            Circle()
                                .fill(colorName.color)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(Color.metacityTextPrimary, lineWidth: viewModel.preferences.avatarColorName == colorName ? 2 : 0))
                                .onTapGesture { viewModel.updatePreferences { $0.avatarColorName = colorName } }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: Spacing.sm) {
                        ForEach(UserPreferences.symbolChoices, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.system(size: 18))
                                .foregroundStyle(Color.metacityTextPrimary)
                                .frame(width: 36, height: 36)
                                .background(viewModel.preferences.avatarSymbol == symbol ? Color.metacitySurfaceElevated : Color.clear, in: Circle())
                                .onTapGesture { viewModel.updatePreferences { $0.avatarSymbol = symbol } }
                        }
                    }
                }
                .padding(Spacing.md)
                .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }

            // Bio
            VStack(alignment: .leading, spacing: Spacing.sm) {
                settingsSectionHeader("Bio")
                TextField("Add a short bio", text: bioBinding, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .font(.metacityBody)
                    .foregroundStyle(Color.metacityTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }

            // Privacy
            VStack(alignment: .leading, spacing: Spacing.sm) {
                settingsSectionHeader("Privacy")
                VStack(spacing: 0) {
                    settingsRow { Toggle("Public profile", isOn: publicProfileBinding).tint(Color.metacityPrimary) }
                    Divider().padding(.leading, Spacing.md)
                    settingsRow { Toggle("Share location", isOn: locationSharingBinding).tint(Color.metacityPrimary) }
                }
                .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }

            // Security
            VStack(alignment: .leading, spacing: Spacing.sm) {
                settingsSectionHeader("Security")
                settingsRow {
                    if viewModel.isBiometricAvailable {
                        Toggle("Require \(viewModel.biometryDisplayName)", isOn: biometricLockBinding).tint(Color.metacityPrimary)
                    } else {
                        HStack {
                            Text("Require \(viewModel.biometryDisplayName)").foregroundStyle(Color.metacityTextSecondary)
                            Spacer()
                            Text("Unavailable").font(.metacityCaption).foregroundStyle(Color.metacityTextTertiary)
                        }
                    }
                }
                .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
    }

    private var logoutSection: some View {
        PrimaryButton(title: "Log Out", isLoading: isLoggingOut) {
            Task {
                isLoggingOut = true
                await viewModel.logout()
                isLoggingOut = false
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.xl + 40)   // above tab bar
    }

    // MARK: - Locked view

    private var lockedView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: viewModel.biometryDisplayName == "Face ID" ? "faceid" : "touchid")
                .font(.system(size: 48))
                .foregroundStyle(Color.metacityPrimary)
            Text("Profile Locked")
                .font(.metacityTitle)
                .foregroundStyle(Color.metacityTextPrimary)
            Text("Unlock with \(viewModel.biometryDisplayName) to see your passport and settings.")
                .font(.metacitySubheadline)
                .foregroundStyle(Color.metacityTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            PrimaryButton(title: "Unlock with \(viewModel.biometryDisplayName)", isLoading: false) {
                Task { await viewModel.unlock() }
            }
            .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.metacityTextTertiary)
            .tracking(1.5)
    }

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.metacityBody)
            .foregroundStyle(Color.metacityTextPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
    }

    // MARK: - Bindings

    private var bioBinding: Binding<String> {
        Binding(get: { viewModel.preferences.bio },
                set: { newValue in viewModel.updatePreferences { $0.bio = newValue } })
    }

    private var publicProfileBinding: Binding<Bool> {
        Binding(get: { viewModel.preferences.isProfilePublic },
                set: { newValue in viewModel.updatePreferences { $0.isProfilePublic = newValue } })
    }

    private var locationSharingBinding: Binding<Bool> {
        Binding(get: { viewModel.preferences.isLocationSharingEnabled },
                set: { newValue in viewModel.updatePreferences { $0.isLocationSharingEnabled = newValue } })
    }

    private var biometricLockBinding: Binding<Bool> {
        Binding(get: { viewModel.preferences.isBiometricLockEnabled },
                set: { newValue in viewModel.updatePreferences { $0.isBiometricLockEnabled = newValue } })
    }
}

// MARK: - Subviews

private struct PassportStat: View {
    let value: String
    let total: Int?
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.metacityTitle3)
                    .foregroundStyle(Color.metacityTextPrimary)
                if let total {
                    Text("/ \(total)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.metacityTextTertiary)
                }
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.metacityTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
        .background(Color.metacitySurfaceElevated, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

private struct DistrictStamp: View {
    let district: DistrictEntry
    let visited: Bool
    let accentColor: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(visited ? accentColor.opacity(0.15) : Color.metacitySurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                visited ? accentColor.opacity(0.5) : Color.metacityTextTertiary.opacity(0.2),
                                lineWidth: 1
                            )
                    )
                    .frame(height: 52)

                if visited {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(accentColor)
                } else {
                    Image(systemName: "seal")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.metacityTextTertiary.opacity(0.4))
                }
            }
            Text(district.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(visited ? Color.metacityTextPrimary : Color.metacityTextTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

#Preview {
    ProfileView(viewModel: AppEnvironment().makeProfileViewModel(session: SessionStore(authRepository: MockAuthRepository())))
}
