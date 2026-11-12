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
    let pid: pid_t
    let startedAt: Date
    let log = TerminalLog()
    private let process: PTYProcess
    private var stopRequested = false

    private(set) var state: State = .starting {
        didSet {
            guard state != oldValue else { return }
            Trace.log("session \(pid) state: \(state)")
            managerHook?(state)
            onStateChange?(state)
        }
    }

    /// For the window of the session.
    var onStateChange: ((State) -> Void)?
    /// For SessionManager.
    var managerHook: ((State) -> Void)?
    var onLog: (() -> Void)?

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

    /// Starts `zeus` in ~/Code/zeus. `--no-open` stops it from opening the browser; the app shows the page.
    init() throws {
        startedAt = Date()
        let env = ShellEnvironment.make()
        guard FileManager.default.isExecutableFile(atPath: Paths.zeusCommand) else {
            throw NSError(domain: "Zeus", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The zeus command is not installed (\(Paths.zeusCommand)). Run the Zeus setup."])
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Paths.zeusDir, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "Zeus", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The Zeus workspace is not in ~/Code/zeus. Run the Zeus setup."])
        }
        let process = try PTYProcess(executable: Paths.zeusCommand, arguments: ["--no-open"],
                                     environment: env, directory: Paths.zeusDir)
        self.process = process
        pid = process.pid
        process.onOutput = { [weak self] data in self?.log.append(data) }
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
        if stopRequested || chatURL != nil {
            state = .ended
            return
        }
        state = .failed("Zeus stopped (exit code \(code)) before the chat page opened.")
    }

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
    func start() throws -> ZeusSession {
        let session = try ZeusSession()
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
