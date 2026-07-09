import Foundation

enum PlaceCategory: String, Codable, CaseIterable {
    case monument
    case religious
    case museum
    case bridge
    case nature
}

struct PlaceAnnotationItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let coordinate: Coordinate
    let category: PlaceCategory

    /// The bundled `District` JSON name (see `MetaCity/Resources/Districts/`) this landmark has
    /// real, OpenStreetMap-derived 3D coverage for, if any. Landmarks without a curated district
    /// fall back to their city's broader (artistic-scale) skyline view — see `LandmarkInspectorView`.
    var districtName: String? {
        switch id {
        case "jakarta-kota-tua": "KotaTua"
        case "jakarta-menteng": "Menteng"
        case "jakarta-bundaran-hi": "SudirmanThamrin"
        case "jakarta-kemang": "Kemang"
        case "jakarta-ancol": "Ancol"
        default: nil
        }
    }
}
