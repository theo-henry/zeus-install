import AppKit
import Darwin
import Foundation

/// The chat tabs of the app, kept across an update from the settings: the old copy writes them before it ends its
/// sessions, and the new copy (or the old copy after a roll back) opens the same tabs again.
/// Each tab gets a new `zeus` session that resumes the Claude Code session of the tab (`LaunchControl`),
/// its project, its name, its open terminal, and the unsent text of its message box and of its terminal.
/// The same record keeps the tabs of a mode while the app runs in the other mode (`ModeTabs`).
/// Each tab has its mode: a tab opens again only in the same mode, so an EU chat never resumes in Standard.
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

    var tabCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }

    /// Only the tabs of this mode, and only the windows that keep a tab.
    func only(_ mode: ZeusMode) -> TabRestore {
        var copy = self
        copy.windows = windows.map { Window(frame: $0.frame, tabs: $0.tabs.filter { $0.tabMode == mode }) }.filter { !$0.tabs.isEmpty }
        return copy
    }

    private static var url: URL { URL(fileURLWithPath: Paths.appSupport + "/restore.json") }
    /// A file older than this is left from an update that did not finish, and is not used.
    private static let maximumAge: TimeInterval = 15 * 60

    func write() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }

    /// The tabs for this version of the app and this mode, read once: the file is removed.
    /// A tab of the other mode does not open.
    static func take(mode: ZeusMode) -> TabRestore? {
        defer { remove() }
        guard let data = try? Data(contentsOf: url), let restore = decode(data) else { return nil }
        guard restore.version == Updater.currentVersion, Date().timeIntervalSince(restore.createdAt) < maximumAge else {
            Trace.log("restore: not used (for \(restore.version), written \(restore.createdAt))")
            return nil
        }
        let kept = restore.only(mode)
        if kept.tabCount < restore.tabCount {
            Trace.log("restore: \(restore.tabCount - kept.tabCount) tabs of another mode not opened in \(mode.rawValue)")
        }
        return kept
    }

    fileprivate static func decode(_ data: Data) -> TabRestore? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TabRestore.self, from: data)
    }
}

/// The tabs of the mode that the app left at a mode switch, so that a switch back opens them again with their chats.
/// One file per mode: `~/Library/Application Support/Zeus/tabs-<mode>.json`. Only tabs of that mode go in it.
enum ModeTabs {
    private static func url(_ mode: ZeusMode) -> URL { URL(fileURLWithPath: Paths.appSupport + "/tabs-\(mode.rawValue).json") }

    static func save(_ restore: TabRestore, mode: ZeusMode) {
        let kept = restore.only(mode)
        guard kept.tabCount > 0 else { try? FileManager.default.removeItem(at: url(mode)); return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(kept).write(to: url(mode), options: .atomic)
        } catch {
            Trace.log("mode tabs: not written: \(error.localizedDescription)")
        }
    }

    /// The kept tabs of this mode, read once: the file is removed.
    static func take(_ mode: ZeusMode) -> TabRestore? {
        defer { try? FileManager.default.removeItem(at: url(mode)) }
        guard let data = try? Data(contentsOf: url(mode)), let restore = TabRestore.decode(data) else { return nil }
        let kept = restore.only(mode)
        return kept.tabCount > 0 ? kept : nil
    }
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
    /// The launch record is in the Zeus Editor state folder of the session's mode.
    static func endpoint(launchID: String?, chatURL: URL?, mode: ZeusMode) -> Endpoint? {
        guard let launchID, !launchID.contains("/"), let fragment = chatURL?.fragment,
              let token = URLComponents(string: "x:?" + fragment)?.queryItems?.first(where: { $0.name == "k" })?.value,
              let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.launchesDir(for: mode) + "/\(launchID).json")),
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
