import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    /// The chat tabs in the order they opened, and the windows that show them.
    private var chatTabs: [ChatTab] = []
    private var chatWindows: [ChatWindowController] = []
    private var setupWindow: SetupWindowController?
    /// A user quit checks the tabs and asks about the unsafe ones before it stops the sessions.
    private var checkingQuit = false
    /// The quit is approved: the next terminate stops every session.
    private var quitApproved = false
    /// The approved quit is stopping the sessions; the app quits when they have ended.
    private var stoppingForQuit = false
    /// The window that shows the quit question as a sheet.
    private var quitQuestionWindow: NSWindow?
    private let statusMenu = StatusMenu()
    /// The update check at launch runs; only its loading screen shows, and no Zeus session opens until it ends.
    private var updating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Brand.registerFonts()
        NSApp.mainMenu = makeMainMenu()
        statusMenu.app = self
        statusMenu.update()
        listenForTestActions()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            Trace.log("macOS powers off")
            guard let self, self.checkingQuit else { return }
            self.approveQuit()
        }

        Trace.log("launched: version=\(Updater.currentVersion) setupNeeded=\(setupNeeded)")
        // The new copy of an updated app tells the old copy that it runs, and does not check again.
        if Updater.confirmPendingUpdate() {
            startZeus()
            return
        }

        // First setup: the app puts itself in /Applications and continues from there.
        if setupNeeded, AppMover.shouldMove, AppMover.moveAndRelaunch() {
            Trace.log("moving the app to Applications")
            return
        }

        // Updates install only here, before any Zeus session starts.
        updating = true
        Updater.checkAtLaunch { [weak self] relaunching in
            guard let self, !relaunching else { return }
            self.updating = false
            self.startZeus()
        }
    }

    private func startZeus() {
        if setupNeeded {
            showSetup(nil)
        } else {
            newChat(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The first start, or a Mac where the zeus command or the workspace has gone.
    private var setupNeeded: Bool {
        !Preferences.setupDone || !FileManager.default.isExecutableFile(atPath: Paths.zeusCommand)
            || !FileManager.default.fileExists(atPath: Paths.zeusDir)
    }

    /// The microphone stops before the app ends.
    func applicationWillTerminate(_ notification: Notification) {
        SpeechService.shared.cancelAll(reason: "app quits")
    }

    /// A click on the Dock icon while no window is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if updating {
            UpdateWindow.shared.bringForward()
            return true
        }
        if flag { return true }
        let alive = SessionManager.shared.sessions.filter(\.isAlive)
        if let setupWindow, setupWindow.model.isBusy {
            setupWindow.showWindow(nil)
        } else if !alive.isEmpty {
            alive.forEach { show($0) }
        } else if setupNeeded {
            showSetup(nil)
        } else {
            newChat(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting the app ends every session, so that no Claude Code session keeps running unseen.
    /// A user quit checks the tabs first and asks one question for all tabs that are not safe to close;
    /// it waits for that answer outside the quit, so that a macOS log out, restart, or shut down still
    /// reaches the app. A quit that macOS starts asks nothing and ends within 12 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        setupWindow?.model.stop()
        guard SessionManager.shared.sessions.contains(where: \.isAlive) else { return .terminateNow }
        Trace.log("quit requested: approved=\(quitApproved) checking=\(checkingQuit)")
        if Self.quitStartedByMacOS {
            Trace.log("quit by macOS")
            quitApproved = true
        }
        if stoppingForQuit { return .terminateLater }
        if quitApproved {
            stoppingForQuit = true
            checkingQuit = false
            endQuitQuestion()
            stopAllAndQuit()
            return .terminateLater
        }
        if !checkingQuit {
            checkingQuit = true
            checkTabsBeforeQuit()
        }
        return .terminateCancel
    }

    private static var quitStartedByMacOS: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    private func checkTabsBeforeQuit() {
        let tabs = chatTabs
        guard !tabs.isEmpty else { approveQuit(); return }
        var unsafe: [(ChatTab, String)] = []
        var remaining = tabs.count
        for tab in tabs {
            tab.closeState { [weak self] reason in
                if let reason { unsafe.append((tab, reason)) }
                remaining -= 1
                if remaining == 0 { DispatchQueue.main.async { self?.confirmQuit(unsafe) } }
            }
        }
    }

    private func confirmQuit(_ unsafe: [(ChatTab, String)]) {
        guard checkingQuit else { return }
        guard let first = unsafe.first?.0, let window = first.host?.window else { approveQuit(); return }
        first.host?.select(first)
        Trace.log("quit deferred: \(unsafe.map(\.1).joined(separator: " "))")
        let alert = NSAlert()
        alert.messageText = unsafe.count == 1 ? "A Zeus tab is not safe to close" : "\(unsafe.count) Zeus tabs are not safe to close"
        alert.informativeText = unsafe.map { "\($0.0.tabName.title): \(ChatTab.closeSummary(for: $0.1))" }
            .joined(separator: "\n") + "\n\nIf you quit, Zeus stops in every tab."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        quitQuestionWindow = window
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.checkingQuit else { return }
            self.quitQuestionWindow = nil
            if response == .alertSecondButtonReturn {
                self.checkingQuit = false
                Trace.log("quit cancelled")
                return
            }
            self.approveQuit()
        }
    }

    private func approveQuit() {
        checkingQuit = false
        quitApproved = true
        // AppKit does not quit while a sheet is open.
        endQuitQuestion()
        // Not from inside a main-queue block: quitting waits for callbacks on the main queue.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private func endQuitQuestion() {
        guard let window = quitQuestionWindow, let sheet = window.attachedSheet else { return }
        quitQuestionWindow = nil
        window.endSheet(sheet, returnCode: .abort)
    }

    /// The close check takes at most `closeCheckLimit`, so the quit ends within 12 s.
    private func stopAllAndQuit() {
        SpeechService.shared.cancelAll(reason: "app quits")
        SessionManager.shared.stopAll(timeout: 12 - ChatTab.closeCheckLimit) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    // MARK: Windows

    @objc func newChat(_ sender: Any?) {
        guard !updating else { return }
        if let session = startSession(host: .forNewTab) { show(session) }
    }

    /// Starts a session on a host. When `zeus` or the workspace is missing, it says so and offers the setup.
    func startSession(host: ClaudeHost) -> ZeusSession? {
        do {
            let session = try SessionManager.shared.start(host: host)
            Trace.log("session \(session.pid) started on \(host.rawValue)")
            return session
        } catch {
            Trace.log("session not started: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Zeus cannot start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Run the Zeus Setup")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { showSetup(nil) }
            return nil
        }
    }

    func show(_ session: ZeusSession) {
        if let existing = chatTabs.first(where: { $0.session === session }), let host = existing.host {
            host.select(existing)
            host.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let tab = ChatTab(session: session)
        tab.onClosed = { [weak self] closed in self?.chatTabs.removeAll { $0 === closed } }
        tab.startSession = { [weak self] host in self?.startSession(host: host) }
        tab.onRunSetup = { [weak self, weak tab] in
            tab?.requestClose()
            self?.showSetup(nil)
        }
        chatTabs.append(tab)
        // New chats open as tabs of the chat window in use, like new tabs in a browser.
        let host = keyChatWindow ?? chatWindows.last ?? {
            let window = ChatWindowController()
            window.onClosed = { [weak self] closed in self?.chatWindows.removeAll { $0 === closed } }
            chatWindows.append(window)
            return window
        }()
        host.add(tab)
        host.showWindow(nil)
        host.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The key window, or the front window of the app while another app is active.
    private var frontWindow: NSWindow? { NSApp.keyWindow ?? NSApp.orderedWindows.first }
    private var keyChatWindow: ChatWindowController? { frontWindow?.windowController as? ChatWindowController }
    private var keyChatTab: ChatTab? { keyChatWindow?.selectedTab }

    @objc func showSetup(_ sender: Any?) {
        guard !updating else { return }
        if let setupWindow {
            setupWindow.showWindow(nil)
            setupWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SetupWindowController()
        controller.model.onOptionsApplied = { [weak self] in self?.statusMenu.update() }
        controller.model.onFinished = { [weak self, weak controller] in
            controller?.window?.close()
            self?.setupWindow = nil
            self?.newChat(nil)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window,
                                               queue: .main) { [weak self] _ in self?.setupWindow = nil }
        setupWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Test actions

    /// Debug only, active only when ZEUS_APP_TRACE is set: another process can press the app's buttons
    /// with a distributed notification "io.github.theo-henry.zeus.test" whose object is the action name.
    /// With ZEUS_APP_TEST_ID set, the name ends in ".<id>", so that a test drives only its own app copy.
    private func listenForTestActions() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ZEUS_APP_TRACE"] != nil else { return }
        let testID = ProcessInfo.processInfo.environment["ZEUS_APP_TEST_ID"].map { "." + $0 } ?? ""
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.theo-henry.zeus.test" + testID),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let self, var object = note.object as? String else { return }
            // "@<pid> <action>" goes to one copy of the app only.
            if object.hasPrefix("@") {
                let parts = object.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, Int32(parts[0]) == ProcessInfo.processInfo.processIdentifier else { return }
                object = parts[1]
            }
            Trace.log("test action: \(object.prefix(60))")
            // An action can carry one argument after a colon: "test-rename-save:New name".
            let parts = object.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let action = String(parts[0])
            let argument = parts.count > 1 ? String(parts[1]) : ""
            let model = self.setupWindow?.model
            switch action {
            case "setup-install": model?.install()
            case "setup-start":
                model?.applyOptions()
                Preferences.setupDone = true
                model?.onFinished?()
            case "setup-menubar-on": model?.showMenuBar = true
            case "setup-answer-yes": model?.answerQuestion(true)
            case "setup-enter": model?.send("")
            case "setup-show": self.showSetup(nil)
            case "test-cmd-t", "test-cmd-j":
                let key = action == "test-cmd-t" ? "t" : "j"
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "t" ? 17 : 38) {
                    _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
                }
            case "test-cancel-close": self.chatTabs.last?.cancelClose()
            case "test-close-anyway": self.chatTabs.last?.closeAnyway()
            case "new-chat": self.newChat(nil)
            case "close-chat": self.chatTabs.last.map { $0.host?.close($0) }
            case "toggle-terminal": self.chatTabs.last?.toggleTerminal()
            case "test-draft": self.chatTabs.last?.webView.evaluateJavaScript("document.querySelector('textarea').value = 'Test chat turn'; document.querySelector('textarea').dispatchEvent(new Event('input',{bubbles:true}))")
            case "test-clear": self.chatTabs.last?.webView.evaluateJavaScript("document.querySelector('textarea').value = ''; document.querySelector('textarea').dispatchEvent(new Event('input',{bubbles:true}))")
            case "test-send": self.chatTabs.last?.webView.evaluateJavaScript("document.querySelector('#send,.send-button').click()")
            case "test-real-turn":
                self.chatTabs.last?.webView.evaluateJavaScript("const input=document.querySelector('textarea'); input.value='Reply with APP_OK. Do not use tools or change files.'; input.dispatchEvent(new Event('input',{bubbles:true})); document.querySelector('.send-button').click()")
            case "test-inspect":
                self.chatTabs.last?.webView.evaluateJavaScript("document.body.innerText.slice(-1800)") { result, error in
                    Trace.log("test page: \(result ?? error?.localizedDescription ?? "empty")")
                }
            case "test-terminal-input": self.chatTabs.last?.testTerminalInput()
            // Picks a project in the project menu of the chat page, as a click does.
            case "test-pick-project":
                self.chatTabs.last?.webView.callAsyncJavaScript(
                    "[...document.querySelectorAll('.project-menu [role=\"option\"]')].find((option) => option.querySelector('.menu-item-label')?.textContent.trim() === name)?.click()",
                    arguments: ["name": argument], in: nil, in: .page)
            // The chat page of the first tab posts "chat-focus", as after "Go to the chat" in Zeus Editor.
            case "test-chat-focus":
                self.chatTabs.first?.webView.evaluateJavaScript("window.webkit.messageHandlers.zeusApp.postMessage('chat-focus')")
            // Speech to text: the chat page of the last tab (or with "editor-", the newest Zeus Editor page) posts a
            // speech message, as the mic button does; "test-speech-page" writes what the page has into the trace.
            case "test-speech-post", "test-editor-speech-post":
                let webView = action == "test-speech-post" ? self.chatTabs.last?.webView : EditorWindowController.newestWebView
                webView?.callAsyncJavaScript("window.webkit.messageHandlers.zeusApp.postMessage(JSON.parse(message))",
                                             arguments: ["message": argument], in: nil, in: .page)
            case "test-speech-page", "test-editor-speech-page":
                let webView = action == "test-speech-page" ? self.chatTabs.last?.webView : EditorWindowController.newestWebView
                let script = "JSON.stringify({version: window.zeusApp?.speech?.version ?? null, close: typeof window.zeusApp?.closeState, "
                    + "text: document.querySelector('textarea')?.value ?? null, events: window.speechEvents ?? null})"
                webView?.evaluateJavaScript(script) { result, error in
                    Trace.log("speech page: \(result ?? error?.localizedDescription ?? "empty")")
                }
            case "test-open-editor":
                self.chatTabs.last?.webView.evaluateJavaScript("window.open('/editor', '_blank'); void 0")
            case "test-close-editor":
                EditorWindowController.newestWebView?.window?.performClose(nil)
            case "test-rename-open": self.chatTabs.last.map { $0.host?.startRename($0) }
            case "test-rename-save": self.chatTabs.last.map { $0.host?.endRename($0, name: argument) }
            case "toggle-menubar": self.toggleMenuBar(nil)
            // Developer Settings: "dev-setting:switch=on", "costEU", "costApolix", "blind".
            case "dev-setting":
                let pair = argument.split(separator: "=").map(String.init)
                guard pair.count == 2 else { break }
                let on = pair[1] == "on"
                switch pair[0] {
                case "switch": Preferences.developerHostSwitch = on
                case "costEU": Preferences.showCostEU = on
                case "costApolix": Preferences.showCostApolix = on
                case "blind": Preferences.blindMode = on
                default: break
                }
                Trace.log("developer setting: \(pair[0])=\(on)")
            case "dev-settings-show": DeveloperSettingsWindow.show()
            case "dev-settings-close": DeveloperSettingsWindow.close()
            // The host switch of the selected tab, as a click on it does.
            case "switch-host": self.chatWindows.last?.selectedTab?.requestSwitch(to: argument == "eu" ? .eu : .apolix)
            case "test-handoff": self.chatWindows.last?.selectedTab?.runningHandoff?.testPress(argument)
            case "test-select-first": self.chatTabs.first.map { $0.host?.select($0) }
            // "Try again" on the failure page of the selected tab.
            case "test-retry":
                self.chatWindows.last?.selectedTab?.webView.evaluateJavaScript("window.webkit.messageHandlers.zeusApp.postMessage('retry')")
            // A cost report from the chat page of the last tab, as zeus-editor posts it.
            case "test-cost":
                self.chatWindows.last?.selectedTab?.webView.callAsyncJavaScript("window.webkit.messageHandlers.zeusApp.postMessage('cost:' + json)",
                                                               arguments: ["json": argument], in: nil, in: .page)
            // For screenshots: the chat window on the sharpest screen, at a fixed size.
            case "test-retina":
                if let window = self.chatWindows.last?.window,
                   let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
                    let size = NSSize(width: 1100, height: 720)
                    let area = screen.visibleFrame
                    window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                           width: size.width, height: size.height), display: true)
                }
            // The title bar in the light appearance, for screenshots.
            case "test-light":
                let window = self.chatTabs.last?.host?.window
                window?.appearance = NSAppearance(named: argument == "off" ? .darkAqua : .aqua)
                window?.backgroundColor = argument == "off" ? LoaderPage.background
                    : NSColor(srgbRed: 241/255, green: 246/255, blue: 249/255, alpha: 1)
            // Not from inside this main-queue block: quitting waits for callbacks on the main queue.
            case "quit": NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            case "test-power-off":
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willPowerOffNotification, object: NSWorkspace.shared)
            default: break
            }
        }
        #endif
    }

    // MARK: Menu actions

    @objc private func toggleMenuBar(_ sender: Any?) {
        Preferences.showMenuBar.toggle()
        statusMenu.update()
    }

    @objc private func showDeveloperSettings(_ sender: Any?) {
        DeveloperSettingsWindow.show()
    }

    @objc private func keepInDock(_ sender: Any?) {
        DockPin.pin()
    }

    @objc private func openLogs(_ sender: Any?) {
        try? FileManager.default.createDirectory(atPath: Paths.logDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logDir))
    }

    /// The chat page (or editor page) of the front window. A chat window holds it below its loading screen.
    private var keyWebView: WKWebView? {
        keyChatTab?.webView ?? (frontWindow?.contentView as? WKWebView)
    }

    @objc private func toggleTerminal(_ sender: Any?) {
        keyChatTab?.toggleTerminal(sender)
    }

    @objc private func reloadPage(_ sender: Any?) {
        if let tab = keyChatTab {
            tab.reload()
        } else {
            keyWebView?.reload()
        }
    }

    @objc private func zoomIn(_ sender: Any?) { keyWebView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }
    @objc private func zoomOut(_ sender: Any?) { keyWebView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.5) } }
    @objc private func actualSize(_ sender: Any?) { keyWebView?.pageZoom = 1 }

    /// Cmd+W closes the selected tab of a chat window, and the window with its last tab.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let tabs = keyChatWindow?.tabs.count ?? 0
        menu.items.first { $0.action == #selector(NSWindow.performClose(_:)) }?.title = tabs > 1 ? "Close Tab" : "Close Window"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMenuBar(_:)):
            menuItem.state = Preferences.showMenuBar ? .on : .off
        case #selector(keepInDock(_:)):
            let pinned = DockPin.isPinned()
            menuItem.state = pinned ? .on : .off
            return !pinned
        case #selector(reloadPage(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)):
            return keyWebView != nil
        default:
            break
        }
        return true
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Zeus")
        app.addItem(withTitle: "About Zeus", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Zeus Setup…", action: #selector(showSetup(_:)), keyEquivalent: ",")
        app.addItem(withTitle: "Show in Menu Bar", action: #selector(toggleMenuBar(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Keep in Dock", action: #selector(keepInDock(_:)), keyEquivalent: "")
        let developer = NSMenu(title: "Developer")
        developer.addItem(withTitle: "Developer Settings…", action: #selector(showDeveloperSettings(_:)), keyEquivalent: "")
        app.addItem(submenu: developer)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Zeus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Zeus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(newChat(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "New Chat", action: #selector(newChat(_:)), keyEquivalent: "n")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.delegate = self
        main.addItem(submenu: file)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit)

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Show or Hide Terminal", action: #selector(toggleTerminal(_:)), keyEquivalent: "j")
        view.addItem(withTitle: "Reload Page", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: view)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let previousTab = window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        let nextTab = window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = .control
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: window)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Open Install Logs", action: #selector(openLogs(_:)), keyEquivalent: "")
        main.addItem(submenu: help)

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
