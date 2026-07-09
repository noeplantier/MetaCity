import SwiftUI

/// The app's single "card" treatment: a surface, a subtle border, optional soft elevation. Used for
/// any grouped block of content that should read as one unit (the 3D controls panel, future
/// settings groups) without re-deriving the same background/corner-radius/border stack by hand
/// every time.
struct SurfaceCard<Content: View>: View {
    var isElevated: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            content()
        }
        .padding(Spacing.lg)
        .background(
            isElevated ? Color.metacitySurfaceElevated : Color.metacitySurface,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.metacityBorder, lineWidth: 1)
        )
        .elevation(isElevated ? .raised : .soft)
    }
}

#Preview {
    SurfaceCard {
        Text("Title").font(.metacityHeadline)
        Text("Supporting copy goes here.").font(.metacitySubheadline).foregroundStyle(Color.metacityTextSecondary)
    }
    .padding()
    .background(Color.metacityBackground)
}
