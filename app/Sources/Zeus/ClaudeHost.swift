import Foundation

/// Where the Claude Code of a session sends its requests. Claude Code cannot change this while it
/// runs, so a session has one host from its start to its end.
enum ClaudeHost: String {
    /// The Claude Code subscription login, as before the host switch existed.
    case apolix
    /// Claude on Google Cloud Vertex AI in the EU, with the variables of the `claude-eu` shell alias.
    case eu

    var title: String { self == .eu ? "EU" : "Apolix" }

    /// One line for confirmation texts and tooltips.
    var summary: String {
        self == .eu ? "Claude in the EU (Google Cloud Vertex AI)" : "the Apolix Claude subscription"
    }

    /// The host of a new tab: the last one picked while the host switch shows, else Apolix.
    static var forNewTab: ClaudeHost {
        Preferences.developerHostSwitch ? Preferences.lastHost : .apolix
    }
}

/// A start on the EU host that must not happen. The app shows the message on the loading screen;
/// it never starts the session on Apolix instead.
struct HostError: LocalizedError {
    let message: String
    /// Command output for the log below the message, without secrets.
    var detail = ""
    var errorDescription: String? { message }
}

/// The environment of an EU session, and the check that must pass before one starts.
enum EUHost {
    /// The name of the shell alias whose variables the EU host uses.
    static let aliasName = "claude-eu"

    /// Variables that select another provider, endpoint, or region. An EU session starts without the
    /// inherited ones, so that no key, proxy, or region override sends a request outside the EU.
    static func isProviderVariable(_ key: String) -> Bool {
        let exact: Set<String> = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
            "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION",
            "ANTHROPIC_VERTEX_PROJECT_ID", "ANTHROPIC_VERTEX_BASE_URL", "CLOUD_ML_REGION",
            "AWS_BEARER_TOKEN_BEDROCK", "ZEUS_CLAUDE_HOST", BlindMode.variable,
        ]
        if exact.contains(key) { return true }
        return ["ANTHROPIC_BEDROCK_", "ANTHROPIC_FOUNDRY_", "ANTHROPIC_DEFAULT_", "VERTEX_REGION_", "CLAUDE_CODE_"]
            .contains { key.hasPrefix($0) }
    }

    /// Variables that the alias may never set: an EU session uses Google Cloud credentials only.
    private static let forbidden: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
        "ANTHROPIC_CUSTOM_HEADERS", "AWS_BEARER_TOKEN_BEDROCK", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    static func isEURegion(_ region: String) -> Bool {
        let value = region.lowercased()
        return value == "eu" || value.hasPrefix("europe-")
    }

    /// The leading `NAME=value` words of an alias definition, as the shell prints it:
    /// `claude-eu='A=1 B=two claude'` (zsh) or `alias claude-eu='A=1 B=two claude'` (bash).
    static func assignments(inAlias definition: String) -> [String: String] {
        var text = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("alias ") { text.removeFirst(6) }
        guard let equals = text.firstIndex(of: "=") else { return [:] }
        return assignments(in: words(String(text[text.index(after: equals)...])).joined(separator: " "))
    }

    /// The leading `NAME=value` words of a command line; the first other word ends them.
    static func assignments(in commandLine: String) -> [String: String] {
        var result: [String: String] = [:]
        for word in words(commandLine) {
            guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { break }
            let name = String(word[..<equals])
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { break }
            result[name] = String(word[word.index(after: equals)...])
        }
        return result
    }

    /// Shell words: split at spaces outside quotes; quotes are removed and `\` keeps the next character.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character == " " || character == "\t" || character == "\n" {
                if started { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { words.append(current) }
        return words
    }

    /// The variables of an EU session from the alias variables, or the reason why they are not safe.
    static func variables(from alias: [String: String]) -> Result<[String: String], HostError> {
        var result = alias.filter { !forbidden.contains($0.key) }
        let vertex = (result["CLAUDE_CODE_USE_VERTEX"] ?? "").lowercased()
        guard ["1", "true", "yes"].contains(vertex) else {
            return .failure(HostError(message: "The \(aliasName) alias does not set CLAUDE_CODE_USE_VERTEX=1, so it is not a Vertex AI setup."))
        }
        let region = result["CLOUD_ML_REGION"] ?? ""
        guard isEURegion(region) else {
            return .failure(HostError(message: "The \(aliasName) alias sets CLOUD_ML_REGION to \"\(region)\". The EU host needs eu or a europe- region."))
        }
        if let other = result.first(where: { $0.key.hasPrefix("VERTEX_REGION_") && !isEURegion($0.value) }) {
            return .failure(HostError(message: "The \(aliasName) alias sends one model outside the EU: \(other.key)=\(other.value)."))
        }
        guard !(result["ANTHROPIC_VERTEX_PROJECT_ID"] ?? "").isEmpty else {
            return .failure(HostError(message: "The \(aliasName) alias does not set ANTHROPIC_VERTEX_PROJECT_ID."))
        }
        result.removeValue(forKey: "ZEUS_CLAUDE_HOST")
        result.removeValue(forKey: BlindMode.variable)
        // No update checks, telemetry, or error reports to servers outside the EU.
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return .success(result)
    }

    /// Reads the alias from the user's login shell. ZEUS_APP_EU_ENV ("A=1 B=2") replaces the alias (for tests).
    static func loadVariables() -> Result<[String: String], HostError> {
        if let override = ProcessInfo.processInfo.environment["ZEUS_APP_EU_ENV"], !override.isEmpty {
            return variables(from: assignments(in: override))
        }
        let marker = "__ZEUS_ALIAS__"
        let script = "printf '\(marker)'; alias \(aliasName) 2>/dev/null; printf '\(marker)'"
        guard let output = Shell.run(ShellEnvironment.loginShell, ["-ilc", script], timeout: 10)?.output,
              let start = output.range(of: marker),
              let end = output.range(of: marker, range: start.upperBound ..< output.endIndex)
        else {
            return .failure(HostError(message: "Zeus could not read your shell profile to find the \(aliasName) alias."))
        }
        let definition = String(output[start.upperBound ..< end.lowerBound])
        let found = assignments(inAlias: definition)
        guard !found.isEmpty else {
            return .failure(HostError(message: "Your shell profile has no \(aliasName) alias. The EU host uses the variables of that alias."))
        }
        return variables(from: found)
    }

    /// The whole environment of an EU session: the app's usual one without provider variables, plus `variables`,
    /// the host label, and blind build mode when it is on.
    static func environment(variables: [String: String]) -> [String: String] {
        var env = ShellEnvironment.make()
        for key in env.keys where isProviderVariable(key) { env.removeValue(forKey: key) }
        for (key, value) in variables { env[key] = value }
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return ShellEnvironment.session(host: .eu, base: env)
    }

    /// The check before an EU start: the alias is an EU Vertex setup, and Google Cloud gives an access
    /// token for it. Runs off the main queue; `completion` is called on the main queue with the variables.
    static func preflight(completion: @escaping (Result<[String: String], HostError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = loadVariables().flatMap { variables in checkCredentials().map { variables } }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// `gcloud auth application-default print-access-token` must succeed. The token itself is never kept.
    /// ZEUS_APP_GCLOUD replaces the gcloud command (for tests).
    static func checkCredentials() -> Result<Void, HostError> {
        let gcloud = ProcessInfo.processInfo.environment["ZEUS_APP_GCLOUD"] ?? "gcloud"
        let login = "Run `gcloud auth application-default login` in Terminal, then try again."
        guard let run = Shell.run("/usr/bin/env", [gcloud, "auth", "application-default", "print-access-token"],
                                  environment: ShellEnvironment.make(), timeout: 30, keepOutput: false)
        else {
            return .failure(HostError(message: "Google Cloud did not answer in time, so Zeus cannot check your sign-in for the EU host. Check your network, then try again."))
        }
        if run.status == 127 {
            return .failure(HostError(message: "The gcloud command is not installed, so Zeus cannot sign in to Google Cloud for the EU host. Install the Google Cloud CLI. " + login,
                                      detail: run.errors))
        }
        guard run.status == 0, run.hadOutput else {
            return .failure(HostError(message: "You are not signed in to Google Cloud for the EU host. " + login, detail: run.errors))
        }
        return .success(())
    }
}

/// Runs a short command and waits for it, with a time limit.
enum Shell {
    struct Run {
        let status: Int32
        let output: String
        let errors: String
        /// Whether the command wrote to its output; true also when `keepOutput` is off.
        let hadOutput: Bool
    }

    /// Nil when the command did not start or did not end within `timeout` seconds. With `keepOutput` off,
    /// the output is counted and dropped, for a command that prints a secret.
    /// `onErrorLine` gets each line of the error output as it comes (for progress lines), on a background queue.
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil, directory: String? = nil,
                    timeout: TimeInterval, keepOutput: Bool = true, onErrorLine: ((String) -> Void)? = nil) -> Run? {
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
        var outputBytes = 0
        var errorData = Data()
        let lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            outputBytes += data.count
            if keepOutput { outputData.append(data) }
            lock.unlock()
        }
        var partial = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            if errorData.count < 16000 { errorData.append(data) }
            var lines: [String] = []
            if onErrorLine != nil {
                partial.append(data)
                while let newline = partial.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: partial[partial.startIndex ..< newline], as: UTF8.self))
                    partial.removeSubrange(partial.startIndex ... newline)
                }
            }
            lock.unlock()
            lines.forEach { onErrorLine?($0) }
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
        usleep(50000) // The last output arrives a moment after the exit.
        lock.lock()
        defer { lock.unlock() }
        return Run(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                   errors: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                   hadOutput: outputBytes > 0)
    }
}
