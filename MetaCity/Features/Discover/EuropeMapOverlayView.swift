import MapKit
import SwiftUI

/// Interactive hybrid-satellite Europe map — replaces the SceneKit 3D globe.
/// Pulsing neon cyan city markers; tap one → navigate to that city at OVERVIEW preset.
struct EuropeMapOverlayView: View {
    @Binding var isPresented: Bool
    let visibleCities: [CityEntry]
    let onCitySelected: (String) -> Void

    @State private var camera: MapCameraPosition = .camera(MapCamera(
        centerCoordinate: CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0),
        distance: 3_200_000,
        heading: 0, pitch: 0
    ))

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                ForEach(visibleCities.filter { $0.anchor.latitude != 0 || $0.anchor.longitude != 0 }) { city in
                    Annotation("", coordinate: city.anchor.clLocationCoordinate) {
                        EuropeCityDot(name: city.displayName) {
                            withAnimation(.easeInOut(duration: 0.22)) { isPresented = false }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                                onCitySelected(city.id)
                            }
                        }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                footer
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { isPresented = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
            }
            Spacer()
            VStack(spacing: 3) {
                Text("EUROPE 3D")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.metacityNeonCyan)
                    .tracking(3.5)
                Text("\(visibleCities.count) VILLES DISPONIBLES")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .tracking(1.4)
            }
            Spacer()
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 20)
        .padding(.top, 58)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.82), Color.clear]),
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: - Footer

    private var footer: some View {
        Text("TOUCHER UNE VILLE POUR EXPLORER")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.metacityNeonCyan.opacity(0.50))
            .tracking(1.6)
            .padding(.bottom, 44)
    }
}

// MARK: - Pulsing city dot

private struct EuropeCityDot: View {
    let name: String
    let onTap: () -> Void

    @State private var pulsing = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(Color.metacityNeonCyan.opacity(0.30))
                        .frame(width: 30, height: 30)
                        .scaleEffect(pulsing ? 1.9 : 1.0)
                        .opacity(pulsing ? 0.0 : 0.80)
                    Circle()
                        .fill(Color.metacityNeonCyan)
                        .frame(width: 10, height: 10)
                        .shadow(color: Color.metacityNeonCyan.opacity(0.85), radius: 5)
                }
                Text(name.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .tracking(1.2)
                    .shadow(color: .black.opacity(0.90), radius: 3)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(
                .easeOut(duration: 1.6)
                .repeatForever(autoreverses: false)
            ) {
                pulsing = true
            }
        }
    }
}
