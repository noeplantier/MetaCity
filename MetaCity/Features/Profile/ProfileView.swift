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

    // MARK: - Main scroll content

    private var passport: some View {
        ScrollView {
            VStack(spacing: 0) {
                identityCard
                kpiRow
                districtBadges
                proLinks
                if showSettings { settingsSection }
                settingsToggle
                logoutSection
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - HUD Identity card hero

    private var identityCard: some View {
        ZStack(alignment: .bottom) {
            // Background gradient
            LinearGradient(
                colors: [
                    Color.metacityHUDBackground,
                    Color.metacityHUDBackground.opacity(0.40),
                    Color.metacityBackground
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 260)

            // Scan grid overlay
            HUDScanGridOverlay()
                .frame(height: 260)
                .clipped()

            // Neon liseré accent line
            VStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.clear, Color.metacityNeonCyan.opacity(0.55), Color.clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                Spacer()
            }
            .frame(height: 260)

            // Content
            VStack(spacing: Spacing.sm) {
                Avatar(
                    name: viewModel.currentUser?.displayName ?? "Explorateur",
                    size: 76,
                    backgroundColor: Color.metacityNeonCyan.opacity(0.18),
                    systemImage: viewModel.preferences.avatarSymbol
                )
                .shadow(color: Color.metacityNeonCyan.opacity(0.35), radius: 12, y: 4)
                .overlay(
                    Circle()
                        .strokeBorder(Color.metacityNeonCyan.opacity(0.45), lineWidth: 1.5)
                )

                VStack(spacing: 4) {
                    Text(viewModel.currentUser?.displayName ?? "Explorateur")
                        .font(.metacityTitle3)
                        .foregroundStyle(Color.metacityTextPrimary)

                    Text("EXPLORATEUR NUMÉRIQUE · TOURISME 3D & RA")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.metacityNeonCyan)
                        .tracking(1.4)
                        .multilineTextAlignment(.center)

                    if !viewModel.preferences.bio.isEmpty {
                        Text(viewModel.preferences.bio)
                            .font(.metacityCaption)
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

    // MARK: - 4 KPI chips

    private var kpiRow: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: Spacing.sm),
                GridItem(.flexible(), spacing: Spacing.sm)
            ],
            spacing: Spacing.sm
        ) {
            ProKPICard(
                value: "\(viewModel.preferences.visitedDistrictIds.count)",
                total: viewModel.districtCount,
                label: "Quartiers explorés",
                icon: "building.2.fill",
                accent: Color.metacityNeonCyan
            )
            ProKPICard(
                value: "\(viewModel.preferences.visitedDistrictIds.count)",
                total: nil,
                label: "Sessions immersives",
                icon: "arkit",
                accent: Color(red: 0.35, green: 0.75, blue: 1.00)
            )
            ProKPICard(
                value: "\(viewModel.virtualKm)",
                total: nil,
                label: "KM virtuels",
                icon: "location.north.fill",
                accent: Color.metacitySecondary
            )
            ProKPICard(
                value: "\(viewModel.realBuildingCount)",
                total: nil,
                label: "Bâtiments OSM",
                icon: "square.3.layers.3d.down.right",
                accent: Color.metacitySuccess
            )
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - District badges

    private var districtBadges: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.metacityNeonCyan)
                    .frame(width: 3, height: 14)
                Text("DISTRICTS EXPLORÉS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.metacityTextTertiary)
                    .tracking(1.5)
            }
            .padding(.horizontal, Spacing.md)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 3),
                spacing: Spacing.sm
            ) {
                ForEach(CityManifest.shared.allDistricts) { district in
                    let visited = viewModel.preferences.visitedDistrictIds.contains(district.id)
                    DistrictBadge(district: district, visited: visited)
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
    }

    // MARK: - Pro links section

    private var proLinks: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.metacityNeonCyan)
                    .frame(width: 3, height: 14)
                Text("LIENS PRO")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.metacityTextTertiary)
                    .tracking(1.5)
            }
            .padding(.horizontal, Spacing.md)

            VStack(spacing: 0) {
                proLinkRow(icon: "arkit", label: "MetaCity — App 3D & RA")
                Divider().padding(.leading, 52)
                proLinkRow(icon: "globe", label: "OpenStreetMap Data")
                Divider().padding(.leading, 52)
                proLinkRow(icon: "chart.bar.xaxis", label: "25 districts · 10 villes")
            }
            .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .padding(.horizontal, Spacing.md)
        }
        .padding(.bottom, Spacing.lg)
    }

    private func proLinkRow(icon: String, label: String) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.metacityNeonCyan.opacity(0.10))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.metacityNeonCyan)
            }
            Text(label)
                .font(.metacityBody)
                .foregroundStyle(Color.metacityTextPrimary)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.metacityTextTertiary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    // MARK: - Settings (collapsible)

    private var settingsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { showSettings.toggle() }
        } label: {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.metacityTextTertiary)
                Text(showSettings ? "Masquer les réglages" : "Réglages")
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
                TextField("Ajoutez une courte bio", text: bioBinding, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                    .font(.metacityBody)
                    .foregroundStyle(Color.metacityTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }

            // Privacy
            VStack(alignment: .leading, spacing: Spacing.sm) {
                settingsSectionHeader("Confidentialité")
                VStack(spacing: 0) {
                    settingsRow { Toggle("Profil public", isOn: publicProfileBinding).tint(Color.metacityPrimary) }
                    Divider().padding(.leading, Spacing.md)
                    settingsRow { Toggle("Partager localisation", isOn: locationSharingBinding).tint(Color.metacityPrimary) }
                }
                .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }

            // Security
            VStack(alignment: .leading, spacing: Spacing.sm) {
                settingsSectionHeader("Sécurité")
                settingsRow {
                    if viewModel.isBiometricAvailable {
                        Toggle("Requérir \(viewModel.biometryDisplayName)", isOn: biometricLockBinding).tint(Color.metacityPrimary)
                    } else {
                        HStack {
                            Text("Requérir \(viewModel.biometryDisplayName)").foregroundStyle(Color.metacityTextSecondary)
                            Spacer()
                            Text("Indisponible").font(.metacityCaption).foregroundStyle(Color.metacityTextTertiary)
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
        PrimaryButton(title: "Se déconnecter", isLoading: isLoggingOut) {
            Task {
                isLoggingOut = true
                await viewModel.logout()
                isLoggingOut = false
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.xl + 40)
    }

    // MARK: - Locked view

    private var lockedView: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: viewModel.biometryDisplayName == "Face ID" ? "faceid" : "touchid")
                .font(.system(size: 48))
                .foregroundStyle(Color.metacityNeonCyan)
            Text("Profil verrouillé")
                .font(.metacityTitle)
                .foregroundStyle(Color.metacityTextPrimary)
            Text("Déverrouillez avec \(viewModel.biometryDisplayName) pour voir votre passeport et vos réglages.")
                .font(.metacitySubheadline)
                .foregroundStyle(Color.metacityTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            PrimaryButton(title: "Déverrouiller", isLoading: false) {
                Task { await viewModel.unlock() }
            }
            .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
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

// MARK: - HUD scan grid overlay

private struct HUDScanGridOverlay: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24
            var x: CGFloat = 0
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
                x += step
            }
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Pro KPI card

private struct ProKPICard: View {
    let value: String
    let total: Int?
    let label: String
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Spacer()
                if let total {
                    Text("/ \(total)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.metacityTextTertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.metacityTextPrimary)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.metacityTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.metacitySurfaceElevated)
                .overlay(
                    LinearGradient(
                        colors: [accent.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(accent.opacity(0.20), lineWidth: 1)
        )
    }
}

// MARK: - District badge (refactored from DistrictStamp)

private struct DistrictBadge: View {
    let district: DistrictEntry
    let visited: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(visited
                          ? Color.metacityNeonCyan.opacity(0.12)
                          : Color.metacitySurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                visited
                                    ? Color.metacityNeonCyan.opacity(0.45)
                                    : Color.metacityBorder,
                                lineWidth: 1
                            )
                    )
                    .frame(height: 52)

                if visited {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.metacityNeonCyan)
                } else {
                    Image(systemName: "seal")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.metacityTextTertiary.opacity(0.35))
                }
            }
            Text(district.displayName)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(visited ? Color.metacityTextPrimary : Color.metacityTextTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

#Preview {
    ProfileView(viewModel: AppEnvironment().makeProfileViewModel(session: SessionStore(authRepository: MockAuthRepository())))
        .preferredColorScheme(.dark)
}
