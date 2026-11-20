import Foundation
import WebKit

/// The mode of one chat tab: Standard (Claude on Anthropic's API, the Team plan) or EU (Claude on Google Vertex AI in the
/// EU). Each tab runs in its own mode, and Standard and EU tabs run side by side in the same workspace. A tab switches
/// its mode in a new chat (`ChatTab.switchSession`): its session of the old mode ends, so a chat never moves between the
/// modes (zeus-editor docs/chat.md "EU mode", zeus references/eu-mode.md).
enum ZeusMode: String, Codable, CaseIterable {
    case standard
    case eu

    var title: String { self == .eu ? "EU" : "Standard" }

    /// The mode of the tab that the user used last, kept across app starts: the app start opens its first tab in it,
    /// and a new tab without a tab in front gets it.
    static var lastUsed: ZeusMode {
        get { Preferences.zeusMode.flatMap(ZeusMode.init(rawValue:)) ?? .standard }
        set {
            guard newValue != lastUsed else { return }
            Preferences.zeusMode = newValue.rawValue
        }
    }
}

/// The EU values that the app needs, from the EU launch profile that ships with Zeus Editor (`eu-profile.json`, next to
/// the newest installed `dist/zeus.mjs`, which the zeus command starts). `zeus --eu` reads the same file, so the app
/// and the command use the same folders. Without a valid profile (a Zeus Editor from before EU mode) the app uses the
/// defaults of the profile; `found` is then false and EU mode needs the Zeus setup.
///
/// EU and Standard use one workspace, `~/Code/zeus` (`Paths.zeusDir`). Schema 2 of the profile has no `workspace`;
/// the `workspace` of a schema 1 profile (`~/Code/zeus-eu`, from before the shared workspace) is not used.
///
/// `isolation` (default false) is the one switch that Zeus Editor, zeus, and the app share. Off (simple EU): an EU tab is a
/// Standard tab in every way (the same Claude Code folder, plugins, settings, and workspace) and only its model account
/// differs (Google Vertex AI in the EU); the app makes, opens, and mounts no EU vault, and runs Standard without the read
/// block. On: EU runs apart from Standard, with the EU vault (`EUVault`), the read block of Standard (`StandardJail`), the
/// handover, and EU data access.
struct EUProfile: Equatable {
    var vertexProject: String
    var configDir: String
    var editorStateDir: String
    /// The EU temporary folder (`tmp_dir`, with `{uid}` replaced by the user ID), as the profile writes it.
    var tmpDir: String
    /// The path of the profile, or nil when the app uses the defaults.
    var file: String?
    /// EU runs apart from Standard, with the EU vault. False (simple EU) when the profile does not say true.
    var isolation = false

    var found: Bool { file != nil }

    static let defaultTmpDir = "/tmp/zeus-eu-\(getuid())"

    static let defaults = EUProfile(vertexProject: "project-4bf0bacd-fec4-406b-a99",
                                    configDir: Paths.home + "/.zeus/eu/claude",
                                    editorStateDir: Paths.home + "/.zeus/eu/editor",
                                    tmpDir: defaultTmpDir, file: nil)

    /// The profile of the newest installed Zeus Editor, read again on each call (an update can change it).
    static func load() -> EUProfile {
        guard let file = newestProfileFile(),
              let data = FileManager.default.contents(atPath: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schema = object["schema"] as? Int, schema == 1 || schema == 2,
              let project = object["vertex_project"] as? String, project.range(of: #"^[a-z][a-z0-9-]{4,61}[a-z0-9]$"#, options: .regularExpression) != nil,
              let config = expand(object["config_dir"]), let state = expand(object["editor_state_dir"])
        else { return defaults }
        var tmp = defaults.tmpDir
        if let raw = object["tmp_dir"] {
            guard let text = raw as? String, let value = expand(text.replacingOccurrences(of: "{uid}", with: String(getuid()))) else { return defaults }
            tmp = value
        }
        return EUProfile(vertexProject: project, configDir: config, editorStateDir: state, tmpDir: tmp, file: file,
                         isolation: object["isolation"] as? Bool ?? false)
    }

    /// The installed Zeus Editor runs EU apart from Standard (`isolation`), with the EU vault.
    static var isolated: Bool { load().isolation }

    /// EU sessions can start now: always in simple EU, and with isolation only while the EU vault is open.
    static var sessionsCanStart: Bool { !isolated || EUVault.isOpen }

    /// `~/` is the home folder; any other value must be an absolute path.
    private static func expand(_ value: Any?) -> String? {
        guard let text = value as? String, !text.contains("\0") else { return nil }
        if text.hasPrefix("~/") { return (Paths.home as NSString).appendingPathComponent(String(text.dropFirst(2))) }
        return text.hasPrefix("/") ? (text as NSString).standardizingPath : nil
    }

    /// The profile of the newest installed Zeus Editor plugin, or nil.
    private static func newestProfileFile() -> String? {
        guard let root = newestEditorRoot() else { return nil }
        let profile = root + "/eu-profile.json"
        return FileManager.default.fileExists(atPath: profile) ? profile : nil
    }

    /// The folder of the newest installed Zeus Editor plugin, the same choice as the zeus command of the installer
    /// (`write_zeus_shim` in install.sh): the newest `~/.claude/plugins/cache/*/zeus-editor/*/dist/zeus.mjs`.
    static func newestEditorRoot() -> String? {
        let cache = Paths.home + "/.claude/plugins/cache"
        let manager = FileManager.default
        var newest: (date: Date, root: String)?
        for marketplace in (try? manager.contentsOfDirectory(atPath: cache)) ?? [] {
            let plugin = "\(cache)/\(marketplace)/zeus-editor"
            for version in (try? manager.contentsOfDirectory(atPath: plugin)) ?? [] {
                let root = "\(plugin)/\(version)"
                guard let date = (try? manager.attributesOfItem(atPath: root + "/dist/zeus.mjs"))?[.modificationDate] as? Date
                else { continue }
                if newest == nil || date > newest!.date { newest = (date, root) }
            }
        }
        return newest?.root
    }
}

/// What a Mac needs for EU mode. The Zeus setup installs it (install.sh, the EU steps), the same on every Mac.
/// The Google sign-in is not part of it: the setup offers it (a user can skip it), and the EU start checks it and gives
/// the sign-in button (`EUStartFailure`).
/// The EU Claude Code folder is in the EU vault, so its part (the Zeus plugins of EU mode) can be checked and installed
/// only while the vault is open: `missingInVault`.
enum EUSetup {
    /// The parts outside the vault that are missing, in words; empty when the EU vault can open and EU mode can start.
    static func missing(profile: EUProfile = .load()) -> [String] {
        var parts: [String] = []
        if !profile.found { parts.append("a Zeus Editor with EU mode") }
        if GoogleCloud.gcloud() == nil { parts.append("the Google Cloud CLI") }
        return parts
    }

    /// The parts in the open EU vault that are missing, in words: the Zeus plugins in the EU Claude Code folder.
    static func missingInVault(profile: EUProfile = .load()) -> [String] {
        editorPluginInstalled(configDir: profile.configDir) ? [] : ["the Zeus plugins of EU mode"]
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

/// With isolation, EU Claude Code shows the status line of Standard Claude Code (simple EU uses the Claude Code folder of
/// Standard, with its status line). The installer copies it (install.sh
/// `eu_mirror_status_line`), and the app runs that step again before each EU session, so that a change in Standard
/// reaches EU. A failure only leaves the EU status line as it was.
enum EUStatusLine {
    static func sync() {
        guard let installer = Paths.installer else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installer, "--eu-status-line"]
        process.environment = ShellEnvironment.make()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            Trace.log("eu status line: exit \(process.terminationStatus)")
        } catch {
            Trace.log("eu status line: \(error.localizedDescription)")
        }
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
    /// `account`: the Google account, when it is known (the EU sign-in names it after a refused quota project step).
    static func message(status: Int, model: String, account: String? = nil) -> String {
        switch status {
        case 401: return "Your Google sign-in expired."
        case 403:
            return "Your Google account \(account.map { $0 + " " } ?? "")has no access to the EU project of Zeus. Ask the Zeus maintainer for the Vertex AI User and Service Usage Consumer roles."
        case 404: return "The EU model \(model) is not available. Tell the Zeus maintainer."
        case 429: return "The EU project has no capacity for \(model) now. Try again later or tell the Zeus maintainer."
        default: return "Google Cloud refused the EU model \(model) (HTTP \(status)). Try again later or tell the Zeus maintainer."
        }
    }
}

/// The EU session cost that an EU chat page sends after each reply (zeus-editor src/eu/cost.js, the bridge message
/// `cost:<JSON>`). It is an estimate in USD from the transcripts and the Vertex EU prices; USD stays the source of truth.
/// The title bar shows it in euros at the daily ECB rate (`EuroRate`), or in USD with a note when there is no rate today.
/// Standard sends none.
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
        let chat = (object["chat_total"] as? NSNumber)?.doubleValue ?? 0
        chatTotal = chat.isFinite && chat >= 0 ? chat : 0
        calls = (object["calls"] as? NSNumber)?.intValue ?? 0
        unpricedCalls = (object["unpriced_calls"] as? NSNumber)?.intValue ?? 0
        pricesAsOf = object["prices_as_of"] as? String ?? ""
    }

    static func amount(_ value: Double, _ currency: String) -> String {
        value > 0 && value < 0.01 ? "< 0.01 \(currency)" : String(format: "%.2f \(currency)", value)
    }

    static func usd(_ value: Double) -> String { amount(value, "USD") }

    /// The amount in euros at the rate, or in USD without a rate.
    static func shown(_ usd: Double, rate: EuroRate.Rate?) -> String {
        guard let rate else { return amount(usd, "USD") }
        return amount(usd / rate.usdPerEUR, "EUR")
    }

    func label(rate: EuroRate.Rate?) -> String {
        "EU session cost (estimate): \(Self.shown(sessionTotal, rate: rate))" + (rate == nil ? " (no euro rate)" : "")
    }

    func detail(rate: EuroRate.Rate?) -> String {
        var text = "This chat: \(Self.shown(chatTotal, rate: rate)). \(calls) model call\(calls == 1 ? "" : "s")"
        if unpricedCalls > 0 { text += ", \(unpricedCalls) not priced (not in the total)" }
        text += "."
        if let rate {
            text += " The estimate is \(Self.usd(sessionTotal)) (this chat: \(Self.usd(chatTotal))), in euros at the ECB rate of \(rate.date): "
                + String(format: "1 EUR = %.4f USD.", rate.usdPerEUR)
        } else {
            text += " The ECB euro rate of today could not be loaded, so the estimate shows in USD."
        }
        if !pricesAsOf.isEmpty { text += " Vertex EU prices of \(pricesAsOf)." }
        return text
    }
}

/// The daily euro reference rate of the European Central Bank (USD per EUR), for the EU cost label. The app loads it
/// for EU tabs only, once a day, and keeps it for that day in `~/Library/Application Support/Zeus/euro-rate.json`
/// (no user data). Without a rate of today, the label shows USD with a note.
final class EuroRate {
    struct Rate: Codable, Equatable {
        let usdPerEUR: Double
        /// The ECB date of the rate.
        let date: String
        /// The local day on which the app loaded it.
        let loadedOn: String
    }

    static let shared = EuroRate()
    static let changed = Notification.Name("ZeusEuroRateChanged")
    private static let address = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
    /// A failed load is tried again after this time, at the next cost.
    private static let retryAfter: TimeInterval = 10 * 60

    private var rate: Rate?
    private var loading = false
    private var failedAt: Date?

    private var file: String { Paths.appSupport + "/euro-rate.json" }

    static func today(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The rate of today, or nil.
    var current: Rate? {
        if let rate, rate.loadedOn == Self.today() { return rate }
        if let data = FileManager.default.contents(atPath: file), let saved = try? JSONDecoder().decode(Rate.self, from: data),
           saved.loadedOn == Self.today(), Self.plausible(saved.usdPerEUR) {
            rate = saved
            return saved
        }
        return nil
    }

    /// Loads the rate of today when the app has none (main queue). EU tabs only: the caller is an EU cost.
    func load() {
        guard current == nil, !loading else { return }
        if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfter { return }
        var address = Self.address
        if let override = DebugEnvironment.value("ZEUS_APP_EURO_RATE_URL"), !override.isEmpty { address = override }
        guard let url = URL(string: address) else { return }
        loading = true
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Zeus app", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? (url.isFileURL && data != nil)
            let parsed = ok ? data.flatMap { Self.parse(String(decoding: $0, as: UTF8.self)) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                guard let parsed else {
                    self.failedAt = Date()
                    Trace.log("euro rate: not loaded")
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                    return
                }
                let rate = Rate(usdPerEUR: parsed.usdPerEUR, date: parsed.date, loadedOn: Self.today())
                self.rate = rate
                self.failedAt = nil
                if let data = try? JSONEncoder().encode(rate) { try? data.write(to: URL(fileURLWithPath: self.file), options: .atomic) }
                Trace.log("euro rate: \(rate.usdPerEUR) of \(rate.date)")
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }.resume()
    }

    /// The USD rate and the date of the ECB daily file (`<Cube time='…'>` and `<Cube currency='USD' rate='…'/>`).
    static func parse(_ xml: String) -> (usdPerEUR: Double, date: String)? {
        guard let rateMatch = xml.range(of: #"currency=['"]USD['"]\s+rate=['"]([0-9]+\.[0-9]+)['"]"#, options: .regularExpression),
              let dateMatch = xml.range(of: #"time=['"]([0-9]{4}-[0-9]{2}-[0-9]{2})['"]"#, options: .regularExpression)
        else { return nil }
        let rateText = String(xml[rateMatch]).components(separatedBy: CharacterSet(charactersIn: "'\"")).dropLast().last ?? ""
        let dateText = String(xml[dateMatch]).components(separatedBy: CharacterSet(charactersIn: "'\"")).dropLast().last ?? ""
        guard let value = Double(rateText), plausible(value), dateText.count == 10 else { return nil }
        return (value, dateText)
    }

    /// A USD rate that can be true: no file of another kind or a broken number changes the cost by a large factor.
    static func plausible(_ value: Double) -> Bool { value.isFinite && value > 0.5 && value < 2.5 }

    #if DEBUG
    /// Test action: forget the rate, so that the next cost loads it again.
    func reset() {
        rate = nil
        failedAt = nil
        try? FileManager.default.removeItem(atPath: file)
    }
    #endif
}

/// EU data access of an EU project (zeus references/eu-mode.md, "EU data access"): whether Zeus may read client data rows
/// of the project in EU mode. Only the user turns it on or off, with the switch in the title bar. The app runs
/// `eu-access <project> [on|off] --json` with the Zeus of the shared workspace, outside Claude, as it runs the handover commands;
/// Zeus refuses the change from any Claude session.
final class EUDataAccess {
    struct State: Equatable {
        let enabled: Bool
        let by: String?
        let at: String?
    }

    static let shared = EUDataAccess()
    static let changed = Notification.Name("ZeusEUDataAccessChanged")

    /// The known state of each project; a project that is loading has none.
    private(set) var state: [String: State] = [:]
    private var loading: Set<String> = []
    private let queue = DispatchQueue(label: "zeus.eu-access")

    private func cli() -> HandoffCLI { HandoffCLI(profile: EUProfile.load()) }

    /// Reads the state of a project (main queue).
    func load(_ project: String) {
        guard Handover.validProject(project), !loading.contains(project) else { return }
        loading.insert(project)
        queue.async { [weak self] in
            guard let self else { return }
            var result: State?
            var failure: String?
            do { result = try self.parse(self.cli().run(["eu-access", project]).json, project: project) } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                Trace.log("eu access: \(project) read \(result.map { $0.enabled ? "on" : "off" } ?? "failed: \(failure ?? "-")")")
                self.loading.remove(project)
                if let result { self.state[project] = result } else { self.state.removeValue(forKey: project) }
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }

    /// Turns EU data access on or off (main queue). The completion gets the error words, or nil.
    func set(_ project: String, on: Bool, completion: @escaping (String?) -> Void) {
        guard Handover.validProject(project) else { completion("The project name is not valid."); return }
        state.removeValue(forKey: project)
        loading.insert(project)
        NotificationCenter.default.post(name: Self.changed, object: nil)
        queue.async { [weak self] in
            guard let self else { return }
            var error: String?
            var result: State?
            do {
                result = try self.parse(self.cli().run(["eu-access", project, on ? "on" : "off"]).json, project: project)
                if result?.enabled != on { error = "Zeus did not change EU data access of \(project)." }
            } catch let failure {
                error = failure.localizedDescription
            }
            if result == nil { result = try? self.parse(self.cli().run(["eu-access", project]).json, project: project) }
            DispatchQueue.main.async {
                self.loading.remove(project)
                if let result { self.state[project] = result }
                NotificationCenter.default.post(name: Self.changed, object: nil)
                completion(error)
            }
        }
    }

    private func parse(_ json: [String: Any], project: String) throws -> State {
        guard json["project"] as? String == project, let enabled = json["enabled"] as? Bool else {
            throw HandoffCLI.Failure(message: "Zeus eu-access gave an answer for another project.")
        }
        return State(enabled: enabled, by: json["by"] as? String, at: json["at"] as? String)
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
    /// The output of the sign-in, so that the app can tell why it failed (`QuotaProjectDenial`).
    let log = TerminalLog()
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var terminalPID: pid_t { process.pid }

    init(gcloud: String, project: String) throws {
        var env = ShellEnvironment.make()
        env.removeValue(forKey: "GOOGLE_APPLICATION_CREDENTIALS")
        env.removeValue(forKey: "CLOUDSDK_CORE_DISABLE_PROMPTS")
        process = try PTYProcess(executable: "/bin/sh", arguments: GoogleCloud.signInArguments(gcloud: gcloud, project: project),
                                 environment: env, directory: Paths.home)
        process.onOutput = { [weak self] data in
            self?.log.append(data)
            self?.onOutput?(data)
        }
        process.onExit = { [weak self] code in self?.onExit?(code) }
    }

    /// The note of the tab after a failed sign-in: the access words when gcloud refused the EU project for a missing
    /// permission, or else the exit code and where to see the gcloud output.
    static func failureNote(code: Int32, output: String) -> String {
        if let denial = QuotaProjectDenial(output: output) {
            return VertexError.message(status: 403, model: "", account: denial.account)
        }
        return "The Google sign-in did not complete (exit code \(code)). See the terminal below (Cmd+J)."
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
    /// The fix is the Zeus setup (gcloud, the EU plugins, or an old Zeus Editor).
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
