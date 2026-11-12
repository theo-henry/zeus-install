import AppKit
import WebKit

/// The window of one Zeus session. It shows the loading screen (the Zeus globe) while `zeus` starts,
/// then hands over to the chat page. Closing the window ends the session.
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    let session: ZeusSession
    private let handler = WebViewHandler()
    private var webView: WKWebView!
    private var titleObservation: NSKeyValueObservation?
    private var shownURL: URL?
    /// The loading screen, above the chat page until the hand-over.
    private var loader: LoaderOverlay?
    private var handingOver = false

    var onRunSetup: (() -> Void)?
    var onRetry: (() -> Void)?
    var onClosed: ((ChatWindowController) -> Void)?

    init(session: ZeusSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Zeus"
        // The chat page draws its own header; the title bar only keeps the window buttons.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 640, height: 480)
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        // The title bar and the window have the colour of the loading screen and the chat page.
        window.backgroundColor = LoaderPage.background
        window.appearance = NSAppearance(named: .darkAqua)
        webView = handler.makeWebView()
        let content = NSView(frame: window.contentLayoutRect)
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        window.contentView = content
        window.setFrameAutosaveName("ZeusChatWindow")
        if window.frame.origin == .zero { window.center() }

        handler.openLocalWindow = { request, configuration in
            EditorWindowController.open(request: request, configuration: configuration)
        }
        handler.onScriptMessage = { [weak self] message in self?.handle(message) }
        handler.onPageLoaded = { [weak self, weak window] webView in
            WebViewHandler.matchTitleBar(of: window, to: webView)
            // A chat page without the globe (an older Zeus Editor) does not say "chat-ready": do not wait long.
            guard let self, self.shownURL != nil, webView.url == self.shownURL else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.handOver() }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            guard let self, self.shownURL != nil else { return }
            let title = webView.title ?? ""
            self.window?.title = title.isEmpty ? "Zeus" : title
        }

        session.onStateChange = { [weak self] _ in self?.render() }
        session.onLog = { [weak self] in self?.updateLoaderStatus() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        switch session.state {
        case .starting:
            shownURL = nil
            showLoader()
        case let .running(url):
            guard shownURL != url else { return }
            shownURL = url
            loader?.setStatus("Opening the chat…")
            webView.load(URLRequest(url: url))   // Behind the loading screen, until the hand-over.
        case let .failed(message):
            shownURL = nil
            window?.title = "Zeus"
            webView.loadHTMLString(StatusPage.failed(message: message, log: session.log.text), baseURL: nil)
            loader?.remove(over: 0.25)
            loader = nil
        case .ended:
            // Claude Code ended (for example /exit in the chat). The window has nothing left to show.
            window?.close()
        }
    }

    // MARK: Loading screen

    private func showLoader() {
        guard loader == nil, let content = window?.contentView else { return }
        let overlay = LoaderOverlay(frame: content.bounds)
        content.addSubview(overlay.view, positioned: .above, relativeTo: webView)
        loader = overlay
        handingOver = false
    }

    private func updateLoaderStatus() {
        guard shownURL == nil, let loader else { return }
        let updating = session.log.lines.suffix(30).contains { $0.range(of: "updat", options: .caseInsensitive) != nil }
        loader.setStatus(updating ? "Checking for updates…" : "Starting Zeus…")
    }

    /// The chat page is drawn. The loading globe moves to the place of the chat page's globe while the
    /// chat comes in behind it; then the chat page shows its own globe and the loading screen goes away.
    /// A chat page without a globe to hand over to (an older Zeus Editor, or a chat that is not empty)
    /// gets a plain cross-fade.
    private func handOver() {
        guard let loader, !handingOver, shownURL != nil else { return }
        handingOver = true
        DispatchQueue.main.asyncAfter(deadline: .now() + loader.remainingTime) { [weak self] in
            guard let self else { return }
            let question = "window.zeusGlobe ? JSON.stringify(window.zeusGlobe.rect()) : 'null'"
            self.webView.evaluateJavaScript(question) { [weak self] result, _ in
                guard let self, let loader = self.loader else { return }
                self.loader = nil
                let enter = "window.zeusGlobe && window.zeusGlobe.enter()"
                let reveal = "window.zeusGlobe && window.zeusGlobe.reveal()"
                if let rect = Self.rect(from: result) {
                    Trace.log("hand-over: globe moves to \(rect)")
                    loader.moveGlobe(to: rect)
                    self.webView.evaluateJavaScript(enter)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.68) { [weak self] in
                        self?.webView.evaluateJavaScript(reveal)
                        loader.remove(over: 0.18)
                    }
                } else {
                    Trace.log("hand-over: cross-fade")
                    self.webView.evaluateJavaScript("\(enter); \(reveal)")
                    loader.dissolve()
                    loader.remove(over: 0.4)
                }
            }
        }
    }

    private static func rect(from result: Any?) -> CGRect? {
        guard let text = result as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = object["x"] as? Double, let y = object["y"] as? Double,
              let width = object["width"] as? Double, let height = object["height"] as? Double,
              width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func handle(_ message: String) {
        switch message {
        case "chat-ready": handOver()
        case "retry": onRetry?()
        case "setup": onRunSetup?()
        case "copy-log":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.log.text, forType: .string)
        case "close": window?.close()
        default: break
        }
    }

    func reload() {
        if shownURL != nil { webView.reload() } else { render() }
    }

    func windowWillClose(_ notification: Notification) {
        session.stop()
        session.onStateChange = nil
        session.onLog = nil
        if !session.isAlive { SessionManager.shared.remove(session) }
        onClosed?(self)
    }
}

/// A Zeus Editor page that a chat page opened in a new window. It has no session of its own.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [EditorWindowController] = []
    private let handler = WebViewHandler()
    private var webView: WKWebView!
    private var titleObservation: NSKeyValueObservation?

    static func open(request: URLRequest, configuration: WKWebViewConfiguration) -> WKWebView {
        let controller = EditorWindowController(configuration: configuration)
        open.append(controller)
        controller.showWindow(nil)
        return controller.webView
    }

    private init(configuration: WKWebViewConfiguration) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Zeus Editor"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        handler.isPopup = true
        webView = handler.makeWebView(configuration: configuration)
        window.contentView = webView
        window.center()
        handler.openLocalWindow = { request, configuration in
            EditorWindowController.open(request: request, configuration: configuration)
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak window] webView, _ in
            let title = webView.title ?? ""
            window?.title = title.isEmpty ? "Zeus Editor" : title
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.open.removeAll { $0 === self }
    }
}
