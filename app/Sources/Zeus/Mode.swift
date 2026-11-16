import CryptoKit
import Foundation

/// The app-wide mode of Zeus (zeus-editor docs/chat.md, "EU mode"; zeus references/eu-mode.md).
/// Standard runs Claude Code on the consultant's Claude login in ~/Code/zeus. EU runs `zeus --eu`: Claude Code on Vertex AI in the EU,
/// with its own Claude folder, editor state, and workspace (~/Code/zeus-eu). Every tab of the app has the app's mode, and a chat never
/// moves between modes: a switch ends the open chats and starts new ones. Work goes from EU to Standard only through the handover.
enum ZeusMode: String {
    case standard
    case eu

    var title: String { self == .eu ? "EU" : "Standard" }

    /// The mode of every tab that starts now.
    static var current: ZeusMode {
        get { Preferences.mode }
        set { Preferences.mode = newValue }
    }

    /// The Zeus workspace of the mode. ZEUS_APP_EU_WORKSPACE replaces the EU one (for tests).
    var workspace: String {
        switch self {
        case .standard: return Paths.zeusDir
        case .eu: return ProcessInfo.processInfo.environment["ZEUS_APP_EU_WORKSPACE"] ?? Paths.home + "/Code/zeus-eu"
        }
    }

    /// The arguments of `zeus`. `--no-open` stops it from opening the browser; the app shows the page.
    var arguments: [String] { self == .eu ? ["--eu", "--no-open"] : ["--no-open"] }

    /// The Zeus Editor state of the mode, where `zeus` keeps its launch records.
    var editorStateDir: String {
        switch self {
        case .standard: return Paths.editorStateDir
        case .eu: return ProcessInfo.processInfo.environment["ZEUS_APP_EU_EDITOR_STATE_DIR"] ?? Paths.home + "/.zeus/eu/editor"
        }
    }
}

/// Runs a short command and waits for it, with a time limit.
enum Shell {
    struct Run {
        let status: Int32
        let output: String
        let errors: String
    }

    /// Nil when the command did not start or did not end within `timeout` seconds. Blocks: call it off the main queue.
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil, directory: String? = nil,
                    timeout: TimeInterval) -> Run? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        var outputData = Data()
        var errorData = Data()
        let lock = NSLock()
        var openPipes = 2
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            lock.lock()
            if data.isEmpty { openPipes -= 1 }
            outputData.append(data)
            lock.unlock()
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            lock.lock()
            if data.isEmpty { openPipes -= 1 }
            if errorData.count < 16000 { errorData.append(data) }
            lock.unlock()
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
        }
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        // The last output arrives after the exit; a child that keeps the pipes open does not hold the answer long.
        let drained = Date().addingTimeInterval(2)
        while Date() < drained {
            lock.lock()
            let open = openPipes
            lock.unlock()
            if open == 0 { break }
            usleep(5000)
        }
        lock.lock()
        defer { lock.unlock() }
        return Run(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                   errors: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The Standard | EU controls of the tab strips follow the app's mode.
enum ModeSwitch {
    static let changed = Notification.Name("io.github.theo-henry.zeus.mode-changed")
    static func refresh() { NotificationCenter.default.post(name: changed, object: nil) }
}
