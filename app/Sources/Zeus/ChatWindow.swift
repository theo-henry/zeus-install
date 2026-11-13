import AppKit
import WebKit

/// The tab of one Zeus session in a chat window. It shows the loading screen (the Zeus globe) while `zeus` starts,
/// then hands over to the chat page. Closing the tab ends the session. The host switch replaces the session
/// with a new one on the other Claude host, in the same tab.
final class ChatTab: NSObject {
    private(set) var session: ZeusSession
    /// The cost that the chat page of this session reported last.
    private(set) var cost: SessionCost?
    /// A host switch runs (its question, the EU handoff, or its summary): the switch waits for it.
    private(set) var switching = false
    /// Counts the sessions of this tab, so that a late callback of an earlier session does nothing.
    private var generation = 0
    private var handoff: HandoffFlow?
    /// The chat page of a replaced session stays out of sight (its "session ended" text) until the next page has loaded.
    private var pageHidden = false
    /// An opaque cover over the old page during a host switch. Not alphaValue 0: WebKit stops painting a
    /// transparent web view and may not paint again when it becomes visible (a blank tab after the switch).
    private var curtain: NSView?
    /// The content of the tab: the close banner, the page, and the terminal.
    let view = NSStackView()
    /// The window that shows the tab.
    weak var host: ChatWindowController?
    private let handler = WebViewHandler()
    private(set) var webView: WKWebView!
    /// The name of the tab: the project of the chat, or a name that the user gave it.
    let tabName = TabName()
    private var shownURL: URL?
    /// The loading screen, above the chat page until the hand-over.
    private var loader: LoaderOverlay?
    private var handingOver = false
    /// The globe hand-over plays once per app run, for the first chat. Later chats (Cmd+T, a retry)
    /// come in at once when their page is ready: the user does not wait for the animation again.
    private static var greeted = false

    private var terminal: TerminalPanel!
    private let closeBanner = NSStackView()
    private let closeLabel = NSTextField(labelWithString: "")
    private let closeSpinner = NSProgressIndicator()
    private let closeAnywayButton = NSButton()
    private let cancelCloseButton = NSButton()
    private var closeReason: String?
    private var closeRequestedAt = Date()
    private var closePending = false
    private var closeApproved = false
    private var closeGeneration = 0
    private var closed = false

    var onRunSetup: (() -> Void)?
    var onClosed: ((ChatTab) -> Void)?
    /// Starts a session on a host for this tab; nil when it cannot start (the app says why).
    var startSession: ((ClaudeHost) -> ZeusSession?)?

    init(session: ZeusSession) {
        self.session = session
        super.init()

        webView = handler.makeWebView()
        webView.configuration.userContentController.addUserScript(TabName.projectScript)
        // The window's Zeus background shows until the first page paints, not a gray frame.
        webView.setValue(false, forKey: "drawsBackground")
        terminal = TerminalPanel(session: session)
        terminal.webView.isHidden = true
        makeCloseBanner()
        let content = self.view
        for part in [closeBanner, webView!, terminal.webView] { content.addArrangedSubview(part) }
        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .leading
        for view in [closeBanner, webView!, terminal.webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        terminal.webView.heightAnchor.constraint(equalToConstant: 260).isActive = true
        webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        handler.openLocalWindow = { request, configuration in
            EditorWindowController.open(request: request, configuration: configuration)
        }
        handler.onScriptMessage = { [weak self] message in self?.handle(message) }
        handler.onPageLoaded = { [weak self] webView in
            guard let self else { return }
            if self.pageHidden, (self.shownURL != nil && webView.url == self.shownURL) || self.isFailed {
                self.pageHidden = false
                self.curtain?.removeFromSuperview()
                self.curtain = nil
            }
            if self.host?.selectedTab === self { WebViewHandler.matchTitleBar(of: webView.window, to: webView) }
            guard self.shownURL != nil, webView.url == self.shownURL else { return }
            // After the first chat, the page comes in as soon as it is loaded.
            guard !Self.greeted else { self.handOver(); return }
            // A chat page without the globe (an older Zeus Editor) does not say "chat-ready": do not wait long.
            let generation = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.handOver()
            }
        }
        // A chat page that does not load must not stay behind the loading screen.
        handler.onPageFailed = { [weak self] in self?.handOver() }

        attach(session)
    }

    /// Follows a session: the tab shows its state from now on.
    private func attach(_ session: ZeusSession) {
        session.onStateChange = { [weak self, weak session] _ in
            guard let self, session === self.session else { return }
            self.render()
        }
        session.onLog = { [weak self, weak session] in
            guard let self, session === self.session else { return }
            self.updateLoaderStatus()
        }
        render()
        updateLoaderStatus()
        host?.tabStateChanged(self)
    }

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
            webView.loadHTMLString(StatusPage.failed(message: message, log: session.log.text, host: session.host), baseURL: nil)
            if let loader { dismiss(loader, over: 0.25) }
            loader = nil
        case .ended:
            // Claude Code ended (for example /exit in the chat). The tab has nothing left to show.
            finishClose()
        }
    }

    // MARK: Loading screen

    /// The loading screen covers the chat page only: the close banner and the terminal panel stay usable.
    /// It has the chat page's frame, so the globe's place in the chat page is also its place here.
    private func showLoader() {
        guard loader == nil else { return }
        let overlay = LoaderOverlay(frame: webView.frame)
        cover(with: overlay.view)
        loader = overlay
        handingOver = false
    }

    /// Puts a view over the chat page only, in its frame: the close banner and the terminal panel stay usable.
    /// A later view lies below the views that cover the page already (the handoff step stays on top until it fades).
    func cover(with view: NSView) {
        let content = self.view
        view.translatesAutoresizingMaskIntoConstraints = false
        // Above the switch cover, so the loading screen draws over it once its page has loaded.
        content.addSubview(view, positioned: .above, relativeTo: curtain ?? webView)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            view.topAnchor.constraint(equalTo: webView.topAnchor),
            view.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
    }

    /// Removes the loading screen. When it had the keyboard focus, the chat page gets it.
    private func dismiss(_ loader: LoaderOverlay, over duration: TimeInterval) {
        loader.remove(over: duration) { [weak self] in
            guard let self, let window = self.view.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self.webView)
        }
    }

    private func updateLoaderStatus() {
        guard shownURL == nil, let loader else { return }
        if let status = session.startStatus {
            loader.setStatus(status)
            return
        }
        let updating = session.log.lines.suffix(30).contains { $0.range(of: "updat", options: .caseInsensitive) != nil }
        loader.setStatus(updating ? "Checking for updates…" : session.host == .eu ? "Starting Zeus on EU…" : "Starting Zeus…")
    }

    /// The chat page is drawn. The loading globe moves to the place of the chat page's globe while the
    /// chat comes in behind it; then the chat page shows its own globe and the loading screen goes away.
    /// A chat page without a globe to hand over to (an older Zeus Editor, or a chat that is not empty)
    /// gets a plain cross-fade. After the first chat of the app run, the chat comes in at once.
    private func handOver() {
        guard let loader, !handingOver, shownURL != nil else { return }
        handingOver = true
        let generation = self.generation
        if Self.greeted {
            Trace.log("hand-over: at once")
            self.loader = nil
            webView.evaluateJavaScript("window.zeusGlobe && (window.zeusGlobe.enter(), window.zeusGlobe.reveal())")
            dismiss(loader, over: 0.15)
            return
        }
        Self.greeted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + loader.remainingTime) { [weak self] in
            guard let self, self.generation == generation else { return }
            let question = "window.zeusGlobe ? JSON.stringify(window.zeusGlobe.rect()) : 'null'"
            self.webView.evaluateJavaScript(question) { [weak self] result, _ in
                guard let self, self.generation == generation, let loader = self.loader else { return }
                self.loader = nil
                let enter = "window.zeusGlobe && window.zeusGlobe.enter()"
                let reveal = "window.zeusGlobe && window.zeusGlobe.reveal()"
                if let rect = Self.rect(from: result) {
                    Trace.log("hand-over: globe moves to \(rect)")
                    loader.moveGlobe(to: rect)
                    self.webView.evaluateJavaScript(enter)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.68) { [weak self] in
                        self?.webView.evaluateJavaScript(reveal)
                        self?.dismiss(loader, over: 0.18)
                    }
                } else {
                    Trace.log("hand-over: cross-fade")
                    self.webView.evaluateJavaScript("\(enter); \(reveal)")
                    loader.dissolve()
                    self.dismiss(loader, over: 0.4)
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

    private func handle(_ body: Any) {
        if let message = body as? [String: Any] {
            if let project = TabName.project(from: message) { tabName.setProject(project) }
            return
        }
        guard let message = body as? String else { return }
        // "cost:<JSON>": the chat page passes on the session cost that the editor counted (zeus-editor docs/chat.md, "Session cost").
        if message.hasPrefix("cost:") {
            receiveCost(String(message.dropFirst(5)))
            return
        }
        switch message {
        case "chat-ready":
            // After a reload of the page there is no loading screen: the page comes in at once.
            if loader == nil {
                webView.evaluateJavaScript("window.zeusGlobe && (window.zeusGlobe.enter(), window.zeusGlobe.reveal())")
            } else {
                handOver()
            }
        case "retry": replaceSession(host: session.host)
        case "setup": onRunSetup?()
        case "copy-log":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.log.text, forType: .string)
        case "close": host?.close(self)
        // "Go to the chat" in Zeus Editor: the chat of this tab must come to the front with the keyboard in it.
        case "chat-focus": host?.bringToFront(self)
        default: break
        }
    }

    // MARK: Claude host

    private func receiveCost(_ json: String) {
        guard shownURL != nil, let reported = SessionCost(json: json) else { return }
        // A report for another host is from a page of the session that this tab just replaced.
        guard reported.host.isEmpty || reported.host == session.host.rawValue else { return }
        guard reported != cost else { return }
        cost = reported
        Trace.log("cost: \(reported.label) on \(session.host.rawValue) shown=\(Preferences.showCost(on: session.host))")
        host?.tabStateChanged(self)
    }

    /// The consultant picked the other host. From EU to Apolix, the app first hands off the EU work
    /// (HandoffFlow); otherwise a running chat is asked about first, and a tab that still loads, or
    /// that failed to start, switches at once.
    func requestSwitch(to target: ClaudeHost) {
        guard target != session.host, !switching else { return }
        switching = true
        host?.tabStateChanged(self)
        if session.host == .eu, target == .apolix {
            let flow = HandoffFlow(tab: self)
            handoff = flow
            flow.start { [weak self] outcome in
                guard let self else { return }
                self.handoff = nil
                switch outcome {
                case .noHandoffNeeded: self.confirmSwitch(to: target)
                case .switchNow: self.finishSwitch(to: target)
                case .stay: self.cancelSwitch()
                }
            }
            return
        }
        confirmSwitch(to: target)
    }

    private func cancelSwitch() {
        switching = false
        Trace.log("host switch cancelled: \(session.host.rawValue)")
        host?.tabStateChanged(self)
    }

    private func finishSwitch(to target: ClaudeHost) {
        switching = false
        replaceSession(host: target)
    }

    /// Asks before a running chat stops. A tab whose chat does not run switches at once.
    private func confirmSwitch(to target: ClaudeHost) {
        guard case .running = session.state, let window = view.window else {
            finishSwitch(to: target)
            return
        }
        closeState { [weak self] reason in
            guard let self, self.switching else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["ZEUS_APP_TEST_NO_SWITCH_QUESTION"] == "1" {
                self.finishSwitch(to: target)
                return
            }
            #endif
            let alert = NSAlert()
            alert.messageText = "Switch this tab to \(target.title)?"
            var text = "Zeus stops the session in this tab and starts a new one on \(target.summary). "
            text += target == .eu
                ? "Your chats stay in the chat history, and you can continue them on EU."
                : "Your chats stay in the chat history. A chat that ran on EU stays an EU chat: you can read it here, but you can continue it only on EU."
            if let reason, reason != "unavailable" { text += "\n\nNow " + ChatTab.closeSummary(for: reason) + ". The switch stops that." }
            alert.informativeText = text
            alert.addButton(withTitle: "Switch to \(target.title)")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.finishSwitch(to: target) } else { self?.cancelSwitch() }
            }
        }
    }

    /// Stops this tab's session and starts a new one on `host` in its place. Also used for "Try again".
    func replaceSession(host target: ClaudeHost) {
        if target != session.host { Preferences.lastHost = target }
        // Start first: when the new session cannot start, the tab keeps the one it has.
        guard let next = startSession?(target) else {
            host?.tabStateChanged(self)
            return
        }
        // The loading screen covers the page before the old session stops, and the old page goes out of sight
        // at once: the loading screen draws only after its own page has loaded.
        pageHidden = true
        if curtain == nil {
            let cover = NSView()
            cover.wantsLayer = true
            cover.layer?.backgroundColor = NSColor(srgbRed: 11 / 255, green: 37 / 255, blue: 69 / 255, alpha: 1).cgColor
            self.cover(with: cover)
            curtain = cover
        }
        let old = session
        old.onStateChange = nil
        old.onLog = nil
        old.stop()
        if !old.isAlive { SessionManager.shared.remove(old) }
        Trace.log("tab: session \(old.pid) on \(old.host.rawValue) replaced by a session on \(target.rawValue)")

        SpeechService.shared.cancel(in: webView, reason: "session replaced")
        generation += 1
        session = next
        cost = nil
        shownURL = nil
        closeReason = nil
        // A loading screen that already moves away belonged to the old chat page.
        if handingOver, let loader {
            loader.remove(over: 0.1)
            self.loader = nil
        }
        handingOver = false
        // The old chat page stops; the loading screen covers the tab until the new one is ready.
        showLoader()
        webView.loadHTMLString(StatusPage.blank, baseURL: nil)
        terminal.show(next)
        attach(next)
    }

    #if DEBUG
    /// The handoff flow that runs, for the test actions.
    var runningHandoff: HandoffFlow? { handoff }
    #endif

    private var isFailed: Bool {
        if case .failed = session.state { return true }
        return false
    }

    /// The view that the handoff step covers: the chat page, as the loading screen does.
    var pageView: NSView { webView }

    func reload() {
        if shownURL != nil { webView.reload() } else { render() }
    }

    @objc func toggleTerminal(_ sender: Any? = nil) {
        terminal.webView.isHidden.toggle()
        if !terminal.webView.isHidden { terminal.focus() }
        else { view.window?.makeFirstResponder(webView) }
        Trace.log("terminal visible: \(session.pid) \(!terminal.webView.isHidden)")
    }

    func testTerminalInput() { terminal.webView.evaluateJavaScript("term.input('terminal-test\\r', true)") }

    /// The view that gets the keyboard when the tab shows.
    var focusView: NSView { terminal.webView.isHidden ? webView : terminal.webView }

    /// Closes the tab at once when its session has ended, else after the safe-close check.
    func requestClose() {
        if closeApproved || !session.isAlive { finishClose() } else { requestSafeClose() }
    }

    /// The chat is the authority for work, draft text, attachments, and pending sends. The tab stays
    /// open while the chat says it is not safe to close, until the user cancels or closes it anyway.
    func requestSafeClose() {
        guard !closePending else { return }
        closePending = true
        closeGeneration += 1
        closeReason = nil
        closeRequestedAt = Date()
        closeLabel.stringValue = "Checking the chat before the tab closes…"
        closeAnywayButton.isHidden = true
        setCancelTitle("Cancel close")
        closeBanner.isHidden = false
        closeSpinner.startAnimation(nil)
        checkClose(generation: closeGeneration)
    }

    @objc func cancelClose() {
        closeGeneration += 1
        closePending = false
        closeBanner.isHidden = true
        closeSpinner.stopAnimation(nil)
        Trace.log("close cancelled: \(session.pid)")
    }

    @objc func closeAnyway() {
        Trace.log("close anyway: \(session.pid) \(closeReason ?? "-")")
        finishClose()
    }

    /// Asks the chat once if the tab can close. Calls back with nil when it is safe, else with the reason.
    /// A chat that cannot answer within `closeCheckLimit` seconds (no window.zeusApp, an error, no reply) is "unavailable".
    func closeState(completion: @escaping (String?) -> Void) {
        guard session.isAlive, shownURL != nil else { completion(nil); return }
        var answered = false
        let answer = { (reason: String?) in
            guard !answered else { return }
            answered = true
            completion(reason)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeCheckLimit) { answer("unavailable") }
        webView.callAsyncJavaScript("return await window.zeusApp?.closeState()", arguments: [:],
                                   in: nil, in: .page) { result in
            guard case let .success(value) = result, let state = value as? [String: Any] else {
                answer("unavailable")
                return
            }
            answer(state["safe_to_close"] as? Bool == true ? nil : state["reason"] as? String ?? "unavailable")
        }
    }

    /// How long the app waits for a chat that cannot answer before it offers to close anyway.
    static let closeCheckLimit: TimeInterval = 3

    private func checkClose(generation: Int) {
        guard closePending, generation == closeGeneration else { return }
        closeState { [weak self] reason in
            guard let self, self.closePending, generation == self.closeGeneration else { return }
            guard let reason else { self.finishClose(); return }
            let waiting = reason == "unavailable" && Date().timeIntervalSince(self.closeRequestedAt) < Self.closeCheckLimit
            if !waiting, reason != self.closeReason {
                self.closeReason = reason
                self.closeLabel.stringValue = Self.closeMessage(for: reason)
                self.setCancelTitle(reason == "unavailable" ? "Cancel" : "Cancel close")
                self.closeAnywayButton.isHidden = false
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
        default: return "Zeus cannot check if this chat is safe to close. Close anyway?"
        }
    }

    /// The same reasons, for the quit question that lists the tabs.
    static func closeSummary(for reason: String) -> String {
        switch reason {
        case "composer-draft": return "the message box has unsent text or files"
        case "pending-message": return "a message is still on its way to Zeus"
        case "busy": return "Zeus is working"
        case "starting": return "Zeus is starting"
        case "terminal-draft": return "the terminal has unsent text"
        default: return "Zeus cannot check if it is safe to close"
        }
    }

    private func setCancelTitle(_ title: String) {
        cancelCloseButton.attributedTitle = Self.bannerTitle(title)
    }

    private static func bannerTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .foregroundColor: Brand.nsLink, .font: NSFont(name: "PPObjectSans-Semibold", size: 13) ?? .boldSystemFont(ofSize: 13),
        ])
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
        for (button, title, action) in [(closeAnywayButton, "Close anyway", #selector(closeAnyway)),
                                        (cancelCloseButton, "Cancel close", #selector(cancelClose))] {
            button.isBordered = false
            button.target = self
            button.action = action
            button.attributedTitle = Self.bannerTitle(title)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [closeSpinner, closeLabel, spacer, closeAnywayButton, cancelCloseButton] {
            closeBanner.addArrangedSubview(view)
        }
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
        guard !closed else { return }
        closed = true
        handoff?.cancel()
        handoff = nil
        closeApproved = true
        closePending = false
        closeGeneration += 1
        SpeechService.shared.cancel(in: webView, reason: "tab closed")
        terminal.detach()
        session.stop()
        session.onStateChange = nil
        session.onLog = nil
        if !session.isAlive { SessionManager.shared.remove(session) }
        host?.remove(self)
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
        SpeechService.shared.cancel(in: webView, reason: "window closed")
        EditorWindowController.open.removeAll { $0 === self }
    }

    /// Speech to text stops when the page goes out of view: another tab of the window shows, or the window is minimized.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, !window.occlusionState.contains(.visible) else { return }
        SpeechService.shared.stop(in: webView, reason: "window hidden")
    }

    #if DEBUG
    /// The newest Zeus Editor page, for the test actions.
    static var newestWebView: WKWebView? { open.last?.webView }
    #endif
}
