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
    /// The menu item of each app action, which shows and runs its shortcut from the Zeus settings.
    private var actionItems: [AppAction: NSMenuItem] = [:]
    /// The update check at launch runs, or an update from the settings installs; only its loading screen shows,
    /// and no Zeus session opens until it ends.
    private var updating = false
    /// A mode switch runs: it asks, ends the sessions of the old mode, then starts the new mode. No session starts meanwhile.
    private(set) var isSwitchingMode = false
    private var handoverWindow: HandoverWindowController?
    /// The question that shows now (a mode switch), which the debug test actions can answer.
    private var openAlert: NSAlert?
    #if DEBUG
    /// The user's pasteboard before the paste test actions, given back by "test-pasteboard-restore".
    private var savedPasteboard: [NSPasteboardItem]?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            guard let self, self.checkingQuit else { return }
            self.approveQuit()
        }

        Trace.log("launched: version=\(Updater.currentVersion) setupNeeded=\(setupNeeded) mode=\(ZeusMode.current.rawValue)")
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
        updating = true
        Updater.checkAtLaunch { [weak self] relaunching in
            guard let self, !relaunching else { return }
            self.updating = false
            self.startZeus()
        }
    }

    private func startZeus(restoring: Bool = false) {
        let firstSetup = setupNeeded
        if firstSetup {
            showSetup(nil)
        } else if restoring, let restore = TabRestore.take(mode: ZeusMode.current), restore.tabCount > 0 {
            reopenTabs(restore)
        } else {
            newChat(nil)
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
        Front.show(window)
        Front.activate()
        quitQuestionWindow = window
        Front.beginSheet(alert, for: window) { [weak self] response in
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
        guard !updating, !isSwitchingMode else { return }
        do {
            let session = try SessionManager.shared.start()
            Trace.log("session \(session.pid) started (\(session.mode.rawValue))")
            show(session)
        } catch {
            Trace.log("session not started: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Zeus cannot start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Run the Zeus Setup")
            alert.addButton(withTitle: "Cancel")
            Front.activate()
            if alert.runModal() == .alertFirstButtonReturn { showSetup(nil) }
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
            tab?.requestClose()
            self?.newChat(nil)
        }
        tab.onRunSetup = { [weak self, weak tab] in
            tab?.requestClose()
            self?.showSetup(nil)
        }
        tab.onSwitchToStandard = { [weak self] in self?.requestMode(.standard) }
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
        // A mode switch ends and starts tabs: the update waits until it is done.
        if isSwitchingMode { completion(1); return }
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
        updating = true
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
                self.updating = false
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
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let restore = TabRestore(version: version, createdAt: Date(), windows: kept.filter { !$0.tabs.isEmpty })
            do {
                try restore.write()
            } catch {
                Trace.log("restore: not written: \(error.localizedDescription)")
            }
            Trace.log("update: ending \(restore.tabCount) tabs for \(version)")
            SpeechService.shared.cancelAll(reason: "app updates")
            for tab in self.chatTabs { tab.closeForUpdate() }
            SessionManager.shared.waitUntilEnded(timeout: 12) {
                UpdateWindow.shared.setStatus("Starting Zeus \(version)…")
                completion(restore)
            }
        }
    }

    /// The new copy did not start: this copy opens the same tabs again and says why.
    func reopenAfterFailedUpdate(_ restore: TabRestore, version: String) {
        updating = false
        reopenTabs(restore)
        let alert = NSAlert()
        alert.messageText = "Zeus \(version) did not start"
        alert.informativeText = "Zeus stays on version \(Updater.currentVersion). Your tabs are open again."
        alert.addButton(withTitle: "OK")
        if let window = chatWindows.last?.window { Front.beginSheet(alert, for: window) { _ in } }
        Trace.log("update: tabs open again after the failed update to \(version)")
    }

    /// Opens the kept tabs in their windows, with their sessions resumed.
    private func reopenTabs(_ restore: TabRestore) {
        Trace.log("restore: \(restore.tabCount) tabs in \(restore.windows.count) windows")
        for saved in restore.windows.reversed() {
            let host = makeChatWindow()
            let frame = NSRectFromString(saved.frame)
            if frame.width > 0, frame.height > 0 { host.window?.setFrame(frame, display: false) }
            var selected: ChatTab?
            for state in saved.tabs {
                // Only tabs of the mode of the app come here (TabRestore.take, ModeTabs.take); a tab never changes mode.
                guard state.tabMode == ZeusMode.current else { continue }
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
        if chatTabs.isEmpty { newChat(nil) }
    }

    /// The key window, or the front window of the app while another app is active.
    private var frontWindow: NSWindow? { NSApp.keyWindow ?? NSApp.orderedWindows.first }
    private var keyChatWindow: ChatWindowController? { frontWindow?.windowController as? ChatWindowController }
    private var keyChatTab: ChatTab? { keyChatWindow?.selectedTab }

    @objc func showSetup(_ sender: Any?) {
        guard !updating else { return }
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

    /// The `Standard | EU` switch of the title bar, the menu, and the menu bar item. A switch asks first; from EU it
    /// offers the handover first. Then it ends every session of the old mode, keeps its tabs for a switch back, and
    /// starts the new mode with the tabs that it had (or one new tab). EU needs its setup on this Mac first.
    func requestMode(_ target: ZeusMode) {
        guard target != ZeusMode.current, !isSwitchingMode, !updating else { refreshModeViews(); return }
        if target == .eu {
            let missing = EUSetup.missing()
            if !missing.isEmpty { askForEUSetup(missing); return }
        }
        isSwitchingMode = true
        refreshModeViews()
        Trace.log("mode: switch to \(target.rawValue) asked")
        let alert = NSAlert()
        if target == .eu {
            alert.messageText = "Switch to EU mode?"
            var text = "Zeus closes the Standard tabs and starts EU mode: Claude on Google Vertex AI in the EU, with its own chats, "
                + "workspace (\(EUSetup.display(EUProfile.load().workspace))), and settings. In EU mode, Zeus can read client data "
                + "after you turn on EU data access for a project. The Standard tabs open again when you switch back."
            if !Preferences.euClipboardNoteShown {
                text += "\n\nThe clipboard is shared by both modes. Do not paste EU data into Standard mode."
            }
            alert.informativeText = text
            alert.addButton(withTitle: "Switch to EU")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.messageText = "Switch to Standard mode?"
            alert.informativeText = "Zeus closes the EU tabs. EU chats and EU files stay in EU mode. To give EU work to Standard "
                + "mode, hand it over first: you check a summary and its files, and you release them."
            alert.addButton(withTitle: "Hand Over First…")
            alert.addButton(withTitle: "Switch Without Handover")
            alert.addButton(withTitle: "Cancel")
        }
        ask(alert) { [weak self] response in
            guard let self else { return }
            let switching = response == .alertFirstButtonReturn && target == .eu
                || response == .alertSecondButtonReturn && target == .standard
            if target == .standard, response == .alertFirstButtonReturn {
                self.endSwitch("handover first")
                self.showHandover(nil)
                return
            }
            guard switching else { self.endSwitch("cancelled"); return }
            self.checkTabsBeforeSwitch(to: target)
        }
    }

    /// Like the quit: tabs where Zeus works or that have unsent text ask once for all.
    private func checkTabsBeforeSwitch(to target: ZeusMode) {
        let tabs = chatTabs
        guard !tabs.isEmpty else { performSwitch(to: target); return }
        var unsafe: [(ChatTab, String)] = []
        var remaining = tabs.count
        for tab in tabs {
            tab.closeState { [weak self] reason in
                if let reason { unsafe.append((tab, reason)) }
                remaining -= 1
                guard remaining == 0 else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard !unsafe.isEmpty else { self.performSwitch(to: target); return }
                    Trace.log("mode: switch deferred: \(unsafe.map(\.1).joined(separator: " "))")
                    let alert = NSAlert()
                    alert.messageText = unsafe.count == 1 ? "A Zeus tab is not safe to close" : "\(unsafe.count) Zeus tabs are not safe to close"
                    alert.informativeText = unsafe.map { "\($0.0.tabName.title): \(ChatTab.closeSummary(for: $0.1))" }
                        .joined(separator: "\n") + "\n\nIf you switch now, Zeus stops in every tab."
                    alert.addButton(withTitle: "Switch Anyway")
                    alert.addButton(withTitle: "Cancel")
                    self.ask(alert) { response in
                        if response == .alertFirstButtonReturn { self.performSwitch(to: target) } else { self.endSwitch("cancelled") }
                    }
                }
            }
        }
    }

    private func performSwitch(to target: ZeusMode) {
        let old = ZeusMode.current
        Trace.log("mode: switching from \(old.rawValue) to \(target.rawValue), ending \(chatTabs.count) tabs")
        handoverWindow?.window?.close()
        let windows = chatWindows
        var kept = windows.map { TabRestore.Window(frame: NSStringFromRect($0.window?.frame ?? .zero), tabs: []) }
        let group = DispatchGroup()
        for (index, window) in windows.enumerated() {
            kept[index].tabs = Array(repeating: TabRestore.Tab(mode: old, terminalVisible: false, selected: false), count: window.tabs.count)
            for (position, tab) in window.tabs.enumerated() {
                group.enter()
                tab.snapshot { snapshot in
                    kept[index].tabs[position] = snapshot
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // The tabs of the old mode, for a switch back. Tabs that had not started keep only their names.
            ModeTabs.save(TabRestore(version: Updater.currentVersion, createdAt: Date(), windows: kept.filter { !$0.tabs.isEmpty }), mode: old)
            SpeechService.shared.cancelAll(reason: "mode switch")
            for tab in self.chatTabs { tab.closeForUpdate() }
            // Zeus Editor pages of the old mode close too: they hold the web data of that mode.
            EditorWindowController.closeAll()
            self.waitForNoSession {
                ZeusMode.current = target
                if target == .eu { Preferences.euClipboardNoteShown = true }
                self.isSwitchingMode = false
                Trace.log("mode: now \(target.rawValue)")
                if let saved = ModeTabs.take(target) { self.reopenTabs(saved) } else { self.newChat(nil) }
                self.refreshModeViews()
            }
        }
    }

    /// The new mode starts only when no session of the old mode runs: each gets SIGTERM, and SIGKILL after 10 s.
    private func waitForNoSession(_ completion: @escaping () -> Void) {
        SessionManager.shared.waitUntilEnded(timeout: 15) { [weak self] in
            if SessionManager.shared.sessions.contains(where: \.isAlive) {
                Trace.log("mode: sessions still run; waiting")
                SessionManager.shared.sessions.filter(\.isAlive).forEach { $0.stop() }
                self?.waitForNoSession(completion)
                return
            }
            completion()
        }
    }

    private func endSwitch(_ reason: String) {
        Trace.log("mode: switch \(reason)")
        isSwitchingMode = false
        refreshModeViews()
    }

    private func refreshModeViews() {
        chatWindows.forEach { $0.modeChanged() }
        statusMenu.update()
    }

    private func askForEUSetup(_ missing: [String]) {
        Trace.log("mode: EU setup missing: \(missing.joined(separator: ", "))")
        let alert = NSAlert()
        alert.messageText = "EU mode needs a one-time setup on this Mac"
        alert.informativeText = "Missing: \(missing.joined(separator: ", ")).\n\nThe Zeus setup installs them, the same on every Mac. "
            + "Then switch to EU mode again."
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
        alert.messageText = "EU mode: Google Cloud refused the request"
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

    /// Hand Over EU Work…: the handover window (EU mode only).
    @objc func showHandover(_ sender: Any?) {
        guard ZeusMode.current == .eu else { return }
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
            self?.handoverWindow?.window?.close()
            self?.requestMode(.standard)
        }
        let controller = HandoverWindowController(model: model)
        controller.onClosed = { [weak self] in self?.handoverWindow = nil }
        handoverWindow = controller
        Front.show(controller.window)
        Front.activate()
        Trace.log("handover: window opened")
    }

    @objc private func chooseStandard(_ sender: Any?) { requestMode(.standard) }
    @objc private func chooseEU(_ sender: Any?) { requestMode(.eu) }

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
            case "test-keyboard":
                guard let tab = self.chatTabs.last?.host?.selectedTab else { break }
                tab.webView.evaluateJavaScript("JSON.stringify(document.querySelector('textarea')?.value ?? null)") { result, _ in
                    Trace.log("test keyboard: \(tab.session.pid) \(tab.keyboardOwner) message=\(result ?? "-")")
                }
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
            case "test-mode": ZeusMode(rawValue: argument).map { self.requestMode($0) }
            case "test-alert":
                guard let alert = self.openAlert, let index = Int(argument) else { Trace.log("test alert: none"); break }
                Trace.log("test alert: \(alert.messageText) -> \(index)")
                if let parent = alert.window.sheetParent {
                    parent.endSheet(alert.window, returnCode: NSApplication.ModalResponse(rawValue: 1000 + index))
                } else {
                    NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 1000 + index))
                }
            case "test-mode-bar":
                Trace.log("mode bar: \(self.chatTabs.last?.host?.modeBarState ?? "none") tabs=\(self.chatTabs.map { $0.mode.rawValue }.joined(separator: ","))")
            case "test-store":
                guard let tab = self.chatTabs.last else { break }
                let store = tab.webView.configuration.websiteDataStore
                Trace.log("web data: \(tab.mode.rawValue) persistent=\(store.isPersistent) default=\(store === WKWebsiteDataStore.default())")
            case "test-handover": self.showHandover(nil)
            case "test-handover-ask":
                guard let model = self.handoverWindow?.model, let chat = model.chats.first else { Trace.log("handover: no chat"); break }
                model.ask(chat)
            case "test-handover-refresh": self.handoverWindow?.model.refresh()
            case "test-handover-open": self.handoverWindow?.model.open(argument)
            case "test-handover-accept-all":
                guard let model = self.handoverWindow?.model else { break }
                for finding in model.review?.findings ?? [] where !finding.blocking { model.setAccepted(finding.id, true) }
            case "test-handover-remove": self.handoverWindow?.model.setInclude(argument, false)
            case "test-handover-summary":
                guard let model = self.handoverWindow?.model else { break }
                model.review?.summary = argument.replacingOccurrences(of: "\\n", with: "\n")
                model.saveSummary()
            case "test-handover-release": self.handoverWindow?.model.release()
            case "test-handover-state":
                guard let model = self.handoverWindow?.model else { Trace.log("handover state: no window"); break }
                let findings = model.review?.findings.map { "\($0.kind)\($0.blocking ? "!" : "")\($0.accepted ? "+" : "")" } ?? []
                Trace.log("handover state: phase=\(model.phase) projects=\(model.projects.map { "\($0.project):\($0.open)" }) chats=\(model.chats.count) files=\(model.review?.files.map { "\($0.path)\($0.include ? "" : "-")" } ?? []) findings=\(findings) open=\(model.openFindings.count) release=\(model.canRelease) message=\(model.message ?? "-")")
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
        case #selector(chooseStandard(_:)), #selector(chooseEU(_:)):
            let mode: ZeusMode = menuItem.action == #selector(chooseEU(_:)) ? .eu : .standard
            menuItem.state = ZeusMode.current == mode ? .on : .off
            return !isSwitchingMode && !updating
        case #selector(showHandover(_:)):
            return ZeusMode.current == .eu && !isSwitchingMode
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
        app.addItem(.separator())
        app.addItem(withTitle: "Standard Mode", action: #selector(chooseStandard(_:)), keyEquivalent: "")
        app.addItem(withTitle: "EU Mode", action: #selector(chooseEU(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Hand Over EU Work…", action: #selector(showHandover(_:)), keyEquivalent: "")
        app.addItem(.separator())
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
