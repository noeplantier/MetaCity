import CoreGraphics

/// A single spacing scale used everywhere instead of ad-hoc magic numbers, so density stays
/// consistent as the app grows and "more breathing room" is a one-file change.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}
