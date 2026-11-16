import Foundation
import WebKit

/// The mode of the whole app: Standard (Claude on Anthropic's API, the Team plan) or EU (Claude on Google Vertex AI in the
/// EU). All tabs run in one mode. A switch ends every session of the old mode before the new mode starts, so that the
/// modes never share a running session (zeus-editor docs/chat.md "EU mode", zeus references/eu-mode.md).
enum ZeusMode: String, Codable, CaseIterable {
    case standard
    case eu

    var title: String { self == .eu ? "EU" : "Standard" }

    /// The current mode of the app, kept across app starts.
    static var current: ZeusMode {
        get { Preferences.zeusMode.flatMap(ZeusMode.init(rawValue:)) ?? .standard }
        set { Preferences.zeusMode = newValue.rawValue }
    }
}

/// The EU values that the app needs, from the EU launch profile that ships with Zeus Editor (`eu-profile.json`, next to
/// the newest installed `dist/zeus.mjs`, which the zeus command starts). `zeus --eu` reads the same file, so the app
/// and the command use the same folders. Without a valid profile (a Zeus Editor from before EU mode) the app uses the
/// defaults of the profile; `found` is then false and EU mode needs the Zeus setup.
struct EUProfile: Equatable {
    var vertexProject: String
    var configDir: String
    var editorStateDir: String
    var workspace: String
    /// The path of the profile, or nil when the app uses the defaults.
    var file: String?

    var found: Bool { file != nil }

    static let defaults = EUProfile(vertexProject: "project-4bf0bacd-fec4-406b-a99",
                                    configDir: Paths.home + "/.zeus/eu/claude",
                                    editorStateDir: Paths.home + "/.zeus/eu/editor",
                                    workspace: Paths.home + "/Code/zeus-eu", file: nil)

    /// The profile of the newest installed Zeus Editor, read again on each call (an update can change it).
    static func load() -> EUProfile {
        guard let file = newestProfileFile(),
              let data = FileManager.default.contents(atPath: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["schema"] as? Int == 1,
              let project = object["vertex_project"] as? String, project.range(of: #"^[a-z][a-z0-9-]{4,61}[a-z0-9]$"#, options: .regularExpression) != nil,
              let config = expand(object["config_dir"]), let state = expand(object["editor_state_dir"]),
              let workspace = expand(object["workspace"])
        else { return defaults }
        return EUProfile(vertexProject: project, configDir: config, editorStateDir: state, workspace: workspace, file: file)
    }

    /// `~/` is the home folder; any other value must be an absolute path.
    private static func expand(_ value: Any?) -> String? {
        guard let text = value as? String, !text.contains("\0") else { return nil }
        if text.hasPrefix("~/") { return (Paths.home as NSString).appendingPathComponent(String(text.dropFirst(2))) }
        return text.hasPrefix("/") ? (text as NSString).standardizingPath : nil
    }

    /// The same choice as the zeus command of the installer (`write_zeus_shim` in install.sh): the newest
    /// `~/.claude/plugins/cache/*/zeus-editor/*/dist/zeus.mjs`; the profile is in the folder of its plugin.
    private static func newestProfileFile() -> String? {
        let cache = Paths.home + "/.claude/plugins/cache"
        let manager = FileManager.default
        var newest: (date: Date, profile: String)?
        for marketplace in (try? manager.contentsOfDirectory(atPath: cache)) ?? [] {
            let plugin = "\(cache)/\(marketplace)/zeus-editor"
            for version in (try? manager.contentsOfDirectory(atPath: plugin)) ?? [] {
                let root = "\(plugin)/\(version)"
                guard let date = (try? manager.attributesOfItem(atPath: root + "/dist/zeus.mjs"))?[.modificationDate] as? Date
                else { continue }
                if newest == nil || date > newest!.date { newest = (date, root + "/eu-profile.json") }
            }
        }
        guard let profile = newest?.profile, manager.fileExists(atPath: profile) else { return nil }
        return profile
    }
}

/// What a Mac needs for EU mode. The Zeus setup installs it (install.sh, the EU steps), the same on every Mac.
/// The Google sign-in is not part of it: the EU start checks it and gives the sign-in button (`EUStartFailure`).
enum EUSetup {
    /// The parts that are missing, in words; empty when EU mode can start.
    static func missing(profile: EUProfile = .load()) -> [String] {
        var parts: [String] = []
        if !profile.found { parts.append("a Zeus Editor with EU mode") }
        if !FileManager.default.fileExists(atPath: profile.workspace + "/.git") { parts.append("the EU workspace (\(display(profile.workspace)))") }
        if !editorPluginInstalled(configDir: profile.configDir) { parts.append("the Zeus plugins of EU mode") }
        if GoogleCloud.gcloud() == nil { parts.append("the Google Cloud CLI") }
        return parts
    }

    /// The Zeus Editor plugin is installed in the EU Claude Code folder.
    static func editorPluginInstalled(configDir: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: configDir + "/plugins/installed_plugins.json"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = object["plugins"] as? [String: Any] else { return false }
        return plugins["zeus-editor@zeus-editor"] != nil
    }

    static func display(_ path: String) -> String {
        path.hasPrefix(Paths.home + "/") ? "~/" + path.dropFirst(Paths.home.count + 1) : path
    }
}

/// The Google Cloud CLI, which the EU sign-in uses. The same places as the EU preflight of Zeus Editor
/// (src/eu/preflight.js `gcloudCandidates`): the login PATH, then the usual install folders.
enum GoogleCloud {
    static func candidates() -> [String] {
        let fromPath = ShellEnvironment.loginPath().split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return (fromPath + [
            Paths.home + "/google-cloud-sdk/bin", "/opt/homebrew/bin", "/opt/homebrew/share/google-cloud-sdk/bin",
            "/usr/local/bin", "/usr/local/share/google-cloud-sdk/bin",
        ]).map { $0 + "/gcloud" }
    }

    static func gcloud() -> String? {
        candidates().first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.isExecutableFile(atPath: path)
                && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    /// The two commands of the one-time sign-in of EU mode (zeus references/eu-mode.md), as one shell line for a PTY:
    /// the application default credentials that Claude Code reads, then the EU project for their quota.
    static func signInArguments(gcloud: String, project: String) -> [String] {
        ["-c", "\"$1\" auth application-default login && \"$1\" auth application-default set-quota-project \"$2\"",
         "zeus-eu-sign-in", gcloud, project]
    }
}

/// The words for a Vertex error that the EU chat reports (the bridge message `eu-error:<JSON>`): the same words as the
/// EU preflight (zeus-editor src/eu/preflight.js `vertexErrorMessage`).
enum VertexError {
    static func message(status: Int, model: String) -> String {
        switch status {
        case 401: return "Your Google sign-in expired."
        case 403: return "Your Google account has no access to the Apolix EU project. Ask the Zeus maintainer for the Vertex AI User role."
        case 404: return "The EU model \(model) is not available. Tell the Zeus maintainer."
        case 429: return "The EU project has no capacity for \(model) now. Try again later or tell the Zeus maintainer."
        default: return "Google Cloud refused the EU model \(model) (HTTP \(status)). Try again later or tell the Zeus maintainer."
        }
    }
}

/// The EU session cost that an EU chat page sends after each reply (zeus-editor src/eu/cost.js, the bridge message
/// `cost:<JSON>`). It is an estimate in USD from the transcripts and the Vertex EU prices. Standard sends none.
struct EUCost: Equatable {
    var sessionTotal: Double
    var chatTotal: Double
    var calls: Int
    var unpricedCalls: Int
    var pricesAsOf: String

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["mode"] as? String == "eu", object["currency"] as? String == "USD",
              let session = (object["session_total"] as? NSNumber)?.doubleValue, session.isFinite, session >= 0
        else { return nil }
        sessionTotal = session
        chatTotal = (object["chat_total"] as? NSNumber)?.doubleValue ?? 0
        calls = (object["calls"] as? NSNumber)?.intValue ?? 0
        unpricedCalls = (object["unpriced_calls"] as? NSNumber)?.intValue ?? 0
        pricesAsOf = object["prices_as_of"] as? String ?? ""
    }

    static func usd(_ value: Double) -> String {
        value > 0 && value < 0.01 ? "< 0.01 USD" : String(format: "%.2f USD", value)
    }

    var label: String { "EU session cost (estimate): \(Self.usd(sessionTotal))" }

    var detail: String {
        var text = "This chat: \(Self.usd(chatTotal)). \(calls) model call\(calls == 1 ? "" : "s")"
        if unpricedCalls > 0 { text += ", \(unpricedCalls) not priced (not in the total)" }
        text += "."
        if !pricesAsOf.isEmpty { text += " Vertex EU prices of \(pricesAsOf)." }
        return text
    }
}

/// The web data (cookies, local storage) of each mode. The Zeus Editor servers of the two modes are on the same host
/// (127.0.0.1), and cookies do not depend on the port, so EU pages get a data store of their own.
enum ModeWebData {
    /// A fixed identifier, so that EU pages keep their data across app starts (macOS 14 and later).
    private static let euIdentifier = UUID(uuidString: "5A1E7E0D-3E55-4C6B-9E0A-0E0EC0DE0E05")!
    /// macOS 13: a data store that keeps nothing on disk, shared by the EU pages of this app run.
    private static var euMemoryStore: WKWebsiteDataStore?

    static func store(for mode: ZeusMode) -> WKWebsiteDataStore {
        switch mode {
        case .standard:
            return .default()
        case .eu:
            if #available(macOS 14.0, *) { return WKWebsiteDataStore(forIdentifier: euIdentifier) }
            if let euMemoryStore { return euMemoryStore }
            let store = WKWebsiteDataStore.nonPersistent()
            euMemoryStore = store
            return store
        }
    }
}

/// The one-time Google sign-in of EU mode, in a hidden terminal that the terminal panel of the tab shows:
/// `gcloud auth application-default login` (the browser opens), then the EU project as the quota project.
/// It runs with the user's own environment, as the EU preflight runs gcloud, without a credentials file from outside,
/// so that it writes the application default credentials file that EU Claude Code reads.
final class GoogleSignIn: TerminalSource {
    private let process: PTYProcess
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var terminalPID: pid_t { process.pid }

    init(gcloud: String, project: String) throws {
        var env = ShellEnvironment.make()
        env.removeValue(forKey: "GOOGLE_APPLICATION_CREDENTIALS")
        env.removeValue(forKey: "CLOUDSDK_CORE_DISABLE_PROMPTS")
        process = try PTYProcess(executable: "/bin/sh", arguments: GoogleCloud.signInArguments(gcloud: gcloud, project: project),
                                 environment: env, directory: Paths.home)
        process.onOutput = { [weak self] data in self?.onOutput?(data) }
        process.onExit = { [weak self] code in self?.onExit?(code) }
    }

    func write(_ text: String) { process.write(text) }
    func resize(rows: UInt16, cols: UInt16) { process.resize(rows: rows, cols: cols) }
    func stop() { process.terminate(grace: 2) }
}

/// Why `zeus --eu` stopped before its chat page opened, from its output. `zeus` prints one line `zeus: <message> <fix>`
/// (zeus-editor src/chat/cli.js): exit code 3 is a failed preflight step (no Google sign-in, an expired sign-in, no access,
/// a model that is not available, no capacity), and other codes are a missing EU setup or a bad EU profile.
struct EUStartFailure: Equatable {
    let message: String
    /// The fix needs the Google sign-in of EU mode (`gcloud auth application-default login`).
    let needsSignIn: Bool
    /// The fix is the Zeus setup (a missing EU workspace, gcloud, or an old Zeus Editor).
    let needsSetup: Bool

    init(log: TerminalLog, exitCode: Int32?) {
        let line = (log.lines + [log.currentLine]).last { $0.hasPrefix("zeus: ") }
        let text = line.map { String($0.dropFirst("zeus: ".count)) }
        message = text ?? "Zeus stopped (exit code \(exitCode.map(String.init) ?? "unknown")) before the EU chat page opened."
        needsSignIn = text?.contains("auth application-default login") ?? false
        let setup = text.map { $0.contains("installer") || $0.contains("Zeus setup") || $0.contains("unknown option --eu") } ?? false
        needsSetup = setup || (exitCode != 3 && text == nil)
    }
}
