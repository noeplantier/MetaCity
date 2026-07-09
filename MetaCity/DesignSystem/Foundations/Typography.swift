import SwiftUI

/// MetaCity's type scale. Every token is built on a system *text style* (`.body`, `.headline`, ...)
/// rather than a fixed point size — that's what makes it scale automatically with the user's
/// Dynamic Type setting (Settings > Accessibility > Display & Text Size). The `.rounded` design on
/// the two largest styles gives the brand a slightly softer, friendlier edge without sacrificing
/// that scaling behavior, since `design:` and `weight:` layer on top of a text style, not a raw size.
extension Font {
    static let metacityLargeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let metacityTitle = Font.system(.title2, design: .rounded).weight(.semibold)
    static let metacityTitle3 = Font.system(.title3, design: .rounded).weight(.semibold)
    static let metacityHeadline = Font.system(.headline, design: .default)
    static let metacityBody = Font.system(.body, design: .default)
    static let metacitySubheadline = Font.system(.subheadline, design: .default)
    static let metacityCaption = Font.system(.caption, design: .default)
}
