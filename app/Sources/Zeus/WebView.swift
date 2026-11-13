import AppKit
import UniformTypeIdentifiers
import WebKit

/// Web view behaviour that the chat window and the editor windows share: Zeus pages on this Mac
/// stay in the app, every other link opens in the default browser.
final class WebViewHandler: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    /// Called with the URL of a Zeus page that asks for a new window.
    var openLocalWindow: ((URLRequest, WKWebViewConfiguration) -> WKWebView?)?
    /// Called for a message from a page: a string from a status page ("retry", "setup", ...),
    /// or an object from the chat page ({type: "project", ...}).
    var onScriptMessage: ((Any) -> Void)?
    /// A pop-up window that has loaded nothing yet closes when its first page is not a Zeus page.
    var isPopup = false
    /// Called when a page has loaded.
    var onPageLoaded: ((WKWebView) -> Void)?
    /// Called when a page cannot load or stops loading.
    var onPageFailed: (() -> Void)?

    static func isLocal(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return true }
        guard url.scheme == "http" || url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Pop-ups (Zeus Editor pages) get this configuration too, so every Zeus page can use speech to text.
        configuration.userContentController.addUserScript(SpeechService.availabilityScript)
        return configuration
    }

    /// A pop-up gets the configuration of the page that opened it, which already has the bridge.
    func makeWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let configuration = configuration ?? {
            let fresh = WebViewHandler.makeConfiguration()
            fresh.userContentController.add(ScriptBridge(handler: self), name: "zeusApp")
            return fresh
        }()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        Front.prepare(webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #if DEBUG
        // A test app behind the other apps: its pages keep running and drawing while other windows cover them.
        let setOcclusionDetection = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if ProcessInfo.processInfo.environment["ZEUS_APP_TEST_BACKGROUND"] == "1", webView.responds(to: setOcclusionDetection) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: setOcclusionDetection), to: Setter.self)(webView, setOcclusionDetection, false)
        }
        #endif
        return webView
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Frames inside a Zeus page can load what they need; only top-level pages leave the app.
        if action.targetFrame?.isMainFrame == false || WebViewHandler.isLocal(url) {
            decisionHandler(.allow)
            return
        }
        if let url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
        if isPopup, webView.url == nil || webView.url?.absoluteString == "about:blank" {
            DispatchQueue.main.async { webView.window?.close() }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.canShowMIMEType { decisionHandler(.allow) } else { decisionHandler(.download) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { result in completionHandler(result == .OK ? panel.url : nil) }
    }

    /// A new page replaces the page that had speech to text on.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        SpeechService.shared.cancel(in: webView, reason: "page changed")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Trace.log("page loaded: \(webView.url?.absoluteString.components(separatedBy: "#").first ?? "-") title=\(webView.title ?? "")")
        onPageLoaded?(webView)
    }

    /// Gives the title bar the background colour of the page, so that the window looks like one surface.
    static func matchTitleBar(of window: NSWindow?, to webView: WKWebView) {
        let script = "getComputedStyle(document.body).backgroundColor"
        webView.evaluateJavaScript(script) { result, _ in
            guard let window, let text = result as? String else { return }
            let numbers = text.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap(Double.init)
            guard numbers.count >= 3, numbers.count < 4 || numbers[3] > 0 else { return }
            let color = NSColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1)
            window.backgroundColor = color
            let brightness = 0.299 * numbers[0] + 0.587 * numbers[1] + 0.114 * numbers[2]
            window.appearance = NSAppearance(named: brightness < 128 ? .darkAqua : .aqua)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Trace.log("page failed: \(error.localizedDescription)")
        onPageFailed?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Trace.log("page failed to load: \(error.localizedDescription)")
        onPageFailed?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        SpeechService.shared.cancel(in: webView, reason: "page process ended")
        webView.reload()
    }

    // MARK: Windows and panels

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // An empty URL is window.open() that sets the address later; the pop-up handles that case.
        let url = action.request.url
        if url == nil || url?.absoluteString == "" || WebViewHandler.isLocal(url) {
            return openLocalWindow?(action.request, configuration)
        }
        if let url, url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.window?.performClose(nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        present(alert, in: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    private func present(_ alert: NSAlert, in webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            Front.beginSheet(alert, for: window, completion: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// Holds the handler weakly, because WKUserContentController keeps its message handlers.
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    weak var handler: WebViewHandler?
    init(handler: WebViewHandler) { self.handler = handler }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Frames inside a page can come from other sites; only the page itself talks to the app.
        guard message.frameInfo.isMainFrame else { return }
        // Speech messages go to the page that sent them, also from a Zeus Editor pop-up of a closed chat tab.
        if SpeechService.shared.handle(message.body, from: message.webView) { return }
        handler?.onScriptMessage?(message.body)
    }
}
