import SwiftUI

/// Every landmark MetaCity has (see `MockMapRepository`) now has real, OpenStreetMap-derived 3D
/// district coverage — there's no broader artistic-skyline fallback left (see CLAUDE.md, the
/// 2026-06-28 Jakarta-only scope cut). `districtName` is required, not optional, to reflect that.
struct LandmarkInspectorView: View {
    @ObservedObject var viewModel: LandmarkInspectorViewModel
    /// Set when opened from Explore for a specific place; falls back to a generic title when
    /// opened standalone (e.g. from a future dedicated "3D" entry point).
    var landmarkTitle: String? = nil
    let districtName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DistrictScene3DView(
                    districtName: districtName,
                    isNightMode: viewModel.isNightMode,
                    isAutoRotating: viewModel.isAutoRotating,
                    rotationSpeed: viewModel.rotationSpeed
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.metacityBackground)
                .accessibilityLabel("3D preview of \(landmarkTitle ?? "MetaCity")")
                .accessibilityHint("Drag to orbit the camera, pinch to zoom")

                controls
            }
            .background(Color.metacityBackground)
            .navigationTitle(landmarkTitle ?? "3D Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Toggle("Auto-rotate", isOn: $viewModel.isAutoRotating)
                .font(.metacityBody)
                .tint(Color.metacityPrimary)

            Toggle("Night mode", isOn: $viewModel.isNightMode)
                .font(.metacityBody)
                .tint(Color.metacityPrimary)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Rotation speed")
                    .font(.metacityCaption)
                    .foregroundStyle(Color.metacityTextSecondary)
                Slider(value: $viewModel.rotationSpeed, in: 0.2...3.0)
                    .tint(Color.metacityPrimary)
                    .accessibilityValue("\(Int(viewModel.rotationSpeed * 100)) percent")
            }

            Text("\(districtName) rendered from real OpenStreetMap building footprints, roads, and green spaces — see CLAUDE.md. Drag to orbit, pinch to zoom.")
                .font(.metacityCaption)
                .foregroundStyle(Color.metacityTextTertiary)
        }
        .padding(Spacing.xl)
        .background(
            Color.metacitySurface,
            in: UnevenRoundedRectangle(topLeadingRadius: Radius.card, topTrailingRadius: Radius.card, style: .continuous)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Color.metacitySeparator).frame(height: 1)
        }
    }
}

#Preview {
    LandmarkInspectorView(viewModel: LandmarkInspectorViewModel(), districtName: "KotaTua")
}
