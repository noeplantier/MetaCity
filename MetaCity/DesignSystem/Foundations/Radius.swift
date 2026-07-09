import CoreGraphics

/// Corner radius scale. `card`/`control` map to the two shapes used almost everywhere (surfaces and
/// buttons/fields); `pill` is for fully-rounded capsule shapes.
enum Radius {
    static let sm: CGFloat = 8
    static let control: CGFloat = 12
    static let card: CGFloat = 16
    static let lg: CGFloat = 20
    static let pill: CGFloat = 999
}
