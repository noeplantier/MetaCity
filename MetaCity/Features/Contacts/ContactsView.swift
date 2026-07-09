import SwiftUI

struct ContactsView: View {
    @ObservedObject var viewModel: ContactsViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    emergencyStrip
                        .padding(.top, Spacing.md)

                    citySelector
                        .padding(.top, Spacing.lg)

                    if viewModel.filteredContacts.isEmpty {
                        emptyState
                    } else {
                        contactsList
                            .padding(.top, Spacing.md)
                    }
                }
                .padding(.bottom, Spacing.xl)
            }
            .background(Color.metacityBackground)
            .scrollContentBackground(.hidden)
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $viewModel.searchQuery, prompt: "Chercher un contact…")
        }
    }

    // MARK: - Emergency strip

    private var emergencyStrip: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("URGENCES")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.metacityTextTertiary)
                .tracking(1.5)
                .padding(.horizontal, Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(viewModel.emergencyNumbers) { item in
                        EmergencyChip(item: item)
                    }
                }
                .padding(.horizontal, Spacing.lg)
            }
        }
    }

    // MARK: - City selector

    private var citySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(viewModel.cityTabs) { tab in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            viewModel.selectCity(tab.id)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.emoji)
                                .font(.system(size: 14))
                            Text(tab.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(viewModel.selectedCityId == tab.id
                                    ? .white
                                    : Color.metacityTextSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            viewModel.selectedCityId == tab.id
                                ? Color.metacityPrimary
                                : Color.metacitySurface,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    viewModel.selectedCityId == tab.id
                                        ? Color.clear
                                        : Color.metacityBorder,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.lg)
        }
    }

    // MARK: - Contacts list

    private var contactsList: some View {
        VStack(spacing: Spacing.sm) {
            ForEach(viewModel.filteredContacts) { contact in
                ContactCard(contact: contact)
                    .padding(.horizontal, Spacing.lg)
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(Color.metacityTextTertiary)
                .padding(.top, 60)
            Text("Aucun résultat")
                .font(.metacityHeadline)
                .foregroundStyle(Color.metacityTextSecondary)
        }
    }
}

// MARK: - Emergency chip

private struct EmergencyChip: View {
    let item: ContactsViewModel.EmergencyNumber

    var body: some View {
        Link(destination: item.phoneURL ?? URL(string: "tel:110")!) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(item.color.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(item.color)
                }
                Text(item.number)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.metacityTextPrimary)
                Text(item.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.metacityTextTertiary)
                    .lineLimit(1)
            }
            .frame(width: 64)
            .padding(.vertical, Spacing.sm)
            .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(item.color.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Contact card

private struct ContactCard: View {
    let contact: TourismContact

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header row
            HStack(alignment: .top, spacing: Spacing.md) {
                // Avatar — gradient circle with emoji
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.metacityPrimary.opacity(0.22), Color.metacityPrimary.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    Circle()
                        .strokeBorder(Color.metacityPrimary.opacity(0.30), lineWidth: 1)
                    Text(contact.avatarEmoji)
                        .font(.system(size: 28))
                }
                .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 3) {
                    Text(contact.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.metacityTextPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(contact.role)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.metacityPrimary)
                        if let rating = contact.rating {
                            Text("·")
                                .foregroundStyle(Color.metacityTextTertiary)
                            Text(String(format: "%.1f ★", rating))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.95, green: 0.72, blue: 0.25))
                        }
                    }

                    Text(contact.organization)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.metacityTextTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(Spacing.md)

            // Specialty + availability row
            if contact.specialty != nil || contact.availability != nil {
                HStack(spacing: Spacing.sm) {
                    if let spec = contact.specialty {
                        Label(spec, systemImage: "sparkle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.metacityPrimary)
                            .lineLimit(1)
                    }
                    if let avail = contact.availability {
                        Spacer(minLength: 0)
                        Label(avail, systemImage: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.metacityTextTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, 6)
            }

            // Language chips
            if let langs = contact.languages, !langs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(langs, id: \.self) { lang in
                            Text(lang.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.metacityTextSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.metacityBorder.opacity(0.8), in: Capsule())
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                }
                .padding(.bottom, 8)
            }

            // Description
            Text(contact.description)
                .font(.system(size: 12))
                .foregroundStyle(Color.metacityTextSecondary)
                .lineLimit(2)
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.md)

            Divider()
                .padding(.horizontal, Spacing.md)

            // Action buttons
            HStack(spacing: 0) {
                if let url = contact.phoneURL {
                    Link(destination: url) {
                        Label("Appeler", systemImage: "phone.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.metacityPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if contact.whatsappURL != nil { Divider().frame(height: 24) }
                }

                if let url = contact.whatsappURL {
                    Link(destination: url) {
                        Label("WhatsApp", systemImage: "bubble.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.18, green: 0.69, blue: 0.33))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }

                if contact.phoneURL == nil && contact.whatsappURL == nil {
                    Text("Contact info disponible sur place")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.metacityTextTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
        }
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.metacityPrimary.opacity(0.18)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.metacityPrimary.opacity(0.08), radius: 12, y: 4)
    }
}

#Preview {
    ContactsView(viewModel: ContactsViewModel())
}
