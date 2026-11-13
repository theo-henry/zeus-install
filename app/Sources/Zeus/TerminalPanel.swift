import AppKit
import WebKit

/// A local-only terminal renderer. Its bridge is never installed in the chat WebView.
final class TerminalPanel: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private weak var session: ZeusSession?
    private var ready = false
    private var pending = Data()

    init(session: ZeusSession) {
        self.session = session
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "terminal")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Terminal") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        session.onOutput = { [weak self] data in self?.append(data) }
    }

    func detach() {
        session?.onOutput = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
    }

    private func append(_ data: Data) {
        guard ready else {
            pending.append(data)
            // Bound startup buffering if WebKit fails to load.
            if pending.count > 2_000_000 { pending.removeFirst(pending.count - 2_000_000) }
            return
        }
        webView.evaluateJavaScript("window.writeBytes('\(data.base64EncodedString())')")
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.fitTerminal(); window.term.focus()") }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any] else { return }
        if body["ready"] as? Bool == true {
            ready = true
            append(pending)
            pending.removeAll()
            Trace.log("terminal ready: \(session?.pid ?? 0)")
        }
        if let input = body["input"] as? String {
            Trace.log("terminal input: \(session?.pid ?? 0) chars=\(input.count)")
            session?.write(input)
        }
        if let rows = body["rows"] as? Int, let cols = body["cols"] as? Int,
           (2...500).contains(rows), (2...500).contains(cols) {
            session?.resize(rows: UInt16(rows), cols: UInt16(cols))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
