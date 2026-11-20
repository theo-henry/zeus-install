import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    /// The chat tabs in the order they opened, and the windows that show them.
    private var chatTabs: [ChatTab] = []
    private var chatWindows: [ChatWindowController] = []
    private var setupWindow: SetupWindowController?
    /// The phase of the app (its start and its updates) and of its quit: the one place that keeps them (`AppLifecycle`).
    private(set) var lifecycle = AppLifecycle<NSWindow>() {
        didSet {
            if lifecycle.app != oldValue.app { Trace.log("app phase: \(oldValue.app) -> \(lifecycle.app)") }
            if lifecycle.quit != oldValue.quit { Trace.log("quit phase: \(oldValue.quit) -> \(lifecycle.quit)") }
        }
    }
    /// The observer of the window that shows the quit question, which ends the quit when that window closes.
    private var quitQuestionObserver: NSObjectProtocol?

    /// Applies an event of the app phase (`AppUpdate` gives the update steps). An event that is not legal in the
    /// phase now changes nothing and returns false.
    @discardableResult
    func apply(_ event: AppEvent) -> Bool {
        let applied = lifecycle.apply(event)
        if !applied { Trace.log("app phase: \(event.rawValue) refused in \(lifecycle.app)") }
        return applied
    }
    private let statusMenu = StatusMenu()
    /// The menu item of each app action, which shows and runs its shortcut from the Zeus settings.
    private var actionItems: [AppAction: NSMenuItem] = [:]
    private var handoverWindow: HandoverWindowController?
    /// The EU tab from which the user opened the handover: "Switch to Standard" after a release switches it.
    private weak var handoverTab: ChatTab?
    /// The EU vault opens for EU mode (Touch ID, then the EU setup check in the vault): no other EU start begins meanwhile.
    private var openingEU = false
    /// The question that shows now (a tab mode switch), which the debug test actions can answer.
    private var openAlert: NSAlert?
    #if DEBUG
    /// The user's pasteboard before the paste test actions, given back by "test-pasteboard-restore".
    private var savedPasteboard: [NSPasteboardItem]?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else: a EU vault that stayed open after a crash locks now, while no session runs.
        EUVault.shared.lockAtStart()
        ShellEnvironment.findGcloudPython()
        // The read block of Standard sessions on a Mac with an EU vault, from the EU folders of the installed Zeus Editor
        // (written again before each Standard start).
        if StandardJail.isOn {
            do { _ = try StandardJail.prepare() } catch { Trace.log("jail: profile not written: \(error.localizedDescription)") }
        }
        Brand.registerFonts()
        NSApp.mainMenu = makeMainMenu()
        ShortcutSettings.shared.onChange = { [weak self] in self?.applyShortcuts() }
        ShortcutSettings.shared.start()
        statusMenu.app = self
        statusMenu.update()
        AppUpdate.shared.app = self
        listenForTestActions()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            Trace.log("macOS powers off")
            guard let self else { return }
            // Only a user quit that checks or asks: a power-off warning alone (a logout that another app cancels) stops nothing.
            guard self.lifecycle.quit.isUserQuit else { return }
            self.approveQuit()
        }

        Trace.log("launched: version=\(Updater.currentVersion) setupNeeded=\(setupNeeded) mode=\(ZeusMode.lastUsed.rawValue)")
        #if DEBUG
        // Test only: the app opens the tabs that "test-keep-tabs-and-quit" kept, as the new copy of an update does.
        if DebugEnvironment.value("ZEUS_APP_TEST_RESTORE") == "1" {
            startZeus(restoring: true)
            return
        }
        #endif
        // The new copy of an updated app tells the old copy that it runs, does not check again, and opens the tabs
        // of an update from the settings again.
        switch Updater.confirmPendingUpdate() {
        case .newCopy:
            startZeus(restoring: true)
            return
        case .unconfirmed:
            return
        case .late:
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            return
        case .normal:
            TabRestore.remove()
        }

        // First setup: the app puts itself in /Applications and continues from there.
        if setupNeeded, AppMover.shouldMove, AppMover.moveAndRelaunch() {
            Trace.log("moving the app to Applications")
            return
        }

        // Updates install only here, before any Zeus session starts.
        apply(.launchUpdateStarted)
        Updater.checkAtLaunch { [weak self] relaunching in
            guard let self, !relaunching else { return }
            self.startZeus()
        }
    }

    private func startZeus(restoring: Bool = false) {
        apply(.zeusStarted)
        let firstSetup = setupNeeded
        if firstSetup {
            showSetup(nil)
        } else if restoring, let restore = TabRestore.take(), restore.tabCount > 0 {
            reopen(restore)
        } else {
            // The first tab has the mode of the tab that the user used last. An EU tab opens the EU vault first.
            newChat(mode: ZeusMode.lastUsed)
        }
        Front.activate()
        // The dictation model downloads and loads in the background, after the first window opens, so that Zeus opens
        // as fast as without it. The first setup shows the download at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + (firstSetup ? 0 : 2)) { Self.startDictation() }
    }

    /// Gets the dictation model (or its new version after an app update) and loads it; it stays loaded.
    static func startDictation() {
        _ = SpeechService.shared
        DictationModels.shared.start()
        DictationRuntime.shared.start()
    }

    /// The first start, or a Mac where the zeus command or the workspace has gone.
    private var setupNeeded: Bool {
        !Preferences.setupDone || !FileManager.default.isExecutableFile(atPath: Paths.zeusCommand)
            || !FileManager.default.fileExists(atPath: Paths.zeusDir)
    }

    /// The microphone stops and the dictation model is freed before the app ends.
    func applicationWillTerminate(_ notification: Notification) {
        SpeechService.shared.cancelAll(reason: "app quits")
        DictationRuntime.shared.shutdown()
    }

    /// A click on the Dock icon while no window is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if lifecycle.app.blocksSessions {
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
            newChat(mode: ZeusMode.lastUsed)
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
        let sessionsAlive = SessionManager.shared.sessions.contains(where: \.isAlive)
        let byMacOS = sessionsAlive && Self.quitStartedByMacOS
        if sessionsAlive {
            Trace.log("quit requested: phase=\(lifecycle.quit)")
            if byMacOS { Trace.log("quit by macOS") }
        }
        switch lifecycle.terminate(sessionsAlive: sessionsAlive, vaultMounted: EUVault.shared.isMounted, byMacOS: byMacOS) {
        case .now:
            return .terminateNow
        case .lockVault:
            EUVault.shared.lockForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        case let .stopSessions(question):
            endQuitQuestion(on: question)
            stopAllAndQuit()
            return .terminateLater
        case .wait:
            return .terminateLater
        case .checkTabs:
            checkTabsBeforeQuit()
            return .terminateCancel
        case .cancel:
            return .terminateCancel
        }
    }

    private static var quitStartedByMacOS: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    private func checkTabsBeforeQuit() {
        let tabs = chatTabs
        guard !tabs.isEmpty else { confirmQuit([]); return }
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
        let first = unsafe.first?.0
        let window: NSWindow
        switch lifecycle.tabsChecked(unsafeWindow: first?.host?.window) {
        case .approved:
            terminateAfterApproval()
            return
        case let .ask(asked):
            window = asked
        case .cancelled, .ignored:
            return
        }
        if let first { first.host?.select(first) }
        Trace.log("quit deferred: \(unsafe.map(\.1).joined(separator: " "))")
        let alert = NSAlert()
        alert.messageText = unsafe.count == 1 ? "A Zeus tab is not safe to close" : "\(unsafe.count) Zeus tabs are not safe to close"
        alert.informativeText = unsafe.map { "\($0.0.tabName.title): \(ChatTab.closeSummary(for: $0.1))" }
            .joined(separator: "\n") + "\n\nIf you quit, Zeus stops in every tab."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        Front.show(window)
        Front.activate()
        // AppKit does not call the completion handler of a sheet whose window closes, and keeps the sheet attached, so
        // that no later quit reaches the app: the quit ends with the window (the window of its last tab, which closes).
        quitQuestionObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                      queue: .main) { [weak self, weak window] _ in
            guard let self, let window, self.lifecycle.questionWindowClosed(window) == .cancelled else { return }
            Trace.log("quit cancelled: the window of the question closed")
            self.endQuitQuestion(on: window)
        }
        Front.beginSheet(alert, for: window) { [weak self, weak window] response in
            guard let self, let window else { return }
            // An answer that comes after the quit was approved or ended (the sheet ended by the app) changes nothing.
            switch self.lifecycle.answered(quitAnyway: response == .alertFirstButtonReturn, on: window) {
            case .approved:
                self.stopObservingQuitQuestion()
                self.terminateAfterApproval()
            case .cancelled:
                self.stopObservingQuitQuestion()
                Trace.log("quit cancelled")
            case .ask, .ignored:
                break
            }
        }
    }

    /// Approves the quit without the question (power off, test action) and terminates again.
    private func approveQuit() {
        guard case let .approved(question) = lifecycle.approve() else { return }
        endQuitQuestion(on: question)
        terminateAfterApproval()
    }

    private func terminateAfterApproval() {
        // Not from inside a main-queue block: quitting waits for callbacks on the main queue.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// Ends the quit question on this window, when it still shows: AppKit does not quit while a sheet is open.
    private func endQuitQuestion(on window: NSWindow?) {
        stopObservingQuitQuestion()
        guard let window, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet, returnCode: .abort)
    }

    private func stopObservingQuitQuestion() {
        if let quitQuestionObserver { NotificationCenter.default.removeObserver(quitQuestionObserver) }
        quitQuestionObserver = nil
    }

    /// The close check takes at most `closeCheckLimit`, so the quit ends within 12 s, and the EU vault lock within 4 s more.
    /// The vault locks after the sessions stopped, so no EU session uses it then.
    private func stopAllAndQuit() {
        SpeechService.shared.cancelAll(reason: "app quits")
        SessionManager.shared.stopAll(timeout: 12 - ChatTab.closeCheckLimit) {
            EUVault.shared.lockForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    // MARK: Windows

    /// New Tab and New Chat: a new tab in the mode of the selected tab of the front chat window, so that a user who works
    /// in EU tabs gets an EU tab, as a Standard user gets a Standard tab. Without a chat window in front: the mode of the
    /// tab that the user used last.
    @objc func newChat(_ sender: Any?) {
        newChat(mode: keyChatTab?.mode ?? ZeusMode.lastUsed)
    }

    @objc func newStandardChat(_ sender: Any?) { newChat(mode: .standard) }
    @objc func newEUChat(_ sender: Any?) { newChat(mode: .eu) }

    /// A new tab of this mode. An EU tab starts only while the EU vault is open: Touch ID opens it first.
    func newChat(mode: ZeusMode) {
        guard !lifecycle.app.blocksSessions, !openingEU else { return }
        if mode == .eu {
            let missing = EUSetup.missing()
            if !missing.isEmpty { askForEUSetup(missing, standardFallback: chatTabs.isEmpty); return }
            if !EUProfile.sessionsCanStart {
                openEU(standardFallback: chatTabs.isEmpty) { [weak self] ready in if ready { self?.newChat(mode: .eu) } }
                return
            }
        }
        do {
            let session = try SessionManager.shared.start(mode: mode)
            Trace.log("session \(session.pid) started (\(session.mode.rawValue))")
            show(session)
        } catch {
            Trace.log("session not started: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Zeus cannot start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Run the Zeus Setup")
            alert.addButton(withTitle: "Cancel")
            ask(alert) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.showSetup(nil) }
            }
        }
    }

    func show(_ session: ZeusSession) {
        if let existing = chatTabs.first(where: { $0.session === session }), let host = existing.host {
            host.select(existing)
            Front.show(host.window)
            Front.activate()
            return
        }
        let tab = makeTab(session)
        // New chats open as tabs of the chat window in use, like new tabs in a browser.
        let host = keyChatWindow ?? chatWindows.last ?? makeChatWindow()
        host.add(tab)
        Front.show(host.window)
        Front.activate()
    }

    private func makeTab(_ session: ZeusSession, restore: TabRestore.Tab? = nil) -> ChatTab {
        let tab = ChatTab(session: session, restore: restore)
        tab.onClosed = { [weak self] closed in self?.chatTabs.removeAll { $0 === closed } }
        tab.onRetry = { [weak self, weak tab] in
            let mode = tab?.mode ?? .standard
            tab?.requestClose()
            self?.newChat(mode: mode)
        }
        tab.onRunSetup = { [weak self, weak tab] in
            tab?.requestClose()
            self?.showSetup(nil)
        }
        tab.onSwitchToStandard = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.switchTab(tab, to: .standard)
        }
        tab.onEUError = { [weak self] tab, words in self?.showEUError(words, in: tab) }
        chatTabs.append(tab)
        return tab
    }

    private func makeChatWindow() -> ChatWindowController {
        let window = ChatWindowController()
        window.onClosed = { [weak self] closed in self?.chatWindows.removeAll { $0 === closed } }
        chatWindows.append(window)
        return window
    }

    // MARK: Update from the settings

    /// The chat pages of all tabs, for the update events.
    var chatPages: [WKWebView] { chatTabs.map(\.webView) }

    /// The number of tabs where Zeus works, a message is on its way, or Zeus starts: the update waits for them.
    func busyTabCount(completion: @escaping (Int) -> Void) {
        // A tab that switches its mode ends and starts a session: the update waits until it is done.
        if chatTabs.contains(where: \.isSwitching) { completion(1); return }
        let tabs = chatTabs
        guard !tabs.isEmpty else { completion(0); return }
        var busy = 0
        var remaining = tabs.count
        for tab in tabs {
            tab.isBusy { isBusy in
                if isBusy { busy += 1 }
                remaining -= 1
                if remaining == 0 { completion(busy) }
            }
        }
    }

    /// Shows the loading screen in the place of the front chat window and hides the chat windows, so that no message
    /// can start a turn; then keeps the tabs for the new copy (`TabRestore`) and ends every session.
    /// Calls `completion` with the kept tabs when the sessions have ended, or with nil (and shows the chat windows
    /// again) when a tab started to work before the windows were hidden: the update then waits again.
    func endTabsForUpdate(to version: String, completion: @escaping (TabRestore?) -> Void) {
        // The front chat window first, so that it is the window that the loading screen replaces.
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? ChatWindowController }
        let windows = ordered + chatWindows.filter { window in !ordered.contains { $0 === window } }
        UpdateWindow.shared.show(status: "Installing Zeus \(version)…", frame: windows.first?.window?.frame)
        windows.forEach { $0.window?.orderOut(nil) }
        // A message sent just before the windows were hidden can have started a turn.
        busyTabCount { [weak self] busy in
            guard let self else { return }
            guard busy == 0 else {
                Trace.log("update: \(busy) tabs work again; the update waits")
                self.apply(.tabsBusyAgain)
                windows.forEach { Front.show($0.window) }
                UpdateWindow.shared.close()
                completion(nil)
                return
            }
            self.keepAndEndTabs(windows, version: version, completion: completion)
        }
    }

    private func keepAndEndTabs(_ windows: [ChatWindowController], version: String, completion: @escaping (TabRestore?) -> Void) {
        setupWindow?.window?.close()
        setupWindow = nil
        keepTabs(windows, version: version) { [weak self] restore in
            guard let self else { return }
            Trace.log("update: ending \(restore.tabCount) tabs for \(version)")
            SpeechService.shared.cancelAll(reason: "app updates")
            for tab in self.chatTabs { tab.closeForUpdate() }
            SessionManager.shared.waitUntilEnded(timeout: 12) {
                UpdateWindow.shared.setStatus("Starting Zeus \(version)…")
                completion(restore)
            }
        }
    }

    /// Writes the tabs of these windows, each with its mode, for the app that opens them again (`TabRestore`).
    private func keepTabs(_ windows: [ChatWindowController], version: String, completion: @escaping (TabRestore) -> Void) {
        var kept = windows.map { TabRestore.Window(frame: NSStringFromRect($0.window?.frame ?? .zero), tabs: []) }
        let group = DispatchGroup()
        for (index, window) in windows.enumerated() {
            kept[index].tabs = Array(repeating: TabRestore.Tab(terminalVisible: false, selected: false), count: window.tabs.count)
            for (position, tab) in window.tabs.enumerated() {
                group.enter()
                tab.snapshot { snapshot in
                    kept[index].tabs[position] = snapshot
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let restore = TabRestore(version: version, createdAt: Date(), windows: kept.filter { !$0.tabs.isEmpty })
            do {
                try restore.write()
            } catch {
                Trace.log("restore: not written: \(error.localizedDescription)")
            }
            completion(restore)
        }
    }

    /// The new copy did not start: this copy opens the same tabs again and says why.
    func reopenAfterFailedUpdate(_ restore: TabRestore, version: String) {
        apply(.installFailed)
        reopenTabs(restore)
        let alert = NSAlert()
        alert.messageText = "Zeus \(version) did not start"
        alert.informativeText = "Zeus stays on version \(Updater.currentVersion). Your tabs are open again."
        alert.addButton(withTitle: "OK")
        if let window = chatWindows.last?.window { Front.beginSheet(alert, for: window) { _ in } }
        Trace.log("update: tabs open again after the failed update to \(version)")
    }

    /// Opens the kept tabs of an app start, each in its own mode. EU tabs need the EU vault: it opens first (Touch ID),
    /// and its EU record fills the places of the EU tabs. When the vault stays locked, only the Standard tabs open, and the
    /// user sees why; a record without a Standard tab then opens a new Standard tab.
    private func reopen(_ restore: TabRestore) {
        guard restore.hasEU else { reopenTabs(restore); return }
        let euReady = { [weak self] in
            guard let self else { return }
            let full = restore.merged(with: TabRestore.takeEU())
            Trace.log("restore: \(full.windows.flatMap(\.tabs).filter { $0.tabMode == .eu }.count) EU tabs ready")
            self.reopenTabs(full)
        }
        if EUProfile.sessionsCanStart, EUSetup.missing().isEmpty { euReady(); return }
        let standardOnly = restore.withoutEU
        openEU(standardFallback: standardOnly.tabCount == 0) { [weak self] ready in
            if ready { euReady(); return }
            Trace.log("restore: EU tabs not opened: the EU vault stays locked")
            if standardOnly.tabCount > 0 { self?.reopenTabs(standardOnly) }
        }
    }

    /// Opens the kept tabs in their windows, each in its own mode, with their sessions resumed. An EU tab opens only
    /// while the EU vault is open.
    private func reopenTabs(_ restore: TabRestore) {
        Trace.log("restore: \(restore.tabCount) tabs in \(restore.windows.count) windows")
        for saved in restore.windows.reversed() {
            let host = makeChatWindow()
            let frame = NSRectFromString(saved.frame)
            if frame.width > 0, frame.height > 0 { host.window?.setFrame(frame, display: false) }
            var selected: ChatTab?
            for state in saved.tabs {
                // An EU chat resumes only in an EU tab, and only with the EU vault open (`reopen`).
                guard state.tabMode == .standard || EUProfile.sessionsCanStart else { continue }
                do {
                    let session = try SessionManager.shared.start(mode: state.tabMode)
                    Trace.log("session \(session.pid) started (restore, \(session.mode.rawValue))")
                    let tab = makeTab(session, restore: state)
                    host.add(tab)
                    if state.selected { selected = tab }
                } catch {
                    Trace.log("session not started: \(error.localizedDescription)")
                }
            }
            if let selected { host.select(selected) }
            if host.tabs.isEmpty { host.window?.close() } else { Front.show(host.window) }
        }
        if chatTabs.isEmpty { newChat(mode: .standard) }
    }

    /// The key window, or the front window of the app while another app is active.
    private var frontWindow: NSWindow? { NSApp.keyWindow ?? NSApp.orderedWindows.first }
    private var keyChatWindow: ChatWindowController? { frontWindow?.windowController as? ChatWindowController }
    private var keyChatTab: ChatTab? { keyChatWindow?.selectedTab }

    @objc func showSetup(_ sender: Any?) {
        guard !lifecycle.app.blocksSessions else { return }
        if let setupWindow {
            Front.show(setupWindow.window)
            Front.activate()
            return
        }
        let controller = SetupWindowController()
        Self.startDictation()
        controller.model.onOptionsApplied = { [weak self] in self?.statusMenu.update() }
        controller.model.onFinished = { [weak self, weak controller] in
            controller?.window?.close()
            self?.setupWindow = nil
            self?.newChat(nil)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window,
                                               queue: .main) { [weak self] _ in self?.setupWindow = nil }
        setupWindow = controller
        Front.show(controller.window)
        Front.activate()
    }

    // MARK: Mode

    /// The `Standard | EU` control of the title bar, for the selected tab. A switch asks first (a new chat of the
    /// other mode in this tab; from EU it offers the handover first), opens the EU vault for EU (Touch ID), checks the tab
    /// as a close does, then ends the tab's session and starts a new chat of the other mode in the same tab
    /// (`ChatTab.switchSession`). The other tabs keep running, in their own modes. EU needs its setup on this Mac first.
    /// `afterRelease`: the user clicked Switch to Standard after a release in the handover window; the switch does not
    /// ask again.
    func switchTab(_ tab: ChatTab, to target: ZeusMode, afterRelease: Bool = false) {
        guard target != tab.mode, !tab.isSwitching, !lifecycle.app.blocksSessions, !openingEU, chatTabs.contains(where: { $0 === tab }) else {
            refreshModeViews()
            return
        }
        if target == .eu {
            let missing = EUSetup.missing()
            if !missing.isEmpty { askForEUSetup(missing); return }
        }
        tab.isSwitching = true
        refreshModeViews()
        if afterRelease, target == .standard {
            Trace.log("tab mode: \(tab.session.pid) switch to standard after a release")
            checkTabBeforeSwitch(tab, to: target)
            return
        }
        Trace.log("tab mode: \(tab.session.pid) switch to \(target.rawValue) asked")
        let alert = NSAlert()
        let isolated = EUProfile.isolated
        if target == .eu {
            alert.messageText = "Start a new EU chat in this tab?"
            var text = "The Standard chat of this tab ends and stays in your Standard history. The new chat runs Claude on Google "
                + (isolated ? "Vertex AI in the EU. Its chats and EU data stay in the EU vault, which Touch ID opens. Your other tabs keep running."
                    : "Vertex AI in the EU, with your Google Cloud account. Your other tabs keep running.")
            if isolated, !Preferences.euClipboardNoteShown {
                text += "\n\nThe clipboard is shared by Standard and EU tabs. Do not paste EU data into a Standard tab."
            }
            alert.informativeText = text
            alert.addButton(withTitle: "Start EU Chat")
            alert.addButton(withTitle: "Cancel")
        } else if isolated {
            alert.messageText = "Start a new Standard chat in this tab?"
            alert.informativeText = "The EU chat of this tab ends and stays in your EU history; Standard tabs can not read it. "
                + "To give EU work to Standard, hand it over first: you check a summary and its files, and you release them."
            alert.addButton(withTitle: "Start Standard Chat")
            alert.addButton(withTitle: "Hand Over First…")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.messageText = "Start a new Standard chat in this tab?"
            alert.informativeText = "The EU chat of this tab ends and stays in your chat history. The new chat runs Claude on your "
                + "Claude account. Your other tabs keep running."
            alert.addButton(withTitle: "Start Standard Chat")
            alert.addButton(withTitle: "Cancel")
        }
        ask(alert, on: tab.host?.window) { [weak self, weak tab] response in
            guard let self, let tab else { return }
            if isolated, target == .standard, response == .alertSecondButtonReturn {
                self.endSwitch(tab, "handover first")
                self.showHandover(from: tab)
                return
            }
            guard response == .alertFirstButtonReturn else { self.endSwitch(tab, "cancelled"); return }
            guard target == .eu else { self.checkTabBeforeSwitch(tab, to: target); return }
            // The vault opens before the Standard chat ends: without it, the tab stays Standard.
            self.openEU(standardFallback: false) { ready in
                if ready { self.checkTabBeforeSwitch(tab, to: target) } else { self.endSwitch(tab, "eu vault not opened") }
            }
        }
    }

    /// EU sessions start only while the EU vault is open (`EUVault`): the EU Claude Code folder, the EU chats, and EU data
    /// are in it. This opens it after Touch ID, and makes it on the first use of EU mode; then it checks the EU setup in
    /// it (the Zeus plugins of EU mode). `completion(true)`: EU sessions can start. Otherwise the user sees why. With
    /// `standardFallback` (no chat window is open, as at an app start in EU mode), the app starts Standard mode first and
    /// shows why on its window, so that the user is never left without a window.
    private func openEU(standardFallback: Bool, completion: @escaping (Bool) -> Void) {
        let missing = EUSetup.missing()
        if !missing.isEmpty { askForEUSetup(missing, standardFallback: standardFallback); completion(false); return }
        // Simple EU (no isolation): EU tabs start like Standard tabs, with no EU vault.
        guard EUProfile.isolated else { completion(true); return }
        guard !openingEU else { completion(false); return }
        openingEU = true
        let creating = !EUVault.shared.exists && !EUVault.shared.isMounted
        Trace.log("mode: eu vault \(creating ? "create" : "unlock") asked")
        EUVault.shared.open { [weak self] result in
            guard let self else { return }
            self.openingEU = false
            switch result {
            case .success:
                let inVault = EUSetup.missingInVault()
                if inVault.isEmpty { completion(true); return }
                self.askForEUSetup(inVault, standardFallback: standardFallback)
                completion(false)
            case let .failure(failure):
                Trace.log("mode: eu vault not opened: \(failure.traceName)")
                let alert = NSAlert()
                alert.messageText = creating ? "Zeus could not make the EU vault" : "EU mode can not start"
                var text = failure.localizedDescription
                if failure == .folderNotEmpty { text += " Move those files out of ~/.zeus/eu, then try again." }
                text += "\n\nEU mode needs the vault: it keeps the EU chats and EU data encrypted on this Mac."
                if standardFallback {
                    // No window: Standard starts, and the message shows on its window. The mode switch tries EU again.
                    self.useStandardInstead()
                    alert.informativeText = text + " Zeus opened a Standard tab; switch it to EU to try again."
                    alert.addButton(withTitle: "OK")
                    self.ask(alert) { _ in }
                    completion(false)
                    return
                }
                alert.informativeText = text
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Cancel")
                self.ask(alert) { response in
                    if response == .alertFirstButtonReturn {
                        self.openEU(standardFallback: standardFallback, completion: completion)
                        return
                    }
                    completion(false)
                }
            }
        }
    }

    /// No chat window is open and an EU tab can not start: a Standard tab opens, so a window shows.
    private func useStandardInstead() {
        Trace.log("mode: standard instead of eu")
        ZeusMode.lastUsed = .standard
        newChat(mode: .standard)
    }

    /// Like a close: a tab where Zeus works or that has unsent text asks once more.
    private func checkTabBeforeSwitch(_ tab: ChatTab, to target: ZeusMode) {
        tab.closeState { [weak self, weak tab] reason in
            DispatchQueue.main.async {
                guard let self, let tab else { return }
                guard let reason else { self.performSwitch(tab, to: target); return }
                Trace.log("tab mode: switch deferred: \(reason)")
                let alert = NSAlert()
                alert.messageText = "This tab is not safe to switch"
                alert.informativeText = "\(tab.tabName.title): \(ChatTab.closeSummary(for: reason)).\n\nIf you switch now, Zeus stops in this tab."
                alert.addButton(withTitle: "Switch Anyway")
                alert.addButton(withTitle: "Cancel")
                self.ask(alert, on: tab.host?.window) { response in
                    if response == .alertFirstButtonReturn { self.performSwitch(tab, to: target) } else { self.endSwitch(tab, "cancelled") }
                }
            }
        }
    }

    /// Starts the session of the other mode and gives it to the tab; the tab ends its old session.
    private func performSwitch(_ tab: ChatTab, to target: ZeusMode) {
        guard chatTabs.contains(where: { $0 === tab }) else { endSwitch(tab, "tab closed"); return }
        guard target == .standard || EUProfile.sessionsCanStart else { endSwitch(tab, "eu vault locked"); return }
        do {
            let session = try SessionManager.shared.start(mode: target)
            Trace.log("session \(session.pid) started (\(session.mode.rawValue))")
            if target == .eu { Preferences.euClipboardNoteShown = true }
            if handoverTab === tab, target == .standard { handoverWindow?.window?.close() }
            let oldPID = tab.session.pid
            tab.switchSession(to: session)
            if tab.host?.selectedTab === tab { ZeusMode.lastUsed = target }
            // The trace names the tab by the session that it had when the switch was asked.
            endSwitch(tab, "now \(target.rawValue)", pid: oldPID)
        } catch {
            endSwitch(tab, "not started")
            Trace.log("session not started: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Zeus cannot start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            ask(alert, on: tab.host?.window) { _ in }
        }
    }

    private func endSwitch(_ tab: ChatTab, _ reason: String, pid: pid_t? = nil) {
        Trace.log("tab mode: \(pid ?? tab.session.pid) switch \(reason)")
        tab.isSwitching = false
        refreshModeViews()
    }

    private func refreshModeViews() {
        chatWindows.forEach { $0.modeChanged() }
    }

    /// `standardFallback`: no chat window is open; Standard starts first, and the question shows on its window.
    private func askForEUSetup(_ missing: [String], standardFallback: Bool = false) {
        Trace.log("mode: EU setup missing: \(missing.joined(separator: ", "))")
        if standardFallback { useStandardInstead() }
        let alert = NSAlert()
        alert.messageText = "EU mode needs a one-time setup on this Mac"
        alert.informativeText = "Missing: \(missing.joined(separator: ", ")).\n\nThe Zeus setup installs them, the same on every Mac. "
            + "Then start the EU chat again."
        alert.addButton(withTitle: "Run the Zeus Setup")
        alert.addButton(withTitle: "Cancel")
        ask(alert) { [weak self] response in
            self?.refreshModeViews()
            if response == .alertFirstButtonReturn { self?.showSetup(nil) }
        }
    }

    /// A Vertex error in an EU chat (zeus-editor `eu-error`): the same words as the EU start check, once per error.
    private func showEUError(_ words: String, in tab: ChatTab) {
        guard openAlert == nil, let window = tab.host?.window, window.attachedSheet == nil else {
            Trace.log("eu error: not shown, another question shows")
            return
        }
        let alert = NSAlert()
        alert.messageText = "EU chat: Google Cloud refused the request"
        alert.informativeText = words
        alert.addButton(withTitle: "OK")
        Trace.log("eu error shown: \(words)")
        ask(alert, on: window) { _ in }
    }

    /// Shows a question as a sheet on a chat window without a sheet (the front one first), or alone without one.
    private func ask(_ alert: NSAlert, on preferred: NSWindow? = nil, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let candidates = [preferred, keyChatWindow?.window] + chatWindows.reversed().map(\.window)
        guard let window = candidates.compactMap({ $0 }).first(where: { $0.isVisible && $0.attachedSheet == nil }) else {
            openAlert = alert
            Front.activate()
            let response = alert.runModal()
            openAlert = nil
            completion(response)
            return
        }
        openAlert = alert
        Front.show(window)
        Front.activate()
        Front.beginSheet(alert, for: window) { [weak self] response in
            if self?.openAlert === alert { self?.openAlert = nil }
            completion(response)
        }
    }

    /// The EU data access switch of the title bar: only the user turns it on, after this question, and the app (not Claude)
    /// runs Zeus. Off needs no question.
    func setEUDataAccess(project: String, on: Bool) {
        guard EUProfile.isolated, chatTabs.contains(where: { $0.mode == .eu && !$0.isSwitching }) else { refreshModeViews(); return }
        let apply = { [weak self] in
            Trace.log("eu access: \(project) \(on ? "on" : "off") asked")
            EUDataAccess.shared.set(project, on: on) { error in
                Trace.log("eu access: \(project) \(error == nil ? (on ? "on" : "off") : "failed")")
                guard let self, let error else { return }
                let alert = NSAlert()
                alert.messageText = "EU data access did not change"
                alert.informativeText = error
                alert.addButton(withTitle: "OK")
                self.ask(alert) { _ in }
            }
        }
        guard on else { apply(); return }
        let alert = NSAlert()
        alert.messageText = "Turn on EU data access for \(project)?"
        alert.informativeText = "Zeus can then read client data rows of \(project) in EU mode: SQL results, data profiles, and research "
            + "results, and it can write row files into the project's out folder. The data stays in EU mode, on Google Vertex AI in the EU. "
            + "Only you can turn it on or off, here; Zeus can not. Tell Zeus in the chat when you turned it on."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        ask(alert) { response in
            if response == .alertFirstButtonReturn { apply() } else { Trace.log("eu access: \(project) on cancelled") }
        }
    }

    /// The handover window (with an EU tab only), from the "Hand Over First…" choice of a tab's switch to Standard.
    func showHandover(from tab: ChatTab? = nil) {
        guard EUProfile.isolated, chatTabs.contains(where: { $0.mode == .eu }) else { return }
        if let tab, tab.mode == .eu { handoverTab = tab }
        if let handoverWindow {
            Front.show(handoverWindow.window)
            Front.activate()
            return
        }
        let model = HandoverModel()
        model.chatProvider = { [weak self] in
            (self?.chatTabs ?? []).filter { $0.mode == .eu && $0.session.chatURL != nil }
                .map { HandoverModel.ChatChoice(id: $0.session.id, name: $0.tabName.title) }
        }
        model.askChat = { [weak self] id, completion in
            guard let tab = self?.chatTabs.first(where: { $0.session.id == id }) else { completion(false); return }
            tab.askForHandoverSummary(completion: completion)
        }
        model.onSwitchToStandard = { [weak self] in
            guard let self else { return }
            self.handoverWindow?.window?.close()
            let tab = self.handoverTab.flatMap { $0.mode == .eu ? $0 : nil }
                ?? self.keyChatTab.flatMap { $0.mode == .eu ? $0 : nil } ?? self.chatTabs.last { $0.mode == .eu }
            guard let tab else { return }
            self.switchTab(tab, to: .standard, afterRelease: true)
        }
        let controller = HandoverWindowController(model: model)
        controller.onClosed = { [weak self] in self?.handoverWindow = nil }
        handoverWindow = controller
        Front.show(controller.window)
        Front.activate()
        Trace.log("handover: window opened")
    }

    // MARK: Test actions

    /// Debug only, active only when ZEUS_APP_TRACE is set: another process can press the app's buttons
    /// with a distributed notification "io.github.theo-henry.zeus.test" whose object is the action name.
    /// With ZEUS_APP_TEST_ID set, the name ends in ".<id>", so that a test drives only its own app copy.
    private func listenForTestActions() {
        #if DEBUG
        guard DebugEnvironment.value("ZEUS_APP_TRACE") != nil else { return }
        let testID = DebugEnvironment.value("ZEUS_APP_TEST_ID").map { "." + $0 } ?? ""
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
            case "setup-answer-no": model?.answerQuestion(false)
            case "setup-enter": model?.send("")
            case "setup-show": self.showSetup(nil)
            case "test-cmd-t", "test-cmd-j":
                let key = action == "test-cmd-t" ? "t" : "j"
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "t" ? 17 : 38) {
                    _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
                }
            // A key press of a shortcut ("test-key:Shift+Cmd+K"), as the keyboard sends it: the chat window first, then the menu.
            case "test-key":
                guard let shortcut = Accelerator(argument) else { Trace.log("test key: not a shortcut"); break }
                let window = self.chatTabs.last?.host?.window
                guard let event = shortcut.event(windowNumber: window?.windowNumber ?? 0) else { break }
                let handled = window?.performKeyEquivalent(with: event) == true || NSApp.mainMenu?.performKeyEquivalent(with: event) == true
                Trace.log("test key: \(shortcut) handled=\(handled)")
            // The same key press in the newest Zeus Editor window.
            case "test-editor-key":
                guard let shortcut = Accelerator(argument), let window = EditorWindowController.newestWebView?.window,
                      let event = shortcut.event(windowNumber: window.windowNumber) else { break }
                let handled = window.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true
                Trace.log("test editor key: \(shortcut) handled=\(handled)")
            case "test-menu-shortcuts":
                Trace.log("menu shortcuts: " + AppAction.allCases.compactMap { action in
                    self.actionItems[action].map { "\(action.rawValue)=\(Accelerator(menuItem: $0).map(String.init(describing:)) ?? "-")" }
                }.joined(separator: " "))
            case "test-settings": self.openSettings(nil)
            case "test-shortcuts-page":
                let script = "JSON.stringify({shortcuts: window.zeusApp?.shortcuts ?? null, close: typeof window.zeusApp?.closeState, settings: window.settingsOpened ?? 0})"
                self.chatTabs.last?.host?.selectedTab?.webView.evaluateJavaScript(script) { result, error in
                    Trace.log("shortcuts page: \(result ?? error?.localizedDescription ?? "empty")")
                }
            case "test-settings-changed":
                self.chatTabs.last?.webView.evaluateJavaScript("window.webkit.messageHandlers.zeusApp.postMessage({type: 'settings-changed'})")
            case "test-cancel-close": self.chatTabs.last?.cancelClose()
            case "test-close-anyway": self.chatTabs.last?.closeAnyway()
            case "new-chat": self.newChat(nil)
            case "close-chat": self.chatTabs.last.map { $0.host?.close($0) }
            case "toggle-terminal": self.chatTabs.last?.toggleTerminal()
            case "test-draft": self.chatTabs.last?.webView.evaluateJavaScript("document.querySelector('textarea').value = 'Test chat turn'; document.querySelector('textarea').dispatchEvent(new Event('input',{bubbles:true}))")
            // Clears the message box of the selected tab (of the last tab's window), where the paste checks paste.
            case "test-clear": self.chatTabs.last?.host?.selectedTab?.webView.evaluateJavaScript("document.querySelector('textarea').value = ''; document.querySelector('textarea').dispatchEvent(new Event('input',{bubbles:true}))")
            case "test-send": self.chatTabs.last?.webView.evaluateJavaScript("document.querySelector('#send,.send-button').click()")
            case "test-real-turn":
                self.chatTabs.last?.webView.evaluateJavaScript("const input=document.querySelector('textarea'); input.value='Reply with APP_OK. Do not use tools or change files.'; input.dispatchEvent(new Event('input',{bubbles:true})); document.querySelector('.send-button').click()")
            case "test-inspect":
                self.chatTabs.last?.webView.evaluateJavaScript("document.body.innerText.slice(-1800)") { result, error in
                    Trace.log("test page: \(result ?? error?.localizedDescription ?? "empty")")
                }
            case "test-terminal-input": self.chatTabs.last?.testTerminalInput()
            // Types text in the terminal of the last tab, without Enter.
            case "test-terminal-type": self.chatTabs.last?.testTerminalInput(argument)
            // The chat page of the last tab posts a message to the app ("test-post:{\"type\":\"app-update-check\"}"),
            // and "test-update-page" writes the update events that the page got into the trace.
            case "test-post":
                self.chatTabs.last?.webView.callAsyncJavaScript("window.webkit.messageHandlers.zeusApp.postMessage(JSON.parse(message))",
                                                               arguments: ["message": argument], in: nil, in: .page)
            case "test-update-page":
                self.chatTabs.last?.webView.evaluateJavaScript("JSON.stringify({version: window.zeusApp?.update?.version ?? null, events: window.updateEvents ?? null})") { result, error in
                    Trace.log("update page: \(result ?? error?.localizedDescription ?? "empty")")
                }
            // Paste: "test-pasteboard" puts the text on the pasteboard ("\\n" is a line end) and keeps the user's pasteboard
            // until "test-pasteboard-restore". "test-paste" is Edit > Paste, where Cmd+V also ends, in the chat window; that
            // window may not be the key window (the test app stays behind the other apps), so it goes to its first responder.
            // "test-click-chat" and "test-click-terminal" click as the user does; "test-keyboard" writes where the keyboard is.
            case "test-click-chat", "test-click-terminal":
                self.chatTabs.last?.host?.selectedTab?.testClick(terminal: action == "test-click-terminal")
            case "test-pasteboard":
                if self.savedPasteboard == nil {
                    self.savedPasteboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
                        let copy = NSPasteboardItem()
                        for type in item.types { item.data(forType: type).map { _ = copy.setData($0, forType: type) } }
                        return copy
                    }
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(argument.replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
            case "test-paste":
                guard let window = self.chatTabs.last?.host?.window else { break }
                NSApp.sendAction(#selector(NSText.paste(_:)), to: window.firstResponder, from: nil)
            case "test-pasteboard-restore":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(self.savedPasteboard ?? [])
                self.savedPasteboard = nil
            case "test-next-tab": self.chatTabs.last?.host?.selectTab(offset: 1)
            // "test-select-tab:<n>" shows tab n (0 is the first) of the last tab's window, as a click does.
            case "test-select-tab":
                guard let host = self.chatTabs.last?.host, let index = Int(argument), host.tabs.indices.contains(index) else { break }
                host.select(host.tabs[index])
            case "test-keyboard":
                guard let tab = self.chatTabs.last?.host?.selectedTab else { break }
                tab.webView.evaluateJavaScript("JSON.stringify(document.querySelector('textarea')?.value ?? null)") { result, _ in
                    Trace.log("test keyboard: \(tab.session.pid) \(tab.keyboardOwner) message=\(result ?? "-")")
                }
            // Picks a project in the project menu of the chat page of the selected tab (of the last tab's window), as a click does.
            case "test-pick-project":
                self.chatTabs.last?.host?.selectedTab?.webView.callAsyncJavaScript(
                    "[...document.querySelectorAll('.project-menu [role=\"option\"]')].find((option) => option.querySelector('.menu-item-label')?.textContent.trim() === name)?.click()",
                    arguments: ["name": argument], in: nil, in: .page)
            // The chat page of the first tab posts "chat-focus", as after "Go to the chat" in Zeus Editor.
            case "test-chat-focus":
                self.chatTabs.first?.webView.evaluateJavaScript("window.webkit.messageHandlers.zeusApp.postMessage('chat-focus')")
            // Speech to text: the chat page of the last tab (or with "editor-", the newest Zeus Editor page) posts a
            // speech message, as the mic button does; "test-speech-page" writes what the page has into the trace.
            // A JSON array posts each of its messages at once, one after the other, as quick clicks do.
            case "test-speech-post", "test-editor-speech-post":
                let webView = action == "test-speech-post" ? self.chatTabs.last?.webView : EditorWindowController.newestWebView
                webView?.callAsyncJavaScript(
                    "for (const m of [].concat(JSON.parse(message))) window.webkit.messageHandlers.zeusApp.postMessage(m)",
                                             arguments: ["message": argument], in: nil, in: .page)
            case "test-speech-page", "test-editor-speech-page":
                let webView = action == "test-speech-page" ? self.chatTabs.last?.webView : EditorWindowController.newestWebView
                let script = "JSON.stringify({version: window.zeusApp?.speech?.version ?? null, versions: window.zeusApp?.speech?.versions ?? null, "
                    + "close: typeof window.zeusApp?.closeState, "
                    + "text: document.querySelector('textarea')?.value ?? null, events: window.speechEvents ?? null, "
                    + "status: window.speechStatus ?? null, settings: window.speechSettings ?? null, models: window.speechModelStates ?? null})"
                webView?.evaluateJavaScript(script) { result, error in
                    Trace.log("speech page: \(result ?? error?.localizedDescription ?? "empty")")
                }
            case "test-open-editor":
                self.chatTabs.last?.webView.evaluateJavaScript("window.open('/editor', '_blank'); void 0")
            case "test-close-editor":
                EditorWindowController.newestWebView?.window?.performClose(nil)
            // Mode: "test-mode:eu" asks for a switch as the title bar does; "test-alert:<n>" presses button n (0 is the first)
            // of the question that shows; "test-mode-bar" writes what the title bar of the last tab's window shows.
            // "test-mode:eu" switches the selected tab of the last tab's window, as the title bar does.
            case "test-mode":
                guard let mode = ZeusMode(rawValue: argument), let tab = self.chatTabs.last?.host?.selectedTab else { break }
                self.switchTab(tab, to: mode)
            case "test-new-eu-chat": self.newEUChat(nil)
            case "test-new-standard-chat": self.newStandardChat(nil)
            // Keeps the tabs as an update does, then quits; an app start with ZEUS_APP_TEST_RESTORE=1 opens them again.
            case "test-keep-tabs-and-quit":
                let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? ChatWindowController }
                let windows = ordered + self.chatWindows.filter { window in !ordered.contains { $0 === window } }
                self.keepTabs(windows, version: Updater.currentVersion) { restore in
                    Trace.log("restore: kept \(restore.tabCount) tabs")
                    self.approveQuit()
                }
            case "test-alert":
                guard let alert = self.openAlert, let index = Int(argument) else { Trace.log("test alert: none"); break }
                Trace.log("test alert: \(alert.messageText) -> \(index)")
                if let parent = alert.window.sheetParent {
                    parent.endSheet(alert.window, returnCode: NSApplication.ModalResponse(rawValue: 1000 + index))
                } else {
                    NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 1000 + index))
                    // stopModal from outside an event ends the modal loop only at the next event: the test sends one.
                    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            case "test-mode-bar":
                let host = self.chatTabs.last?.host
                Trace.log("mode bar: \(host?.modeBarState ?? "none") tabs=\((host?.tabs ?? []).map { $0.mode.rawValue }.joined(separator: ","))")
            case "test-store":
                guard let tab = self.chatTabs.last else { break }
                let store = tab.webView.configuration.websiteDataStore
                Trace.log("web data: \(tab.mode.rawValue) persistent=\(store.isPersistent) default=\(store === WKWebsiteDataStore.default())")
            case "test-handover": self.showHandover()
            // "test-eu-access:<project>=on|off" moves the EU data access switch, as a click does.
            case "test-eu-access":
                let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { break }
                self.setEUDataAccess(project: parts[0], on: parts[1] == "on")
            case "test-euro-rate-reset": EuroRate.shared.reset()
            // The EU vault (EUVault). The answer of the test Touch ID: "test-vault-auth:allow|cancel|fail".
            case "test-vault-auth": (EUVault.shared.authenticator as? TestVaultAuthenticator)?.answer = argument
            case "test-vault-create": EUVault.shared.create { _ in }
            case "test-vault-unlock": EUVault.shared.unlock { _ in }
            // A lock that does not force: it fails while a program uses a file of the vault.
            case "test-vault-lock": EUVault.shared.lock(force: false) { _ in }
            // A new key in the keychain that does not open the vault.
            case "test-vault-wrong-key":
                do { try EUVault.shared.keys.save(EUVault.newKey()); Trace.log("vault: wrong key saved") } catch {
                    Trace.log("vault: wrong key not saved: \(error.localizedDescription)")
                }
            case "test-vault-state":
                Trace.log("vault state: exists=\(EUVault.shared.exists) mounted=\(EUVault.shared.isMounted) marker=\(EUVault.markerIsValid())")
            // Asks the last EU tab, the tab that the other test actions (test-pick-project) use.
            case "test-handover-ask":
                guard let model = self.handoverWindow?.model, let chat = model.chats.last else { Trace.log("handover: no chat"); break }
                model.ask(chat)
            case "test-handover-refresh": self.handoverWindow?.model.refresh()
            case "test-handover-open": self.handoverWindow?.model.open(argument)
            case "test-handover-keep-all":
                guard let model = self.handoverWindow?.model else { break }
                for group in model.groups where group.canKeep && model.decision(group) == .open { model.decide(group.id, .keep) }
            case "test-handover-mask-all": self.handoverWindow?.model.maskAll()
            // "test-handover-decide:<kind>=keep|mask|open" decides every group of that kind.
            case "test-handover-decide":
                guard let model = self.handoverWindow?.model else { break }
                let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                let choice: HandoverModel.Decision? = parts.count == 2 ? ["keep": .keep, "mask": .mask, "open": .open][parts[1]] : nil
                guard let choice else { break }
                for group in model.groups where group.kind == parts[0] { model.decide(group.id, choice) }
            // Whether the sheet shows this text as the value of a group. Only true or false goes into the trace, never a value.
            case "test-handover-value":
                let shown = self.handoverWindow?.model.groups.contains { $0.values.contains(argument) } ?? false
                Trace.log("handover value shown: \(shown)")
            case "test-handover-retry": self.handoverWindow?.model.retry()
            case "test-handover-rebuild": self.handoverWindow?.model.rebuild()
            case "test-handover-remove": self.handoverWindow?.model.setInclude(argument, false)
            case "test-handover-include": self.handoverWindow?.model.setInclude(argument, true)
            case "test-handover-switch": self.handoverWindow?.model.onSwitchToStandard?()
            case "test-handover-summary":
                guard let model = self.handoverWindow?.model else { break }
                model.review?.summary = argument.replacingOccurrences(of: "\\n", with: "\n")
                model.saveSummary()
            case "test-handover-release": self.handoverWindow?.model.release()
            case "test-handover-state":
                guard let model = self.handoverWindow?.model else { Trace.log("handover state: no window"); break }
                let groups = model.groups.map { "\($0.kind):\(model.decision($0))" }
                var phase = "\(model.phase)"
                if case let .failed(text) = model.phase { phase = "failed"; Trace.log("handover failure: \(text)") }
                Trace.log("handover state: phase=\(phase) projects=\(model.projects.map { "\($0.project):\($0.open)" }) chats=\(model.chats.count) files=\(model.review?.files.map { "\($0.path)\($0.include ? "" : "-")" } ?? []) groups=\(groups) open=\(model.openGroups.count) masked=\(model.review?.maskedKinds.count ?? 0) release=\(model.canRelease) nothing=\(model.nothingReason ?? "-") message=\(model.message ?? "-")")
            case "test-rename-open": self.chatTabs.last.map { $0.host?.startRename($0) }
            case "test-rename-save": self.chatTabs.last.map { $0.host?.endRename($0, name: argument) }
            case "toggle-menubar": self.toggleMenuBar(nil)
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

    /// Settings… (Cmd+,): the settings pop-up of the chat page (or Zeus Editor page) in front, with the keyboard in it.
    @objc private func openSettings(_ sender: Any?) {
        if let tab = keyChatTab {
            tab.host?.bringToFront(tab)
            tab.openSettings()
        } else if let webView = keyWebView {
            webView.window?.makeFirstResponder(webView)
            webView.evaluateJavaScript(ChatTab.openSettingsScript)
        }
        Trace.log("settings opened")
    }

    /// Runs the menu item of an app action, as its shortcut does. Returns false when the item is not available now.
    func perform(_ action: AppAction) -> Bool {
        guard let item = actionItems[action], let menu = item.menu, let selector = item.action else { return false }
        menu.update()
        guard item.isEnabled else { return false }
        return NSApp.sendAction(selector, to: item.target, from: item)
    }

    /// Gives the menu items of the app actions their shortcuts from the Zeus settings.
    private func applyShortcuts() {
        for (action, item) in actionItems {
            let shortcut = ShortcutSettings.shared.shortcut(for: action)
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
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
        case #selector(reloadPage(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)), #selector(openSettings(_:)):
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
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        app.addItem(withTitle: "Zeus Setup…", action: #selector(showSetup(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Show in Menu Bar", action: #selector(toggleMenuBar(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Keep in Dock", action: #selector(keepInDock(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Zeus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Zeus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let file = NSMenu(title: "File")
        actionItems[.newTab] = file.addItem(withTitle: "New Tab", action: #selector(newChat(_:)), keyEquivalent: "t")
        actionItems[.newChat] = file.addItem(withTitle: "New Chat", action: #selector(newChat(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Standard Chat", action: #selector(newStandardChat(_:)), keyEquivalent: "")
        let newEU = file.addItem(withTitle: "New EU Chat", action: #selector(newEUChat(_:)), keyEquivalent: "t")
        newEU.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        actionItems[.closeTab] = file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        actionItems[.toggleTerminal] = view.addItem(withTitle: "Show or Hide Terminal", action: #selector(toggleTerminal(_:)), keyEquivalent: "j")
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
        actionItems[.prevTab] = previousTab
        let nextTab = window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = .control
        actionItems[.nextTab] = nextTab
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
