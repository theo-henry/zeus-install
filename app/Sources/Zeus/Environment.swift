import Foundation

enum Paths {
    /// HOME first, so that a test can run the app against a separate home folder.
    static let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    /// The Zeus workspace. ZEUS_APP_WORKSPACE replaces it (for development and tests).
    static let zeusDir = ProcessInfo.processInfo.environment["ZEUS_APP_WORKSPACE"].flatMap { $0.isEmpty ? nil : $0 }
        ?? home + "/Code/zeus"
    /// ZEUS_APP_ZEUS_COMMAND replaces the zeus command (for tests).
    static let zeusCommand = ProcessInfo.processInfo.environment["ZEUS_APP_ZEUS_COMMAND"] ?? home + "/.local/bin/zeus"
    static let logDir = home + "/Library/Logs/zeus-install"

    static var editorStateDir: String {
        ProcessInfo.processInfo.environment["ZEUS_EDITOR_STATE_DIR"] ?? home + "/.zeus-editor"
    }

    static var launchesDir: String { editorStateDir + "/chat/launches" }

    static var appSupport: String {
        let dir = home + "/Library/Application Support/Zeus"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The installer inside the app. ZEUS_APP_INSTALLER replaces it (for tests).
    static var installer: String? {
        if let path = ProcessInfo.processInfo.environment["ZEUS_APP_INSTALLER"] { return path }
        return Bundle.main.path(forResource: "install", ofType: "sh")
    }
}

/// The environment for the commands that the app starts. An app that opens from the Dock gets only
/// the system PATH, so the app reads the PATH of the user's login shell once, as Terminal would.
enum ShellEnvironment {
    private static var cachedPath: String?

    static func loginPath() -> String {
        if let cachedPath { return cachedPath }
        let fallback = [
            Paths.home + "/.local/node/bin", Paths.home + "/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        var path = readLoginPath() ?? fallback
        // Tools that the installer puts in the home folder, also before the shell profile has them.
        for extra in [Paths.home + "/.local/bin", Paths.home + "/.local/node/bin"] where !path.split(separator: ":").contains(Substring(extra)) {
            path = extra + ":" + path
        }
        if FileManager.default.isExecutableFile(atPath: Paths.home + "/anaconda3/bin/conda"),
           !path.contains("/anaconda3/bin") {
            path += ":" + Paths.home + "/anaconda3/bin"
        }
        cachedPath = path
        return path
    }

    /// Forgets the PATH, so that the next command sees tools that the installer just added.
    static func reset() { cachedPath = nil }

    /// The user's login shell, when it is zsh or bash; else zsh.
    static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
    }

    private static func readLoginPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-ilc", "printf '__ZEUS_PATH__%s__ZEUS_PATH__' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline { usleep(50000) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let start = text.range(of: "__ZEUS_PATH__"),
              let end = text.range(of: "__ZEUS_PATH__", range: start.upperBound ..< text.endIndex)
        else { return nil }
        let path = String(text[start.upperBound ..< end.lowerBound])
        return path.isEmpty ? nil : path
    }

    static func make(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Variables of a Claude Code session, if the app was started from one.
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDECODE" { env.removeValue(forKey: key) }
        env["PATH"] = loginPath()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["ZEUS_APP"] = "1"
        // Blind build mode is the app's setting only: an inherited value never reaches a session.
        env.removeValue(forKey: BlindMode.variable)
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// The environment of a Zeus session on a host: `make()`, the host label, and blind build mode when it is on.
    /// `base` is the EU environment for an EU session (EUHost.environment).
    static func session(host: ClaudeHost, base: [String: String]? = nil) -> [String: String] {
        var env = base ?? make()
        env.removeValue(forKey: BlindMode.variable)
        env["ZEUS_CLAUDE_HOST"] = host.rawValue
        if Preferences.blindMode { env[BlindMode.variable] = "1" }
        return env
    }
}

/// Blind build mode (Developer Settings): sessions outside the EU see no row values of client data.
/// Zeus enforces it; the app only passes the setting to each session that it starts.
enum BlindMode {
    static let variable = "ZEUS_BLIND_MODE"
}
