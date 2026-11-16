import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// The EU to Standard handover (zeus references/eu-mode.md, "Handover"). EU Claude writes a summary of its work on a fixed
/// template; the app builds the handover and scans it for data values with the Zeus commands of the EU workspace, outside
/// Claude; the user reviews the summary, the files, and each finding here; and on Release the app, not Claude, copies the
/// files into the Standard workspace and writes `released.json`. EU Claude can not write into the Standard workspace, so
/// it can not make a release. A finding is accepted only here, never by Claude, and e-mail and IBAN findings can not be
/// accepted. EU chats and EU work files never open in Standard: only the released files cross.
enum Handover {
    /// The handover id of `handoff build` (`\d{8}T\d{6}Z-[0-9a-f]{6}`).
    static func validID(_ id: String) -> Bool { id.range(of: #"^\d{8}T\d{6}Z-[0-9a-f]{6}$"#, options: .regularExpression) != nil }

    /// A project folder name: no separator, no dot first.
    static func validProject(_ project: String) -> Bool {
        project.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil && !project.contains("..")
    }

    /// A path of the manifest: `summary.md` or a relative path under `files/`, with no `..`, no empty part, and no dot first.
    static func validManifestPath(_ path: String) -> Bool {
        guard path == "summary.md" || path.hasPrefix("files/"), !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0")
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && !$0.hasPrefix(".") }
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A regular file, not a link (lstat).
    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

/// The app contract of the zeus handoff commands (I2): `python3 scripts/zeus.py handoff <command> --json` in the EU
/// workspace. Exit codes: 0 ok, 2 user error, 3 findings (scan), 4 internal error; every answer is one JSON object.
struct HandoffCLI {
    let workspace: String
    let profile: EUProfile

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Off the main queue.
    func run(_ arguments: [String]) throws -> (code: Int32, json: [String: Any]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "scripts/zeus.py", "--workspace", workspace, "handoff"] + arguments + ["--json"]
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
        // Read before the wait: a large answer fills the pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let code = process.terminationStatus
        Trace.log("handoff \(arguments.first ?? "-"): exit \(code)")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let detail = errorText.split(separator: "\n").last.map(String.init) ?? "no answer"
            throw Failure(message: "Zeus handoff \(arguments.first ?? "") did not answer (exit code \(code)): \(detail)")
        }
        if code == 2 || code == 4 || json["status"] as? String == "error" {
            throw Failure(message: json["error"] as? String ?? "Zeus handoff \(arguments.first ?? "") failed (exit code \(code)).")
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

    struct Finding: Identifiable, Equatable {
        var id: String { "\(file):\(line):\(col):\(kind)" }
        let file: String
        let line: Int
        let col: Int
        let kind: String
        let excerpt: String
        let blocking: Bool
        var accepted = false
    }

    struct Review: Equatable {
        let id: String
        let project: String
        let dir: String
        var summary: String
        var savedSummary: String
        var files: [File]
        var skipped: [(path: String, reason: String)]
        var findings: [Finding]
        var note: String
        var summaryEdited = false

        static func == (a: Review, b: Review) -> Bool {
            a.id == b.id && a.summary == b.summary && a.files == b.files && a.findings == b.findings && a.note == b.note
                && a.skipped.map(\.path) == b.skipped.map(\.path)
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
    @Published var chats: [ChatChoice] = []
    @Published var review: Review?
    @Published var message: String?

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
        cli = HandoffCLI(workspace: profile.workspace, profile: profile)
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
                let (_, json) = try self.cli.run(["pending"])
                let list = (json["projects"] as? [[String: Any]] ?? []).compactMap { item -> Project? in
                    guard let project = item["project"] as? String, Handover.validProject(project) else { return nil }
                    return Project(project: project, lastActivity: item["last_eu_activity_at"] as? String,
                                   open: item["has_open_handoff"] as? Bool == true)
                }
                DispatchQueue.main.async {
                    let open = Set(list.filter(\.open).map(\.project))
                    if quiet, !open.subtracting(self.openBefore).isEmpty {
                        self.message = "A handover summary is ready to review."
                    }
                    self.openBefore = open
                    self.projects = list.filter { $0.open || $0.lastActivity != nil }
                    if self.phase == .loading || quiet && self.phase == .list { self.phase = .list }
                }
            } catch {
                DispatchQueue.main.async { if !quiet { self.phase = .failed(error.localizedDescription) } }
            }
        }
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

    /// Off the main queue: `handoff build`, then `handoff scan`. `keeping` carries the user's choices (removed files and
    /// accepted findings) over a new build, for findings that are still the same.
    private func buildAndScan(project: String, keeping old: Review?) throws -> Review {
        let (_, built) = try cli.run(["build", project])
        guard let id = built["id"] as? String, Handover.validID(id), built["project"] as? String == project,
              let dir = built["dir"] as? String else {
            throw HandoffCLI.Failure(message: "Zeus handoff build gave an answer that the app does not know.")
        }
        // The folder must be the handover folder of this project in the EU workspace.
        let expected = (profile.workspace as NSString).appendingPathComponent("clients/\(project)/handoff/\(id)")
        guard (dir as NSString).standardizingPath == (expected as NSString).standardizingPath else {
            throw HandoffCLI.Failure(message: "The handover folder is not in the EU workspace.")
        }
        var files = (built["files"] as? [[String: Any]] ?? []).compactMap { entry -> File? in
            guard let path = entry["path"] as? String, Handover.validManifestPath(path), let sha = entry["sha256"] as? String
            else { return nil }
            return File(path: path, sha256: sha, bytes: (entry["bytes"] as? NSNumber)?.intValue ?? 0)
        }
        guard files.contains(where: \.isSummary) else { throw HandoffCLI.Failure(message: "The handover has no summary.") }
        let skipped = (built["skipped"] as? [[String: Any]] ?? []).map { ($0["path"] as? String ?? "?", $0["reason"] as? String ?? "") }
        let (_, scanned) = try cli.run(["scan", id])
        guard scanned["id"] as? String == id else { throw HandoffCLI.Failure(message: "The scan is of another handover.") }
        var findings = (scanned["findings"] as? [[String: Any]] ?? []).map { item in
            Finding(file: item["file"] as? String ?? "?", line: (item["line"] as? NSNumber)?.intValue ?? 0,
                    col: (item["col"] as? NSNumber)?.intValue ?? 0, kind: item["kind"] as? String ?? "?",
                    excerpt: item["excerpt_masked"] as? String ?? "", blocking: item["blocking"] as? Bool ?? true)
        }
        if let old {
            for index in files.indices { files[index].include = old.files.first { $0.path == files[index].path }?.include ?? true }
            for index in findings.indices where !findings[index].blocking {
                findings[index].accepted = old.findings.first { $0.id == findings[index].id }?.accepted ?? false
            }
        }
        let summary = (try? String(contentsOfFile: dir + "/summary.md", encoding: .utf8)) ?? ""
        return Review(id: id, project: project, dir: dir, summary: summary, savedSummary: summary, files: files,
                      skipped: skipped, findings: findings, note: scanned["note"] as? String ?? "",
                      summaryEdited: old?.summaryEdited ?? false)
    }

    // MARK: Review

    /// The findings that still need the user: in an included file, and not accepted.
    var openFindings: [Finding] {
        guard let review else { return [] }
        let included = Set(review.files.filter(\.include).map(\.path))
        return review.findings.filter { included.contains($0.file) && !$0.accepted }
    }

    var blockingFindings: [Finding] { openFindings.filter(\.blocking) }

    var summaryChanged: Bool { review.map { $0.summary != $0.savedSummary } ?? false }

    var canRelease: Bool { phase == .review && review != nil && openFindings.isEmpty && !summaryChanged }

    func setInclude(_ path: String, _ include: Bool) {
        guard let index = review?.files.firstIndex(where: { $0.path == path }), review?.files[index].isSummary == false else { return }
        review?.files[index].include = include
    }

    func setAccepted(_ id: String, _ accepted: Bool) {
        guard let index = review?.findings.firstIndex(where: { $0.id == id }), review?.findings[index].blocking == false else { return }
        review?.findings[index].accepted = accepted
    }

    /// Saves the edited summary into the handover, then builds and scans again: the edit can add a value.
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
        refresh()
    }

    // MARK: Release

    /// Copies the included files, with the hashes of the manifest, into the Standard workspace, and writes released.json
    /// there and in the EU handover folder. It scans again first: a finding that the user did not see stops the release.
    func release() {
        guard let current = review, canRelease else { return }
        phase = .working("Releasing the handover to Standard mode…")
        queue.async { [weak self] in
            guard let self else { return }
            do {
                // The files must be exactly the scanned ones: a new scan with a finding that the user did not accept stops it.
                let (_, scanned) = try self.cli.run(["scan", current.id])
                let included = Set(current.files.filter(\.include).map(\.path))
                let accepted = Set(current.findings.filter(\.accepted).map(\.id))
                let fresh = (scanned["findings"] as? [[String: Any]] ?? []).map { item in
                    Finding(file: item["file"] as? String ?? "?", line: (item["line"] as? NSNumber)?.intValue ?? 0,
                            col: (item["col"] as? NSNumber)?.intValue ?? 0, kind: item["kind"] as? String ?? "?",
                            excerpt: item["excerpt_masked"] as? String ?? "", blocking: item["blocking"] as? Bool ?? true)
                }
                let unseen = fresh.filter { included.contains($0.file) && ($0.blocking || !accepted.contains($0.id)) }
                if !unseen.isEmpty {
                    let review = try self.buildAndScan(project: current.project, keeping: current)
                    DispatchQueue.main.async {
                        self.review = review
                        self.phase = .review
                        self.message = "The handover changed after your review. Check the findings again."
                    }
                    return
                }
                let target = try self.copy(current)
                DispatchQueue.main.async {
                    self.review = nil
                    self.phase = .released(target)
                    let recorded = current.findings.filter { $0.accepted && included.contains($0.file) }.count
                    Trace.log("handover: released \(current.id) of \(current.project) files=\(included.count) accepted=\(recorded)")
                }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Off the main queue. Returns the folder in the Standard workspace.
    private func copy(_ review: Review) throws -> String {
        let fail = { (message: String) in HandoffCLI.Failure(message: message) }
        let manager = FileManager.default
        guard Handover.validID(review.id), Handover.validProject(review.project) else { throw fail("The handover id is not valid.") }
        let projectDir = (standardWorkspace as NSString).appendingPathComponent("clients/\(review.project)")
        guard manager.fileExists(atPath: projectDir + "/project.json") else {
            throw fail("Standard mode has no project \(review.project). Make the project in Standard mode with the same project ID, then release again.")
        }
        // The manifest of the build decides the hashes; the scan read the same files.
        guard let data = manager.contents(atPath: review.dir + "/manifest.json"),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              manifest["id"] as? String == review.id, manifest["project"] as? String == review.project,
              let entries = manifest["files"] as? [[String: Any]] else { throw fail("The manifest of the handover can not be read.") }
        var hashes: [String: (sha: String, bytes: Int)] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String, Handover.validManifestPath(path), let sha = entry["sha256"] as? String
            else { throw fail("The manifest names a file that the app does not copy.") }
            hashes[path] = (sha, (entry["bytes"] as? NSNumber)?.intValue ?? 0)
        }
        let chosen = review.files.filter(\.include)
        guard chosen.contains(where: \.isSummary) else { throw fail("The summary must be released.") }
        for file in chosen {
            guard let expected = hashes[file.path], expected.sha == file.sha256 else { throw fail("\(file.path) is not in the manifest.") }
            let source = review.dir + "/" + file.path
            guard Handover.isRegularFile(source), Handover.sha256(of: URL(fileURLWithPath: source)) == expected.sha else {
                throw fail("\(file.path) changed after the build. Review the handover again.")
            }
        }
        let released = projectDir + "/handoff/from-eu"
        let target = released + "/" + review.id
        guard !manager.fileExists(atPath: target) else { throw fail("This handover is already released in Standard mode.") }
        try manager.createDirectory(atPath: released, withIntermediateDirectories: true)
        let staging = released + "/.zeus-release-\(review.id)-\(UUID().uuidString.prefix(8))"
        try manager.createDirectory(atPath: staging, withIntermediateDirectories: false)
        do {
            for file in chosen {
                let destination = staging + "/" + file.path
                try manager.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let content = try Data(contentsOf: URL(fileURLWithPath: review.dir + "/" + file.path))
                guard SHA256.hash(data: content).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    throw fail("\(file.path) changed while Zeus copied it. Review the handover again.")
                }
                try content.write(to: URL(fileURLWithPath: destination), options: .withoutOverwriting)
            }
            let record: [String: Any] = [
                "schema": 1,
                "id": review.id,
                "project": review.project,
                "released_at": ISO8601DateFormatter().string(from: Date()),
                "released_by": NSUserName(),
                "released_with": "Zeus app \(Updater.currentVersion)",
                "files": chosen.map { ["path": $0.path, "sha256": $0.sha256, "bytes": $0.bytes] },
                "removed": review.files.filter { !$0.include }.map(\.path),
                "accepted_findings": review.findings.filter { $0.accepted && chosen.map(\.path).contains($0.file) }.map {
                    ["file": $0.file, "line": $0.line, "col": $0.col, "kind": $0.kind, "excerpt_masked": $0.excerpt]
                },
                "summary_edited_in_app": review.summaryEdited,
                "scan_note": review.note,
            ]
            let json = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: URL(fileURLWithPath: staging + "/released.json"), options: .withoutOverwriting)
            try manager.moveItem(atPath: staging, toPath: target)
            // The EU folder gets the same record, so that `handoff pending` shows the handover as closed.
            try? json.write(to: URL(fileURLWithPath: review.dir + "/released.json"), options: .withoutOverwriting)
        } catch {
            try? manager.removeItem(atPath: staging)
            throw error
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Hand Over EU Work"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: HandoverView(model: model))
        window.setContentSize(NSSize(width: 920, height: 700))
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
        .frame(minWidth: 760, minHeight: 560)
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
                HStack { Button("Back") { model.back() }; Spacer() }
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
                Text("Zeus writes the goal, the decisions, the open items, the files to hand over, and Zeus feedback, without client data values. Ask in the EU chat of the project.")
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
                    Text("No EU project has work to hand over.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.projects) { project in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.project)
                                Text(project.open ? "Summary ready" : "No summary yet").font(.caption).foregroundStyle(.secondary)
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
                .frame(minWidth: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        filesBox(review)
                        findingsBox(review)
                    }
                }
                .frame(minWidth: 360)
            }
            Text(review.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { model.back() }
                Spacer()
                if !model.blockingFindings.isEmpty {
                    Text("An e-mail address, IBAN, or changed file blocks the release. Change it in EU mode or remove the file.")
                        .font(.caption).foregroundStyle(.red)
                } else if !model.openFindings.isEmpty {
                    Text("\(model.openFindings.count) finding\(model.openFindings.count == 1 ? "" : "s") to check.").font(.caption)
                }
                Button("Release to Standard") { model.release() }.disabled(!model.canRelease).keyboardShortcut(.defaultAction)
            }
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
        }
    }

    private func findingsBox(_ review: HandoverModel.Review) -> some View {
        let included = Set(review.files.filter(\.include).map(\.path))
        let shown = review.findings.filter { included.contains($0.file) }
        return box {
            Text(shown.isEmpty ? "Scan: no findings" : "Scan findings (\(shown.count))").fontWeight(.semibold)
            Text("The scan finds values that EU Zeus showed and common data patterns. It does not know values that you typed or that came from a file or a screenshot: read the summary and the files yourself.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(shown) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(finding.file)\(finding.line > 0 ? ":\(finding.line)" : " (file name)") · \(finding.kind)")
                        .font(.caption).foregroundStyle(finding.blocking ? .red : .secondary)
                    Text(finding.excerpt.isEmpty ? "-" : finding.excerpt).font(.custom("Menlo", size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    if finding.blocking {
                        Text("Can not be accepted. Change it in EU mode, or remove the file.").font(.caption).foregroundStyle(.red)
                    } else {
                        Toggle("Not a data value", isOn: Binding(
                            get: { model.review?.findings.first { $0.id == finding.id }?.accepted ?? false },
                            set: { model.setAccepted(finding.id, $0) }))
                            .font(.caption)
                    }
                }
                .padding(.vertical, 3)
            }
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
