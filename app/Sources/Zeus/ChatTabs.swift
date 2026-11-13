import AppKit
import WebKit

extension Notification.Name {
    /// The name of a tab changed.
    static let zeusTabNameChanged = Notification.Name("ZeusTabNameChanged")
}

/// The name of one chat tab: a name that the user gave in the tab strip, else the project of the chat, else "Project".
/// The app does not keep the names after it quits.
final class TabName {
    static let noProject = "Project"
    private static let maxLength = 120

    /// The project that the chat page shows, or nil when the chat has no project.
    private(set) var project: String?
    /// The name that the user gave the tab, or nil for the automatic name.
    private(set) var custom: String?

    var title: String { custom ?? project ?? Self.noProject }

    func setProject(_ name: String?) {
        let name = Self.clean(name)
        guard name != project else { return }
        project = name
        changed()
    }

    /// An empty name gives the tab its automatic name again.
    func rename(_ name: String?) {
        let name = Self.clean(name)
        guard name != custom else { return }
        custom = name
        changed()
    }

    private func changed() {
        Trace.log("tab name: \(title) project=\(project ?? "-") custom=\(custom ?? "-")")
        NotificationCenter.default.post(name: .zeusTabNameChanged, object: self)
    }

    private static func clean(_ name: String?) -> String? {
        let text = (name ?? "").components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(maxLength))
    }

    /// The project message of the chat page: {type: "project", name: <project name or null>}.
    /// Returns nil when the message is not a project message.
    static func project(from message: [String: Any]) -> String?? {
        guard message["type"] as? String == "project" else { return nil }
        return .some(message["name"] as? String)
    }

    /// Sends the project message for chat pages that do not send it themselves: it reads the project
    /// button in the top bar of the chat (zeus-editor src/chat/client/main.js, renderHeader), where
    /// "No project" means no project.
    static let projectScript = WKUserScript(source: """
        (() => {
          const bridge = window.webkit?.messageHandlers?.zeusApp;
          if (!bridge || !location.pathname.startsWith("/chat/")) return;
          let last;
          const report = () => {
            const label = document.querySelector(".project-pill .pill-text");
            if (!label) return;
            const text = label.textContent.trim();
            const name = text === "No project" ? null : text;
            if (name === last) return;
            last = name;
            bridge.postMessage({ type: "project", name });
          };
          new MutationObserver(report).observe(document.documentElement, { subtree: true, childList: true, characterData: true });
          report();
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
}

/// A chat window with tabs. The app draws the tabs itself in the title bar, because the macOS tab bar
/// cannot take the Zeus theme or a Rename item, and macOS shows it whenever a window has two tabs.
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    private(set) var tabs: [ChatTab] = []
    private(set) var selectedTab: ChatTab?
    private var strip: TabStripView!
    private let tabArea = NSView()
    var onClosed: ((ChatWindowController) -> Void)?

    init() {
        let window = ChatTabWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.title = TabName.noProject
        // The chat page draws its own header; the title bar keeps the window buttons and the tabs.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty toolbar makes the title bar as high as the tabs and centres the window buttons in it.
        window.toolbar = NSToolbar(identifier: "ZeusChatTabs")
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 640, height: 480)
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = LoaderPage.background
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        strip = TabStripView(controller: self)
        let container = NSView()
        for view in [strip!, tabArea] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        window.contentView = container
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: container.topAnchor),
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: TabStripView.height),
            tabArea.topAnchor.constraint(equalTo: strip.bottomAnchor),
            tabArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.setFrameAutosaveName("ZeusChatWindow")
        if window.frame.origin == .zero { window.center() }
        NotificationCenter.default.addObserver(self, selector: #selector(tabNameChanged(_:)),
                                               name: .zeusTabNameChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func add(_ tab: ChatTab) {
        tab.host = self
        tabs.append(tab)
        tab.view.translatesAutoresizingMaskIntoConstraints = false
        tabArea.addSubview(tab.view)
        NSLayoutConstraint.activate([
            tab.view.topAnchor.constraint(equalTo: tabArea.topAnchor),
            tab.view.bottomAnchor.constraint(equalTo: tabArea.bottomAnchor),
            tab.view.leadingAnchor.constraint(equalTo: tabArea.leadingAnchor),
            tab.view.trailingAnchor.constraint(equalTo: tabArea.trailingAnchor),
        ])
        select(tab)
    }

    func select(_ tab: ChatTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let changed = selectedTab !== tab
        // Speech to text stops in the tab that the user leaves; its page keeps the text.
        if changed, let previous = selectedTab {
            SpeechService.shared.stop(in: previous.webView, reason: "tab hidden")
            previous.rememberKeyboard()
        }
        selectedTab = tab
        for other in tabs { other.view.isHidden = other !== tab }
        window?.title = tab.tabName.title
        strip.reload()
        WebViewHandler.matchTitleBar(of: window, to: tab.webView)
        if changed {
            window?.makeFirstResponder(tab.focusView)
            Trace.log("tab selected: \(tab.session.pid) \(tab.tabName.title)")
        }
    }

    /// Shows the tab and its window in front of all other windows, with the keyboard in the chat page,
    /// also when Zeus Editor is in another app (the default browser).
    func bringToFront(_ tab: ChatTab) {
        guard tabs.contains(where: { $0 === tab }), let window else { return }
        select(tab)
        if window.isMiniaturized { window.deminiaturize(nil) }
        Front.activate()
        Front.show(window)
        window.makeFirstResponder(tab.webView)
        let inPage = (window.firstResponder as? NSView)?.isDescendant(of: tab.webView) ?? false
        Trace.log("chat focused: \(tab.session.pid) \(tab.tabName.title) page-has-keyboard=\(inPage)")
    }

    /// Shows the tab next to the selected tab: +1 is the tab to the right, -1 the tab to the left.
    func selectTab(offset: Int) {
        guard tabs.count > 1, let selectedTab, let index = tabs.firstIndex(where: { $0 === selectedTab }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// The tab shows first, so that its close banner is in view.
    func close(_ tab: ChatTab) {
        select(tab)
        tab.requestClose()
    }

    /// Called by a tab that has closed. The window closes with its last tab.
    func remove(_ tab: ChatTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        tab.view.removeFromSuperview()
        tab.host = nil
        if tabs.isEmpty {
            selectedTab = nil
            window?.close()
        } else if selectedTab === tab {
            selectedTab = nil
            select(tabs[min(index, tabs.count - 1)])
        } else {
            strip.reload()
        }
    }

    #if DEBUG
    /// Test actions: open the rename field of a tab, and save a name in it as Return does.
    func startRename(_ tab: ChatTab) { strip.item(of: tab)?.startRename() }
    func endRename(_ tab: ChatTab, name: String) { strip.item(of: tab)?.saveRename(name) }
    #endif

    @objc private func tabNameChanged(_ notification: Notification) {
        guard tabs.contains(where: { $0.tabName === notification.object as AnyObject }) else { return }
        if let selectedTab { window?.title = selectedTab.tabName.title }
        strip.reload()
    }

    /// The close button of the window and Cmd+W close the selected tab, as before.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let selectedTab else { return true }
        close(selectedTab)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        onClosed?(self)
    }
}

/// The window of the chat tabs: Control-Tab and Control-Shift-Tab show the next and the previous tab.
final class ChatTabWindow: NSWindow {
    private var tabs: ChatWindowController? { windowController as? ChatWindowController }

    override func selectNextTab(_ sender: Any?) { tabs?.selectTab(offset: 1) }
    override func selectPreviousTab(_ sender: Any?) { tabs?.selectTab(offset: -1) }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectNextTab(_:)) || menuItem.action == #selector(selectPreviousTab(_:)) {
            return (tabs?.tabs.count ?? 0) > 1
        }
        return super.validateMenuItem(menuItem)
    }

    /// A click in the chat page or in the terminal gives that part of the tab the keyboard before the click goes on.
    /// The click that only brings an inactive window to the front does not reach the page (WebKit does not take
    /// the first click), so without this the keyboard stays in the terminal, and Cmd+V in the chat box pastes there.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           let hit = contentView?.superview?.hitTest(event.locationInWindow) {
            tabs?.selectedTab?.giveKeyboard(forClickOn: hit)
        }
        super.sendEvent(event)
    }

    /// The web page must not take Control-Tab before the menu does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] {
            tabs?.selectTab(offset: modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The tabs of a chat window in the Zeus chat theme (zeus-editor src/chat/chat.css): a click shows a tab,
/// a right-click renames or closes it, and + opens a new tab.
final class TabStripView: NSView {
    static let height: CGFloat = 40
    private weak var controller: ChatWindowController?
    private let stack = NSStackView()
    private let addButton = HoverButton(symbol: "plus", label: "New Tab")
    private var leadingConstraint: NSLayoutConstraint!

    init(controller: ChatWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addButton.target = self
        addButton.action = #selector(newTab)
        addSubview(addButton)
        leadingConstraint = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 80)
        NSLayoutConstraint.activate([
            leadingConstraint,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 4),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowStyleChanged), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLeadingInset()
    }

    override func layout() {
        super.layout()
        updateLeadingInset()
    }

    @objc private func windowStyleChanged() { needsLayout = true }

    /// Room for the window buttons, which macOS hides in full screen.
    private func updateLeadingInset() {
        guard let window else { return }
        var inset: CGFloat = 12
        if !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton), zoom.window != nil {
            inset = zoom.convert(zoom.bounds, to: nil).maxX + 14
        }
        if leadingConstraint.constant != inset { leadingConstraint.constant = inset }
    }

    // MARK: Moving and zooming the window from the empty part of the strip

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }

    // MARK: Tabs

    func reload() {
        guard let controller else { return }
        let old = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        // An item stays while its tab is open, so that an open rename field stays across updates.
        let items = controller.tabs.map { tab in old.first { $0.tab === tab } ?? TabItemView(tab: tab, strip: self) }
        for item in old where !items.contains(where: { $0 === item }) { item.removeFromSuperview() }
        for (index, item) in items.enumerated() where stack.arrangedSubviews.firstIndex(of: item) != index {
            item.removeFromSuperview()
            stack.insertArrangedSubview(item, at: index)
        }
        for item in items { item.update(selected: item.tab === controller.selectedTab) }
    }

    fileprivate func item(of tab: ChatTab) -> TabItemView? {
        stack.arrangedSubviews.lazy.compactMap { $0 as? TabItemView }.first { $0.tab === tab }
    }

    func select(_ tab: ChatTab) { controller?.select(tab) }
    func close(_ tab: ChatTab) { controller?.close(tab) }

    @objc private func newTab() {
        Front.show(window)
        NSApp.sendAction(#selector(AppDelegate.newChat(_:)), to: nil, from: self)
    }
}

/// The Zeus chat colours of the tab strip (zeus-editor src/chat/chat.css).
private enum TabColors {
    static let selected = NSColor(srgbRed: 19/255, green: 53/255, blue: 97/255, alpha: 1)       // --ink-600
    static let selectedBorder = NSColor(srgbRed: 36/255, green: 71/255, blue: 122/255, alpha: 1) // --line-strong
    static let hover = NSColor(srgbRed: 13/255, green: 42/255, blue: 78/255, alpha: 1)          // --ink-800
    static let border = NSColor(srgbRed: 26/255, green: 58/255, blue: 100/255, alpha: 1)        // --line
    static let text = NSColor(srgbRed: 241/255, green: 246/255, blue: 249/255, alpha: 1)        // --fg
    static let dimText = NSColor(srgbRed: 169/255, green: 189/255, blue: 213/255, alpha: 1)     // --fg-dim
    static let focus = NSColor(srgbRed: 55/255, green: 114/255, blue: 1, alpha: 1)               // --venus
    static let field = NSColor(srgbRed: 11/255, green: 37/255, blue: 69/255, alpha: 1)          // --ink-900
}

/// A borderless icon button with the hover surface of the ghost buttons of the chat.
private final class HoverButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = hovering ? TabColors.hover.cgColor : NSColor.clear.cgColor
        contentTintColor = hovering ? TabColors.text : TabColors.dimText
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// One tab: its name, and a close button on the selected tab and under the pointer.
private final class TabItemView: NSView, NSTextFieldDelegate {
    private static let font = NSFont(name: "ObjectSans-Regular", size: 13) ?? .systemFont(ofSize: 13)
    private static let selectedFont = NSFont(name: "PPObjectSans-Semibold", size: 13) ?? .boldSystemFont(ofSize: 13)
    private static let width: (min: CGFloat, max: CGFloat) = (96, 220)

    private(set) weak var tab: ChatTab?
    private weak var strip: TabStripView?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = HoverButton(symbol: "xmark", label: "Close Tab")
    private var field: NSTextField?
    private var selected = false
    private var hovering = false { didSet { updateAppearance() } }

    init(tab: ChatTab, strip: TabStripView) {
        self.tab = tab
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)

        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        addSubview(closeButton)
        // As wide as the maximum while there is room, narrower when the window has many tabs.
        let preferred = widthAnchor.constraint(equalToConstant: Self.width.max)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.width.min),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.width.max),
            preferred,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    private var name: String { tab?.tabName.title ?? "" }

    func update(selected: Bool) {
        self.selected = selected
        label.stringValue = name
        toolTip = name
        setAccessibilityLabel(name)
        setAccessibilityValue(selected)
        updateAppearance()
    }

    private func updateAppearance() {
        let renaming = field != nil
        layer?.backgroundColor = (selected ? TabColors.selected : hovering ? TabColors.hover : .clear).cgColor
        layer?.borderColor = (selected ? TabColors.selectedBorder : TabColors.border).cgColor
        label.font = selected ? Self.selectedFont : Self.font
        label.textColor = selected ? TabColors.text : TabColors.dimText
        label.isHidden = renaming
        closeButton.isHidden = renaming || !(selected || hovering)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard let tab else { return }
        strip?.select(tab)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab…", action: #selector(startRename), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "").target = self
        return menu
    }

    override func accessibilityPerformPress() -> Bool {
        guard let tab else { return false }
        strip?.select(tab)
        return true
    }

    @objc private func closeTab() {
        guard let tab else { return }
        strip?.close(tab)
    }

    // MARK: Rename

    @objc func startRename() {
        guard field == nil, let tab else { return }
        strip?.select(tab)
        let field = NSTextField(string: name)
        field.font = Self.selectedFont
        field.textColor = TabColors.text
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderString = tab.tabName.project ?? TabName.noProject
        field.delegate = self
        field.setAccessibilityLabel("Tab name")
        field.translatesAutoresizingMaskIntoConstraints = false
        // The frame of the field, in the focus colour of the chat's rename field.
        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 6
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = TabColors.focus.cgColor
        frame.layer?.backgroundColor = TabColors.field.cgColor
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(field)
        addSubview(frame)
        NSLayoutConstraint.activate([
            frame.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            frame.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            frame.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            frame.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            field.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
        ])
        self.field = field
        updateAppearance()
        tab.rememberKeyboard()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Return saves the name, Escape keeps the old name. An empty name gives the tab its automatic name.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endRename(save: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endRename(save: false); return true
        default: return false
        }
    }

    #if DEBUG
    func saveRename(_ name: String) {
        field?.stringValue = name
        endRename(save: true)
    }
    #endif

    /// A click somewhere else saves the name, as in the Finder.
    func controlTextDidEndEditing(_ notification: Notification) { endRename(save: true) }

    private func endRename(save: Bool) {
        guard let field else { return }
        self.field = nil
        field.delegate = nil
        let editing = field.currentEditor() != nil
        field.superview?.removeFromSuperview()
        if save { tab?.tabName.rename(field.stringValue) }
        update(selected: selected)
        if editing, let tab { window?.makeFirstResponder(tab.focusView) }
    }
}
