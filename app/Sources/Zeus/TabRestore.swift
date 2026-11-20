import AppKit
import Darwin
import Foundation

/// The chat tabs of the app, kept across an update from the settings: the old copy writes them before it ends its
/// sessions, and the new copy (or the old copy after a roll back) opens the same tabs again, each in its own mode.
/// Each tab gets a new `zeus` session that resumes the Claude Code session of the tab (`LaunchControl`),
/// its project, its name, its open terminal, and the unsent text of its message box and of its terminal.
/// An EU chat never resumes in Standard: an EU tab opens again only as an EU tab, after the EU vault is open.
struct TabRestore: Codable {
    struct Tab: Codable {
        /// The mode of the tab. Nil in a file from before EU mode: a Standard tab.
        var mode: ZeusMode?
        /// The Claude Code session of the chat, from the launcher. Nil for a tab that had not started yet.
        var sessionID: String?
        var project: String?
        /// The name that the user gave the tab.
        var customName: String?
        /// The unsent text of the message box of the chat page.
        var draft: String?
        /// The unsent text in Claude Code's input box in the terminal.
        var terminalDraft: String?
        var terminalVisible: Bool
        var selected: Bool

        init(mode: ZeusMode? = nil, sessionID: String? = nil, project: String? = nil, customName: String? = nil,
             draft: String? = nil, terminalDraft: String? = nil, terminalVisible: Bool, selected: Bool) {
            self.mode = mode
            self.sessionID = sessionID
            self.project = project
            self.customName = customName
            self.draft = draft
            self.terminalDraft = terminalDraft
            self.terminalVisible = terminalVisible
            self.selected = selected
        }

        var tabMode: ZeusMode { mode ?? .standard }

        /// The place of an EU tab in the Standard record: its mode and place only, never its chat, project, name, or text.
        var placeholder: Tab { Tab(mode: tabMode, terminalVisible: terminalVisible, selected: selected) }
    }

    struct Window: Codable {
        /// The frame of the window, as NSStringFromRect gives it.
        var frame: String
        var tabs: [Tab]
    }

    /// The version that the new copy has. Only that version opens the tabs.
    var version: String
    var createdAt: Date
    var windows: [Window]
    /// The same in the Standard record and in the EU record of one write: an EU record of another write is not used.
    var id: UUID?

    init(version: String, createdAt: Date, windows: [Window], id: UUID? = UUID()) {
        self.version = version
        self.createdAt = createdAt
        self.windows = windows
        self.id = id
    }

    var tabCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }

    /// The record has EU tabs (or their places).
    var hasEU: Bool { windows.contains { $0.tabs.contains { $0.tabMode == .eu } } }

    /// Without the EU tabs, and only the windows that keep a tab.
    var withoutEU: TabRestore {
        var copy = self
        copy.windows = windows.map { Window(frame: $0.frame, tabs: $0.tabs.filter { $0.tabMode != .eu }) }.filter { !$0.tabs.isEmpty }
        return copy
    }

    /// The record of each mode. The Standard record keeps every window and the place of each EU tab
    /// (`Tab.placeholder`), so that the tabs open again in their order; the EU record has the EU tabs, window by window.
    func split() -> (standard: TabRestore, eu: TabRestore) {
        var standard = self
        var eu = self
        standard.windows = windows.map { Window(frame: $0.frame, tabs: $0.tabs.map { $0.tabMode == .eu ? $0.placeholder : $0 }) }
        eu.windows = windows.map { Window(frame: $0.frame, tabs: $0.tabs.filter { $0.tabMode == .eu }) }
        return (standard, eu)
    }

    /// The Standard record with each EU place filled from the EU record of the same write, in order. A place without an
    /// EU tab (no EU record, or one of another write) is left out.
    func merged(with eu: TabRestore?) -> TabRestore {
        let usable = eu.flatMap { $0.id != nil && $0.id == id ? $0 : nil }
        var copy = self
        copy.windows = windows.enumerated().map { index, window in
            var euTabs = (usable?.windows.indices.contains(index) ?? false) ? usable!.windows[index].tabs[...] : []
            let tabs: [Tab] = window.tabs.compactMap { tab in
                guard tab.tabMode == .eu else { return tab }
                guard let full = euTabs.popFirst(), full.tabMode == .eu else { return nil }
                return full
            }
            return Window(frame: window.frame, tabs: tabs)
        }.filter { !$0.tabs.isEmpty }
        return copy
    }

    /// The file of the tab records of a mode (`TabFiles.folder`). In simple EU both are in the app folder, so EU has a name
    /// of its own.
    private static func url(_ mode: ZeusMode) -> URL {
        let name = mode == .eu && TabFiles.folder(.eu) == TabFiles.folder(.standard) ? "restore-eu.json" : "restore.json"
        return URL(fileURLWithPath: TabFiles.folder(mode) + "/" + name)
    }
    /// A file older than this is left from an update that did not finish, and is not used.
    private static let maximumAge: TimeInterval = 15 * 60

    /// Each mode's tabs go into the folder of that mode, so the unsent text of an EU tab stays in the EU vault.
    func write() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let records = split()
        if records.eu.tabCount > 0 {
            try TabFiles.prepare(.eu)
            try encoder.encode(records.eu).write(to: Self.url(.eu), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: Self.url(.eu))
        }
        try TabFiles.prepare(.standard)
        try encoder.encode(records.standard).write(to: Self.url(.standard), options: .atomic)
    }

    static func remove() {
        for mode in ZeusMode.allCases { try? FileManager.default.removeItem(at: url(mode)) }
        try? FileManager.default.removeItem(at: TabFiles.legacy("restore.json"))
        removeOldModeTabs()
    }

    /// The tabs for this version of the app, read once: the Standard record is removed. Its EU tabs are only places
    /// until `takeEU` fills them, which needs the open EU vault.
    static func take() -> TabRestore? {
        defer {
            try? FileManager.default.removeItem(at: url(.standard))
            try? FileManager.default.removeItem(at: TabFiles.legacy("restore.json"))
        }
        let data = (try? Data(contentsOf: url(.standard))) ?? (try? Data(contentsOf: TabFiles.legacy("restore.json")))
        guard let data, let restore = decode(data) else { return nil }
        guard restore.version == Updater.currentVersion, Date().timeIntervalSince(restore.createdAt) < maximumAge else {
            Trace.log("restore: not used (for \(restore.version), written \(restore.createdAt))")
            return nil
        }
        return restore
    }

    /// The EU record, read once (main queue): the file is removed. With isolation it is in the EU vault, which must be open.
    static func takeEU() -> TabRestore? {
        defer { try? FileManager.default.removeItem(at: url(.eu)) }
        removeOldModeTabs()
        guard EUProfile.sessionsCanStart, let data = try? Data(contentsOf: url(.eu)) else { return nil }
        return decode(data)
    }

    /// The tabs that an app from before the per-tab mode kept for a switch back of the whole app (`tabs-<mode>.json`).
    /// The per-tab mode has no app switch, so they are not used.
    static func removeOldModeTabs() {
        for mode in ZeusMode.allCases {
            try? FileManager.default.removeItem(at: TabFiles.legacy("tabs-\(mode.rawValue).json"))
            if mode == .standard || EUProfile.sessionsCanStart {
                try? FileManager.default.removeItem(atPath: TabFiles.folder(mode) + "/tabs-\(mode.rawValue).json")
            }
        }
    }

    fileprivate static func decode(_ data: Data) -> TabRestore? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TabRestore.self, from: data)
    }
}

/// Where the app keeps the tab records of a mode. With isolation, they hold the unsent text of each tab, so an EU tab's
/// text, which can name client data, stays in an EU folder: the EU Zeus Editor state of the EU profile
/// (`<EU editor state>/app`), in the EU vault, which Standard sessions can not read. Standard tabs, and the EU tabs of
/// simple EU, stay in `~/Library/Application Support/Zeus`.
enum TabFiles {
    static func folder(_ mode: ZeusMode) -> String {
        mode == .eu && EUProfile.isolated ? Paths.editorStateDir(for: .eu) + "/app" : Paths.appSupport
    }

    /// Makes the folder, owner only for EU.
    static func prepare(_ mode: ZeusMode) throws {
        let attributes: [FileAttributeKey: Any]? = mode == .eu ? [.posixPermissions: 0o700] : nil
        try FileManager.default.createDirectory(atPath: folder(mode), withIntermediateDirectories: true, attributes: attributes)
    }

    /// A file of an app from before this change, in `~/Library/Application Support/Zeus`: read once, then removed.
    static func legacy(_ name: String) -> URL { URL(fileURLWithPath: Paths.appSupport + "/" + name) }
}

/// The control socket of a `zeus` launch (zeus-editor packages/launcher/control.js): one JSON object per line.
/// The first message is {op: "hello", token}; then {op: "state"} gives the launcher state (with `sessionId` and the
/// terminal's input box), and {op: "restart", resume: <session id>} restarts Claude Code with `--resume`.
/// The launch record `<editor state>/chat/launches/<launch id>.json` names the socket; the token is in the chat URL (#k=).
enum LaunchControl {
    struct Endpoint {
        let socket: String
        let token: String
    }

    /// Off the main queue: the endpoint of the session's launch, or nil when the session has no chat URL or record.
    /// The launch record is in the Zeus Editor state folder of the session's mode; in simple EU, Zeus Editor can keep EU
    /// launches in the Standard state folder, so the other folder is the second place. The token of the chat URL still
    /// has to open the socket.
    static func endpoint(launchID: String?, chatURL: URL?, mode: ZeusMode) -> Endpoint? {
        guard let launchID, !launchID.contains("/"), let fragment = chatURL?.fragment,
              let token = URLComponents(string: "x:?" + fragment)?.queryItems?.first(where: { $0.name == "k" })?.value else { return nil }
        let other: ZeusMode = mode == .eu ? .standard : .eu
        let folders = [mode] + (mode == .eu && !EUProfile.isolated ? [other] : [])
        guard let data = folders.lazy.compactMap({ try? Data(contentsOf: URL(fileURLWithPath: Paths.launchesDir(for: $0) + "/\(launchID).json")) }).first,
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let socket = record["socket"] as? String else { return nil }
        return Endpoint(socket: socket, token: token)
    }

    /// Off the main queue: sends one request after the hello and returns its result, or nil on any error.
    static func request(_ endpoint: Endpoint, _ message: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(endpoint.socket.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var reader = LineReader(descriptor: descriptor)
        guard send(descriptor, ["id": 1, "op": "hello", "token": endpoint.token]),
              reply(to: 1, from: &reader, until: deadline)?["ok"] as? Bool == true else { return nil }
        var request = message
        request["id"] = 2
        guard send(descriptor, request), let answer = reply(to: 2, from: &reader, until: deadline),
              answer["ok"] as? Bool == true else { return nil }
        return answer["result"] as? [String: Any] ?? [:]
    }

    private static func send(_ descriptor: Int32, _ message: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// The reply with this id. State events of the launcher come in between and are skipped.
    private static func reply(to id: Int, from reader: inout LineReader, until deadline: Date) -> [String: Any]? {
        while let line = reader.next(until: deadline) {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if object["id"] as? Int == id { return object }
        }
        return nil
    }

    private struct LineReader {
        let descriptor: Int32
        var buffer = Data()

        mutating func next(until deadline: Date) -> Data? {
            while true {
                if let end = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex ..< end]
                    buffer.removeSubrange(buffer.startIndex ... end)
                    return Data(line)
                }
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return nil }
                var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, Int32(min(left, 60) * 1000)) > 0 else { return nil }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let count = read(descriptor, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0 ..< count])
            }
        }
    }
}
