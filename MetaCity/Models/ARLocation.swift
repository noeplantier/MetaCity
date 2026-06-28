import Foundation

/// The 5 real, OpenStreetMap-derived Jakarta districts MetaCity models — the entire AR/3D content
/// of the app as of the 2026-06-28 Jakarta-only scope cut (see CLAUDE.md). Each case is named the
/// way a person would actually say the place, not its internal data-pipeline codename — "Bundaran
/// HI", not "SudirmanThamrin". A flat `CaseIterable` enum replaces the old city-or-district
/// generic type now that there's no more city-overview mode to be generic over.
enum ARLocation: String, CaseIterable, Identifiable, Hashable {
    case bundaranHI
    case kotaTua
    case kemang
    case tamanSuropati
    case ancol

    var id: String { rawValue }

    /// The bundled district JSON name (`MetaCity/Resources/Districts/<name>.json`).
    var jsonResourceName: String {
        switch self {
        case .bundaranHI: "SudirmanThamrin"
        case .kotaTua: "KotaTua"
        case .kemang: "Kemang"
        case .tamanSuropati: "Menteng"
        case .ancol: "Ancol"
        }
    }

    var displayName: String {
        switch self {
        case .bundaranHI: "Bundaran HI"
        case .kotaTua: "Kota Tua"
        case .kemang: "Jalan Kemang Raya"
        case .tamanSuropati: "Taman Suropati"
        case .ancol: "Taman Impian Jaya Ancol"
        }
    }

    /// `PlaceAnnotationItem.districtName` for the landmark this location corresponds to on the Map.
    static func matching(districtName: String) -> ARLocation? {
        allCases.first { $0.jsonResourceName == districtName }
    }

    /// The real, named building this district's "visit" experience deliberately focuses the
    /// camera on — looked up by name in the district's own `buildings` array (see
    /// `tools/fetch_district_data.py`'s output), not a hardcoded position, so it always matches
    /// wherever the real OSM polygon for that building actually is.
    ///
    /// Picked from each district's tallest/most-recognizable *named* building, since OSM has no
    /// "this is the landmark" tag to query directly — see `CLAUDE.md` for the honesty note this
    /// implies: Bundaran HI's own Selamat Datang statue isn't `building=*` tagged in OSM and isn't
    /// in this dataset at all, so the focus is the most iconic real tower that actually overlooks
    /// it instead. Taman Suropati is itself a green space with no building — the focus is the real
    /// colonial church facing it, the most prominent real structure tied to that specific square.
    var focusBuildingName: String {
        switch self {
        case .bundaranHI: "Menara BCA"
        case .kotaTua: "Museum Sejarah Jakarta"
        case .kemang: "The Tiffany"
        case .tamanSuropati: "Gereja Kristen Indonesia Barat"
        case .ancol: "Istana Boneka"
        }
    }
}
