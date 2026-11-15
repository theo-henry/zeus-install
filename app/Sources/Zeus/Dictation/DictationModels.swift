import CryptoKit
import Foundation

/// One model of the model list (`Resources/dictation-models.json`). See docs/dictation-models.md.
struct DictationModel: Codable, Equatable {
    /// Unique and stable: a new file (another model, quantization, or revision) gets a new id.
    let id: String
    /// "accurate" or "fast": the choice in the dictation settings that this model serves.
    let role: String
    /// The code that runs the model ("whisper"); see `DictationRuntime.makeTranscriber`.
    let engine: String
    let name: String
    let description: String
    /// A download link that is pinned to one revision of the file.
    let url: URL
    let bytes: Int64
    let sha256: String
    let multilingual: Bool
    /// The Whisper language codes of a model that is not multilingual.
    let languages: [String]?
    let license: String
    let source: String

    var fileName: String { id + ".bin" }
}

struct DictationManifest: Codable, Equatable {
    let version: Int
    let defaultRole: String
    let models: [DictationModel]

    func model(for role: String) -> DictationModel? { models.first { $0.role == role } }
    var roles: [String] { models.map(\.role) }

    /// The model list in the app. Debug builds take `ZEUS_APP_DICTATION_MANIFEST` instead, for the tests.
    static func load() -> DictationManifest {
        var url = Bundle.main.url(forResource: "dictation-models", withExtension: "json")
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["ZEUS_APP_DICTATION_MANIFEST"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        }
        #endif
        guard let url, let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(DictationManifest.self, from: data),
              manifest.version == 1, Set(manifest.roles).count == manifest.models.count,
              manifest.model(for: manifest.defaultRole) != nil else {
            Trace.log("dictation: the model list is missing or not valid")
            return DictationManifest(version: 1, defaultRole: "accurate", models: [])
        }
        return manifest
    }
}

/// Downloads, checks, and keeps the dictation models on this Mac, in
/// `~/Library/Application Support/io.github.theo-henry.zeus/whisper-models/`, outside the app,
/// so that an app update does not download them again.
///
/// - `<id>.bin` is a complete file with the size and SHA-256 of the model list: only a checked download gets this name.
/// - `installed.json` maps each role to the model that is in use for it.
/// - A new model of a role (an app update changed the model list) downloads in the background.
///   The old model stays in use until the new one loads; then the old file is deleted (`commit`).
/// All calls are on the main queue.
final class DictationModels: NSObject, ObservableObject {
    static let shared = DictationModels()

    enum State: Equatable {
        case missing
        case downloading(received: Int64, total: Int64)
        case verifying
        /// Checked, on this Mac.
        case downloaded
        case failed(String)
        case cancelled
    }

    let manifest = DictationManifest.load()
    /// The download state of each model id of the model list.
    @Published private(set) var states: [String: State] = [:]
    /// When a failed download tries again, for each model id.
    private(set) var retryAt: [String: Date] = [:]
    /// Called after each change (the speech bridge tells the pages).
    var onChange: [() -> Void] = []

    let directory: URL
    private var installed: [String: String] = [:]
    private var session: URLSession!
    private var tasks: [Int: (task: URLSessionDownloadTask, model: DictationModel)] = [:]
    private var retryTimers: [String: Timer] = [:]
    private var failures: [String: Int] = [:]
    private var lastProgress: [String: Date] = [:]
    private var started = false
    /// `ZEUS_APP_NO_MODEL_DOWNLOAD=1`: no download (the tests of other parts); dictation then uses Apple's recognizer.
    let downloadsOff = ProcessInfo.processInfo.environment["ZEUS_APP_NO_MODEL_DOWNLOAD"] == "1"
    private static let retryDelays: [TimeInterval] = [30, 120, 600, 1800, 3600]
    /// Space that must stay free after a download.
    private static let spareBytes: Int64 = 256 * 1024 * 1024

    private override init() {
        directory = URL(fileURLWithPath: Paths.home + "/Library/Application Support/io.github.theo-henry.zeus/whisper-models",
                        isDirectory: true)
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        installed = readInstalled()
        for model in manifest.models { states[model.id] = isComplete(model) ? .downloaded : .missing }
    }

    // MARK: Queries

    func model(for role: String) -> DictationModel? { manifest.model(for: role) }

    func state(of model: DictationModel) -> State { states[model.id] ?? .missing }

    /// The model file to load for a role: the model of the model list when it is on this Mac,
    /// otherwise the model that the role used before (an older app's model, until the new one loads).
    func candidate(for role: String) -> (id: String, file: URL, committed: Bool)? {
        if let model = model(for: role), isComplete(model) {
            return (model.id, file(model.id), installed[role] == model.id)
        }
        if let old = installed[role], FileManager.default.fileExists(atPath: file(old).path) {
            return (old, file(old), true)
        }
        return nil
    }

    /// The id of the model that a role uses now, also an old one.
    func installedID(for role: String) -> String? { installed[role] }

    private func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".bin") }

    private func isComplete(_ model: DictationModel) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file(model.id).path)[.size] as? NSNumber)?.int64Value
        return size == model.bytes
    }

    // MARK: Lifecycle

    /// At app start (and when the setup window opens): removes unfinished downloads and gets the models that the
    /// user needs: the model of the chosen role, and a new version of each role that this Mac already has.
    func start() {
        guard !started else { return }
        started = true
        // Another model in the settings downloads at once.
        DictationSettings.shared.onChange.append { [weak self] in self?.reconcile() }
        if let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "download" { try? FileManager.default.removeItem(at: item) }
        }
        Trace.log("dictation: models start dir=\(directory.path) installed=\(installed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        reconcile()
    }

    /// Starts the downloads that are needed now.
    func reconcile() {
        guard started else { return }
        let selected = DictationSettings.shared.role
        for model in manifest.models {
            let needed = model.role == selected || installed[model.role] != nil
            guard needed else { continue }
            switch state(of: model) {
            case .missing: download(model, reason: "needed")
            case .failed, .cancelled, .downloading, .verifying, .downloaded: break
            }
        }
        removeUnusedFiles()
    }

    /// The download (again) of the model of a role, for the user: also after a failure or a cancel.
    func download(role: String) {
        guard let model = model(for: role) else { return }
        start()
        switch state(of: model) {
        case .missing, .failed, .cancelled:
            failures[model.id] = 0
            download(model, reason: "requested")
        case .downloading, .verifying, .downloaded: break
        }
    }

    /// Stops the download of a role. It starts again only when the user asks, or at the next app start.
    func cancel(role: String) {
        guard let model = model(for: role) else { return }
        retryTimers.removeValue(forKey: model.id)?.invalidate()
        retryAt[model.id] = nil
        for (key, entry) in tasks where entry.model.id == model.id {
            tasks[key] = nil
            entry.task.cancel()
        }
        if case .downloaded = state(of: model) { return }
        Trace.log("dictation: download \(model.id) cancelled")
        set(model.id, .cancelled)
    }

    /// The runtime loaded this model for its role: it is the model of the role now, and the old file goes.
    func commit(role: String, id: String) {
        guard installed[role] != id else { return }
        let old = installed[role]
        installed[role] = id
        writeInstalled()
        Trace.log("dictation: \(role) model is now \(id)" + (old.map { ", was \($0)" } ?? ""))
        removeUnusedFiles()
        changed()
    }

    /// A checked file that does not load is removed; the role keeps its old model. No retry until the next app start.
    func reject(id: String, message: String) {
        try? FileManager.default.removeItem(at: file(id))
        Trace.log("dictation: model \(id) does not load: \(message)")
        set(id, .failed("The model does not load: \(message)"))
    }

    /// Deletes each model file that no role uses and that the model list does not have:
    /// an old model goes only after the new model of its role replaced it (`commit`).
    private func removeUnusedFiles() {
        let keep = Set(installed.values).union(manifest.models.filter { isComplete($0) }.map(\.id))
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.pathExtension == "bin" {
            let id = item.deletingPathExtension().lastPathComponent
            guard !keep.contains(id) else { continue }
            Trace.log("dictation: deleting unused model file \(item.lastPathComponent)")
            try? FileManager.default.removeItem(at: item)
        }
        // A role that the model list no longer has keeps nothing.
        let roles = Set(manifest.roles)
        if installed.keys.contains(where: { !roles.contains($0) }) {
            installed = installed.filter { roles.contains($0.key) }
            writeInstalled()
        }
    }

    // MARK: Download

    private func download(_ model: DictationModel, reason: String) {
        guard !downloadsOff else {
            Trace.log("dictation: download \(model.id) skipped (ZEUS_APP_NO_MODEL_DOWNLOAD)")
            return
        }
        retryTimers.removeValue(forKey: model.id)?.invalidate()
        retryAt[model.id] = nil
        if let free = freeSpace(), free < model.bytes + Self.spareBytes {
            let needed = ByteCountFormatter.string(fromByteCount: model.bytes + Self.spareBytes, countStyle: .file)
            fail(model, "There is not enough free disk space. The model needs \(needed).")
            return
        }
        var request = URLRequest(url: model.url)
        request.setValue("Zeus", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        tasks[task.taskIdentifier] = (task, model)
        Trace.log("dictation: download \(model.id) starts (\(reason))")
        set(model.id, .downloading(received: 0, total: model.bytes))
        task.resume()
    }

    private func freeSpace() -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func fail(_ model: DictationModel, _ message: String) {
        let count = (failures[model.id] ?? 0) + 1
        failures[model.id] = count
        let delay = Self.retryDelays[min(count - 1, Self.retryDelays.count - 1)]
        Trace.log("dictation: download \(model.id) failed: \(message); retry in \(Int(delay)) s")
        retryAt[model.id] = Date().addingTimeInterval(delay)
        retryTimers[model.id]?.invalidate()
        retryTimers[model.id] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retryTimers[model.id] = nil
            if case .failed = self.state(of: model) { self.download(model, reason: "retry \(count)") }
        }
        set(model.id, .failed(message))
    }

    /// Checks the size and the SHA-256 off the main queue, then gives the file its final name in one rename.
    private func verify(_ model: DictationModel, at partial: URL) {
        set(model.id, .verifying)
        let target = file(model.id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var problem = Self.check(partial, bytes: model.bytes, sha256: model.sha256)
            if problem == nil {
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: partial, to: target)
                } catch {
                    problem = "The download cannot be saved: \(error.localizedDescription)"
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let problem {
                    try? FileManager.default.removeItem(at: partial)
                    self.fail(model, problem)
                    return
                }
                self.failures[model.id] = 0
                Trace.log("dictation: download \(model.id) checked")
                self.set(model.id, .downloaded)
                // The model of the chosen role becomes the role's model when it loads (DictationRuntime);
                // another role's model replaces the old one at once.
                if model.role != DictationSettings.shared.role { self.commit(role: model.role, id: model.id) }
                self.removeUnusedFiles()
            }
        }
    }

    static func check(_ url: URL, bytes: Int64, sha256: String) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == bytes else { return "The download has \(size) bytes, not \(bytes)." }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "The download cannot be read." }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 4 * 1024 * 1024) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256.lowercased() ? nil : "The download does not have the expected SHA-256 checksum."
    }

    // MARK: State

    private func set(_ id: String, _ state: State) {
        states[id] = state
        changed()
    }

    private func changed() { onChange.forEach { $0() } }

    private var installedFile: URL { directory.appendingPathComponent("installed.json") }

    private func readInstalled() -> [String: String] {
        guard let data = try? Data(contentsOf: installedFile),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    private func writeInstalled() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: installedFile, options: .atomic)
    }
}

extension DictationModels: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let entry = tasks[downloadTask.taskIdentifier] else { return }
        let now = Date()
        if let last = lastProgress[entry.model.id], now.timeIntervalSince(last) < 0.25 { return }
        lastProgress[entry.model.id] = now
        set(entry.model.id, .downloading(received: totalBytesWritten, total: entry.model.bytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let entry = tasks.removeValue(forKey: downloadTask.taskIdentifier) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            fail(entry.model, "The download failed (HTTP \(status)).")
            return
        }
        // The system deletes `location` when this call returns: move it next to its final place first.
        let partial = directory.appendingPathComponent(entry.model.id + ".bin.download")
        do {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            fail(entry.model, "The download cannot be saved: \(error.localizedDescription)")
            return
        }
        verify(entry.model, at: partial)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let entry = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail(entry.model, "The download failed: \(error.localizedDescription)")
    }
}
