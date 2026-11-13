import AppKit

/// A keyboard shortcut in the format of the Zeus settings file: the modifiers in the order Ctrl, Alt, Shift, Cmd,
/// then one key, joined by "+" (for example "Shift+Cmd+M").
struct Accelerator: Equatable, CustomStringConvertible {
    let modifiers: NSEvent.ModifierFlags
    let key: String

    private static let modifierOrder: [(name: String, flag: NSEvent.ModifierFlags)] = [
        ("Ctrl", .control), ("Alt", .option), ("Shift", .shift), ("Cmd", .command),
    ]
    private static let namedKeys = ["Enter", "Escape", "Backspace", "Tab", "Space", "Up", "Down", "Left", "Right"]
    private static let symbolKeys = ["[", "]", ",", ".", "/", ";", "'", "`", "-", "="]

    /// The keys of the format: A-Z, 0-9, the named keys, and the symbol keys.
    static let keys: Set<String> = Set((65...90).map { String(UnicodeScalar(UInt8($0))) })
        .union((0...9).map(String.init)).union(namedKeys).union(symbolKeys)

    /// The key name of each key code on a US keyboard.
    private static let keyCodeNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Enter",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab",
        49: "Space", 50: "`", 51: "Backspace", 53: "Escape", 76: "Enter", 123: "Left", 124: "Right", 125: "Down",
        126: "Up",
    ]

    init(modifiers: NSEvent.ModifierFlags, key: String) {
        self.modifiers = modifiers.intersection([.control, .option, .shift, .command])
        self.key = key
    }

    /// Reads "Shift+Cmd+M". The modifiers can come in any order; nil for a text that is not a shortcut.
    init?(_ text: String) {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "Cmd+=" and "Ctrl+Shift+-" split cleanly; only a "+" key is not in the format.
        guard let key = parts.popLast(), Self.keys.contains(key) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            guard let flag = Self.modifierOrder.first(where: { $0.name == part })?.flag, !modifiers.contains(flag) else { return nil }
            modifiers.insert(flag)
        }
        self.init(modifiers: modifiers, key: key)
    }

    /// The text in the order of the format.
    var description: String {
        (Self.modifierOrder.filter { modifiers.contains($0.flag) }.map(\.name) + [key]).joined(separator: "+")
    }

    /// The key equivalent of a menu item for this key.
    var keyEquivalent: String {
        let special: [String: Int] = [
            "Enter": 0x0D, "Escape": 0x1B, "Backspace": 0x08, "Tab": 0x09, "Space": 0x20,
            "Up": NSUpArrowFunctionKey, "Down": NSDownArrowFunctionKey, "Left": NSLeftArrowFunctionKey, "Right": NSRightArrowFunctionKey,
        ]
        if let code = special[key], let scalar = UnicodeScalar(code) { return String(Character(scalar)) }
        return key.lowercased()
    }

    /// The shortcut of a key press. A letter is the letter of the keyboard layout; other keys are the key of a US
    /// keyboard at that place, because Shift changes their character ("/" gives "?").
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let typed = event.charactersIgnoringModifiers?.uppercased() ?? ""
        let key: String
        if typed.count == 1, let scalar = typed.unicodeScalars.first, ("A"..."Z").contains(scalar) {
            key = typed
        } else if let name = Self.keyCodeNames[event.keyCode] {
            key = name
        } else {
            return nil
        }
        self.init(modifiers: modifiers, key: key)
    }

    /// The shortcut of a menu item, or nil for an item without one.
    init?(menuItem: NSMenuItem) {
        let equivalent = menuItem.keyEquivalent
        guard !equivalent.isEmpty else { return nil }
        let key = Self.keys.first { Accelerator(modifiers: [], key: $0).keyEquivalent == equivalent } ?? equivalent.uppercased()
        self.init(modifiers: menuItem.keyEquivalentModifierMask, key: key)
    }

    /// A key press for this shortcut, as the keyboard makes it (test actions).
    func event(windowNumber: Int) -> NSEvent? {
        let keyCode = Self.keyCodeNames.first { $0.value == key && $0.key != 76 }?.key ?? 0
        let characters = keyEquivalent
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                windowNumber: windowNumber, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }
}

/// The app actions that have a keyboard shortcut in the Zeus settings.
enum AppAction: String, CaseIterable {
    case newTab = "app.newTab"
    case newChat = "app.newChat"
    case closeTab = "app.closeTab"
    case nextTab = "app.nextTab"
    case prevTab = "app.prevTab"
    case toggleTerminal = "app.toggleTerminal"

    var defaultShortcut: Accelerator {
        switch self {
        case .newTab: return Accelerator(modifiers: .command, key: "T")
        case .newChat: return Accelerator(modifiers: .command, key: "N")
        case .closeTab: return Accelerator(modifiers: .command, key: "W")
        case .nextTab: return Accelerator(modifiers: .control, key: "Tab")
        case .prevTab: return Accelerator(modifiers: [.control, .shift], key: "Tab")
        case .toggleTerminal: return Accelerator(modifiers: .command, key: "J")
        }
    }
}

/// The keyboard shortcuts of the app actions, from the Zeus settings file
/// `~/Library/Application Support/Zeus/settings.json`: `{"version": 1, "shortcuts": {"<action id>": "<shortcut>"}}`.
/// The file has only the changed shortcuts; an action without an entry has its default.
/// The chat and Zeus Editor pages write the file (the settings pop-up) and read their own action ids from it.
/// The app only reads it: at launch, after a page posts `{type: "settings-changed"}`, and when the file changes.
final class ShortcutSettings {
    static let shared = ShortcutSettings()

    /// Shortcuts that macOS or the app menu keeps: an app action cannot take them.
    /// Cmd+, opens the settings, and the others are the system shortcuts and the fixed items of the app menu.
    static let reserved: Set<String> = [
        "Cmd+Q", "Cmd+Tab", "Cmd+Space", "Cmd+H", "Cmd+M", "Shift+Cmd+3", "Shift+Cmd+4", "Shift+Cmd+5",
        "Ctrl+Cmd+Q", "Alt+Cmd+Escape", "Cmd+,",
        "Alt+Cmd+H", "Cmd+Z", "Shift+Cmd+Z", "Cmd+X", "Cmd+C", "Cmd+V", "Cmd+A", "Cmd+R", "Cmd+0",
        "Cmd+=", "Shift+Cmd+=", "Cmd+-", "Ctrl+Cmd+F",
    ]

    /// The page bridge: `window.zeusApp.shortcuts`, so that the settings pop-up shows the app shortcuts in the app.
    static let pageInfo: [String: Any] = ["version": 1, "appActions": AppAction.allCases.map(\.rawValue)]

    /// The shortcut of each app action now.
    private(set) var shortcuts: [AppAction: Accelerator] = Dictionary(uniqueKeysWithValues: AppAction.allCases.map { ($0, $0.defaultShortcut) })
    /// Called on the main queue when the shortcuts change.
    var onChange: (() -> Void)?

    private var directoryWatch: DispatchSourceFileSystemObject?
    private var fileWatch: DispatchSourceFileSystemObject?
    private var reloadPending = false

    var fileURL: URL { URL(fileURLWithPath: Paths.appSupport + "/settings.json") }

    /// Reads the file and watches its folder and the file, so that a change from a browser also applies.
    func start() {
        reload(reason: "launch")
        watch()
    }

    /// The message of a page after it saved the settings: `{type: "settings-changed"}`. Returns false for other messages.
    func handle(_ body: Any) -> Bool {
        guard let message = body as? [String: Any], message["type"] as? String == "settings-changed" else { return false }
        reload(reason: "page")
        return true
    }

    func shortcut(for action: AppAction) -> Accelerator { shortcuts[action] ?? action.defaultShortcut }

    /// The app action of a key press, or nil.
    func action(for event: NSEvent) -> AppAction? {
        guard let pressed = Accelerator(event: event) else { return nil }
        return AppAction.allCases.first { shortcut(for: $0) == pressed }
    }

    private func reload(reason: String) {
        let loaded = Self.read(fileURL)
        guard loaded != shortcuts || reason == "launch" else {
            Trace.log("shortcuts: unchanged (\(reason))")
            return
        }
        shortcuts = loaded
        Trace.log("shortcuts: " + AppAction.allCases.map { "\($0.rawValue)=\(shortcut(for: $0))" }.joined(separator: " ") + " (\(reason))")
        onChange?()
    }

    /// The shortcuts of the file. A missing or damaged file, an entry that is not a shortcut, a reserved shortcut,
    /// a shortcut without Cmd or Ctrl, and a shortcut of two actions give the default.
    static func read(_ url: URL) -> [AppAction: Accelerator] {
        var result = Dictionary(uniqueKeysWithValues: AppAction.allCases.map { ($0, $0.defaultShortcut) })
        guard let data = try? Data(contentsOf: url) else { return result }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Trace.log("shortcuts: the settings file is not valid JSON; the defaults apply")
            return result
        }
        guard let entries = root["shortcuts"] as? [String: Any] else { return result }
        for action in AppAction.allCases {
            guard let value = entries[action.rawValue] else { continue }
            guard let text = value as? String, let shortcut = Accelerator(text) else {
                Trace.log("shortcuts: \(action.rawValue) is not a shortcut: \(value)")
                continue
            }
            if reserved.contains(shortcut.description) {
                Trace.log("shortcuts: \(action.rawValue) \(shortcut) is reserved")
                continue
            }
            if shortcut.modifiers.isDisjoint(with: [.command, .control]) {
                Trace.log("shortcuts: \(action.rawValue) \(shortcut) needs Cmd or Ctrl")
                continue
            }
            result[action] = shortcut
        }
        // Two actions with one shortcut: the changed ones get their defaults again.
        for action in AppAction.allCases where result[action] != action.defaultShortcut {
            if AppAction.allCases.contains(where: { $0 != action && result[$0] == result[action] }) {
                Trace.log("shortcuts: \(action.rawValue) \(result[action]!) is used twice")
                result[action] = action.defaultShortcut
            }
        }
        return result
    }

    // MARK: Watching the file

    /// The folder gets an event when a write replaces the file (a temp file and a rename);
    /// the file gets an event when an editor writes it in place.
    private func watch() {
        directoryWatch?.cancel()
        directoryWatch = Self.source(path: Paths.appSupport, mask: [.write, .delete, .rename]) { [weak self] in
            self?.changed(folder: true)
        }
        watchFile()
    }

    private func watchFile() {
        fileWatch?.cancel()
        fileWatch = Self.source(path: fileURL.path, mask: [.write, .extend, .delete, .rename]) { [weak self] in
            self?.changed(folder: false)
        }
    }

    private func changed(folder: Bool) {
        // A removed or renamed folder: watch the new one.
        if folder, let directoryWatch, directoryWatch.data.contains(.delete) || directoryWatch.data.contains(.rename) {
            watch()
        }
        guard !reloadPending else { return }
        reloadPending = true
        // One read after a burst of events, when the writer has finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.watchFile()
            self.reload(reason: "file")
        }
    }

    private static func source(path: String, mask: DispatchSource.FileSystemEvent,
                               handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
