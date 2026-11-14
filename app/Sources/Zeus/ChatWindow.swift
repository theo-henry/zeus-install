import AppKit
import WebKit

/// The tab of one Zeus session in a chat window. It shows the loading screen (the Zeus globe) while `zeus` starts,
/// then hands over to the chat page. Closing the tab ends the session.
final class ChatTab: NSObject {
    let session: ZeusSession
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
    /// The chat page of `shownURL` has loaded.
    private var pageLoaded = false
    /// Settings… came while the chat page was not loaded yet: the settings open when it has loaded.
    private var settingsWanted = false

    private var terminal: TerminalPanel!
    /// The terminal had the keyboard when the tab last went out of view (or the rename field took the keyboard).
    private var keyboardWasInTerminal = false
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

    /// The tab as it was before an update from the settings, which this tab opens again (`TabRestore`).
    private let restore: TabRestore.Tab?
    private enum Resume { case none, waiting, running, done }
    /// The Claude Code session of `restore` resumes before the chat page loads.
    private var resume = Resume.none
    /// The unsent text of `restore` goes back into the message box once.
    private var draftRestored = false

    var onRunSetup: (() -> Void)?
    var onRetry: (() -> Void)?
    var onClosed: ((ChatTab) -> Void)?

    init(session: ZeusSession, restore: TabRestore.Tab? = nil) {
        self.session = session
        self.restore = restore
        super.init()

        webView = handler.makeWebView()
        webView.configuration.userContentController.addUserScript(TabName.projectScript)
        // The window's Zeus background shows until the first page paints, not a gray frame.
        webView.setValue(false, forKey: "drawsBackground")
        terminal = TerminalPanel(session: session)
        terminal.webView.isHidden = !(restore?.terminalVisible ?? false)
        if let restore {
            tabName.setProject(restore.project)
            tabName.rename(restore.customName)
            if restore.sessionID != nil || restore.terminalDraft != nil { resume = .waiting }
        }
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
            if self.host?.selectedTab === self { WebViewHandler.matchTitleBar(of: webView.window, to: webView) }
            guard self.shownURL != nil, webView.url == self.shownURL else { return }
            self.restoreDraft()
            self.pageLoaded = true
            if self.settingsWanted {
                self.settingsWanted = false
                self.openSettings()
            }
            // After the first chat, the page comes in as soon as it is loaded.
            guard !Self.greeted else { self.handOver(); return }
            // A chat page without the globe (an older Zeus Editor) does not say "chat-ready": do not wait long.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.handOver() }
        }
        // A chat page that does not load must not stay behind the loading screen.
        handler.onPageFailed = { [weak self] in self?.handOver() }

        session.onStateChange = { [weak self] _ in self?.render() }
        session.onLog = { [weak self] in self?.updateLoaderStatus() }
        render()
    }

    private func render() {
        switch session.state {
        case .starting:
            shownURL = nil
            pageLoaded = false
            showLoader()
        case let .running(url):
            guard shownURL != url else { return }
            // A tab that an update opens again first resumes its Claude Code session, then shows the chat.
            switch resume {
            case .waiting:
                resume = .running
                loader?.setStatus("Opening the chat again…")
                resumeSession(url: url)
                return
            case .running:
                return
            case .none, .done:
                break
            }
            shownURL = url
            pageLoaded = false
            loader?.setStatus("Opening the chat…")
            webView.load(URLRequest(url: url))   // Behind the loading screen, until the hand-over.
        case let .failed(message):
            shownURL = nil
            pageLoaded = false
            settingsWanted = false
            webView.loadHTMLString(StatusPage.failed(message: message, log: session.log.text), baseURL: nil)
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
        let content = self.view
        let overlay = LoaderOverlay(frame: webView.frame)
        let view = overlay.view
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            view.topAnchor.constraint(equalTo: webView.topAnchor),
            view.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
        loader = overlay
        handingOver = false
    }

    /// Removes the loading screen. When it had the keyboard focus, the chat page gets it.
    private func dismiss(_ loader: LoaderOverlay, over duration: TimeInterval) {
        loader.remove(over: duration) { [weak self] in
            guard let self, let window = self.view.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self.webView)
        }
    }

    private func updateLoaderStatus() {
        guard shownURL == nil, resume != .running, let loader else { return }
        let updating = session.log.lines.suffix(30).contains { $0.range(of: "updat", options: .caseInsensitive) != nil }
        loader.setStatus(updating ? "Checking for updates…" : "Starting Zeus…")
    }

    /// The chat page is drawn. The loading globe moves to the place of the chat page's globe while the
    /// chat comes in behind it; then the chat page shows its own globe and the loading screen goes away.
    /// A chat page without a globe to hand over to (an older Zeus Editor, or a chat that is not empty)
    /// gets a plain cross-fade. After the first chat of the app run, the chat comes in at once.
    private func handOver() {
        guard let loader, !handingOver, shownURL != nil else { return }
        handingOver = true
        if Self.greeted {
            Trace.log("hand-over: at once")
            self.loader = nil
            webView.evaluateJavaScript("window.zeusGlobe && (window.zeusGlobe.enter(), window.zeusGlobe.reveal())")
            dismiss(loader, over: 0.15)
            return
        }
        Self.greeted = true
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
        switch message {
        case "chat-ready":
            // After a reload of the page there is no loading screen: the page comes in at once.
            if loader == nil {
                webView.evaluateJavaScript("window.zeusGlobe && (window.zeusGlobe.enter(), window.zeusGlobe.reveal())")
            } else {
                handOver()
            }
        case "retry": onRetry?()
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

    func reload() {
        if shownURL != nil { webView.reload() } else { render() }
    }

    // MARK: Update from the settings

    /// The composer of the Zeus chat (zeus-editor src/chat/client, `#zeus-message`).
    private static let draftScript = "document.getElementById('zeus-message')?.value ?? null"

    /// The tab as it is now, for the new copy of the app: the Claude Code session and the terminal's unsent text
    /// from the launcher, the unsent text of the message box from the page.
    func snapshot(completion: @escaping (TabRestore.Tab) -> Void) {
        var tab = TabRestore.Tab(sessionID: nil, project: tabName.project, customName: tabName.custom, draft: nil,
                                 terminalDraft: nil, terminalVisible: !terminal.webView.isHidden,
                                 selected: host?.selectedTab === self)
        // A tab that has not shown its chat yet keeps what it was to open again.
        if shownURL == nil, let restore {
            tab.sessionID = restore.sessionID
            tab.draft = restore.draft
            tab.terminalDraft = restore.terminalDraft
        }
        let group = DispatchGroup()
        let launchID = session.launchID, chatURL = session.chatURL
        var launcherState: [String: Any]?
        if chatURL != nil {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                if let endpoint = LaunchControl.endpoint(launchID: launchID, chatURL: chatURL) {
                    launcherState = LaunchControl.request(endpoint, ["op": "state"], timeout: 3)
                }
                group.leave()
            }
        }
        var pageDraft: String?
        if shownURL != nil {
            group.enter()
            webView.evaluateJavaScript(Self.draftScript) { result, _ in
                pageDraft = result as? String
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            if let state = launcherState {
                if let id = state["sessionId"] as? String, !id.isEmpty { tab.sessionID = id }
                let input = state["input"] as? [String: Any]
                tab.terminalDraft = (input?["draft"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            if self?.shownURL != nil { tab.draft = pageDraft.flatMap { $0.isEmpty ? nil : $0 } }
            Trace.log("snapshot: \(self?.session.pid ?? 0) session=\(tab.sessionID ?? "-") project=\(tab.project ?? "-") draft=\(tab.draft?.count ?? 0) terminal-draft=\(tab.terminalDraft?.count ?? 0)")
            completion(tab)
        }
    }

    /// Zeus works in the tab: a turn, a question or permission prompt in a turn, a message on its way, or a start.
    /// The chat answers the close check with the first reason only (unsent text before work), so the launcher
    /// state tells the rest. Calls back on the main queue.
    func isBusy(completion: @escaping (Bool) -> Void) {
        if session.isAlive, shownURL == nil {
            DispatchQueue.main.async { completion(true) }
            return
        }
        closeState { [weak self] reason in
            if let reason, ["busy", "pending-message", "starting"].contains(reason) {
                DispatchQueue.main.async { completion(true) }
                return
            }
            guard let self, reason != nil else { DispatchQueue.main.async { completion(false) }; return }
            let launchID = self.session.launchID, chatURL = self.session.chatURL
            DispatchQueue.global(qos: .userInitiated).async {
                var busy = false
                if let endpoint = LaunchControl.endpoint(launchID: launchID, chatURL: chatURL),
                   let state = LaunchControl.request(endpoint, ["op": "state"], timeout: 3) {
                    let status = state["status"] as? String
                    busy = status == "busy" || status == "waiting" || state["restarting"] as? Bool == true
                        || !((state["pending"] as? [Any])?.isEmpty ?? true)
                }
                DispatchQueue.main.async { completion(busy) }
            }
        }
    }

    /// Ends the session for an update, without the close check: the update waited for the turns, and the new copy
    /// opens the tab again with its unsent text.
    func closeForUpdate() { finishClose() }

    /// Restarts Claude Code in the new launch with `--resume` for the session of the tab, then types the terminal's
    /// unsent text back when Claude Code is ready for it.
    private func resumeSession(url: URL) {
        guard let restore else { return }
        let launchID = session.launchID, pid = session.pid
        let terminalDraft = restore.terminalDraft?.replacingOccurrences(of: "\r", with: "")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var resumed = false
            var ready = false
            if let endpoint = LaunchControl.endpoint(launchID: launchID, chatURL: url) {
                if let id = restore.sessionID {
                    resumed = LaunchControl.request(endpoint, ["op": "restart", "resume": id], timeout: 30) != nil
                }
                if let terminalDraft, !terminalDraft.isEmpty {
                    // Claude Code shows an empty input box when it is ready for typing.
                    let deadline = Date().addingTimeInterval(30)
                    while !ready, Date() < deadline {
                        let input = LaunchControl.request(endpoint, ["op": "state"], timeout: 3)?["input"] as? [String: Any]
                        ready = input?["present"] as? Bool == true && input?["empty"] as? Bool == true
                        if !ready { usleep(300_000) }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                Trace.log("restore: \(pid) resume=\(restore.sessionID ?? "-") \(resumed ? "ok" : "not resumed")")
                guard let self, !self.closed else { return }
                if ready, let terminalDraft {
                    // A text of several lines goes in as a paste, so that its line ends do not send it.
                    self.session.write(terminalDraft.contains("\n") ? "\u{1b}[200~\(terminalDraft)\u{1b}[201~" : terminalDraft)
                    Trace.log("restore: \(pid) terminal text back")
                }
                self.resume = .done
                self.render()
            }
        }
    }

    /// Puts the unsent text back into the message box of the chat page, when the box is empty.
    private func restoreDraft() {
        guard !draftRestored, let draft = restore?.draft, !draft.isEmpty else { return }
        draftRestored = true
        let script = """
            for (let i = 0; i < 150; i++) {
              const box = document.getElementById('zeus-message');
              if (box) {
                if (!box.value) {
                  box.value = draft;
                  box.dispatchEvent(new Event('input', { bubbles: true }));
                }
                return box.value === draft;
              }
              await new Promise((resolve) => setTimeout(resolve, 100));
            }
            return false;
            """
        let pid = session.pid
        webView.callAsyncJavaScript(script, arguments: ["draft": draft], in: nil, in: .page) { result in
            Trace.log("restore: \(pid) message box text back=\((try? result.get()) as? Bool ?? false)")
        }
    }

    /// Settings… (Cmd+,): opens the settings pop-up of the chat page. A tab that still starts or loads its chat
    /// page opens it when the page has loaded, so that the shortcut is not lost behind the loading screen.
    func openSettings() {
        guard shownURL != nil, pageLoaded, !webView.isLoading else {
            settingsWanted = true
            Trace.log("settings: waiting for the chat page of \(session.pid)")
            return
        }
        webView.evaluateJavaScript(Self.openSettingsScript)
    }

    static let openSettingsScript = "window.zeusApp?.openSettings?.(); void 0"

    @objc func toggleTerminal(_ sender: Any? = nil) {
        terminal.webView.isHidden.toggle()
        keyboardWasInTerminal = !terminal.webView.isHidden
        if !terminal.webView.isHidden { terminal.focus() }
        else { view.window?.makeFirstResponder(webView) }
        Trace.log("terminal visible: \(session.pid) \(!terminal.webView.isHidden)")
    }

    func testTerminalInput(_ text: String = "terminal-test\r") {
        terminal.webView.callAsyncJavaScript("term.input(text, true)", arguments: ["text": text], in: nil, in: .page)
    }

    #if DEBUG
    /// Test actions: a mouse click in the message box of the chat page or in the terminal, as the user clicks,
    /// and the part of the tab that has the keyboard.
    func testClick(terminal inTerminal: Bool) {
        let target: WKWebView = inTerminal ? terminal.webView : webView
        let script = "JSON.stringify(document.querySelector(\(inTerminal ? "'#terminal'" : "'textarea'"))?.getBoundingClientRect() ?? null)"
        target.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let rect = Self.rect(from: result), let window = target.window else {
                Trace.log("test click: nothing to click")
                return
            }
            let zoom = target.pageZoom * target.magnification
            let local = NSPoint(x: rect.midX * zoom, y: target.isFlipped ? rect.midY * zoom : target.bounds.height - rect.midY * zoom)
            let point = target.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                window.sendEvent(event)
            }
            let hit = window.contentView?.superview?.hitTest(point)
            let hitName = hit.map { $0.isDescendant(of: self.terminal.webView) ? "terminal" : $0.isDescendant(of: self.webView) ? "chat" : String(describing: type(of: $0)) } ?? "none"
            Trace.log("test click: \(inTerminal ? "terminal" : "chat") hit=\(hitName) keyboard=\(self.keyboardOwner)")
        }
    }

    var keyboardOwner: String {
        guard let responder = view.window?.firstResponder as? NSView else { return "none" }
        if keyboardIsInTerminal { return "terminal" }
        if responder.isDescendant(of: webView) { return "chat" }
        return String(describing: type(of: responder))
    }
    #endif

    /// The view that gets the keyboard when the tab shows: the part of the tab that had it before.
    /// The terminal gets it only when the user opened it or clicked in it, never only because it is open.
    var focusView: NSView { terminal.webView.isHidden || !keyboardWasInTerminal ? webView : terminal.webView }

    /// The terminal has the keyboard: typing and pasting go to Claude Code's input box.
    var keyboardIsInTerminal: Bool {
        (view.window?.firstResponder as? NSView)?.isDescendant(of: terminal.webView) ?? false
    }

    /// Called before the tab goes out of view, or before another view takes the keyboard for a short time.
    func rememberKeyboard() { keyboardWasInTerminal = !terminal.webView.isHidden && keyboardIsInTerminal }

    /// A click in the chat page or in the terminal: that part gets the keyboard, also for a click that the page does not get.
    func giveKeyboard(forClickOn view: NSView) {
        guard let window = view.window else { return }
        let target: WKWebView
        if view.isDescendant(of: terminal.webView) {
            target = terminal.webView
        } else if view.isDescendant(of: webView) {
            target = webView
        } else {
            return
        }
        if (window.firstResponder as? NSView)?.isDescendant(of: target) == true { return }
        if target === terminal.webView { terminal.focus() } else { window.makeFirstResponder(webView) }
        Trace.log("keyboard: \(session.pid) \(target === webView ? "chat" : "terminal") (click)")
    }

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

/// The window of a Zeus Editor page: the page must not take the shortcuts of the app actions, and they match as in
/// a chat window (a symbol key by its place on the keyboard), not only by the character as the menu does.
/// The next and previous tab actions show the window tabs of macOS.
final class EditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = ShortcutSettings.shared.action(for: event), (NSApp.delegate as? AppDelegate)?.perform(action) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
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
        Front.show(controller.window)
        return controller.webView
    }

    private init(configuration: WKWebViewConfiguration) {
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
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
        guard let window, Front.isOutOfView(window) else { return }
        SpeechService.shared.stop(in: webView, reason: "window hidden")
    }

    #if DEBUG
    /// The newest Zeus Editor page, for the test actions.
    static var newestWebView: WKWebView? { open.last?.webView }
    #endif
}
