import AppKit
import WebKit

/// The loading screen of a chat window: the Zeus globe in the middle, with one line of status text.
/// It lies above the chat page as a transparent layer. When the chat is ready, the globe moves to the
/// place of the chat page's own globe while the chat comes in behind it, and the layer goes away.
final class LoaderOverlay: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private let shownAt = Date()
    /// The loading screen stays at least this long, so a fast start does not look like a flicker.
    private let minimumTime: TimeInterval = 1.2
    /// The status text, also for a change that comes before the page has loaded.
    private var status: String

    init(frame: NSRect, status: String = "Starting Zeus…") {
        self.status = status
        view = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        Front.prepare(view)
        super.init()
        view.setValue(false, forKey: "drawsBackground") // The chat page shows through when the background fades.
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.navigationDelegate = self
        view.loadHTMLString(LoaderPage.html(status: status), baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setStatus(status)
    }

    /// The time that is left until the loading screen may go away.
    var remainingTime: TimeInterval { max(0, minimumTime - Date().timeIntervalSince(shownAt)) }

    func setStatus(_ text: String) {
        status = text
        run("zeusLoader.status(\(LoaderPage.quote(text)))")
    }

    /// Moves the globe to `rect` (in the page's coordinates, the same as the chat page's), over about 0.65 s.
    func moveGlobe(to rect: CGRect) {
        run("zeusLoader.handOff({x:\(rect.minX),y:\(rect.minY),width:\(rect.width),height:\(rect.height)})")
    }

    /// Fades the loading screen out as a whole. Used when the chat page has no globe to hand over to.
    func dissolve() {
        run("zeusLoader.dissolve()")
    }

    /// Fades the layer out and removes it.
    func remove(over duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            view.animator().alphaValue = 0
        }, completionHandler: { [view] in
            view.removeFromSuperview()
            completion?()
        })
    }

    private func run(_ script: String) {
        view.evaluateJavaScript("window.zeusLoader && \(script)")
    }
}

enum LoaderPage {
    /// The background of the Zeus chat page (--ink-900 in zeus-editor's chat.css).
    static let background = NSColor(srgbRed: 0x0B / 255, green: 0x25 / 255, blue: 0x45 / 255, alpha: 1)

    static func quote(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// The globe, the same code as in the Zeus chat page (zeus-editor, src/chat/client/globe.js).
    private static let globeScript: String = {
        guard let path = Bundle.main.path(forResource: "globe", ofType: "js"),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return script
    }()

    static func html(status: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html, body { margin:0; height:100%; overflow:hidden; background:transparent;
                     font:14px -apple-system, BlinkMacSystemFont, sans-serif; }
        #bg { position:fixed; inset:0; background:#0b2545; transition:opacity .5s ease-out; }
        #ambient { position:fixed; inset:0; transition:opacity .5s ease-out;
                   background:radial-gradient(circle at 50% 46%, rgba(60,130,255,.26), rgba(35,80,210,.08) 30%, rgba(11,37,69,0) 60%); }
        #globe { position:fixed; transform-origin:0 0; will-change:transform; }
        #inner { position:absolute; inset:0; animation:arrive .9s cubic-bezier(.2,.8,.2,1) both; }
        @keyframes arrive { from { opacity:0; transform:scale(.84); } }
        .zeus-globe { position:absolute; inset:0; width:100%; height:100%;
                      background:radial-gradient(circle, rgba(60,130,255,.3) 0%, rgba(40,90,220,.1) 30%, rgba(0,0,0,0) 55%); }
        #status { position:fixed; left:0; right:0; text-align:center; color:#9fb4cc; letter-spacing:.02em;
                  transition:opacity .22s ease-out; animation:arrive-text .6s ease-out .35s both; }
        @keyframes arrive-text { from { opacity:0; } }
        @media (prefers-reduced-motion: reduce) { #inner, #status { animation:none; } }
        </style></head><body>
        <div id="bg"></div><div id="ambient"></div>
        <div id="globe"><div id="inner"></div></div>
        <div id="status" role="status"></div>
        <script>\(globeScript)</script>
        <script>
        const box = document.getElementById("globe"), statusLine = document.getElementById("status");
        statusLine.textContent = \(quote(status));
        const globe = typeof createZeusGlobe === "function" ? createZeusGlobe() : null;
        if (globe) { document.getElementById("inner").append(globe.canvas); globe.setEnergy(0.55); globe.start(); }
        let place = null, moving = false;
        // The globe itself takes 54% of its canvas: here 40% of the smaller side of the window.
        function layout() {
          if (moving) return;
          const side = Math.min(innerWidth, innerHeight), size = Math.round(side * 0.75);
          place = { x: (innerWidth - size) / 2, y: (innerHeight - size) / 2 - side * 0.04, size };
          box.style.left = place.x + "px"; box.style.top = place.y + "px";
          box.style.width = box.style.height = size + "px";
          statusLine.style.top = (place.y + size * 0.97 + 6) + "px";   // Below the longest protrusion.
        }
        addEventListener("resize", layout); layout();
        window.zeusLoader = {
          status(text) {
            if (statusLine.textContent === text || moving) return;
            statusLine.style.opacity = 0;
            setTimeout(() => { statusLine.textContent = text; if (!moving) statusLine.style.opacity = 1; }, 200);
          },
          // The globe shrinks and moves to the place of the chat page's globe; the background lets the chat show.
          handOff(rect) {
            moving = true;
            statusLine.style.opacity = 0;
            document.getElementById("bg").style.opacity = 0;
            document.getElementById("ambient").style.opacity = 0;
            // The globe holds still while it moves, like the chat page's globe: then the change does not show.
            if (globe) { globe.setEnergy(0.12); globe.setCalm(true); }
            box.style.transition = "transform .65s cubic-bezier(.2,.8,.2,1)";
            box.style.transform = `translate(${rect.x - place.x}px, ${rect.y - place.y}px) scale(${rect.width / place.size})`;
          },
          dissolve() {
            moving = true;
            document.body.style.transition = "opacity .35s ease-out";
            document.body.style.opacity = 0;
          },
        };
        </script></body></html>
        """
    }
}
