import MapKit
import SwiftUI

struct MapScreenView: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        NavigationStack {
            Map(position: $viewModel.cameraPosition) {
                UserAnnotation()

                ForEach(viewModel.places) { place in
                    Annotation(place.title, coordinate: place.coordinate.clLocationCoordinate) {
                        PlaceMarkerView(category: place.category, isSelected: viewModel.selectedPlace?.id == place.id)
                            .accessibilityLabel(place.title)
                            .accessibilityAddTraits(.isButton)
                            .onTapGesture {
                                viewModel.select(place)
                            }
                    }
                }

                if viewModel.routeCoordinates.count > 1 {
                    // Simple polyline overlay connecting the user to a nearby place — stand-in for
                    // turn-by-turn directions from a real routing API.
                    MapPolyline(coordinates: viewModel.routeCoordinates)
                        .stroke(Color.metacityPrimary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            // Pairing realistic elevation with a pitched MapCamera (see MapViewModel) is what
            // gives the "3D map" effect requested in the brief.
            .mapStyle(.standard(elevation: viewModel.is3DEnabled ? .realistic : .flat))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: Spacing.md) {
                    IconButton(systemImage: "location.fill", accessibilityLabel: "Center on my location") {
                        viewModel.recenterOnUser()
                    }
                    IconButton(
                        systemImage: viewModel.is3DEnabled ? "view.2d" : "view.3d",
                        accessibilityLabel: viewModel.is3DEnabled ? "Switch to 2D view" : "Switch to 3D view"
                    ) {
                        viewModel.toggle3DPerspective()
                    }
                }
                .padding(Spacing.xl)
            }
            .safeAreaInset(edge: .bottom) {
                if let place = viewModel.selectedPlace {
                    PlaceCalloutCard(place: place, onViewInAR: viewModel.viewSelectedPlaceInAR, onDismiss: viewModel.clearSelection)
                        .padding(Spacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.standard, value: viewModel.selectedPlace)
            .navigationTitle("Map")
            .task { viewModel.onAppear() }
            .errorAlert($viewModel.presentedError)
        }
    }
}

private struct PlaceMarkerView: View {
    let category: PlaceCategory
    let isSelected: Bool

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(Spacing.sm)
            .background(category.tintColor, in: Circle())
            .overlay(
                Circle().strokeBorder(Color.white, lineWidth: isSelected ? 3 : 0)
            )
            .scaleEffect(isSelected ? 1.25 : 1.0)
            .elevation(.soft)
            .animation(Motion.standard, value: isSelected)
    }
}

private struct PlaceCalloutCard: View {
    let place: PlaceAnnotationItem
    let onViewInAR: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: place.category.systemImage)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(place.category.tintColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(place.title)
                    .font(.metacityHeadline)
                    .foregroundStyle(Color.metacityTextPrimary)
                Text(place.subtitle)
                    .font(.metacityCaption)
                    .foregroundStyle(Color.metacityTextSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: Spacing.sm)

            VStack(spacing: Spacing.xs) {
                Button(action: onViewInAR) {
                    Label("AR", systemImage: "arkit")
                        .font(.metacityCaption)
                        .frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.metacityPrimary)
                .accessibilityLabel("View \(place.title) in AR")

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.metacityTextTertiary)
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(Spacing.md)
        .background(Color.metacitySurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.metacityBorder, lineWidth: 1)
        )
        .elevation(.raised)
    }
}

#Preview {
    let environment = AppEnvironment()
    MapScreenView(viewModel: environment.makeMapViewModel())
}
