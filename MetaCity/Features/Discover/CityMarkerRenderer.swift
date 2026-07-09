import UIKit

/// Renders a custom city-pin `UIImage` per `CityEntry` using CoreGraphics, cached statically.
/// Deliberately NOT a live RealityKit scene — 10 concurrent ARViews for map annotations
/// would be catastrophic. One CoreGraphics pass at first access, cached forever.
@MainActor
enum CityMarkerRenderer {
    private static var cache: [String: UIImage] = [:]

    static func image(for city: CityEntry) -> UIImage {
        if let cached = cache[city.id] { return cached }
        let img = render(city: city)
        cache[city.id] = img
        return img
    }

    private static func render(city: CityEntry) -> UIImage {
        let size = CGSize(width: 44, height: 52)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let color = UIColor(hex: city.markerColor) ?? .systemOrange

            // Compute lighter top-of-gradient variant via HSB
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let lighter = UIColor(hue: h, saturation: max(0, s - 0.15), brightness: min(1, b + 0.22), alpha: 1)

            // Pin body: rounded square
            let bodyRect = CGRect(x: 2, y: 0, width: 40, height: 40)
            let bodyPath = UIBezierPath(roundedRect: bodyRect, cornerRadius: 10)
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [lighter.cgColor, color.cgColor] as CFArray,
                locations: [0, 1]
            ) else { return }
            cg.saveGState()
            bodyPath.addClip()
            cg.drawLinearGradient(gradient, start: CGPoint(x: 22, y: 0), end: CGPoint(x: 22, y: 40), options: [])
            cg.restoreGState()

            // Pin tip triangle
            cg.setFillColor(color.cgColor)
            let tip = CGMutablePath()
            tip.move(to: CGPoint(x: 14, y: 37))
            tip.addLine(to: CGPoint(x: 30, y: 37))
            tip.addLine(to: CGPoint(x: 22, y: 50))
            tip.closeSubpath()
            cg.addPath(tip)
            cg.fillPath()

            // City initial: first letter of shortName, white bold
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 17, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let label = NSAttributedString(string: String(city.shortName.prefix(1)).uppercased(), attributes: attrs)
            let ts = label.size()
            label.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (40 - ts.height) / 2))
        }
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let val = UInt64(s, radix: 16) else { return nil }
        self.init(
            red:   CGFloat((val >> 16) & 0xFF) / 255,
            green: CGFloat((val >> 8)  & 0xFF) / 255,
            blue:  CGFloat( val        & 0xFF) / 255,
            alpha: 1
        )
    }
}
