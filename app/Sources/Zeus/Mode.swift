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

/// The cost of a session, as Zeus Editor counts it after each reply (zeus-editor docs/chat.md, "Session cost") and the chat page
/// passes it on as the bridge message `cost:<JSON>`: EU at Vertex EU prices, Standard at the Anthropic API list prices.
struct SessionCost: Equatable {
    let mode: String
    let sessionTotal: Double
    let chatTotal: Double
    let calls: Int
    let unpricedCalls: Int
    let pricesAsOf: String

    init?(json: String) {
        guard let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let session = (object["session_total"] as? NSNumber)?.doubleValue, let chat = (object["chat_total"] as? NSNumber)?.doubleValue
        else { return nil }
        mode = object["mode"] as? String ?? "eu"
        sessionTotal = session
        chatTotal = chat
        calls = object["calls"] as? Int ?? 0
        unpricedCalls = object["unpriced_calls"] as? Int ?? 0
        pricesAsOf = object["prices_as_of"] as? String ?? ""
    }

    /// "€0.39", or "$0.42" while no euro rate is known; below a cent, "< €0.01".
    static func amount(_ usd: Double) -> String {
        if let rate = EuroRate.current {
            let euro = usd / rate.usdPerEuro
            return euro > 0 && euro < 0.01 ? "< €0.01" : String(format: "€%.2f", euro)
        }
        return usd > 0 && usd < 0.01 ? "< $0.01" : String(format: "$%.2f", usd)
    }

    /// "Session €0.39 · Chat total €0.29"; a "+" says that some calls have no price.
    var label: String {
        "Session \(Self.amount(sessionTotal))\(unpricedCalls > 0 ? "+" : "") · Chat total \(Self.amount(chatTotal))"
    }

    var tooltip: String {
        let prices = mode == "eu" ? "Vertex AI EU list prices" : "Anthropic API list prices (not a charge on the Claude subscription)"
        var lines = ["Session: every chat of this tab's Zeus session, \(Self.amount(sessionTotal)).",
                     "Chat total: the chat on screen, \(Self.amount(chatTotal)).",
                     "\(calls) model call\(calls == 1 ? "" : "s")\(unpricedCalls > 0 ? ", \(unpricedCalls) without a price (fast mode or an unknown model) and not in the amount" : "")."]
        var source = "An estimate at \(prices) of \(pricesAsOf), in US dollars"
        if let rate = EuroRate.current {
            source += String(format: ", converted at $%.4f for €1 (European Central Bank, %@)", rate.usdPerEuro, rate.date)
        }
        lines.append(source + ".")
        return lines.joined(separator: "\n")
    }
}

/// The cost labels and the switch follow the developer settings and the tabs' cost reports at once in every window.
enum CostDisplay {
    static let changed = Notification.Name("io.github.theo-henry.zeus.cost-changed")
    static func refresh() { NotificationCenter.default.post(name: changed, object: nil) }
}
