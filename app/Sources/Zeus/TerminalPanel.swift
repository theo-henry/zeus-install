import AppKit
import WebKit

/// A local-only terminal renderer. Its bridge is never installed in the chat WebView.
/// It shows one hidden terminal at a time: the `zeus` session of the tab, or the Google sign-in of EU mode.
final class TerminalPanel: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private weak var session: TerminalSource?
    private var ready = false
    private var pending = Data()
    /// The last size of the terminal, which a newly attached source gets.
    private var size: (rows: UInt16, cols: UInt16)?

    init(session: TerminalSource) {
        self.session = session
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        Front.prepare(webView)
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

    /// Shows another hidden terminal from now on, on a clear screen. The old one no longer gets the typing.
    func attach(_ source: TerminalSource) {
        session?.onOutput = nil
        session = source
        pending.removeAll()
        if ready { webView.evaluateJavaScript("window.term.reset()") }
        source.onOutput = { [weak self] data in self?.append(data) }
        if let size { source.resize(rows: size.rows, cols: size.cols) }
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
            Trace.log("terminal ready: \(pid)")
        }
        if let input = body["input"] as? String {
            Trace.log("terminal input: \(pid) chars=\(input.count)")
            session?.write(input)
        }
        if let rows = body["rows"] as? Int, let cols = body["cols"] as? Int,
           (2...500).contains(rows), (2...500).contains(cols) {
            size = (UInt16(rows), UInt16(cols))
            session?.resize(rows: UInt16(rows), cols: UInt16(cols))
        }
    }

    private var pid: pid_t { session?.terminalPID ?? 0 }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
