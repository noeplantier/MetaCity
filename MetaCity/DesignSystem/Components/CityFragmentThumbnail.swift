import SwiftUI

/// Gradient placeholder used as a characteristic illustration for each city or district.
/// Per the design brief, when the 3D scenes are screenshot-captured in-app, those renders
/// replace these gradient stubs. Until then the gradients carry the city's visual identity.
struct CityFragmentThumbnail: View {
    let cityId: String
    var cornerRadius: CGFloat = Radius.sm
    var showScanGrid: Bool = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: fragmentGradient(for: cityId),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if showScanGrid { ScanGridLayer() }
            // City identifier in the bottom-left corner
            Text(cityCode(for: cityId))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
                .tracking(1.4)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Per-city gradients

    private func fragmentGradient(for cityId: String) -> [Color] {
        switch cityId {
        case "paris":
            return [
                Color(red: 0.22, green: 0.18, blue: 0.45),
                Color(red: 0.55, green: 0.42, blue: 0.20)
            ]
        case "tokyo":
            return [
                Color(red: 0.08, green: 0.04, blue: 0.18),
                Color(red: 0.60, green: 0.05, blue: 0.35)
            ]
        case "vancouver":
            return [
                Color(red: 0.04, green: 0.22, blue: 0.38),
                Color(red: 0.10, green: 0.55, blue: 0.65)
            ]
        case "jakarta":
            return [
                Color(red: 0.18, green: 0.10, blue: 0.04),
                Color(red: 0.72, green: 0.40, blue: 0.10)
            ]
        case "denpasar":
            return [
                Color(red: 0.05, green: 0.22, blue: 0.12),
                Color(red: 0.22, green: 0.58, blue: 0.28)
            ]
        case "london":
            return [
                Color(red: 0.12, green: 0.14, blue: 0.20),
                Color(red: 0.40, green: 0.44, blue: 0.55)
            ]
        case "madrid":
            return [
                Color(red: 0.28, green: 0.14, blue: 0.04),
                Color(red: 0.78, green: 0.48, blue: 0.10)
            ]
        case "rome":
            return [
                Color(red: 0.25, green: 0.12, blue: 0.04),
                Color(red: 0.68, green: 0.36, blue: 0.14)
            ]
        case "newyork":
            return [
                Color(red: 0.06, green: 0.06, blue: 0.14),
                Color(red: 0.30, green: 0.30, blue: 0.50)
            ]
        default:
            return [Color.metacityBackground, Color.metacityPrimary.opacity(0.6)]
        }
    }

    private func cityCode(for cityId: String) -> String {
        switch cityId {
        case "paris": return "CDG"
        case "tokyo": return "TYO"
        case "vancouver": return "YVR"
        case "jakarta": return "CGK"
        case "denpasar": return "DPS"
        case "london": return "LHR"
        case "madrid": return "MAD"
        case "rome": return "FCO"
        case "newyork": return "JFK"
        default: return cityId.prefix(3).uppercased()
        }
    }
}

// MARK: - Scan grid overlay (subtle HUD texture)

/// Lightweight 1×1pt grid drawn via Canvas — zero image assets, no UIKit import.
private struct ScanGridLayer: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 16
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            ctx.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}
