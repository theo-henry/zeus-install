import AppKit
import Foundation

/// One Zeus chat: the `zeus` command in a hidden terminal, and its chat page.
final class ZeusSession {
    enum State: Equatable {
        case starting
        case running(URL)
        case failed(String)
        case ended
    }

    let id = UUID()
    /// Where this session's Claude Code sends its requests; fixed for the whole session.
    let host: ClaudeHost
    /// The process ID of `zeus`; 0 until it starts (an EU session checks the Google Cloud sign-in first).
    private(set) var pid: pid_t = 0
    let startedAt: Date
    let log = TerminalLog()
    private var process: PTYProcess?
    private var stopRequested = false
    /// What the loading screen says before `zeus` writes its first lines.
    private(set) var startStatus: String?

    private(set) var state: State = .starting {
        didSet {
            guard state != oldValue else { return }
            let summary: String
            if case let .running(url) = state {
                summary = "running(\(url.absoluteString.components(separatedBy: "#").first ?? ""))"
            } else { summary = "\(state)" }
            Trace.log("session \(pid) state: \(summary)")
            managerHook?(state)
            onStateChange?(state)
        }
    }

    /// For the window of the session.
    var onStateChange: ((State) -> Void)?
    /// For SessionManager.
    var managerHook: ((State) -> Void)?
    var onLog: (() -> Void)?
    var onOutput: ((Data) -> Void)?
    #if DEBUG
    private var capture: PTYCapture?
    #endif

    var chatURL: URL? {
        if case let .running(url) = state { return url }
        return nil
    }

    var launchID: String? {
        guard let url = chatURL else { return nil }
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "chat"), index + 1 < parts.count { return parts[index + 1] }
        return nil
    }

    var isAlive: Bool { state == .starting || chatURL != nil }

    /// Starts `zeus` in the Zeus workspace. `--no-open` stops it from opening the browser; the app shows the page.
    /// An Apolix session starts at once. An EU session first checks the EU setup and the Google Cloud
    /// sign-in; when that check fails, the session fails with the reason and nothing starts on Apolix.
    init(host: ClaudeHost = .apolix) throws {
        self.host = host
        startedAt = Date()
        guard FileManager.default.isExecutableFile(atPath: Paths.zeusCommand) else {
            throw NSError(domain: "Zeus", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The zeus command is not installed (\(Paths.zeusCommand)). Run the Zeus setup."])
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Paths.zeusDir, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "Zeus", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The Zeus workspace is not in \(Paths.zeusDir). Run the Zeus setup."])
        }
        log.onChange = { [weak self] in self?.scanForChatURL(); self?.onLog?() }
        switch host {
        case .apolix:
            try spawn(environment: ShellEnvironment.session(host: .apolix))
        case .eu:
            startStatus = "Checking the Google Cloud sign-in for EU…"
            Trace.log("session: EU preflight starts")
            EUHost.preflight { [weak self] result in self?.preflightEnded(result) }
        }
    }

    private func spawn(environment: [String: String]) throws {
        let process = try PTYProcess(executable: Paths.zeusCommand, arguments: ["--no-open"],
                                     environment: environment, directory: Paths.zeusDir)
        self.process = process
        pid = process.pid
        Trace.log("session \(pid) host: \(host.rawValue) blind=\(environment[BlindMode.variable] ?? "-")")
        #if DEBUG
        capture = PTYCapture(pid: process.pid)
        #endif
        process.onOutput = { [weak self] data in
            #if DEBUG
            self?.capture?.record(">", data)
            #endif
            self?.log.append(data)
            self?.onOutput?(data)
        }
        process.onExit = { [weak self] code in self?.processEnded(code: code) }
    }

    private func preflightEnded(_ result: Result<[String: String], HostError>) {
        startStatus = nil
        // The tab closed, or the consultant switched the host, while the check ran.
        if stopRequested {
            if state != .ended { state = .ended }
            return
        }
        do {
            let variables = try result.get()
            Trace.log("session: EU preflight passed")
            try spawn(environment: EUHost.environment(variables: variables))
            onLog?()
        } catch {
            Trace.log("session: EU start refused: \(error.localizedDescription)")
            if let detail = (error as? HostError)?.detail, !detail.isEmpty { log.append(Data((detail + "\n").utf8)) }
            state = .failed(error.localizedDescription)
        }
    }

    private func scanForChatURL() {
        guard state == .starting else { return }
        // zeus prints: "Zeus chat: http://127.0.0.1:<port>/chat/<id>#k=<token>"
        for line in (log.lines.suffix(40) + [log.currentLine]).reversed() {
            guard let range = line.range(of: "Zeus chat: ") else { continue }
            let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let token = rest.split(separator: " ").first.map(String.init) ?? rest
            if let url = URL(string: token), WebViewHandler.isLocal(url) {
                state = .running(url)
                return
            }
        }
    }

    private func processEnded(code: Int32) {
        if stopRequested || chatURL != nil {
            state = .ended
            return
        }
        state = .failed("Zeus stopped (exit code \(code)) before the chat page opened.")
    }

    func write(_ text: String) {
        #if DEBUG
        capture?.record("<", Data(text.utf8))
        #endif
        process?.write(text)
    }

    func resize(rows: UInt16, cols: UInt16) { process?.resize(rows: rows, cols: cols) }

    /// Ends the session the way Ctrl+C in Terminal would end `zeus`: it stops Claude Code and cleans up.
    func stop() {
        stopRequested = true
        guard let process else {
            // `zeus` did not start: the EU check still runs, or it failed. Nothing to stop.
            if state != .ended { state = .ended }
            return
        }
        // zeus gives Claude Code up to 7 seconds to stop, then removes its launch record; wait longer than that.
        process.terminate(grace: 10)
    }
}

/// All the sessions of this app. A session never outlives the app: if the app crashes, its hidden
/// terminal closes and zeus stops, as after a closed Terminal window.
final class SessionManager {
    static let shared = SessionManager()

    private(set) var sessions: [ZeusSession] = []
    var onChange: (() -> Void)?

    @discardableResult
    func start(host: ClaudeHost = .apolix) throws -> ZeusSession {
        let session = try ZeusSession(host: host)
        add(session)
        return session
    }

    private func add(_ session: ZeusSession) {
        sessions.append(session)
        session.managerHook = { [weak self, weak session] state in
            guard let self, let session else { return }
            if state == .ended { self.sessions.removeAll { $0 === session } }
            self.onChange?()
        }
        onChange?()
    }

    func remove(_ session: ZeusSession) {
        sessions.removeAll { $0 === session }
        onChange?()
    }

    /// Stops every session and calls `completion` when they have ended, or after `timeout` seconds.
    func stopAll(timeout: TimeInterval = 12, completion: @escaping () -> Void) {
        let alive = sessions.filter(\.isAlive)
        if alive.isEmpty { completion(); return }
        alive.forEach { $0.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if sessions.allSatisfy({ !$0.isAlive }) || Date() > deadline { completion(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
        }
        check()
    }
}

#if DEBUG
/// Debug only, active only when ZEUS_APP_PTY_CAPTURE names a folder: records every byte that the
/// session's PTY sends (">") and receives ("<"), with times, in <folder>/pty-<pid>.log.
private final class PTYCapture {
    private let file: FileHandle
    private let start = Date()

    init?(pid: pid_t) {
        guard let dir = ProcessInfo.processInfo.environment["ZEUS_APP_PTY_CAPTURE"], !dir.isEmpty else { return nil }
        let path = dir + "/pty-\(pid).log"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: path) else { return nil }
        self.file = file
    }

    func record(_ direction: String, _ data: Data) {
        let escaped = data.map { byte -> String in
            switch byte {
            case 0x20 ..< 0x7F where byte != 0x5C: return String(UnicodeScalar(byte))
            case 0x0A: return "\\n\n"
            default: return String(format: "\\x%02x", byte)
            }
        }.joined()
        let line = String(format: "%.3f %@ ", Date().timeIntervalSince(start), direction) + escaped + "\n"
        file.write(Data(line.utf8))
    }
}
#endif
