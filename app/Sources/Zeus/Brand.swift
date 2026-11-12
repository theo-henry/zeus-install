import AppKit
import CoreText
import Foundation
import SwiftUI

enum Brand {
    static func registerFonts() {
        for weight in ["regular", "semibold"] {
            if let url = Bundle.main.url(forResource: "object-sans-" + weight, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    // zeus-editor/src/chat/chat.css: Pitch Black surfaces and Venus Blue actions.
    static let background = Color(red: 11/255, green: 37/255, blue: 69/255)
    static let surface = Color(red: 9/255, green: 32/255, blue: 57/255)
    static let foreground = Color(red: 241/255, green: 246/255, blue: 249/255)
    static let accent = Color(red: 55/255, green: 114/255, blue: 1)
    static let nsSurface = NSColor(srgbRed: 13/255, green: 42/255, blue: 78/255, alpha: 1)
    static let nsForeground = NSColor(srgbRed: 241/255, green: 246/255, blue: 249/255, alpha: 1)
    static let nsLine = NSColor(srgbRed: 26/255, green: 58/255, blue: 100/255, alpha: 1)
    static let nsLink = NSColor(srgbRed: 91/255, green: 140/255, blue: 1, alpha: 1)
    static var logo: String {
        guard let url = Bundle.main.url(forResource: "zeus-logo", withExtension: "svg"),
              let svg = try? String(contentsOf: url) else { return "" }
        return svg
    }
    static var fontCSS: String {
        ["regular", "semibold"].map { weight in
            guard let url = Bundle.main.url(forResource: "object-sans-" + weight, withExtension: "woff"),
                  let data = try? Data(contentsOf: url) else { return "" }
            return "@font-face{font-family:Object Sans;src:url(data:font/woff;base64,\(data.base64EncodedString())) format('woff');font-weight:\(weight == "regular" ? "400" : "600 800");font-display:swap}"
        }.joined()
    }
}

/// The chat's vector mark (zeus-logo.svg, view box 246 240 540 540), drawn natively so it shows at once.
struct ZeusMark: View {
    private static func polygon(_ points: [(CGFloat, CGFloat)], _ map: (CGFloat, CGFloat) -> CGPoint) -> Path {
        var path = Path()
        path.addLines(points.map { map($0.0, $0.1) })
        path.closeSubpath()
        return path
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 540
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 246) * scale, y: (y - 240) * scale) }
            let ink = Color(red: 241/255, green: 246/255, blue: 249/255)
            let ring = Path(ellipseIn: CGRect(origin: map(300, 326), size: CGSize(width: 372 * scale, height: 372 * scale)))
            context.stroke(ring, with: .color(ink), lineWidth: 83.7 * scale)
            let stem = Self.polygon([(674.7, 324.4), (766.9, 324.4), (723.5, 512), (766.9, 699.6), (674.7, 699.6)], map)
            context.fill(stem, with: .color(ink))
            context.stroke(stem, with: .color(ink), style: StrokeStyle(lineWidth: 14.8 * scale, lineJoin: .round))
            let bolt = Self.polygon([(679.1, 278.4), (379.4, 507.6), (472.1, 545), (328.4, 740.6), (628.1, 511.4), (535.4, 474)], map)
            context.stroke(bolt, with: .color(Brand.accent.opacity(0.18)), style: StrokeStyle(lineWidth: 46 * scale, lineJoin: .round))
            context.stroke(bolt, with: .color(Brand.background), style: StrokeStyle(lineWidth: 26 * scale, lineJoin: .round))
            let gradient = Gradient(stops: [
                .init(color: Color(red: 214/255, green: 227/255, blue: 1), location: 0),
                .init(color: Color(red: 106/255, green: 152/255, blue: 1), location: 0.35),
                .init(color: Color(red: 29/255, green: 70/255, blue: 200/255), location: 1),
            ])
            let fill = GraphicsContext.Shading.linearGradient(gradient, startPoint: map(0, 278.4), endPoint: map(0, 740.6))
            context.fill(bolt, with: fill)
            context.stroke(bolt, with: fill, style: StrokeStyle(lineWidth: 4 * scale, lineJoin: .round))
        }
    }
}
