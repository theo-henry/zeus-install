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
    private let process: PTYProcess?
    private var exitSource: DispatchSourceProcess?
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

    /// A session that an earlier run of the app started, still running after the app quit unexpectedly.
    init(adoptingPID pid: pid_t, url: URL, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
        process = nil
        state = .running(url)
        log.appendLine("This session was started by an earlier run of the Zeus app (process \(pid)).")
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.exitSource?.cancel()
            self?.processEnded(code: 0)
        }
        source.resume()
        exitSource = source
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
        if let process {
            process.terminate(grace: 10)
        } else if kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [pid] in
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        } else {
            state = .ended
        }
    }
}

/// All the sessions of the app. Remembers their process IDs, so that sessions left behind by a crash
/// of the app are found at the next start and do not stay hidden.
final class SessionManager {
    static let shared = SessionManager()

    private(set) var sessions: [ZeusSession] = []
    var onChange: (() -> Void)?

    private var recordFile: String { Paths.appSupport + "/sessions.json" }

    private struct Record: Codable {
        let pid: Int32
        let url: String
        let startedAt: Date
    }

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
            self.save()
            self.onChange?()
        }
        save()
        onChange?()
    }

    /// Adds the sessions that an earlier run of the app left running.
    func adoptLeftovers() {
        guard let data = FileManager.default.contents(atPath: recordFile),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        for record in records where kill(record.pid, 0) == 0 && launchRecordExists(pid: record.pid) {
            guard let url = URL(string: record.url) else { continue }
            add(ZeusSession(adoptingPID: record.pid, url: url, startedAt: record.startedAt))
        }
        save()
    }

    /// zeus writes ~/.zeus-editor/chat/launches/<id>.json with its pid, and removes it when it stops.
    /// This check makes sure that the pid is still that zeus, not a new process with the same number.
    private func launchRecordExists(pid: Int32) -> Bool {
        let dir = Paths.launchesDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if (object["pid"] as? NSNumber)?.int32Value == pid { return true }
        }
        return false
    }

    private func save() {
        let records = sessions.compactMap { session -> Record? in
            guard session.isAlive else { return nil }
            return Record(pid: session.pid, url: session.chatURL?.absoluteString ?? "", startedAt: session.startedAt)
        }.filter { !$0.url.isEmpty }
        guard let data = try? JSONEncoder().encode(records) else { return }
        FileManager.default.createFile(atPath: recordFile, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func remove(_ session: ZeusSession) {
        sessions.removeAll { $0 === session }
        save()
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
