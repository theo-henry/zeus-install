import AppKit
import Foundation

/// The output of a hidden terminal, which the terminal panel of a tab shows and types into.
protocol TerminalSource: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    /// The process of the terminal, for the trace.
    var terminalPID: pid_t { get }
    func write(_ text: String)
    func resize(rows: UInt16, cols: UInt16)
}

/// One Zeus chat: the `zeus` command in a hidden terminal, and its chat page.
final class ZeusSession: TerminalSource {
    enum State: Equatable {
        case starting
        case running(URL)
        case failed(String)
        case ended
    }

    let id = UUID()
    /// The mode of the session: `zeus` (Standard) or `zeus --eu` (EU). It never changes: a tab that switches its mode
    /// gets a new session.
    let mode: ZeusMode
    let pid: pid_t
    let startedAt: Date
    let log = TerminalLog()
    private let process: PTYProcess
    private var stopRequested = false
    /// The exit code of `zeus`, when it has stopped.
    private(set) var exitCode: Int32?

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

    var terminalPID: pid_t { pid }

    /// Starts `zeus` or `zeus --eu` in the shared workspace ~/Code/zeus. `--no-open` stops it from opening the browser;
    /// the app shows the page. A Standard `zeus` runs in the read block of `StandardJail` (`sandbox-exec` execs it, so
    /// the process ID is the one of `zeus`). `zeus --eu` builds the environment of EU Claude Code from the EU profile only and checks
    /// the Google Cloud access first (zeus-editor src/eu/preflight.js); a failed check stops it with exit code 3.
    /// An EU session starts only while the EU vault is open: its Claude Code folder and its data are in the vault, and
    /// zeus refuses EU mode without the vault marker. The app opens the vault before it starts EU sessions.
    init(mode: ZeusMode = .standard) throws {
        self.mode = mode
        startedAt = Date()
        let env = ShellEnvironment.make()
        guard FileManager.default.isExecutableFile(atPath: Paths.zeusCommand) else {
            throw NSError(domain: "Zeus", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The zeus command is not installed (\(Paths.zeusCommand)). Run the Zeus setup."])
        }
        let workspace = Paths.workspace
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "Zeus", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The Zeus workspace is not in ~/Code/zeus. Run the Zeus setup."])
        }
        let isolated = mode == .eu && EUProfile.isolated
        if isolated, !EUVault.isOpen {
            throw NSError(domain: "Zeus", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "The EU vault is locked. Start the EU chat again to unlock it with Touch ID."])
        }
        if isolated { EUStatusLine.sync() }
        let arguments = (mode == .eu ? ["--eu"] : []) + ["--no-open"]
        var executable = Paths.zeusCommand
        var launchArguments = arguments
        if mode == .standard {
            // A Standard session may not read the EU folders (StandardJail).
            let launch = try StandardJail.launch(command: Paths.zeusCommand, arguments: arguments)
            executable = launch.executable
            launchArguments = launch.arguments
            Trace.log(launch.jailed ? "jail: on" : StandardJail.vaultExists ? "jail: off: simple EU (no isolation)" : "jail: off: no EU vault on this Mac")
        }
        Trace.log("session command: \(([executable] + launchArguments).joined(separator: " "))")
        let process = try PTYProcess(executable: executable, arguments: launchArguments, environment: env, directory: workspace)
        self.process = process
        pid = process.pid
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
        log.onChange = { [weak self] in self?.scanForChatURL(); self?.onLog?() }
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
        exitCode = code
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
        process.write(text)
    }

    func resize(rows: UInt16, cols: UInt16) { process.resize(rows: rows, cols: cols) }

    /// Ends the session the way Ctrl+C in Terminal would end `zeus`: it stops Claude Code and cleans up.
    func stop() {
        stopRequested = true
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
    func start(mode: ZeusMode) throws -> ZeusSession {
        let session = try ZeusSession(mode: mode)
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
        waitUntilEnded(timeout: timeout, completion: completion)
    }

    /// Calls `completion` when no session is alive, or after `timeout` seconds. It stops nothing.
    func waitUntilEnded(timeout: TimeInterval, completion: @escaping () -> Void) {
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
        guard let dir = DebugEnvironment.value("ZEUS_APP_PTY_CAPTURE"), !dir.isEmpty else { return nil }
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
