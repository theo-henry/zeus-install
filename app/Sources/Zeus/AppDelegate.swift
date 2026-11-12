import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var chatWindows: [ChatWindowController] = []
    private var setupWindow: SetupWindowController?
    private let statusMenu = StatusMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusMenu.app = self
        statusMenu.update()

        SessionManager.shared.adoptLeftovers()
        let adopted = SessionManager.shared.sessions
        adopted.forEach { show($0) }

        Trace.log("launched: setupNeeded=\(setupNeeded) adopted=\(adopted.count)")
        if setupNeeded {
            showSetup(nil)
        } else if adopted.isEmpty {
            newChat(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The first start, or a Mac where the zeus command or the workspace has gone.
    private var setupNeeded: Bool {
        !Preferences.setupDone || !FileManager.default.isExecutableFile(atPath: Paths.zeusCommand)
            || !FileManager.default.fileExists(atPath: Paths.zeusDir)
    }

    /// A click on the Dock icon while no window is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        setupWindow?.model.stop()
        guard SessionManager.shared.sessions.contains(where: \.isAlive) else { return .terminateNow }
        SessionManager.shared.stopAll {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Windows

    @objc func newChat(_ sender: Any?) {
        do {
            let session = try SessionManager.shared.start()
            Trace.log("session \(session.pid) started")
            show(session)
        } catch {
            Trace.log("session not started: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Zeus cannot start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Run the Zeus Setup")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { showSetup(nil) }
        }
    }

    func show(_ session: ZeusSession) {
        if let existing = chatWindows.first(where: { $0.session === session }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ChatWindowController(session: session)
        controller.onClosed = { [weak self] closed in self?.chatWindows.removeAll { $0 === closed } }
        controller.onRetry = { [weak self, weak controller] in
            controller?.window?.close()
            self?.newChat(nil)
        }
        controller.onRunSetup = { [weak self, weak controller] in
            controller?.window?.close()
            self?.showSetup(nil)
        }
        chatWindows.append(controller)
        // New chats open as tabs of an open chat window, like new tabs in a browser.
        if let host = chatWindows.dropLast().last?.window, host.isVisible, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSetup(_ sender: Any?) {
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

    private var keyWebView: WKWebView? {
        NSApp.keyWindow?.contentView as? WKWebView
    }

    @objc private func reloadPage(_ sender: Any?) {
        if let controller = NSApp.keyWindow?.windowController as? ChatWindowController {
            controller.reload()
        } else {
            keyWebView?.reload()
        }
    }

    @objc private func zoomIn(_ sender: Any?) { keyWebView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }
    @objc private func zoomOut(_ sender: Any?) { keyWebView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.5) } }
    @objc private func actualSize(_ sender: Any?) { keyWebView?.pageZoom = 1 }

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
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Zeus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Zeus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Chat", action: #selector(newChat(_:)), keyEquivalent: "n")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
