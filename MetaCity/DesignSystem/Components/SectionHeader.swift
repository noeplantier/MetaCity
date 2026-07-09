import SwiftUI

/// Consistent section title treatment for grouped lists — tracked, uppercase, tertiary-weight text
/// instead of relying on each `List` section's default styling (which varies by container).
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.metacityCaption)
            .fontWeight(.semibold)
            .tracking(0.6)
            .foregroundStyle(Color.metacityTextTertiary)
    }
}
