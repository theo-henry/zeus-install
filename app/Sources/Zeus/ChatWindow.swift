import AppKit
import WebKit

/// The window of one Zeus session. It shows a start page while `zeus` starts, then the chat page.
/// Closing the window ends the session.
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    let session: ZeusSession
    private let handler = WebViewHandler()
    private var webView: WKWebView!
    private var titleObservation: NSKeyValueObservation?
    private var logUpdateScheduled = false
    private var shownURL: URL?

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

        webView = handler.makeWebView()
        window.contentView = webView
        window.setFrameAutosaveName("ZeusChatWindow")
        if window.frame.origin == .zero { window.center() }

        handler.openLocalWindow = { request, configuration in
            EditorWindowController.open(request: request, configuration: configuration)
        }
        handler.onScriptMessage = { [weak self] message in self?.handle(message) }
        handler.onPageLoaded = { [weak window] webView in WebViewHandler.matchTitleBar(of: window, to: webView) }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            guard let self, self.shownURL != nil else { return }
            let title = webView.title ?? ""
            self.window?.title = title.isEmpty ? "Zeus" : title
        }

        session.onStateChange = { [weak self] _ in self?.render() }
        session.onLog = { [weak self] in self?.scheduleLogUpdate() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        switch session.state {
        case .starting:
            shownURL = nil
            webView.loadHTMLString(StatusPage.starting(log: session.log.text), baseURL: nil)
        case let .running(url):
            guard shownURL != url else { return }
            shownURL = url
            webView.load(URLRequest(url: url))
        case let .failed(message):
            shownURL = nil
            window?.title = "Zeus"
            webView.loadHTMLString(StatusPage.failed(message: message, log: session.log.text), baseURL: nil)
        case .ended:
            // Claude Code ended (for example /exit in the chat). The window has nothing left to show.
            window?.close()
        }
    }

    private func scheduleLogUpdate() {
        guard shownURL == nil, !logUpdateScheduled else { return }
        logUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.logUpdateScheduled = false
            guard self.shownURL == nil else { return }
            let text = self.session.log.text
            guard let json = try? JSONSerialization.data(withJSONObject: [text]),
                  let literal = String(data: json, encoding: .utf8) else { return }
            self.webView.evaluateJavaScript("window.zeusSetLog && window.zeusSetLog(\(literal)[0])")
        }
    }

    private func handle(_ message: String) {
        switch message {
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
