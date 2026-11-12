import AppKit
import WebKit

/// The window of one Zeus session. It shows a start page while `zeus` starts, then the chat page.
/// Closing the window ends the session.
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    let session: ZeusSession
    private let handler = WebViewHandler()
    private(set) var webView: WKWebView!
    private var titleObservation: NSKeyValueObservation?
    private var logUpdateScheduled = false
    private var shownURL: URL?
    /// The startup page as a still image and the place of its logo, kept while the chat page loads.
    private var arrival: (cover: NSImageView, logo: [Double])?

    private var terminal: TerminalPanel!
    private let closeBanner = NSStackView()
    private let closeLabel = NSTextField(labelWithString: "")
    private let closeSpinner = NSProgressIndicator()
    private var closeReason: String?
    private var closePending = false
    private var closeApproved = false
    private var closeGeneration = 0
    private var onSafeClose: ((Bool) -> Void)?

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
        window.tabbingIdentifier = "ZeusChat"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 11/255, green: 37/255, blue: 69/255, alpha: 1)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        webView = handler.makeWebView()
        // The window's Zeus background shows until the first page paints, not a gray frame.
        webView.setValue(false, forKey: "drawsBackground")
        terminal = TerminalPanel(session: session)
        terminal.webView.isHidden = true
        makeCloseBanner()
        let content = NSStackView(views: [closeBanner, webView, terminal.webView])
        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .leading
        window.contentView = content
        for view in [closeBanner, webView!, terminal.webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        terminal.webView.heightAnchor.constraint(equalToConstant: 260).isActive = true
        webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        window.setFrameAutosaveName("ZeusChatWindow")
        if window.frame.origin == .zero { window.center() }

        handler.openLocalWindow = { request, configuration in
            EditorWindowController.open(request: request, configuration: configuration)
        }
        handler.onScriptMessage = { [weak self] message in self?.handle(message) }
        handler.onPageLoaded = { [weak self, weak window] webView in
            WebViewHandler.matchTitleBar(of: window, to: webView)
            self?.playArrival()
        }
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
            let fromStartPage = shownURL == nil
            shownURL = url
            if fromStartPage { loadChatAfterStartPage(url) } else { webView.load(URLRequest(url: url)) }
        case let .failed(message):
            removeArrivalCover()
            shownURL = nil
            window?.title = "Zeus"
            webView.loadHTMLString(StatusPage.failed(message: message, log: session.log.text), baseURL: nil)
        case .ended:
            // Claude Code ended (for example /exit in the chat). The window has nothing left to show.
            window?.close()
        }
    }

    /// Keeps the startup page on screen as a still image while the chat page loads, so that the
    /// logo can break into particles over the loaded chat instead of the page flashing.
    private func loadChatAfterStartPage(_ url: URL) {
        let request = URLRequest(url: url)
        let measure = "(() => { const r = document.querySelector('.mark')?.getBoundingClientRect(); return r ? [r.left, r.top, r.width] : null })()"
        webView.evaluateJavaScript(measure) { [weak self] result, _ in
            guard let self, self.shownURL == url else { return }
            guard let logo = result as? [Double], logo.count == 3 else {
                Trace.log("arrival skipped: no startup logo")
                self.webView.load(request)
                return
            }
            self.webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self, self.shownURL == url else { return }
                if let image {
                    self.removeArrivalCover()
                    let cover = NSImageView(image: image)
                    cover.imageScaling = .scaleAxesIndependently
                    cover.frame = self.webView.bounds
                    cover.autoresizingMask = [.width, .height]
                    cover.wantsLayer = true
                    self.webView.addSubview(cover)
                    self.arrival = (cover, logo)
                }
                self.webView.load(request)
            }
        }
    }

    private func playArrival() {
        guard let arrival, shownURL != nil else { return }
        self.arrival = nil
        let cover = arrival.cover
        var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #if DEBUG
        // Records the animation on a Mac that has Reduce motion on.
        if ProcessInfo.processInfo.environment["ZEUS_APP_FORCE_MOTION"] == "1" { reduceMotion = false }
        #endif
        let arguments: [String: Any] = ["left": arrival.logo[0], "top": arrival.logo[1], "size": arrival.logo[2],
                                        "logo": Brand.logo, "reduce": reduceMotion]
        webView.callAsyncJavaScript(StatusPage.arrivalScript, arguments: arguments, in: nil, in: .page) { result in
            Trace.log("arrival: \(result)")
            guard !reduceMotion else { cover.removeFromSuperview(); return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cover.animator().alphaValue = 0
            }, completionHandler: { cover.removeFromSuperview() })
        }
    }

    private func removeArrivalCover() {
        arrival?.cover.removeFromSuperview()
        arrival = nil
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
        case "close": window?.performClose(nil)
        default: break
        }
    }

    func reload() {
        if shownURL != nil { webView.reload() } else { render() }
    }

    @objc func toggleTerminal(_ sender: Any? = nil) {
        terminal.webView.isHidden.toggle()
        if !terminal.webView.isHidden { terminal.focus() }
        else { window?.makeFirstResponder(webView) }
        Trace.log("terminal visible: \(session.pid) \(!terminal.webView.isHidden)")
    }

    func testTerminalInput() { terminal.webView.evaluateJavaScript("term.input('terminal-test\\r', true)") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved || !session.isAlive { return true }
        requestSafeClose()
        return false
    }

    /// The chat is the authority for work, draft text, attachments, and pending sends.
    /// Missing or failed checks retain both the page and PTY and retry until cancelled.
    func requestSafeClose(completion: ((Bool) -> Void)? = nil) {
        if let completion { onSafeClose = completion }
        guard !closePending else { return }
        closePending = true
        closeGeneration += 1
        closeReason = nil
        closeLabel.stringValue = "Checking the chat before the tab closes…"
        closeBanner.isHidden = false
        closeSpinner.startAnimation(nil)
        checkClose(generation: closeGeneration)
    }

    @objc func cancelClose() {
        closeGeneration += 1
        closePending = false
        closeBanner.isHidden = true
        closeSpinner.stopAnimation(nil)
        let callback = onSafeClose
        onSafeClose = nil
        callback?(false)
        Trace.log("close cancelled: \(session.pid)")
    }

    private func checkClose(generation: Int) {
        guard closePending, generation == closeGeneration else { return }
        guard session.isAlive, shownURL != nil else { finishClose(); return }
        webView.callAsyncJavaScript("return await window.zeusApp?.closeState()", arguments: [:],
                                   in: nil, in: .page) { [weak self] result in
            guard let self, self.closePending, generation == self.closeGeneration else { return }
            var reason = "unavailable"
            if case let .success(value) = result, let state = value as? [String: Any] {
                if state["safe_to_close"] as? Bool == true { self.finishClose(); return }
                reason = state["reason"] as? String ?? reason
            }
            if reason != self.closeReason {
                self.closeReason = reason
                self.closeLabel.stringValue = Self.closeMessage(for: reason)
                Trace.log("close deferred: \(self.session.pid) \(reason)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkClose(generation: generation)
            }
        }
    }

    /// The reasons of window.zeusApp.closeState() (zeus-editor docs/chat.md), in words.
    static func closeMessage(for reason: String) -> String {
        switch reason {
        case "composer-draft": return "The message box has unsent text or files. Send or clear them, and the tab closes."
        case "pending-message": return "A message is still on its way to Zeus. The tab closes when it arrives."
        case "busy": return "Zeus is working. The tab closes when Zeus finishes."
        case "starting": return "Zeus is starting. The tab closes when it is ready."
        case "terminal-draft": return "The terminal has unsent text. Clear it (Cmd+J), and the tab closes."
        default: return "Zeus cannot check this chat now, so the tab stays open."
        }
    }

    private func makeCloseBanner() {
        closeBanner.orientation = .horizontal
        closeBanner.alignment = .centerY
        closeBanner.spacing = 10
        closeBanner.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        closeBanner.wantsLayer = true
        closeBanner.layer?.backgroundColor = Brand.nsSurface.cgColor
        closeSpinner.style = .spinning
        closeSpinner.controlSize = .small
        closeSpinner.appearance = NSAppearance(named: .darkAqua)
        closeLabel.font = NSFont(name: "ObjectSans-Regular", size: 13) ?? .systemFont(ofSize: 13)
        closeLabel.textColor = Brand.nsForeground
        closeLabel.lineBreakMode = .byTruncatingTail
        closeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "", target: self, action: #selector(cancelClose))
        cancel.isBordered = false
        cancel.attributedTitle = NSAttributedString(string: "Cancel close", attributes: [
            .foregroundColor: Brand.nsLink, .font: NSFont(name: "PPObjectSans-Semibold", size: 13) ?? .boldSystemFont(ofSize: 13),
        ])
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [closeSpinner, closeLabel, spacer, cancel] { closeBanner.addArrangedSubview(view) }
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Brand.nsLine
        line.translatesAutoresizingMaskIntoConstraints = false
        closeBanner.addSubview(line)
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: closeBanner.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: closeBanner.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: closeBanner.bottomAnchor),
        ])
        closeBanner.isHidden = true
    }

    private func finishClose() {
        closeApproved = true
        closePending = false
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        closeGeneration += 1
        terminal.detach()
        session.stop()
        session.onStateChange = nil
        session.onLog = nil
        if !session.isAlive { SessionManager.shared.remove(session) }
        onClosed?(self)
        let callback = onSafeClose
        onSafeClose = nil
        callback?(true)
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
