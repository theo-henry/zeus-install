import AppKit
import CryptoKit
import Darwin
import Foundation

/// Updates the app from the Zeus app releases in the private zeus repo (tags "app-v<version>", made by
/// app/release.sh). It runs once at launch, before any Zeus session starts, and never during a session.
///
/// It uses the user's own GitHub CLI login, so the app holds no token and only an account with access
/// gets an update. Offline, without gh, without access, or with any error, the app starts its current
/// version and says nothing. An update is downloaded, checked (checksum, zip, bundle identifier, version,
/// signature), and swapped in place of the app in one rename. The old copy stays until the new copy has
/// started and confirmed it; when the new copy does not start, the old copy is put back and runs.
/// The user's state (settings, workspace, sessions) is outside the app bundle and does not change.
enum Updater {
    static let tagPrefix = "app-v"
    /// ZEUS_APP_REPO replaces the repo (for tests), as in install.sh.
    static var repo: String { ProcessInfo.processInfo.environment["ZEUS_APP_REPO"] ?? "theo-henry/zeus" }
    static let checkTimeout: TimeInterval = 5
    static let downloadTimeout: TimeInterval = 300
    /// The time that the new copy has to start and confirm the update.
    static let confirmTimeout: TimeInterval = 20

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// An update in progress, in a file that the old and the new copy of the app both read.
    struct Pending: Codable {
        var from: String
        var to: String
        var appPath: String
        /// The old copy of the app, kept until the new copy confirms.
        var backupPath: String
        /// The folder of the update files, removed at the end.
        var workPath: String
        /// The old copy, which waits for the confirmation.
        var waitingPID: Int32
        var confirmed = false
    }

    private static var pendingURL: URL { URL(fileURLWithPath: Paths.appSupport + "/update.json") }

    private static func readPending() -> Pending? {
        (try? Data(contentsOf: pendingURL)).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) }
    }

    private static func writePending(_ pending: Pending) throws {
        try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
    }

    private static func removePending() { try? FileManager.default.removeItem(at: pendingURL) }

    // MARK: The new copy

    /// Called first at launch. Returns true when this copy is the new version of an update: it confirms
    /// the update to the old copy, which then removes the old app and quits.
    @discardableResult
    static func confirmPendingUpdate() -> Bool {
        guard let pending = readPending() else { return false }
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let oldCopyRuns = kill(pending.waitingPID, 0) == 0
        if pending.to == currentVersion, pending.appPath == bundlePath {
            #if DEBUG
            if ProcessInfo.processInfo.environment["ZEUS_APP_TEST_NO_CONFIRM"] == "1" {
                Trace.log("update: not confirmed (test)")
                return true
            }
            #endif
            if oldCopyRuns {
                var confirmed = pending
                confirmed.confirmed = true
                try? writePending(confirmed)
                Trace.log("update: confirmed \(pending.from) -> \(pending.to)")
            } else {
                // The old copy stopped before it could finish the update. This copy finishes it.
                Trace.log("update: finished \(pending.from) -> \(pending.to) without the old copy")
                removeUpdateFiles(pending)
            }
            return true
        }
        if !oldCopyRuns {
            // A stopped update: the app is the old copy again, or the update files are left from an earlier launch.
            Trace.log("update: removed the files of a stopped update to \(pending.to)")
            if FileManager.default.fileExists(atPath: pending.appPath) { removeUpdateFiles(pending) }
        }
        return false
    }

    private static func removeUpdateFiles(_ pending: Pending) {
        try? FileManager.default.removeItem(atPath: pending.backupPath)
        try? FileManager.default.removeItem(atPath: pending.workPath)
        removePending()
    }

    // MARK: The old copy

    /// Checks for a newer app release and installs it. Calls `done(false)` on the main queue when the app
    /// continues with this version, or `done(true)` when a new copy runs and this copy quits.
    static func checkAtLaunch(done: @escaping (Bool) -> Void) {
        guard let reason = skipReason() else {
            UpdateWindow.shared.show()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = checkAndDownload()
                DispatchQueue.main.async {
                    switch result {
                    case .none(let why):
                        Trace.log("update: none (\(why))")
                        done(false)
                        UpdateWindow.shared.close()
                    case .ready(let update):
                        install(update, done: done)
                    }
                }
            }
            return
        }
        Trace.log("update: not checked (\(reason))")
        done(false)
    }

    /// Why this copy does not update itself, or nil when it does.
    private static func skipReason() -> String? {
        let env = ProcessInfo.processInfo.environment
        if env["ZEUS_APP_NO_UPDATE"] == "1" { return "ZEUS_APP_NO_UPDATE" }
        guard Version(currentVersion) != nil else { return "development version \(currentVersion)" }
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app" else { return "not an app bundle" }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            return "the app folder is read-only"
        }
        return nil
    }

    private struct Update {
        let version: String
        let work: URL
        /// The new Zeus.app, checked, in a folder on the same volume as the app.
        let app: URL
    }

    private enum CheckResult {
        case none(String)
        case ready(Update)
    }

    /// Off the main queue: finds the newest release, then downloads and checks it.
    private static func checkAndDownload() -> CheckResult {
        guard let gh = findGH() else { return .none("no gh") }
        guard let current = Version(currentVersion) else { return .none("version \(currentVersion)") }
        let list = run(gh, ["api", "repos/\(repo)/releases?per_page=100",
                            "--jq", ".[] | select((.draft or .prerelease) | not) | .tag_name"], timeout: checkTimeout)
        guard list.status == 0 else { return .none("no release list: status \(list.status)") }
        let newest = list.output.split(separator: "\n")
            .compactMap { line -> Version? in
                guard line.hasPrefix(tagPrefix) else { return nil }
                return Version(String(line.dropFirst(tagPrefix.count)))
            }
            .max()
        guard let newest else { return .none("no app release") }
        Trace.log("update: current=\(currentVersion) newest=\(newest)")
        guard newest > current else { return .none("up to date") }

        DispatchQueue.main.async { UpdateWindow.shared.showDownload(version: newest.description) }
        let fileManager = FileManager.default
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        // A folder on the same volume as the app, so that the swap is one rename.
        guard let work = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: bundle, create: true) else {
            return .none("no work folder")
        }
        let failed: (String) -> CheckResult = { why in
            try? fileManager.removeItem(at: work)
            return .none("failed: \(why)")
        }
        let tag = tagPrefix + newest.description
        Trace.log("update: downloading \(tag) to \(work.path)")
        let download = run(gh, ["release", "download", tag, "-R", repo, "-p", "Zeus.zip", "-p", "Zeus.zip.sha256",
                                "-D", work.path, "--clobber"], timeout: downloadTimeout)
        guard download.status == 0 else { return failed("download status \(download.status)") }

        let zip = work.appendingPathComponent("Zeus.zip")
        guard let data = try? Data(contentsOf: zip),
              let expected = (try? String(contentsOf: work.appendingPathComponent("Zeus.zip.sha256")))?
                  .split(whereSeparator: \.isWhitespace).first.map(String.init),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected.lowercased()
        else { return failed("checksum mismatch") }
        let unpacked = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 120).status == 0 else {
            return failed("the zip cannot be unpacked")
        }
        let app = unpacked.appendingPathComponent("Zeus.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == newest.description
        else { return failed("not Zeus \(newest)") }
        guard run("/usr/bin/codesign", ["--verify", "--strict", app.path], timeout: 60).status == 0 else {
            return failed("signature check")
        }
        try? fileManager.removeItem(at: zip)
        return .ready(Update(version: newest.description, work: work, app: app))
    }

    /// On the main queue: swaps the new app in, starts it, and waits for its confirmation.
    private static func install(_ update: Update, done: @escaping (Bool) -> Void) {
        let fileManager = FileManager.default
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let backup = update.work.appendingPathComponent("previous")
        let finish: (String) -> Void = { why in
            Trace.log("update: failed: \(why)")
            try? fileManager.removeItem(at: update.work)
            removePending()
            done(false)
            UpdateWindow.shared.close()
        }
        let pending = Pending(from: currentVersion, to: update.version, appPath: bundle.path,
                              backupPath: backup.appendingPathComponent("Zeus.app").path, workPath: update.work.path,
                              waitingPID: getpid())
        do {
            try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
            try writePending(pending)
        } catch {
            return finish("cannot prepare: \(error.localizedDescription)")
        }
        // After the swap, the app path holds the new app and the update folder holds the old app.
        guard swap(update.app, bundle) else { return finish("cannot replace the app (errno \(errno))") }
        do {
            try fileManager.moveItem(at: update.app, to: URL(fileURLWithPath: pending.backupPath))
        } catch {
            _ = swap(update.app, bundle)
            return finish("cannot keep the old app: \(error.localizedDescription)")
        }
        Trace.log("update: installed \(update.version), starting it")

        // Puts the old app back when the new app does not start.
        let rollBack: (String, NSRunningApplication?) -> Void = { why, newApp in
            newApp?.forceTerminate()
            // The new app goes to the update folder, which `finish` removes.
            if swap(URL(fileURLWithPath: pending.backupPath), bundle) {
                Trace.log("update: rolled back to \(currentVersion)")
            } else {
                Trace.log("update: roll back failed (errno \(errno)); the new app stays")
            }
            finish(why)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // The new copy gets the same environment (HOME, test settings) as this copy.
        configuration.environment = ProcessInfo.processInfo.environment
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { newApp, error in
            DispatchQueue.main.async {
                if let error { return rollBack("the new app does not open: \(error.localizedDescription)", newApp) }
                let deadline = Date().addingTimeInterval(confirmTimeout)
                Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
                    if readPending()?.confirmed == true {
                        timer.invalidate()
                        Trace.log("update: done \(currentVersion) -> \(update.version)")
                        removeUpdateFiles(pending)
                        UpdateWindow.shared.close()
                        done(true)
                        NSApp.terminate(nil)
                    } else if newApp?.isTerminated == true || Date() > deadline {
                        timer.invalidate()
                        rollBack(newApp?.isTerminated == true ? "the new app stopped" : "the new app did not confirm", newApp)
                    }
                }
            }
        }
    }

    /// Swaps two folders on the same volume in one step. Without APFS, two renames.
    private static func swap(_ first: URL, _ second: URL) -> Bool {
        if renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 { return true }
        guard errno == ENOTSUP || errno == EINVAL else { return false }
        let temporary = first.deletingLastPathComponent().appendingPathComponent("swap-\(getpid())")
        guard rename(second.path, temporary.path) == 0 else { return false }
        guard rename(first.path, second.path) == 0 else {
            rename(temporary.path, second.path)
            return false
        }
        return rename(temporary.path, first.path) == 0
    }

    // MARK: Helpers

    private static func findGH() -> String? {
        ShellEnvironment.loginPath().split(separator: ":").map { $0 + "/gh" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a tool without input and with a time limit. The output goes to a file, so a large output cannot block it.
    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-update-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let output = try? FileHandle(forWritingTo: outputURL) else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ShellEnvironment.make(extra: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return (-2, "")
        }
        try? output.close()
        return (process.terminationStatus, (try? String(contentsOf: outputURL)) ?? "")
    }
}

/// A release version X.Y.Z. Development versions such as "0.0.0-dev" are not versions here.
struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    static func < (lhs: Version, rhs: Version) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    var description: String { parts.map(String.init).joined(separator: ".") }
}

/// The window that shows the loading screen (the Zeus globe) while the app checks for an update and
/// downloads it, before Zeus starts. It has the place and size of the chat window.
final class UpdateWindow {
    static let shared = UpdateWindow()
    private var window: NSWindow?
    private var loader: LoaderOverlay?

    func show() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                              styleMask: [.titled, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Zeus"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = LoaderPage.background
        window.isReleasedWhenClosed = false
        // The globe has the same place as in the chat window, below the space of the tabs.
        let content = NSView()
        let loader = LoaderOverlay(frame: .zero, status: "Checking for updates…")
        loader.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(loader.view)
        window.contentView = content
        NSLayoutConstraint.activate([
            loader.view.topAnchor.constraint(equalTo: content.topAnchor, constant: TabStripView.height),
            loader.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            loader.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            loader.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if !window.setFrameUsingName("ZeusChatWindow") { window.center() }
        self.window = window
        self.loader = loader
        bringForward()
        Trace.log("update window: checking")
    }

    func showDownload(version: String) {
        loader?.setStatus("Downloading Zeus \(version)…")
        Trace.log("update window: downloading \(version)")
    }

    func bringForward() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activateZeus()
    }

    func close() {
        window?.close()
        window = nil
        loader = nil
    }
}
