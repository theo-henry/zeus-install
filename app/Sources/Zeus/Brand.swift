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
    static var logoImage: NSImage? {
        Bundle.main.url(forResource: "zeus-logo", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    }
    static var fontCSS: String {
        ["regular", "semibold"].map { weight in
            guard let url = Bundle.main.url(forResource: "object-sans-" + weight, withExtension: "woff"),
                  let data = try? Data(contentsOf: url) else { return "" }
            return "@font-face{font-family:Object Sans;src:url(data:font/woff;base64,\(data.base64EncodedString())) format('woff');font-weight:\(weight == "regular" ? "400" : "600 800");font-display:swap}"
        }.joined()
    }
}
