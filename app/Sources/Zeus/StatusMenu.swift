import AppKit

/// The optional menu bar item: the running sessions, with Open and Stop for each.
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    weak var app: AppDelegate?

    func update() {
        defer { updateIcon() }
        if Preferences.showMenuBar, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = StatusMenu.icon()
            item.button?.toolTip = "Zeus"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !Preferences.showMenuBar, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// In EU mode the menu bar item shows "EU" next to its icon, like the EU pill of the windows.
    private func updateIcon() {
        guard let button = item?.button else { return }
        let eu = ZeusMode.current == .eu
        item?.length = eu ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.title = eu ? "EU" : ""
        button.imagePosition = eu ? .imageLeading : .imageOnly
        button.toolTip = eu ? "Zeus, EU mode" : "Zeus"
    }

    private static func icon() -> NSImage? {
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Zeus")
        image?.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = SessionManager.shared.sessions.filter(\.isAlive)
        let mode = ZeusMode.current
        let header = menu.addItem(withTitle: mode == .eu ? "Mode: EU (Google Vertex AI, EU)" : "Mode: Standard", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let switching = app?.isSwitchingMode ?? false
        for choice in ZeusMode.allCases {
            let item = menu.addItem(withTitle: "\(choice.title) Mode", action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == mode ? .on : .off
            item.isEnabled = !switching
        }
        if mode == .eu {
            menu.addItem(withTitle: "Hand Over EU Work…", action: #selector(handover), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Zeus Chat", action: #selector(newChat), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if sessions.isEmpty {
            let none = menu.addItem(withTitle: "No Zeus sessions run", action: nil, keyEquivalent: "")
            none.isEnabled = false
        } else {
            let header = menu.addItem(withTitle: "Running sessions", action: nil, keyEquivalent: "")
            header.isEnabled = false
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            for session in sessions {
                let title = session.chatURL == nil ? "Starting… (since \(formatter.string(from: session.startedAt)))"
                    : "Chat started at \(formatter.string(from: session.startedAt))"
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                let open = submenu.addItem(withTitle: "Open", action: #selector(openSession(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = session
                let stop = submenu.addItem(withTitle: "Stop", action: #selector(stopSession(_:)), keyEquivalent: "")
                stop.target = self
                stop.representedObject = session
                entry.submenu = submenu
                menu.addItem(entry)
            }
            menu.addItem(withTitle: "Stop All Sessions", action: #selector(stopAll), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Zeus Setup…", action: #selector(setup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Hide Menu Bar Icon", action: #selector(hide), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Zeus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func newChat() { app?.newChat(nil) }
    @objc private func handover() { app?.showHandover(nil) }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(ZeusMode.init(rawValue:)) else { return }
        app?.requestMode(mode)
    }
    @objc private func setup() { app?.showSetup(nil) }
    @objc private func stopAll() { SessionManager.shared.sessions.forEach { $0.stop() } }

    @objc private func hide() {
        Preferences.showMenuBar = false
        update()
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? ZeusSession else { return }
        app?.show(session)
    }

    @objc private func stopSession(_ sender: NSMenuItem) {
        (sender.representedObject as? ZeusSession)?.stop()
    }
}
