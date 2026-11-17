import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// The EU to Standard handover (zeus references/eu-mode.md, "Handover"). EU Claude writes a summary of its work on a fixed
/// template. The app then builds the handover into a folder that only the app writes (`Handover.root`), scans it for data
/// values, masks the values that the user chooses to mask, and copies the released files into the Standard workspace,
/// all with the Zeus commands of the Standard workspace, outside Claude and out of reach of EU Claude. The EU sandbox can
/// write the EU workspace, but not the app folder: so the files that the scan reads, the files that the user sees, and
/// the files that cross are the same bytes. EU Claude can not write into the Standard workspace, so it can not make a
/// release. The user decides each finding group here, never Claude: Keep (not a data value) or Mask. E-mail and IBAN
/// groups can only be masked. EU chats and EU work files never open in Standard: only the released files cross.
enum Handover {
    /// The handover id of `handoff build` (`\d{8}T\d{6}Z-[0-9a-f]{6}`).
    static func validID(_ id: String) -> Bool { id.range(of: #"^\d{8}T\d{6}Z-[0-9a-f]{6}$"#, options: .regularExpression) != nil }

    /// A project folder name: no separator, no dot first.
    static func validProject(_ project: String) -> Bool {
        project.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil && !project.contains("..")
    }

    /// A finding group of the scan (`g` and 15 hex digits): a salted hash of a kind and a value, which names no value.
    static func validGroup(_ group: String) -> Bool { group.range(of: #"^g[0-9a-f]{15}$"#, options: .regularExpression) != nil }

    /// A path of the manifest: `summary.md` or a relative path under `files/`, with no `..`, no empty part, and no dot first.
    static func validManifestPath(_ path: String) -> Bool {
        guard path == "summary.md" || path.hasPrefix("files/"), !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0")
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && !$0.hasPrefix(".") }
    }

    /// The finding kinds about a whole file (zeus `handoff_scan.FILE_KINDS`): no Keep or Mask; the handover must be built again.
    static let fileKinds: Set<String> = ["missing-file", "changed-after-build"]
    /// The kinds that can only be masked (zeus `handoff_scan.BLOCKING`).
    static let maskOnlyKinds: Set<String> = ["email", "iban"]

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The folder where the app builds, scans, and masks each handover: `~/Library/Application Support/Zeus/handover`,
    /// owner only. Neither mode's Claude can write it: the EU sandbox writes only its own folders (zeus-editor
    /// src/eu/profile.js), and the Standard read block denies this folder (`StandardJail`). Each handover is in
    /// `<root>/<project>/<id>`.
    static var root: String { Paths.appSupport + "/handover" }

    /// Makes the root folder if needed; fails when it, or the app folder above it, is a link or not a folder.
    static func prepareRoot() throws -> String {
        let folder = root
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isDirectory(Paths.appSupport), isDirectory(folder) else {
            throw HandoffCLI.Failure(message: "The handover folder of the app (\(EUSetup.display(folder))) is not a plain folder.")
        }
        chmod(folder, 0o700)
        return folder
    }

    /// A folder, not a link (lstat).
    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A regular file, not a link (lstat).
    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// The content of a regular file under `base`, read without following a link in any part of `relative`.
    static func read(_ relative: String, under base: String) -> Data? {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, let folder = openFolder(base, parts.dropLast()) else { return nil }
        defer { close(folder) }
        let descriptor = openat(folder, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    /// Writes a new file (never one that exists) under `base`, without following a link in any part of `relative`.
    static func writeNew(_ data: Data, _ relative: String, under base: String) throws {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, let folder = openFolder(base, parts.dropLast()) else {
            throw HandoffCLI.Failure(message: "The folder of \(relative) is not a plain folder.")
        }
        defer { close(folder) }
        let descriptor = openat(folder, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw HandoffCLI.Failure(message: "Zeus could not write \(relative): \(String(cString: strerror(errno))).") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
    }

    /// A descriptor of `base`/`parts`, opened one part at a time without following a link; nil when a part is a link or
    /// not a folder. `base` itself must be a folder, not a link.
    private static func openFolder<S: Sequence>(_ base: String, _ parts: S) -> Int32? where S.Element == String {
        var current = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { return nil }
        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else { close(current); return nil }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { return nil }
            current = next
        }
        return current
    }

    /// The lines of a text as the scan numbers them: Python's `str.splitlines()`, without line ends, as Unicode scalars,
    /// so that the `col` and `length` of a finding (Python string positions) give the same characters here.
    static func scanLines(_ text: String) -> [[Unicode.Scalar]] {
        let breaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]
        var lines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A, previousCR { previousCR = false; continue }
            previousCR = false
            if breaks.contains(scalar.value) {
                lines.append(current)
                current = []
                previousCR = scalar.value == 0x0D
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// The text of a finding in a file of the handover: `line` 0 is the file name without `files/`. Nil when the place is
    /// not in the file. The value is for the release sheet only: never written to a file or a log.
    static func value(file: String, line: Int, col: Int, length: Int, content: Data?) -> String? {
        guard col >= 1, length >= 1 else { return nil }
        let scalars: [Unicode.Scalar]
        if line == 0 {
            scalars = Array((file.hasPrefix("files/") ? String(file.dropFirst(6)) : file).unicodeScalars)
        } else {
            guard let content else { return nil }
            let lines = scanLines(String(decoding: content, as: UTF8.self))
            guard line <= lines.count else { return nil }
            scalars = lines[line - 1]
        }
        guard col - 1 + length <= scalars.count else { return nil }
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars[(col - 1) ..< (col - 1 + length)])
        return text
    }
}

/// The Zeus commands that the app runs in the EU workspace (zeus references/eu-mode.md, "App contract"):
/// `python3 -E -s <Standard workspace>/scripts/zeus.py --workspace <EU workspace> <command> ... --json`.
/// Exit codes: 0 ok, 2 user error, 3 findings (scan), 4 internal error; every answer is one JSON object.
/// The script is the one of the Standard workspace, which EU Claude can not write: EU Claude can change the scripts of
/// the EU workspace, and so the scan. `-E -s` keep PYTHONPATH and the user site folder out, and a script run puts only the
/// folder of its script on the import path, not the working folder: no module of the EU workspace loads.
struct HandoffCLI {
    let workspace: String
    let profile: EUProfile
    /// The Standard workspace, whose `scripts/zeus.py` runs.
    let scriptsWorkspace: String

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Off the main queue. `arguments` follow `zeus.py --workspace <EU workspace>`, such as `["handoff", "pending"]`.
    func run(_ arguments: [String]) throws -> (code: Int32, json: [String: Any]) {
        let name = arguments.prefix(2).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = (scriptsWorkspace as NSString).appendingPathComponent("scripts/zeus.py")
        process.arguments = ["python3", "-E", "-s", script, "--workspace", workspace] + arguments + ["--json"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspace)
        var env = ShellEnvironment.make()
        // The app's calls have no Claude session; the EU workspace and the profile decide.
        for key in env.keys where key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_") || key == "ZEUS_MODE" || key == "CLOUD_ML_REGION" {
            env.removeValue(forKey: key)
        }
        env.removeValue(forKey: "ZEUS_EU_PROFILE")
        if let file = profile.file { env["ZEUS_EU_PROFILE"] = file }
        process.environment = env
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure(message: "Zeus could not run python3: \(error.localizedDescription)") }
        // Read both pipes before the wait, and at the same time: a large answer or a large error output fills its pipe.
        var errorData = Data()
        let errorsRead = DispatchGroup()
        errorsRead.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            errorsRead.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        errorsRead.wait()
        let errorText = String(decoding: errorData, as: UTF8.self)
        process.waitUntilExit()
        let code = process.terminationStatus
        Trace.log("zeus \(name): exit \(code)")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let detail = errorText.split(separator: "\n").last.map(String.init) ?? "no answer"
            throw Failure(message: "Zeus \(name) did not answer (exit code \(code)): \(detail)")
        }
        if code == 2 || code == 4 || json["status"] as? String == "error" {
            throw Failure(message: json["error"] as? String ?? "Zeus \(name) failed (exit code \(code)).")
        }
        return (code, json)
    }
}

final class HandoverModel: ObservableObject {
    struct Project: Identifiable, Equatable {
        var id: String { project }
        let project: String
        let lastActivity: String?
        let open: Bool
    }

    struct File: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let sha256: String
        let bytes: Int
        var include = true
        var isSummary: Bool { path == "summary.md" }
    }

    /// One place of the scan. `value` is the text at that place in the app's copy of the handover, for the release sheet
    /// only: it stays in memory, the sheet shows it as text that can not be selected, and no file or log gets it.
    struct Finding: Equatable {
        let file: String
        let line: Int
        let col: Int
        let length: Int
        let kind: String
        let excerpt: String
        let group: String
        let value: String?
        /// A hash of the value: a Keep holds for this value only, so a new value in the same group needs a new choice.
        let valueHash: String
        /// The group and the value hash: what a Keep records.
        var keepKey: String { group + ":" + valueHash }
    }

    /// The findings of one group: the same kind and value (case and accents folded) in every file.
    struct Group: Identifiable, Equatable {
        let id: String
        let kind: String
        let findings: [Finding]
        /// A file that changed or is missing: no Keep or Mask, the handover must be built again.
        var isFileProblem: Bool { Handover.fileKinds.contains(kind) }
        /// E-mail addresses and IBANs: Mask only.
        var maskOnly: Bool { Handover.maskOnlyKinds.contains(kind) }
        var canKeep: Bool { !isFileProblem && !maskOnly }
        var canMask: Bool { !isFileProblem }
        /// The different texts of the group, as the sheet shows them.
        var values: [String] {
            var seen = Set<String>()
            return findings.compactMap(\.value).filter { seen.insert($0).inserted }
        }
        var files: [String] { Array(Set(findings.map(\.file))).sorted() }
    }

    enum Decision: Equatable { case open, keep, mask, rebuild }

    struct Review: Equatable {
        let id: String
        let project: String
        /// The app's folder of the handover: `<Handover.root>/<project>/<id>`.
        let dir: String
        var summary: String
        var savedSummary: String
        var files: [File]
        var skipped: [(path: String, reason: String)]
        var findings: [Finding]
        var note: String
        var summaryEdited = false
        /// The kinds of the groups that are masked in the handover, from its manifest (`masked`).
        var maskedKinds: [String] = []

        static func == (a: Review, b: Review) -> Bool {
            a.id == b.id && a.summary == b.summary && a.files == b.files && a.findings == b.findings && a.note == b.note
                && a.skipped.map(\.path) == b.skipped.map(\.path) && a.maskedKinds == b.maskedKinds
        }
    }

    /// An EU tab that the user can ask for a summary.
    struct ChatChoice: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    enum Phase: Equatable { case loading, list, working(String), review, released(String), failed(String) }

    @Published var phase: Phase = .loading
    @Published var projects: [Project] = []
    /// Why no project has work to hand over, when none has.
    @Published var nothingReason: String?
    @Published var chats: [ChatChoice] = []
    @Published var review: Review?
    @Published var message: String?
    /// The user's Keep choices: `group:value hash` (`Finding.keepKey`). They stay over a new build or scan.
    @Published private(set) var kept: Set<String> = []
    /// The groups that the user chose to mask; Release masks them first.
    @Published private(set) var masking: Set<String> = []

    let profile: EUProfile
    let standardWorkspace: String
    private let cli: HandoffCLI
    private let queue = DispatchQueue(label: "zeus.handover")
    private var pollTimer: Timer?
    /// The projects with a summary at the last refresh: a new summary shows a message.
    private var openBefore: Set<String> = []

    /// The EU tabs of the app, and a way to ask one of them for a summary.
    var chatProvider: (() -> [ChatChoice])?
    var askChat: ((UUID, @escaping (Bool) -> Void) -> Void)?
    /// After a release, the user can go on to Standard mode.
    var onSwitchToStandard: (() -> Void)?

    init(profile: EUProfile = .load(), standardWorkspace: String = Paths.zeusDir) {
        self.profile = profile
        self.standardWorkspace = standardWorkspace
        cli = HandoffCLI(workspace: profile.workspace, profile: profile, scriptsWorkspace: standardWorkspace)
    }

    deinit { pollTimer?.invalidate() }

    func start() {
        refresh()
        // While the list shows, a summary that EU Zeus saves shows up by itself.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, self.phase == .list else { return }
            self.refresh(quiet: true)
        }
    }

    func stop() { pollTimer?.invalidate(); pollTimer = nil }

    func refresh(quiet: Bool = false) {
        chats = chatProvider?() ?? []
        if !quiet { phase = .loading }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let (_, json) = try self.cli.run(["handoff", "pending"])
                let all = (json["projects"] as? [[String: Any]] ?? []).compactMap { item -> Project? in
                    guard let project = item["project"] as? String, Handover.validProject(project) else { return nil }
                    return Project(project: project, lastActivity: item["last_eu_activity_at"] as? String,
                                   open: item["has_open_handoff"] as? Bool == true)
                }
                DispatchQueue.main.async {
                    let open = Set(all.filter(\.open).map(\.project))
                    if quiet, !open.subtracting(self.openBefore).isEmpty {
                        self.message = "A handover summary is ready to review."
                    }
                    self.openBefore = open
                    self.projects = all.filter { $0.open || $0.lastActivity != nil }
                    self.nothingReason = self.projects.isEmpty ? Self.nothingReason(all: all, workspace: self.profile.workspace) : nil
                    if self.phase == .loading || quiet && self.phase == .list { self.phase = .list }
                }
            } catch {
                DispatchQueue.main.async { if !quiet { self.phase = .failed(error.localizedDescription) } }
            }
        }
    }

    /// Why the list is empty, in the user's words.
    static func nothingReason(all: [Project], workspace: String) -> String {
        if all.isEmpty {
            return "The EU workspace (\(EUSetup.display(workspace))) has no project. Make the project in an EU chat first; only work "
                + "of an EU project can be handed over."
        }
        let names = all.map(\.project).sorted().joined(separator: ", ")
        return "No EU project has work to hand over: \(names) \(all.count == 1 ? "has" : "have") no changed files or chat messages in "
            + "EU mode, and no handover summary that is not released yet. Earlier handovers are already released."
    }

    func ask(_ chat: ChatChoice) {
        message = nil
        askChat?(chat.id) { [weak self] sent in
            self?.message = sent
                ? "Zeus writes the summary in “\(chat.name)”. It shows here when Zeus has saved it."
                : "Zeus could not send the request to “\(chat.name)”. Ask Zeus in that chat to write the handover summary."
        }
    }

    /// Builds and scans the latest summary of a project, then shows the review.
    func open(_ project: String) {
        message = nil
        kept = []
        masking = []
        phase = .working("Building and scanning the handover of \(project)…")
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let review = try self.buildAndScan(project: project, keeping: nil)
                DispatchQueue.main.async { self.review = review; self.phase = .review }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: Build, scan, mask (off the main queue)

    /// `handoff build --dir`, then `handoff scan --dir`. `old` carries the files that the user removed over a new build.
    private func buildAndScan(project: String, keeping old: Review?) throws -> Review {
        guard Handover.validProject(project) else { throw HandoffCLI.Failure(message: "The project name is not valid.") }
        let root = try Handover.prepareRoot()
        // `--dir` is the handover's own folder, so the app needs the handover ID first: the latest summary of the project,
        // as `handoff build` takes it. The build must answer with the same ID and folder.
        let expected = try Self.latestHandover(workspace: profile.workspace, project: project)
        let projectFolder = root + "/" + project
        try FileManager.default.createDirectory(atPath: projectFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard Handover.isDirectory(projectFolder) else { throw HandoffCLI.Failure(message: "The handover folder of the app is not a plain folder.") }
        let (_, built) = try cli.run(["handoff", "build", project, "--dir", projectFolder + "/" + expected])
        guard let id = built["id"] as? String, id == expected, built["project"] as? String == project,
              let dir = built["dir"] as? String else {
            throw HandoffCLI.Failure(message: "Zeus handoff build gave an answer for another handover. Nothing was released; open the review again.")
        }
        let folder = try handoverFolder(root: root, project: project, id: id, answered: dir)
        var files = try manifestFiles(built["files"], "Zeus handoff build")
        if let old {
            // By path; a mask can rename a file but keeps the manifest order, so a file with a new name gets the choice of
            // the file at its place.
            let sameList = old.files.count == files.count
            for index in files.indices {
                files[index].include = old.files.first { $0.path == files[index].path }?.include
                    ?? (sameList ? old.files[index].include : true)
            }
        }
        let skipped = (built["skipped"] as? [[String: Any]] ?? []).map { ($0["path"] as? String ?? "?", $0["reason"] as? String ?? "") }
        let (findings, note) = try scan(project: project, id: id, folder: folder)
        let summary = Handover.read("summary.md", under: folder).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Review(id: id, project: project, dir: folder, summary: summary, savedSummary: summary, files: files, skipped: skipped,
                      findings: findings, note: note, summaryEdited: old?.summaryEdited ?? false, maskedKinds: maskedKinds(folder))
    }

    /// The ID of the latest handover summary of an EU project (zeus `handoff.latest`): the newest `clients/<project>/handoff/<id>/`
    /// with a `summary.md`. Only names are read, and no link is followed.
    static func latestHandover(workspace: String, project: String) throws -> String {
        let folder = workspace + "/clients/" + project + "/handoff"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter(Handover.validID).sorted()
        guard Handover.isDirectory(folder), let latest = names.last(where: { Handover.isRegularFile(folder + "/" + $0 + "/summary.md") })
        else { throw HandoffCLI.Failure(message: "Project \(project) has no handover summary. Ask Zeus in the EU chat of the project to write it.") }
        guard !FileManager.default.fileExists(atPath: folder + "/" + latest + "/released.json") else {
            throw HandoffCLI.Failure(message: "The latest handover of \(project) is already released. Ask Zeus for a new summary for new work.")
        }
        return latest
    }

    /// The app's folder of a handover; the CLI's answer must name exactly it, and no part of it may be a link.
    private func handoverFolder(root: String, project: String, id: String, answered: String) throws -> String {
        let folder = root + "/" + project + "/" + id
        guard (answered as NSString).standardizingPath == (folder as NSString).standardizingPath, Handover.isDirectory(root + "/" + project), Handover.isDirectory(folder)
        else { throw HandoffCLI.Failure(message: "The handover is not in the handover folder of the app.") }
        return folder
    }

    private func manifestFiles(_ value: Any?, _ source: String) throws -> [File] {
        guard let entries = value as? [[String: Any]] else { throw HandoffCLI.Failure(message: "\(source) gave no file list.") }
        let files = try entries.map { entry -> File in
            guard let path = entry["path"] as? String, Handover.validManifestPath(path), let sha = entry["sha256"] as? String
            else { throw HandoffCLI.Failure(message: "\(source) names a file that the app does not release.") }
            return File(path: path, sha256: sha, bytes: (entry["bytes"] as? NSNumber)?.intValue ?? 0)
        }
        guard files.contains(where: \.isSummary) else { throw HandoffCLI.Failure(message: "The handover has no summary.") }
        return files
    }

    /// `handoff scan <project> <id> --dir`: the answer must be for this project and handover. Each finding gets its value
    /// from the app's copy.
    private func scan(project: String, id: String, folder: String) throws -> ([Finding], String) {
        let (_, scanned) = try cli.run(["handoff", "scan", project, id, "--dir", folder])
        guard scanned["id"] as? String == id, scanned["project"] as? String == project else {
            throw HandoffCLI.Failure(message: "The scan answer is for another project or handover. Nothing was released.")
        }
        var contents: [String: Data?] = [:]
        let findings = try (scanned["findings"] as? [[String: Any]] ?? []).map { item -> Finding in
            guard let file = item["file"] as? String, let kind = item["kind"] as? String, !kind.isEmpty,
                  let group = item["group"] as? String, Handover.validGroup(group) else {
                throw HandoffCLI.Failure(message: "The scan gave a finding that the app does not know. Nothing was released.")
            }
            let line = (item["line"] as? NSNumber)?.intValue ?? 0, col = (item["col"] as? NSNumber)?.intValue ?? 0
            let length = (item["length"] as? NSNumber)?.intValue ?? 0
            var value: String?
            if !Handover.fileKinds.contains(kind), Handover.validManifestPath(file) {
                if contents[file] == nil { contents[file] = Handover.read(file, under: folder) }
                value = Handover.value(file: file, line: line, col: col, length: length, content: contents[file] ?? nil)
            }
            return Finding(file: file, line: line, col: col, length: length, kind: kind,
                           excerpt: item["excerpt_masked"] as? String ?? "", group: group, value: value,
                           valueHash: Handover.sha256(Data((value ?? "\u{0}\(file):\(line):\(col):\(length)").utf8)))
        }
        return (findings, scanned["note"] as? String ?? "")
    }

    /// The kinds of the masked groups in the manifest of the app's copy (`masked: [{group, kind, number, places}]`).
    private func maskedKinds(_ folder: String) -> [String] {
        guard let data = Handover.read("manifest.json", under: folder),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (manifest["masked"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
    }

    // MARK: Review

    /// The groups with a finding in a released file, in scan order.
    var groups: [Group] {
        guard let review else { return [] }
        let included = Set(review.files.filter(\.include).map(\.path))
        var order: [String] = []
        var byGroup: [String: [Finding]] = [:]
        for finding in review.findings where included.contains(finding.file) {
            if byGroup[finding.group] == nil { order.append(finding.group) }
            byGroup[finding.group, default: []].append(finding)
        }
        return order.map { Group(id: $0, kind: byGroup[$0]![0].kind, findings: byGroup[$0]!) }
    }

    func decision(_ group: Group) -> Decision {
        if group.isFileProblem { return .rebuild }
        if masking.contains(group.id) { return .mask }
        if group.canKeep, group.findings.allSatisfy({ kept.contains($0.keepKey) }) { return .keep }
        return .open
    }

    /// The groups that still need the user.
    var openGroups: [Group] { groups.filter { decision($0) == .open || decision($0) == .rebuild } }

    var summaryChanged: Bool { review.map { $0.summary != $0.savedSummary } ?? false }

    var canRelease: Bool { phase == .review && review != nil && openGroups.isEmpty && !summaryChanged }

    func setInclude(_ path: String, _ include: Bool) {
        guard let index = review?.files.firstIndex(where: { $0.path == path }), review?.files[index].isSummary == false else { return }
        review?.files[index].include = include
    }

    func decide(_ groupID: String, _ decision: Decision) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let keys = Set(group.findings.map(\.keepKey))
        switch decision {
        case .keep where group.canKeep:
            masking.remove(group.id)
            kept.formUnion(keys)
        case .mask where group.canMask:
            kept.subtract(keys)
            masking.insert(group.id)
        case .open:
            kept.subtract(keys)
            masking.remove(group.id)
        default:
            return
        }
    }

    /// "Mask All": every group that is not decided yet gets Mask.
    func maskAll() {
        for group in groups where decision(group) == .open && group.canMask { decide(group.id, .mask) }
    }

    /// Builds and scans again, for example after a change in EU mode; the user's choices stay.
    func rebuild() {
        guard let current = review else { return }
        phase = .working("Building and scanning the handover again…")
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let review = try self.buildAndScan(project: current.project, keeping: current)
                DispatchQueue.main.async { self.review = review; self.phase = .review }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Saves the edited summary into the app's copy, then builds and scans again: the edit can add a value.
    func saveSummary() {
        guard var current = review, summaryChanged else { return }
        let text = current.summary
        phase = .working("Scanning the changed summary…")
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard Handover.isRegularFile(current.dir + "/summary.md") else {
                    throw HandoffCLI.Failure(message: "The summary of the handover is not a plain file.")
                }
                try Data(text.utf8).write(to: URL(fileURLWithPath: current.dir + "/summary.md"), options: .atomic)
                current.summaryEdited = true
                let review = try self.buildAndScan(project: current.project, keeping: current)
                DispatchQueue.main.async { self.review = review; self.phase = .review }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func back() {
        review = nil
        kept = []
        masking = []
        refresh()
    }

    // MARK: Release

    /// Masks the groups that the user chose to mask (`handoff mask`), scans again, and releases only when every finding
    /// that is left is one that the user kept. A failure leaves the masks that were made; a retry keeps them.
    func release() {
        guard let current = review, canRelease else { return }
        let toMask = groups.filter { decision($0) == .mask }.map(\.id)
        let keptKeys = kept
        phase = .working(toMask.isEmpty ? "Releasing the handover to Standard mode…" : "Masking and releasing the handover…")
        queue.async { [weak self] in
            guard let self else { return }
            var review = current
            do {
                if !toMask.isEmpty {
                    let (_, masked) = try self.cli.run(["handoff", "mask", current.project, current.id, "--dir", current.dir]
                                                       + toMask.flatMap { ["--group", $0] })
                    guard masked["id"] as? String == current.id, masked["project"] as? String == current.project else {
                        throw HandoffCLI.Failure(message: "The mask answer is for another project or handover. Nothing was released.")
                    }
                    // A mask can change file names, but never the order of the manifest: the user's removed files stay removed.
                    let files = try self.manifestFiles(masked["files"], "Zeus handoff mask")
                    guard files.count == current.files.count else {
                        throw HandoffCLI.Failure(message: "The mask changed the file list. Build the handover again.")
                    }
                    review.files = zip(files, current.files).map { new, old in var file = new; file.include = old.include; return file }
                    review.summary = Handover.read("summary.md", under: current.dir).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    review.savedSummary = review.summary
                    review.maskedKinds = self.maskedKinds(current.dir)
                }
                // The files must be exactly the scanned ones, and every finding that is left must be one that the user kept.
                let (findings, note) = try self.scan(project: current.project, id: current.id, folder: current.dir)
                review.findings = findings
                review.note = note
                let included = Set(review.files.filter(\.include).map(\.path))
                let unseen = findings.filter {
                    included.contains($0.file) && (Handover.fileKinds.contains($0.kind) || Handover.maskOnlyKinds.contains($0.kind) || !keptKeys.contains($0.keepKey))
                }
                if !unseen.isEmpty {
                    DispatchQueue.main.async {
                        self.review = review
                        self.phase = .review
                        self.message = toMask.isEmpty
                            ? "The handover changed after your review. Check the findings again."
                            : "The masks are made. The new scan shows findings to check: decide them, then release again."
                    }
                    return
                }
                let target = try self.copy(review, keptKeys: keptKeys)
                DispatchQueue.main.async {
                    self.review = nil
                    self.phase = .released(target)
                    Trace.log("handover: released \(current.id) of \(current.project) files=\(included.count) masked=\(toMask.count)")
                }
            } catch {
                // Back to the review, with every choice; the masks that were made stay in the handover.
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.review = current
                    self.phase = .failed(message)
                }
            }
        }
    }

    /// After a failed step: back to the review with the user's choices. The handover is scanned again, so masks that
    /// were made show as masked.
    func retry() {
        guard let current = review else { back(); return }
        phase = .working("Scanning the handover again…")
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let review = try self.buildAndScan(project: current.project, keeping: current)
                DispatchQueue.main.async { self.review = review; self.phase = .review }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Off the main queue. Copies the included files of the app's copy, with the hashes of its manifest, into the Standard
    /// workspace, and writes released.json there and in the EU handover folder. Returns the folder in the Standard workspace.
    private func copy(_ review: Review, keptKeys: Set<String>) throws -> String {
        let fail = { (message: String) in HandoffCLI.Failure(message: message) }
        let manager = FileManager.default
        guard Handover.validID(review.id), Handover.validProject(review.project) else { throw fail("The handover id is not valid.") }
        let projectDir = (standardWorkspace as NSString).appendingPathComponent("clients/\(review.project)")
        guard manager.fileExists(atPath: projectDir + "/project.json") else {
            throw fail("Standard mode has no project \(review.project). Make the project in Standard mode with the same project ID, then release again.")
        }
        guard let data = Handover.read("manifest.json", under: review.dir),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              manifest["id"] as? String == review.id, manifest["project"] as? String == review.project,
              let entries = manifest["files"] as? [[String: Any]] else { throw fail("The manifest of the handover can not be read.") }
        var hashes: [String: String] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String, Handover.validManifestPath(path), let sha = entry["sha256"] as? String
            else { throw fail("The manifest names a file that the app does not copy.") }
            hashes[path] = sha
        }
        let chosen = review.files.filter(\.include)
        guard chosen.contains(where: \.isSummary) else { throw fail("The summary must be released.") }
        var contents: [String: Data] = [:]
        for file in chosen {
            guard hashes[file.path] == file.sha256 else { throw fail("\(file.path) is not in the manifest.") }
            guard let content = Handover.read(file.path, under: review.dir), Handover.sha256(content) == file.sha256 else {
                throw fail("\(file.path) changed after the scan. Review the handover again.")
            }
            contents[file.path] = content
        }
        let released = projectDir + "/handoff/from-eu"
        let target = released + "/" + review.id
        guard !manager.fileExists(atPath: target) else { throw fail("This handover is already released in Standard mode.") }
        try manager.createDirectory(atPath: released, withIntermediateDirectories: true)
        let staging = released + "/.zeus-release-\(review.id)-\(UUID().uuidString.prefix(8))"
        try manager.createDirectory(atPath: staging, withIntermediateDirectories: false)
        // Kinds and counts only: a group ID is a hash with the EU-only salt, so it never goes into a Standard record.
        let included = Set(chosen.map(\.path))
        let keptKinds = Dictionary(grouping: Set(review.findings.filter { included.contains($0.file) && keptKeys.contains($0.keepKey) }
            .map { [$0.group, $0.kind] }), by: { $0[1] }).mapValues(\.count)
        let maskedKinds = Dictionary(grouping: review.maskedKinds, by: { $0 }).mapValues(\.count)
        let counts = { (kinds: [String: Int]) in kinds.keys.sorted().map { ["kind": $0, "count": kinds[$0]!] as [String: Any] } }
        let removed = review.files.filter { !$0.include }.map(\.path)
        let record: [String: Any] = [
            "schema": 2,
            "id": review.id,
            "project": review.project,
            "released_at": ISO8601DateFormatter().string(from: Date()),
            "released_by": NSUserName(),
            "released_with": "Zeus app \(Updater.currentVersion)",
            "files": chosen.map { ["path": $0.path, "sha256": $0.sha256, "bytes": $0.bytes] },
            "removed_count": removed.count,
            "kept": counts(keptKinds),
            "masked": counts(maskedKinds),
            "summary_edited_in_app": review.summaryEdited,
            "scan_note": review.note,
        ]
        let json = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        do {
            for file in chosen {
                let destination = staging + "/" + file.path
                try manager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try contents[file.path]!.write(to: URL(fileURLWithPath: destination), options: .withoutOverwriting)
            }
            try json.write(to: URL(fileURLWithPath: staging + "/released.json"), options: .withoutOverwriting)
            try manager.moveItem(atPath: staging, toPath: target)
        } catch {
            try? manager.removeItem(atPath: staging)
            throw error
        }
        // The EU handover folder gets the same record with the removed paths, so that `handoff pending` shows the handover
        // as closed. EU Claude can write that folder, so no part of the path may be a link, and only a new file is written.
        do {
            let euRecord = record.merging(["removed": removed]) { _, new in new }
            let euJSON = try JSONSerialization.data(withJSONObject: euRecord, options: [.prettyPrinted, .sortedKeys])
            try Handover.writeNew(euJSON, "clients/\(review.project)/handoff/\(review.id)/released.json", under: profile.workspace)
        } catch {
            Trace.log("handover: EU record not written: \(error.localizedDescription)")
        }
        return target
    }
}

/// The handover window.
final class HandoverWindowController: NSWindowController, NSWindowDelegate {
    let model: HandoverModel
    var onClosed: (() -> Void)?

    init(model: HandoverModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Hand Over EU Work"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: HandoverView(model: model))
        window.setContentSize(NSSize(width: 980, height: 720))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        onClosed?()
    }
}

struct HandoverView: View {
    @ObservedObject var model: HandoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let message = model.message {
                Text(message).foregroundStyle(Brand.accent).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(24)
        .font(.custom("ObjectSans-Regular", size: 13))
        .background(Brand.background)
        .foregroundStyle(Brand.foreground)
        .tint(Brand.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 580)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("EU").font(.custom("PPObjectSans-Semibold", size: 12)).padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: ModeBarView.euGreen))).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hand over EU work to Standard").font(.custom("PPObjectSans-Semibold", size: 20))
                Text("Only a summary and the files that you release cross to Standard mode. EU chats and other EU files stay in EU mode.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading the EU projects…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .working(text):
            ProgressView(text).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(text):
            VStack(alignment: .leading, spacing: 10) {
                Text(text).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if model.review != nil {
                    Text("Nothing was released. Masks that Zeus already made stay in the handover, and your choices stay.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Back") { model.back() }
                    Spacer()
                    if model.review != nil { Button("Back to the Review") { model.retry() }.keyboardShortcut(.defaultAction) }
                }
            }
            Spacer()
        case .list:
            projectList
        case .review:
            if let review = model.review { reviewView(review) }
        case let .released(path):
            VStack(alignment: .leading, spacing: 10) {
                Text("Released.").font(.custom("PPObjectSans-Semibold", size: 16))
                Text("Standard mode finds the handover in \(EUSetup.display(path)).").fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Hand Over Another Project") { model.back() }
                    Spacer()
                    Button("Switch to Standard") { model.onSwitchToStandard?() }.keyboardShortcut(.defaultAction)
                }
            }
            Spacer()
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 12) {
            box {
                Text("1. Ask Zeus for the summary").fontWeight(.semibold)
                Text("Zeus writes the goal, the decisions, the findings, the open items, the files to hand over, and Zeus feedback, without client data values. Ask in the EU chat of the project.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.chats.isEmpty {
                    Text("No EU chat is open. Open the chat of the project in EU mode, then ask Zeus to write the handover summary.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.chats) { chat in
                        HStack {
                            Text(chat.name)
                            Spacer()
                            Button("Ask Zeus in this chat") { model.ask(chat) }
                        }
                    }
                }
            }
            box {
                HStack {
                    Text("2. Review and release").fontWeight(.semibold)
                    Spacer()
                    Button("Refresh") { model.refresh() }
                }
                if model.projects.isEmpty {
                    Text("Nothing to hand over.").fontWeight(.semibold)
                    Text(model.nothingReason ?? "No EU project has work to hand over.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.projects) { project in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.project)
                                Text(project.open ? "Summary ready" : "No summary yet: ask Zeus in the chat of the project")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review…") { model.open(project.project) }.disabled(!project.open)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private func reviewView(_ review: HandoverModel.Review) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(review.project), handover \(review.id)").fontWeight(.semibold)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary").fontWeight(.semibold)
                    TextEditor(text: Binding(get: { model.review?.summary ?? "" }, set: { model.review?.summary = $0 }))
                        .font(.custom("Menlo", size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.surface))
                    if model.summaryChanged {
                        HStack {
                            Text("Save the change: Zeus scans the summary again.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Revert") { model.review?.summary = review.savedSummary }
                            Button("Save and Scan") { model.saveSummary() }
                        }
                    }
                }
                .frame(minWidth: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        filesBox(review)
                        findingsBox(review)
                    }
                }
                .frame(minWidth: 420)
            }
            HStack {
                Button("Back") { model.back() }
                Spacer()
                releaseNote
                Button(model.groups.contains { model.decision($0) == .mask } ? "Mask and Release" : "Release to Standard") { model.release() }
                    .disabled(!model.canRelease).keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var releaseNote: some View {
        let open = model.openGroups
        if open.contains(where: \.isFileProblem) {
            Text("A file changed after the build or is missing. Click Build Again.").font(.caption).foregroundStyle(.red)
        } else if !open.isEmpty {
            Text("Choose Keep or Mask for \(open.count) more finding\(open.count == 1 ? "" : "s").").font(.caption)
        } else if model.summaryChanged {
            Text("Save or revert the summary first.").font(.caption)
        }
    }

    private func filesBox(_ review: HandoverModel.Review) -> some View {
        box {
            Text("Files").fontWeight(.semibold)
            ForEach(review.files) { file in
                Toggle(isOn: Binding(get: { model.review?.files.first { $0.path == file.path }?.include ?? true },
                                     set: { model.setInclude(file.path, $0) })) {
                    Text(file.path + (file.isSummary ? " (always released)" : "")).font(.custom("Menlo", size: 11))
                }
                .disabled(file.isSummary)
            }
            ForEach(review.skipped, id: \.path) { item in
                Text("Not handed over: \(item.path) (\(item.reason))").font(.caption).foregroundStyle(.secondary)
            }
            if !review.maskedKinds.isEmpty {
                Text("Masked in the handover: \(review.maskedKinds.count) value\(review.maskedKinds.count == 1 ? "" : "s"). Standard mode sees masked-<kind>-<n> in their place.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func findingsBox(_ review: HandoverModel.Review) -> some View {
        let groups = model.groups
        return box {
            HStack {
                Text(groups.isEmpty ? "Scan: no findings" : "Scan findings (\(groups.count))").fontWeight(.semibold)
                Spacer()
                if groups.contains(where: { $0.isFileProblem }) { Button("Build Again") { model.rebuild() } }
                Button("Mask All") { model.maskAll() }
                    .disabled(!groups.contains { model.decision($0) == .open && $0.canMask })
            }
            // The scan's own note says what it can not find; the app's words stand in only when the scan gives none.
            Text(review.note.isEmpty
                 ? "The scan finds values that EU Zeus showed and common data patterns. It does not know values that you typed or that came from a file or a screenshot: read the summary and the files yourself."
                 : review.note)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Keep: not a data value, it crosses as it is. Mask: Zeus replaces it with masked-<kind>-<n> in every file before the release.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(groups) { group in groupRow(group) }
        }
    }

    private func groupRow(_ group: HandoverModel.Group) -> some View {
        let decision = model.decision(group)
        let places = group.findings.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.kindName(group.kind)).fontWeight(.semibold).foregroundStyle(group.isFileProblem || group.maskOnly ? .red : Brand.foreground)
                    .fixedSize()
                Text("\(places) place\(places == 1 ? "" : "s") in \(group.files.count) file\(group.files.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if group.isFileProblem {
                    Text("Build again").font(.caption).foregroundStyle(.red)
                } else {
                    HStack(spacing: 6) {
                        if group.canKeep { choiceButton("Keep", .keep, group, selected: decision == .keep) }
                        choiceButton("Mask", .mask, group, selected: decision == .mask)
                    }
                }
            }
            if group.isFileProblem {
                Text("\(group.files.joined(separator: ", ")): \(group.kind == "missing-file" ? "missing" : "changed after the build"). Build the handover again.")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                // The real value, from the app's copy of the handover: shown so that you can decide, never selectable,
                // never written to a file or a log.
                ForEach(group.values.isEmpty ? ["(the value can not be shown)"] : group.values, id: \.self) { value in
                    Text(value).font(.custom("Menlo", size: 12)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow.opacity(0.18)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(group.findings.prefix(3).enumerated()), id: \.offset) { _, finding in
                    Text("\(finding.file)\(finding.line > 0 ? ":\(finding.line)" : " (file name)")  \(finding.excerpt)")
                        .font(.custom("Menlo", size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                if places > 3 { Text("and \(places - 3) more").font(.caption).foregroundStyle(.secondary) }
                if group.maskOnly {
                    Text("An e-mail address or IBAN can only be masked.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Keep or Mask of a group: the chosen one is filled; a click on the chosen one takes the choice back.
    private func choiceButton(_ title: String, _ choice: HandoverModel.Decision, _ group: HandoverModel.Group, selected: Bool) -> some View {
        Button { model.decide(group.id, selected ? .open : choice) } label: {
            Text(title).font(.custom(selected ? "PPObjectSans-Semibold" : "ObjectSans-Regular", size: 12))
                .frame(minWidth: 58, minHeight: 18, maxHeight: 18).padding(.vertical, 4).padding(.horizontal, 8)
                .foregroundStyle(selected ? Color.white : Brand.foreground)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? (choice == .keep ? Color(nsColor: ModeBarView.euGreen) : Brand.accent) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.clear : Color.primary.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(Self.kindName(group.kind))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "known-value": return "A value that EU Zeus showed"
        case "email": return "E-mail address"
        case "iban": return "IBAN"
        case "phone": return "Phone number"
        case "amount": return "Amount"
        case "date": return "Date"
        case "number": return "Number"
        case "quoted-literal": return "Quoted value"
        case "in-list": return "Value in an IN list"
        case "like-pattern": return "LIKE pattern"
        case "encoded-run": return "Encoded data"
        case "missing-file": return "Missing file"
        case "changed-after-build": return "Changed file"
        default: return kind.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }
}
