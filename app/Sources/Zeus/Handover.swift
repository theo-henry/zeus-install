import AppKit
import Combine
import SwiftUI

/// The EU to Standard handover through the Zeus command line of the EU workspace (zeus references/eu-mode.md, "Handover").
/// The app is not a Claude Code session: it builds, scans, and masks a handover there, and only the app releases one.
///
/// The calls, each `python3 <EU workspace>/scripts/zeus.py --workspace <EU workspace> handoff <arguments> --json` in the EU workspace,
/// with one JSON object on stdout:
/// - `pending`: `{projects: [{project, last_eu_activity_at, has_open_handoff}]}`
/// - `build <project>`: `{id, dir, files: [{path, sha256, bytes}], summary_path, skipped: [{path, reason}]}`
/// - `scan <id>`: `{id, clean, findings: [{file, line, col, length, kind, excerpt_masked, blocking, group}], note}`; exit 3 with findings.
/// - `mask <id> --group <g> ...`: `{id, files, masked: [{group, kind, number, places}]}`
/// An error prints `{status: "error", error}` with exit code 2 (user error) or 4 (internal error).
enum HandoverCLI {
    struct Failure: Error, Equatable {
        let message: String
    }

    struct Pending: Equatable {
        let project: String
        let lastActivity: Date?
        let open: Bool
    }

    struct File: Equatable {
        let path: String
        let sha256: String
        let bytes: Int
    }

    struct Built: Equatable {
        let id: String
        let dir: String
        let files: [File]
        let skipped: [(path: String, reason: String)]

        static func == (lhs: Built, rhs: Built) -> Bool { lhs.id == rhs.id && lhs.files == rhs.files }
    }

    struct Finding: Equatable {
        let file: String
        let line: Int
        /// 1-based, in characters (Unicode scalars, as Python counts them); in a file name, counted without "files/".
        let col: Int
        let length: Int
        let kind: String
        let excerpt: String
        let blocking: Bool
        let group: String
    }

    struct Scan: Equatable {
        let clean: Bool
        let findings: [Finding]
        let note: String
    }

    /// The kinds of a finding about a whole file, not a value: only a new build clears them (handoff_scan.FILE_KINDS).
    static let fileKinds: Set<String> = ["missing-file", "changed-after-build"]

    private static var python: String { ProcessInfo.processInfo.environment["ZEUS_APP_PYTHON"] ?? "python3" }
    static var workspace: String { ZeusMode.eu.workspace }
    private static var script: String { workspace + "/scripts/zeus.py" }

    /// The environment of a call: the app's, without any variable that would make it look like a Claude Code session.
    private static var environment: [String: String] {
        var env = ShellEnvironment.make()
        for key in env.keys where key.hasPrefix("CLAUDE") || key == "ZEUS_SESSION_ID" { env.removeValue(forKey: key) }
        return env
    }

    /// Runs one call and reads its JSON. Blocks: call it off the main queue. `findingsOK`: exit 3 is an answer (scan).
    static func call(_ arguments: [String], timeout: TimeInterval, findingsOK: Bool = false) -> Result<[String: Any], Failure> {
        let what = (["handoff"] + arguments.prefix(1)).joined(separator: " ")
        guard FileManager.default.fileExists(atPath: script) else {
            return .failure(Failure(message: "The EU Zeus workspace has no scripts/zeus.py (\(workspace)). Run the Zeus setup."))
        }
        Trace.log("handover call: \(what)")
        guard let run = Shell.run("/usr/bin/env", [python, script, "--workspace", workspace, "handoff"] + arguments + ["--json"],
                                  environment: environment, directory: workspace, timeout: timeout) else {
            return .failure(Failure(message: "Zeus did not answer within \(Int(timeout)) s (\(what)). Try again."))
        }
        let object = json(run.output)
        if run.status == 0 || (findingsOK && run.status == 3), let object {
            return .success(object)
        }
        if let error = object?["error"] as? String { return .failure(Failure(message: error)) }
        let detail = run.errors.split(separator: "\n").suffix(3).joined(separator: " ")
        return .failure(Failure(message: "Zeus stopped with exit code \(run.status) (\(what)). \(detail)"))
    }

    /// The output as one JSON object (the handoff commands print it indented).
    private static func json(_ text: String) -> [String: Any]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func pending() -> Result<[Pending], Failure> {
        call(["pending"], timeout: 30).map { object in
            (object["projects"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let project = entry["project"] as? String, !project.isEmpty else { return nil }
                return Pending(project: project, lastActivity: (entry["last_eu_activity_at"] as? String).flatMap(Self.date),
                               open: entry["has_open_handoff"] as? Bool == true)
            }
        }
    }

    static func build(_ project: String) -> Result<Built, Failure> {
        call(["build", project], timeout: 120).flatMap { object in
            guard let id = object["id"] as? String, let dir = object["dir"] as? String else {
                return .failure(Failure(message: "The build of \(project) gave no handover ID."))
            }
            return .success(Built(id: id, dir: dir, files: files(object),
                                  skipped: (object["skipped"] as? [[String: Any]] ?? []).map {
                                      (path: $0["path"] as? String ?? "", reason: $0["reason"] as? String ?? "")
                                  }))
        }
    }

    static func scan(_ id: String) -> Result<Scan, Failure> {
        call(["scan", id], timeout: 120, findingsOK: true).map { object in
            let findings = (object["findings"] as? [[String: Any]] ?? []).map { item in
                Finding(file: item["file"] as? String ?? "", line: item["line"] as? Int ?? 0, col: item["col"] as? Int ?? 0,
                        length: item["length"] as? Int ?? 0, kind: item["kind"] as? String ?? "finding",
                        excerpt: item["excerpt_masked"] as? String ?? "", blocking: item["blocking"] as? Bool ?? true,
                        group: item["group"] as? String ?? "")
            }
            return Scan(clean: object["clean"] as? Bool ?? findings.isEmpty, findings: findings, note: object["note"] as? String ?? "")
        }
    }

    static func mask(_ id: String, groups: [String]) -> Result<[File], Failure> {
        call(["mask", id] + groups.flatMap { ["--group", $0] }, timeout: 120).map(files)
    }

    private static func files(_ object: [String: Any]) -> [File] {
        (object["files"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = entry["path"] as? String, let sha = entry["sha256"] as? String else { return nil }
            return File(path: path, sha256: sha, bytes: entry["bytes"] as? Int ?? 0)
        }
    }

    /// An ISO time of Zeus or the app; Python's microseconds are dropped first.
    static func date(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// The time of the latest handover that the app released for this project (EU side), or nil.
    static func lastRelease(_ project: String) -> Date? {
        let folder = workspace + "/clients/\(project)/handoff"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.compactMap { name -> Date? in
            guard let data = FileManager.default.contents(atPath: folder + "/\(name)/released.json"),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let at = object["released_at"] as? String else { return nil }
            return date(at)
        }.max()
    }
}

// MARK: - One project's handover

/// The user's choice for one finding group.
enum HandoverChoice: Equatable { case keep, mask }

/// The findings of one kind and value, in every file: one Keep or Mask choice.
struct FindingGroup: Identifiable, Equatable {
    let id: String
    let kind: String
    let places: [HandoverCLI.Finding]
    var blocking: Bool { places.contains(where: \.blocking) }
    /// A file that changed after the build, or is missing: no choice, only a new build.
    var fileLevel: Bool { HandoverCLI.fileKinds.contains(kind) }
    var files: [String] { Array(Set(places.map(\.file))).sorted() }
    /// The file names without their folders, for the sheet.
    var fileNames: [String] { Array(Set(places.map { ($0.file as NSString).lastPathComponent })).sorted() }
    /// The value in its line, read from the handover's copy: the consultant decides on what they see.
    /// The app shows it on this Mac only; the scan's own output stays masked.
    var preview: Preview?

    struct Preview: Equatable {
        let before: String
        let value: String
        let after: String
    }

    /// The text around the first place of the group, with the value apart. Nil when the copy no longer has it.
    static func preview(of finding: HandoverCLI.Finding, in dir: String) -> Preview? {
        guard finding.col > 0, finding.length > 0 else { return nil }
        let text: String
        if finding.line == 0 {
            text = finding.file.hasPrefix("files/") ? String(finding.file.dropFirst(6)) : finding.file
        } else {
            guard let data = FileManager.default.contents(atPath: dir + "/" + finding.file) else { return nil }
            // Python's splitlines: each line without its line end.
            let lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false,
                                                                     whereSeparator: { $0.isNewline }).map(String.init)
            guard finding.line <= lines.count else { return nil }
            text = lines[finding.line - 1]
        }
        let scalars = Array(text.unicodeScalars)
        let start = finding.col - 1, end = start + finding.length
        guard end <= scalars.count else { return nil }
        func string(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(scalars[range])) }
        var before = string(max(0, start - 40) ..< start), after = string(end ..< min(scalars.count, end + 40))
        if start > 40 { before = "…" + before.drop(while: { $0 != " " }) }
        if scalars.count > end + 40 { after += "…" }
        return Preview(before: before.trimmingCharacters(in: .whitespaces) == "" ? "" : before, value: string(start ..< end), after: after)
    }

    static func groups(_ findings: [HandoverCLI.Finding]) -> [FindingGroup] {
        var order: [String] = []
        var byGroup: [String: [HandoverCLI.Finding]] = [:]
        for finding in findings {
            let key = finding.group.isEmpty ? "\(finding.kind):\(finding.file):\(finding.line)" : finding.group
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(finding)
        }
        return order.map { FindingGroup(id: $0, kind: byGroup[$0]![0].kind, places: byGroup[$0]!, preview: nil) }
    }
}

final class ProjectHandover: ObservableObject, Identifiable {
    let project: String
    var id: String { project }
    /// The project has EU work newer than its last release, but no handover summary: EU Claude writes it first.
    let needsSummary: Bool
    @Published var built: HandoverCLI.Built? { didSet { files = built?.files ?? [] } }
    /// The handover's files as they are now: those of the build, or those that the last mask returned.
    var files: [HandoverCLI.File] = []
    /// The groups that Zeus has masked already: a later Release sends only the others.
    var appliedMasks: [FindingGroup] = []
    @Published var scan: HandoverCLI.Scan?
    @Published var groups: [FindingGroup] = []
    @Published var choices: [String: HandoverChoice] = [:]

    init(project: String, needsSummary: Bool) {
        self.project = project
        self.needsSummary = needsSummary
    }

    func update(scan: HandoverCLI.Scan) {
        self.scan = scan
        groups = FindingGroup.groups(scan.findings).map { group in
            var group = group
            if let dir = built?.dir, let first = group.places.first { group.preview = FindingGroup.preview(of: first, in: dir) }
            return group
        }
        // A choice stays for a group that the new scan still shows; e-mail and IBAN groups can only be masked.
        choices = choices.filter { key, choice in groups.contains { $0.id == key && !$0.fileLevel && (choice == .mask || !$0.blocking) } }
    }

    var undecided: Int { groups.filter { !$0.fileLevel && choices[$0.id] == nil }.count }
    var needsBuild: Bool { groups.contains(where: \.fileLevel) }
    var ready: Bool { built != nil && scan != nil && undecided == 0 && !needsBuild }

    func maskAll() {
        for group in groups where !group.fileLevel { choices[group.id] = .mask }
    }

    var summaryPath: String? { built.map { $0.dir + "/summary.md" } }
}

// MARK: - The flow

/// The switch from EU to Standard: the app hands over the EU work before the EU sessions stop.
/// It checks which projects have EU work to hand over; with none, the switch goes on at once. Otherwise the tab shows the handover
/// step on the loading screen while Zeus builds and scans each handover, then the release sheet: one Keep or Mask choice per finding
/// group, then Release, which masks, scans again, copies the files into the Standard workspace, and switches. Nothing switches by itself.
final class HandoverFlow {
    enum Outcome { case noHandoverNeeded, switchNow, stay, askSummary(project: String) }

    /// The message that the app puts into the EU chat's message box when a project has no summary; the user sends it.
    static func summaryRequest(_ project: String) -> String {
        "Write the handover summary for project \(project), so that I can switch to Standard. Run `python3 scripts/zeus.py handoff summary \(project)`, "
            + "fill every section without client data values (no names, IDs, amounts, or dates of records): put what we learned about the data, "
            + "the model, and the process under Findings, and list the files that Standard needs under Artifacts. Then save it with --input."
    }

    static let title = "Handing off data securely"
    static let subtitle = "Removing and aggregating sensitive information"

    private(set) weak var tab: ChatTab?
    private(set) weak var window: NSWindow?
    private var overlay: LoaderOverlay?
    private var completion: ((Outcome) -> Void)?
    private let queue = DispatchQueue(label: "io.github.theo-henry.zeus.handover", qos: .userInitiated)
    private var ended = false
    private var projects: [ProjectHandover] = []
    private var sheet: HandoverSheet?
    private var stageCount = 0

    init(tab: ChatTab?, window: NSWindow?) {
        self.tab = tab
        self.window = window ?? tab?.view.window
    }

    func start(completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        Trace.log("handover: pending check")
        queue.async { [weak self] in
            let pending = HandoverCLI.pending()
            let result = pending.map { pending in
                pending.compactMap { entry -> ProjectHandover? in
                    if entry.open { return ProjectHandover(project: entry.project, needsSummary: false) }
                    // EU work after the last release (or with no release yet) and no summary for it.
                    guard let last = entry.lastActivity else { return nil }
                    if let released = HandoverCLI.lastRelease(entry.project), released >= last { return nil }
                    return ProjectHandover(project: entry.project, needsSummary: true)
                }
            }
            let reason = (try? pending.get()).map(Self.nothingReason) ?? ""
            DispatchQueue.main.async {
                self?.nothingReason = reason
                self?.pendingEnded(result)
            }
        }
    }

    /// The tab closed: nothing more happens.
    func cancel() {
        guard !ended else { return }
        ended = true
        Trace.log("handover: cancelled")
        sheet?.close()
        overlay?.remove(over: 0.1)
        overlay = nil
        completion = nil
    }

    /// Why nothing needs to cross, for the last line of the handover step.
    private var nothingReason = ""

    /// "no project was used, so these EU chats stay in EU", or "everything was handed over already (16 Nov, 18:40)".
    static func nothingReason(_ pending: [HandoverCLI.Pending]) -> String {
        if pending.isEmpty {
            return "no project was used, so these EU chats stay in EU"
        }
        let released = pending.compactMap { HandoverCLI.lastRelease($0.project) }.max()
        if let released {
            let format = DateFormatter()
            format.dateFormat = "d MMM, HH:mm"
            return "everything was handed over already (\(format.string(from: released)))"
        }
        return "the EU projects have no work to hand over"
    }

    /// The handover step plays also when nothing needs to cross: its last line says so and why; then Standard starts.
    private func showNothing() {
        guard tab != nil else { finish(.noHandoverNeeded); return }
        showStep()
        stage("Checking the EU work")
        Trace.log("handover: no work: \(nothingReason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, !self.ended else { return }
            self.stage("No work to hand over: \(self.nothingReason)")
            self.overlay?.markStage(self.stageCount - 1, "done")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.finish(.noHandoverNeeded) }
        }
    }

    private func pendingEnded(_ result: Result<[ProjectHandover], HandoverCLI.Failure>) {
        guard !ended else { return }
        switch result {
        case let .failure(failure):
            Trace.log("handover: pending failed: \(failure.message)")
            showSheet(error: failure.message)
        case let .success(found) where found.isEmpty:
            Trace.log("handover: nothing to hand over")
            showNothing()
        case let .success(found):
            Trace.log("handover: \(found.map { "\($0.project)\($0.needsSummary ? "(no summary)" : "")" }.joined(separator: " "))")
            projects = found
            let building = found.filter { !$0.needsSummary }
            if building.isEmpty { showSheet(error: nil); return }
            showStep()
            run(building, index: 0)
        }
    }

    private func showStep() {
        guard let tab else { return }
        let overlay = LoaderOverlay(frame: tab.webView.frame, status: "")
        tab.cover(with: overlay.view)
        overlay.beginHandoff(title: Self.title, subtitle: Self.subtitle)
        self.overlay = overlay
    }

    private func stage(_ label: String) {
        if stageCount > 0 { overlay?.markStage(stageCount - 1, "done") }
        overlay?.addStage(label)
        overlay?.markStage(stageCount, "active")
        stageCount += 1
    }

    private func run(_ building: [ProjectHandover], index: Int) {
        guard !ended else { return }
        guard index < building.count else {
            if stageCount > 0 { overlay?.markStage(stageCount - 1, "done") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showSheet(error: nil) }
            return
        }
        let handover = building[index]
        overlay?.clearStages(group: building.count > 1 ? handover.project : nil)
        stageCount = 0
        stage("Collecting the EU work")
        queue.async { [weak self] in
            let built = HandoverCLI.build(handover.project)
            DispatchQueue.main.async { self?.stage("Scanning every file and file name for data values") }
            let scanned = built.flatMap { result in HandoverCLI.scan(result.id).map { scan in (result, scan) } }
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                switch scanned {
                case let .failure(failure):
                    Trace.log("handover: \(handover.project) failed: \(failure.message)")
                    self.overlay?.markStage(max(0, self.stageCount - 1), "failed")
                    self.showSheet(error: "\(handover.project): \(failure.message)")
                case let .success((built, scan)):
                    handover.built = built
                    handover.update(scan: scan)
                    Trace.log("handover: \(handover.project) built \(built.id) files=\(built.files.count) findings=\(scan.findings.count) groups=\(handover.groups.count)")
                    self.stage(scan.clean ? "No data values found" : "Grouping \(handover.groups.count) finding\(handover.groups.count == 1 ? "" : "s") for your review")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.run(building, index: index + 1) }
                }
            }
        }
    }

    // MARK: The sheet

    private func showSheet(error: String?) {
        guard !ended else { return }
        let model = HandoverModel(projects: projects, error: error)
        model.onRelease = { [weak self] in self?.release() }
        model.onOpenSummary = { path in NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        model.onAskSummary = { [weak self] project in self?.finish(.askSummary(project: project)) }
        model.onContinue = { [weak self] in
            Trace.log("handover: continue without handover")
            self?.finish(.switchNow)
        }
        model.onStay = { [weak self] in
            Trace.log("handover: stay in EU")
            self?.finish(.stay)
        }
        let sheet = HandoverSheet(model: model)
        self.sheet = sheet
        sheet.present(on: window)
        Trace.log("handover: sheet shown projects=\(projects.count) groups=\(projects.reduce(0) { $0 + $1.groups.count })")
    }

    /// Masks the masked groups, scans again, and releases every handover; then switches. A changed scan shows again for review.
    private func release() {
        guard let model = sheet?.model, model.canRelease else { return }
        model.releasing = true
        model.error = nil
        let work = projects.filter { $0.built != nil && !model.released.contains($0.project) }.map { handover in
            let applied = Set(handover.appliedMasks.map(\.id))
            return (handover, handover.files, handover.appliedMasks,
                    handover.groups.filter { handover.choices[$0.id] == .mask && !applied.contains($0.id) }.sorted { $0.id < $1.id },
                    Set(handover.choices.filter { $0.value == .keep }.map(\.key)))
        }
        queue.async { [weak self] in
            var failure: String?
            var changed: [(ProjectHandover, HandoverCLI.Scan)] = []
            var maskedNow: [(ProjectHandover, [HandoverCLI.File], [FindingGroup])] = []
            var released: [String] = []
            for (handover, current, applied, toMask, kept) in work {
                guard let built = handover.built else { continue }
                var files = current
                var masked = applied
                if !toMask.isEmpty {
                    switch HandoverCLI.mask(built.id, groups: toMask.map(\.id)) {
                    case let .success(after):
                        files = after
                        masked += toMask
                        maskedNow.append((handover, after, toMask))
                    case let .failure(error): failure = "\(handover.project): \(error.message)"
                    }
                }
                if failure != nil { break }
                switch HandoverCLI.scan(built.id) {
                case let .failure(error):
                    failure = "\(handover.project): \(error.message)"
                case let .success(scan):
                    // After masking, every finding left must be one that the user kept.
                    let left = Set(scan.findings.map(\.group))
                    if !left.isSubset(of: kept) || scan.findings.contains(where: { $0.blocking || HandoverCLI.fileKinds.contains($0.kind) }) {
                        changed.append((handover, scan))
                        continue
                    }
                    let record = HandoverRelease(project: handover.project, built: built, files: files,
                                                 kept: handover.groups.filter { kept.contains($0.id) }, masked: masked)
                    do {
                        try record.write()
                        released.append(handover.project)
                        Trace.log("handover: released \(handover.project) \(built.id) files=\(files.count) kept=\(kept.count) masked=\(masked.count)")
                    } catch {
                        failure = "\(handover.project): \(error.localizedDescription)"
                    }
                }
                if failure != nil { break }
            }
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                model.releasing = false
                model.released += released
                for (handover, files, groups) in maskedNow {
                    handover.files = files
                    handover.appliedMasks += groups
                }
                for (handover, scan) in changed { handover.update(scan: scan) }
                if let failure {
                    Trace.log("handover: release failed: \(failure)")
                    model.error = failure
                } else if !changed.isEmpty {
                    model.error = "The scan changed after masking. Decide the groups that are shown again, then release."
                } else {
                    self.finish(.switchNow)
                }
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !ended else { return }
        ended = true
        sheet?.close()
        sheet = nil
        let overlay = self.overlay
        self.overlay = nil
        let completion = self.completion
        self.completion = nil
        Trace.log("handover: outcome \(outcome)")
        completion?(outcome)
        overlay?.remove(over: 0.35)
    }

    #if DEBUG
    /// Test actions: the buttons of the sheet. "keep" and "mask" decide every open group.
    func testPress(_ button: String) {
        guard let model = sheet?.model else { Trace.log("handover: no sheet to press"); return }
        switch button {
        case "release": model.canRelease ? model.onRelease?() : Trace.log("handover: release is disabled")
        case "state": Trace.log("handover: sheet state undecided=\(model.undecided) release=\(model.canRelease ? "on" : "off") redraws=\(model.redraws)")
        case "continue": model.onContinue?()
        case "stay": model.onStay?()
        // As clicks on the rows: each choice changes only its project, so the sheet must follow it by itself.
        case "mask":
            for project in model.projects { for group in project.groups where !group.fileLevel { project.choices[group.id] = .mask } }
        case "keep":
            for project in model.projects { for group in project.groups where !group.fileLevel && !group.blocking { project.choices[group.id] = .keep } }
        default: break
        }
    }
    #endif
}

/// The release of one handover: the manifest's files, unchanged since the scan, copied into the Standard workspace
/// (clients/<project>/handoff/from-eu/<id>/), with released.json there and in the EU handover folder. Groups and kinds only, never a value.
struct HandoverRelease {
    let project: String
    let built: HandoverCLI.Built
    let files: [HandoverCLI.File]
    let kept: [FindingGroup]
    let masked: [FindingGroup]

    static var standardWorkspace: String { ZeusMode.standard.workspace }

    func write() throws {
        let manager = FileManager.default
        let source = URL(fileURLWithPath: built.dir)
        let target = URL(fileURLWithPath: Self.standardWorkspace + "/clients/\(project)/handoff/from-eu/\(built.id)")
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(built.id).partial")
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in files {
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
                throw NSError(domain: "Zeus", code: 1, userInfo: [NSLocalizedDescriptionKey: "The handover names a file outside its folder: \(file.path)."])
            }
            let data = try Data(contentsOf: source.appendingPathComponent(file.path))
            guard Self.sha256(data) == file.sha256 else {
                throw NSError(domain: "Zeus", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(file.path) changed after the scan, so it was not released. Switch again to build and scan it again."])
            }
            let copy = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: copy)
        }
        let record: [String: Any] = [
            "id": built.id, "project": project, "released_at": ISO8601DateFormatter().string(from: Date()),
            "files": files.map { ["path": $0.path, "sha256": $0.sha256, "bytes": $0.bytes] },
            "kept": kept.map { ["group": $0.id, "kind": $0.kind] },
            "masked": masked.map { ["group": $0.id, "kind": $0.kind] },
        ]
        let json = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: staging.appendingPathComponent("released.json"))
        try? manager.removeItem(at: target)
        try manager.moveItem(at: staging, to: target)
        // The EU side: handoff pending then shows the handover as closed.
        try json.write(to: source.appendingPathComponent("released.json"))
    }

    static func sha256(_ data: Data) -> String { SHA256Hex.digest(data) }
}

// MARK: - The sheet

final class HandoverModel: ObservableObject {
    let projects: [ProjectHandover]
    @Published var error: String?
    @Published var releasing = false
    @Published var released: [String] = []
    var onRelease: (() -> Void)?
    var onOpenSummary: ((String) -> Void)?
    var onAskSummary: ((String) -> Void)?
    var onContinue: (() -> Void)?
    var onStay: (() -> Void)?

    /// A Keep or Mask click changes one project; the sheet's counts and the Release button follow it.
    private var projectChanges: [AnyCancellable] = []

    init(projects: [ProjectHandover], error: String?) {
        self.projects = projects
        self.error = error
        projectChanges = projects.map { project in
            project.objectWillChange.sink { [weak self] _ in
                self?.redraws += 1
                self?.objectWillChange.send()
            }
        }
    }

    /// How often the sheet was told to redraw (for the test actions).
    var redraws = 0

    var building: [ProjectHandover] { projects.filter { $0.built != nil } }
    var undecided: Int { building.reduce(0) { $0 + $1.undecided } }
    var findings: Int { building.reduce(0) { $0 + $1.groups.count } }
    var canRelease: Bool { !releasing && !building.isEmpty && building.allSatisfy(\.ready) && projects.allSatisfy { $0.built != nil || $0.needsSummary } }

    var title: String {
        if building.isEmpty && projects.contains(where: \.needsSummary) { return "Write the handover summary first" }
        if error != nil && building.isEmpty { return "The handover did not complete" }
        if findings > 0 { return "Review what crosses to Standard" }
        return "Handover ready"
    }

    var subtitle: String {
        if building.isEmpty && projects.contains(where: \.needsSummary) {
            return "EU Claude writes what it learned, without client data values. Then switch again."
        }
        if findings > 0 {
            return "Check each value. Keep it when it is not client data; Mask replaces it in what crosses. Nothing in EU changes."
        }
        return "The summary and the listed files cross to Standard. EU chats and work files stay in EU."
    }
}

final class HandoverSheet {
    let model: HandoverModel
    private let window: NSWindow
    private weak var parent: NSWindow?

    init(model: HandoverModel) {
        self.model = model
        let hosting = NSHostingView(rootView: HandoverView(model: model))
        hosting.frame.size = hosting.fittingSize
        window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 13/255, green: 42/255, blue: 78/255, alpha: 1)
        window.title = "Handover to Standard"
        window.contentView = hosting
    }

    func present(on parent: NSWindow?) {
        self.parent = parent
        if let parent { parent.beginSheet(window) } else { window.center(); Front.show(window); Front.activate() }
    }

    func close() {
        if let parent, parent.attachedSheet === window { parent.endSheet(window) } else { window.orderOut(nil) }
    }
}

private enum HandoverColors {
    static let ok = Color(red: 142/255, green: 227/255, blue: 200/255)
    static let warn = Color(red: 1, green: 210/255, blue: 138/255)
    static let bad = Color(red: 1, green: 107/255, blue: 114/255)
    static let dim = Color(red: 169/255, green: 189/255, blue: 213/255)
    static let card = Color(red: 11/255, green: 37/255, blue: 69/255)
    static let well = Color(red: 7/255, green: 29/255, blue: 56/255)
    static let line = Color(red: 26/255, green: 58/255, blue: 100/255)
    static let link = Color(red: 91/255, green: 140/255, blue: 1)
}

private struct HandoverView: View {
    @ObservedObject var model: HandoverModel

    private var state: (symbol: String, color: Color) {
        if model.error != nil { return ("exclamationmark.triangle.fill", HandoverColors.bad) }
        if !model.canRelease { return ("exclamationmark.shield.fill", HandoverColors.warn) }
        return ("checkmark.shield.fill", HandoverColors.ok)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: state.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(state.color)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(state.color.opacity(0.14)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).font(.custom("PPObjectSans-Semibold", size: 17))
                    Text(model.subtitle).foregroundStyle(HandoverColors.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if model.findings > 0 {
                    Button("Mask all") { model.projects.forEach { $0.maskAll() }; model.objectWillChange.send() }
                        .buttonStyle(HandoverButtonStyle())
                        .disabled(model.releasing)
                }
            }
            if !model.projects.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.projects) { project in ProjectCard(project: project, model: model) }
                    }
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { errorBox(error) }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if model.undecided > 0 {
                        Text("\(model.undecided) to decide").foregroundStyle(HandoverColors.warn)
                    }
                    Spacer()
                    Button("Stay in EU") { model.onStay?() }
                        .buttonStyle(HandoverButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.releasing)
                    if !model.building.isEmpty {
                        Button { model.onRelease?() } label: {
                            HStack(spacing: 6) {
                                if model.releasing { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
                                Text(model.releasing ? "Releasing…" : "Release and switch to Standard")
                            }
                        }
                        .buttonStyle(HandoverButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canRelease)
                    }
                }
                HStack(spacing: 6) {
                    Button("Switch without a handover") { model.onContinue?() }
                        .buttonStyle(.plain)
                        .foregroundStyle(HandoverColors.link)
                        .disabled(model.releasing)
                    Text("Standard starts without the EU work.").foregroundStyle(HandoverColors.dim.opacity(0.8))
                }
                .font(.custom("ObjectSans-Regular", size: 12))
            }
        }
        .padding(24)
        .frame(width: 640)
        .font(.custom("ObjectSans-Regular", size: 13))
        .foregroundStyle(Brand.foreground)
        .background(Color(red: 13/255, green: 42/255, blue: 78/255))
    }

    private func errorBox(_ error: String) -> some View {
        Text(error)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(HandoverColors.bad.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HandoverColors.bad.opacity(0.4)))
    }
}

private struct ProjectCard: View {
    @ObservedObject var project: ProjectHandover
    @ObservedObject var model: HandoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project.project).font(.custom("PPObjectSans-Semibold", size: 14))
                Spacer()
                badge
            }
            if project.needsSummary {
                Text("This project has EU work without a handover summary. EU Claude writes it: the goal, the decisions, what it learned about the data and the model, the open items, and the files to hand over, without client data values.")
                    .foregroundStyle(HandoverColors.dim).fixedSize(horizontal: false, vertical: true)
                Button("Ask EU Claude to write it") { model.onAskSummary?(project.project) }
                    .buttonStyle(HandoverButtonStyle())
            } else if let built = project.built {
                HStack(spacing: 14) {
                    Text(crossing(built)).foregroundStyle(HandoverColors.dim)
                        .help(built.skipped.isEmpty ? "" : "Left out: " + built.skipped.map { "\(($0.path as NSString).lastPathComponent) (\($0.reason))" }.joined(separator: "; "))
                    if let path = project.summaryPath {
                        Button("Read the summary") { model.onOpenSummary?(path) }
                            .buttonStyle(.plain).foregroundStyle(HandoverColors.link)
                    }
                    Spacer()
                }
                if !project.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(project.groups) { group in GroupRow(group: group, project: project) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HandoverColors.well))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(HandoverColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HandoverColors.line))
    }

    /// "2 files and the summary cross · 1 left out"
    private func crossing(_ built: HandoverCLI.Built) -> String {
        let files = built.files.filter { $0.path != "summary.md" }.count
        var text = files == 0 ? "The summary crosses" : "\(files) file\(files == 1 ? "" : "s") and the summary cross"
        if !built.skipped.isEmpty { text += " · \(built.skipped.count) left out" }
        return text
    }

    private var badge: some View {
        let text: String
        let color: Color
        if project.needsSummary { (text, color) = ("Summary missing", HandoverColors.warn) }
        else if project.scan?.clean == true { (text, color) = ("Scan clean", HandoverColors.ok) }
        else if project.needsBuild { (text, color) = ("Changed: switch again", HandoverColors.bad) }
        else if project.undecided == 0 { (text, color) = ("All decided", HandoverColors.ok) }
        else { (text, color) = ("\(project.undecided) to decide", HandoverColors.warn) }
        return Text(text).font(.custom("PPObjectSans-Semibold", size: 12)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

private struct GroupRow: View {
    let group: FindingGroup
    @ObservedObject var project: ProjectHandover

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Self.label(group.kind))
                        .font(.custom("PPObjectSans-Semibold", size: 11))
                        .foregroundStyle(group.blocking ? HandoverColors.bad : HandoverColors.warn)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill((group.blocking ? HandoverColors.bad : HandoverColors.warn).opacity(0.14)))
                    Text(places).foregroundStyle(HandoverColors.dim).lineLimit(1).truncationMode(.middle)
                }
                if let preview = group.preview {
                    (Text(preview.before).foregroundColor(HandoverColors.dim)
                        + Text(preview.value).bold().foregroundColor(group.blocking ? HandoverColors.bad : HandoverColors.warn)
                        + Text(preview.after).foregroundColor(HandoverColors.dim))
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                } else if let excerpt = group.places.first?.excerpt, !excerpt.isEmpty {
                    Text(excerpt).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if group.fileLevel {
                Text("Switch again to rebuild").foregroundStyle(HandoverColors.bad).font(.custom("ObjectSans-Regular", size: 12))
            } else {
                HStack(spacing: 0) {
                    if !group.blocking { choice("Keep", .keep) }
                    choice("Mask", .mask)
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(HandoverColors.card))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(red: 36/255, green: 71/255, blue: 122/255)))
                .help(group.blocking ? "An e-mail address or IBAN never crosses: it can only be masked." : "Keep: not client data. Mask: replaced in what crosses.")
            }
        }
    }

    private var places: String {
        let count = group.places.count
        let inName = group.places.contains { $0.line == 0 }
        return "\(count)× in " + group.fileNames.joined(separator: ", ") + (inName ? " (also its file name)" : "")
    }

    private func choice(_ title: String, _ value: HandoverChoice) -> some View {
        let selected = project.choices[group.id] == value
        return Button(title) { project.choices[group.id] = value }
            .buttonStyle(.plain)
            .font(.custom(selected ? "PPObjectSans-Semibold" : "ObjectSans-Regular", size: 12))
            .foregroundStyle(selected ? Color.white : Brand.foreground)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? (value == .mask ? Brand.accent : HandoverColors.ok.opacity(0.35)) : Color.clear))
            .contentShape(Rectangle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "quoted-literal" → "quoted literal".
    static func label(_ kind: String) -> String {
        kind == "known-value" ? "shown value" : kind.replacingOccurrences(of: "-", with: " ")
    }
}

/// The buttons of the handover sheet: a card surface with a line, or Venus Blue for the main action.
struct HandoverButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom(primary ? "PPObjectSans-Semibold" : "ObjectSans-Regular", size: 13))
            .foregroundStyle(primary ? Color.white : Brand.foreground)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? Brand.accent : HandoverColors.card))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? Brand.accent : Color(red: 36/255, green: 71/255, blue: 122/255)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
