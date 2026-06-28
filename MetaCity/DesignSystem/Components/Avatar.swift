import SwiftUI

/// A circular initials avatar, used for the signed-in user and call participants. Replaces the ad-hoc
/// `Image(systemName: "person.crop.circle.fill")` placeholders with something that actually carries
/// identity — initials read faster than a generic person glyph, and it's free of any network/asset
/// dependency, which matters while there's no real backend yet.
struct Avatar: View {
    let name: String
    var size: CGFloat = 44
    /// Lets Profile's avatar customization override the neutral default with a chosen color —
    /// every other call site (call participants, previews) keeps the original look unchanged.
    var backgroundColor: Color = .metacitySurfaceElevated
    /// An SF Symbol name shown instead of initials, e.g. Profile's avatar icon picker. SF Symbols
    /// rather than emoji on purpose — emoji glyphs were unavailable on this Simulator runtime
    /// (rendered as "?" tofu boxes even after a reboot), while SF Symbols are vector system
    /// glyphs already used everywhere else in the app and always render correctly.
    var systemImage: String? = nil

    var body: some View {
        Circle()
            .fill(backgroundColor)
            .overlay(Circle().strokeBorder(Color.metacityBorder, lineWidth: 1))
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(Color.metacityTextPrimary)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.metacityTextPrimary)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

#Preview {
    HStack {
        Avatar(name: "Demo User")
        Avatar(name: "Teammate 1", size: 32)
    }
    .padding()
    .background(Color.metacityBackground)
}
