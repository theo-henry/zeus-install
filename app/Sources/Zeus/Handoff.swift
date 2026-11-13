import AppKit
import SwiftUI

/// The EU handoff through the Zeus command line of the workspace (zeus, scripts/handoff.py, references/eu-handoff.md).
/// The app is not a Claude Code session, so it may build, scan, and release a handoff.
///
/// The calls, each `python3 <workspace>/scripts/zeus.py --workspace <workspace> <arguments>` in the workspace, with one JSON object on stdout:
/// - `handoff pending --json`: `{"projects": [{"project_id", "name", "eu_work": {"first_at", "last_at"}, "released_at", "needs_handoff"}]}`
/// - `handoff build <project> --json`, then `handoff scan <project> --json`: `{"project_id", "ok", "hash", "findings": [{"kind", "where", "preview"}],
///   "summary": {<name>: <count>}, "stages": [{"id", "label", "status": "done" | "blocked"}], "review_page", ...}`.
///   While they run, they print `{"stage", "label"}` on stderr as each step starts; build has the stages collect, strip, aggregate,
///   scan, review, and scan only the last two. Both end with exit code 0 also when the scan is not clean (ok false).
/// - `handoff release <project> <hash> --json`: `{"released": true, "project_id", "path", "hash", "at"}`
/// An error prints `{"error", "fix"}` with exit code 1 (3: findings, 4: wrong hash, 5: inside Claude Code); 2 is a usage error in plain text.
enum HandoffCLI {
    struct Failure: Error, Equatable {
        let message: String
        var fix: String?
    }

    struct Project: Equatable {
        let id: String
        let name: String
    }

    struct Finding: Identifiable, Equatable {
        let id = UUID()
        let kind: String
        let location: String
        /// A masked preview from Zeus; the app never sees the value itself.
        let preview: String
    }

    /// One step of a build or a scan. A blocked step (the review, with findings) shows as failed.
    struct Stage: Equatable {
        let id: String
        let label: String
        var blocked = false
    }

    struct Scan: Identifiable, Equatable {
        var id: String { project.id }
        let project: Project
        let hash: String
        let ok: Bool
        let findings: [Finding]
        let summary: [(name: String, count: Int)]
        /// The steps that Zeus took, in order.
        let stages: [Stage]
        let reviewPage: String?

        var clean: Bool { ok && findings.isEmpty }

        static func == (lhs: Scan, rhs: Scan) -> Bool { lhs.project == rhs.project && lhs.hash == rhs.hash }
    }

    /// The Python of the workspace's Zeus. ZEUS_APP_PYTHON replaces it (for tests).
    private static var python: String { ProcessInfo.processInfo.environment["ZEUS_APP_PYTHON"] ?? "python3" }
    private static var script: String { Paths.zeusDir + "/scripts/zeus.py" }

    /// The environment of a Zeus call: the app's, without any variable that would make it look like a Claude Code session.
    private static var environment: [String: String] {
        var env = ShellEnvironment.make()
        for key in ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "ZEUS_SESSION_ID", BlindMode.variable] {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// Runs one call and reads its JSON. Blocks: call it off the main queue.
    /// `progress` gets each `{"stage", "label"}` line of the error output while the call runs.
    static func call(_ arguments: [String], timeout: TimeInterval, progress: ((Stage) -> Void)? = nil) -> Result<[String: Any], Failure> {
        guard FileManager.default.fileExists(atPath: script) else {
            return .failure(Failure(message: "The Zeus workspace has no scripts/zeus.py (\(Paths.zeusDir)).", fix: "Run the Zeus setup."))
        }
        Trace.log("handoff call: \(arguments.prefix(2).joined(separator: " "))")
        let onLine: ((String) -> Void)? = progress.map { progress in
            { line in
                guard let object = json(line), let id = object["stage"] as? String, let label = object["label"] as? String else { return }
                progress(Stage(id: id, label: label))
            }
        }
        guard let run = Shell.run("/usr/bin/env", [python, script, "--workspace", Paths.zeusDir] + arguments, environment: environment,
                                  directory: Paths.zeusDir, timeout: timeout, onErrorLine: onLine) else {
            return .failure(Failure(message: "Zeus did not answer within \(Int(timeout)) s (\(arguments.prefix(2).joined(separator: " "))).",
                                    fix: "Try again. If it happens again, run the same command in Terminal to see why."))
        }
        // A progress line on stderr is not the answer: an error answer is on stdout, or alone on stderr.
        let object = json(run.output) ?? json(run.errors).flatMap { $0["error"] != nil ? $0 : nil }
        if run.status != 0 {
            if let object, let error = object["error"] as? String {
                return .failure(Failure(message: error, fix: object["fix"] as? String))
            }
            let detail = run.errors.split(separator: "\n").suffix(3).joined(separator: " ")
            return .failure(Failure(message: "Zeus stopped with exit code \(run.status) (\(arguments.prefix(2).joined(separator: " "))). \(detail)",
                                    fix: nil))
        }
        guard let object else {
            return .failure(Failure(message: "Zeus gave no JSON answer (\(arguments.prefix(2).joined(separator: " "))).", fix: nil))
        }
        return .success(object)
    }

    /// The whole output as one JSON object, else its last line that is one.
    private static func json(_ text: String) -> [String: Any]? {
        func parse(_ text: Substring) -> [String: Any]? {
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whole = parse(Substring(trimmed)) { return whole }
        return trimmed.split(separator: "\n").reversed().lazy.compactMap { line in
            line.hasPrefix("{") ? parse(line) : nil
        }.first
    }

    /// The projects whose EU work has no released handoff yet.
    static func pending() -> Result<[Project], Failure> {
        call(["handoff", "pending", "--json"], timeout: 30).map { object in
            (object["projects"] as? [[String: Any]] ?? []).compactMap { entry in
                guard entry["needs_handoff"] as? Bool == true, let id = entry["project_id"] as? String, !id.isEmpty else { return nil }
                let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                return Project(id: id, name: name)
            }
        }
    }

    private static func stages(_ object: [String: Any]) -> [Stage] {
        (object["stages"] as? [Any] ?? []).compactMap { item -> Stage? in
            if let label = item as? String { return label.isEmpty ? nil : Stage(id: label, label: label) }
            guard let entry = item as? [String: Any], let label = entry["label"] as? String, !label.isEmpty else { return nil }
            return Stage(id: entry["id"] as? String ?? label, label: label, blocked: entry["status"] as? String == "blocked")
        }
    }

    /// Builds the handoff of a project, then scans it. The stages are those of the build, with the scan's own at the end.
    static func buildAndScan(_ project: Project, progress: ((Stage) -> Void)? = nil) -> Result<Scan, Failure> {
        var built: [Stage] = []
        return call(["handoff", "build", project.id, "--json"], timeout: 120, progress: progress).flatMap { object in
            built = stages(object)
            return call(["handoff", "scan", project.id, "--json"], timeout: 120, progress: progress)
        }.flatMap { object in
            guard let hash = object["hash"] as? String, !hash.isEmpty else {
                return .failure(Failure(message: "The scan of \(project.name) gave no handoff hash.", fix: nil))
            }
            let findings = (object["findings"] as? [[String: Any]] ?? []).map { item in
                Finding(kind: item["kind"] as? String ?? "finding", location: item["where"] as? String ?? "",
                        preview: item["preview"] as? String ?? "")
            }
            let summary = (object["summary"] as? [String: Any] ?? [:]).compactMap { key, value -> (String, Int)? in
                // What goes over, not what the scan found or left out (those show apart); empty sections stay out.
                guard !["scan_findings", "omitted"].contains(key), let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue > 0 else { return nil }
                return (key, number.intValue)
            }.sorted { $0.0 < $1.0 }
            let scanned = stages(object)
            let merged = built.filter { stage in !scanned.contains { $0.id == stage.id } } + scanned
            return .success(Scan(project: project, hash: hash, ok: object["ok"] as? Bool ?? false, findings: findings,
                                 summary: summary.map { (name: $0.0, count: $0.1) }, stages: merged,
                                 reviewPage: (object["review_page"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
        }
    }

    static func release(_ scan: Scan) -> Result<Void, Failure> {
        // "released" is the path of the released file (or true); an error says false.
        call(["handoff", "release", scan.project.id, scan.hash, "--json"], timeout: 60).flatMap { object in
            object["released"] as? Bool == true || !((object["released"] as? String) ?? "").isEmpty ? .success(())
                : .failure(Failure(message: "Zeus did not confirm the release of \(scan.project.name).", fix: nil))
        }
    }
}

/// The switch of a tab from EU to Apolix: the app hands off the EU work before the EU session stops.
/// It checks which projects need a handoff; with none, it does nothing visible. Otherwise the tab shows the
/// handoff step on the loading screen while Zeus builds and scans each handoff, then a summary sheet:
/// release and continue on Apolix, open the review page, continue without handoff, or stay on EU.
/// No error starts Apolix by itself: the consultant always picks.
final class HandoffFlow {
    enum Outcome { case noHandoffNeeded, switchNow, stay }

    static let title = "Handing off data securely"
    static let subtitle = "Removing and aggregating sensitive information"
    /// The stage that shows while Zeus builds and scans, before it names its own stages.
    static let firstStage = "Collecting the EU work"

    private weak var tab: ChatTab?
    private var overlay: LoaderOverlay?
    private var completion: ((Outcome) -> Void)?
    private let queue = DispatchQueue(label: "io.github.theo-henry.zeus.handoff", qos: .userInitiated)
    private var ended = false
    private var projects: [HandoffCLI.Project] = []
    private var scans: [HandoffCLI.Scan] = []
    private var sheet: HandoffSheet?

    init(tab: ChatTab) {
        self.tab = tab
    }

    func start(completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        Trace.log("handoff: pending check")
        queue.async { [weak self] in
            let result = HandoffCLI.pending()
            DispatchQueue.main.async { self?.pendingEnded(result) }
        }
    }

    /// The tab closed: nothing more happens.
    func cancel() {
        guard !ended else { return }
        ended = true
        sheet?.close()
        overlay?.remove(over: 0.1)
        overlay = nil
        completion = nil
    }

    private func pendingEnded(_ result: Result<[HandoffCLI.Project], HandoffCLI.Failure>) {
        guard !ended else { return }
        switch result {
        case let .failure(failure):
            Trace.log("handoff: pending failed: \(failure.message)")
            showSummary(error: failure)
        case let .success(projects) where projects.isEmpty:
            Trace.log("handoff: none pending")
            finish(.noHandoffNeeded)
        case let .success(projects):
            Trace.log("handoff: pending \(projects.map(\.id).joined(separator: " "))")
            self.projects = projects
            showStep()
            run(index: 0)
        }
    }

    private func showStep() {
        guard let tab else { return }
        let overlay = LoaderOverlay(frame: tab.pageView.frame, status: "")
        tab.cover(with: overlay.view)
        overlay.beginHandoff(title: Self.title, subtitle: Self.subtitle)
        self.overlay = overlay
    }

    // MARK: Stages

    /// The ids of the stages on the screen, in order.
    private var shownStages: [String] = []
    /// The changes of the stage list; each one shows for a moment, so that the step reads as a process.
    private var stageSteps: [() -> Void] = []
    private var pumping = false
    private static let stageTime: TimeInterval = 0.32

    private func enqueue(_ step: @escaping () -> Void) {
        stageSteps.append(step)
        pump()
    }

    private func pump() {
        guard !pumping, !ended, !stageSteps.isEmpty else { return }
        pumping = true
        stageSteps.removeFirst()()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stageTime) { [weak self] in
            self?.pumping = false
            self?.pump()
        }
    }

    /// A stage starts: the one before it is done.
    private func startStage(_ stage: HandoffCLI.Stage) {
        guard !shownStages.contains(stage.id) else { return }
        if !shownStages.isEmpty { overlay?.markStage(shownStages.count - 1, "done") }
        overlay?.addStage(stage.label)
        shownStages.append(stage.id)
        overlay?.markStage(shownStages.count - 1, "active")
        Trace.log("handoff: stage started: \(stage.label)")
    }

    private func run(index: Int) {
        guard !ended else { return }
        guard index < projects.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showSummary(error: nil) }
            return
        }
        let project = projects[index]
        let started = Date()
        enqueue { [weak self] in
            guard let self else { return }
            self.overlay?.clearStages(group: self.projects.count > 1 ? project.name : nil)
            self.shownStages = []
            // Until Zeus names its first step; Zeus's own "collect" step then takes this place.
            self.startStage(HandoffCLI.Stage(id: "collect", label: Self.firstStage))
        }
        queue.async { [weak self] in
            let result = HandoffCLI.buildAndScan(project) { stage in
                DispatchQueue.main.async { self?.enqueue { self?.startStage(stage) } }
            }
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                switch result {
                case let .failure(failure):
                    Trace.log("handoff: \(project.id) failed: \(failure.message)")
                    self.enqueue { [weak self] in
                        guard let self else { return }
                        self.overlay?.markStage(max(0, self.shownStages.count - 1), "failed")
                    }
                    self.enqueue { [weak self] in self?.showSummary(error: failure) }
                case let .success(scan):
                    Trace.log("handoff: \(project.id) scanned ok=\(scan.ok) findings=\(scan.findings.count) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                    self.scans.append(scan)
                    self.finishStages(scan) { [weak self] in self?.run(index: index + 1) }
                }
            }
        }
    }

    /// Shows the stages that Zeus reported only in its result, then ticks them all off: a blocked one fails.
    private func finishStages(_ scan: HandoffCLI.Scan, then next: @escaping () -> Void) {
        let resultAt = Date()
        var final = scan.stages
        // A scan that is not clean ends in a failed stage, also when Zeus marks none blocked.
        if !scan.clean, !final.contains(where: \.blocked), !final.isEmpty { final[final.count - 1].blocked = true }
        for stage in final where !shownStages.contains(stage.id) {
            enqueue { [weak self] in self?.startStage(stage) }
        }
        enqueue { [weak self] in
            guard let self else { return }
            for (index, id) in self.shownStages.enumerated() {
                let stage = final.first { $0.id == id }
                let failed = stage?.blocked ?? false
                // Zeus's own label replaces the waiting text, and a blocked review says why.
                self.overlay?.markStage(index, failed ? "failed" : "done", label: stage?.label)
                Trace.log("handoff: stage \(index + 1)/\(self.shownStages.count) \(failed ? "failed" : "done"): \(stage?.label ?? id)")
            }
            Trace.log("handoff: stages shown in \(String(format: "%.1f", Date().timeIntervalSince(resultAt))) s after the result")
        }
        enqueue { next() }
    }

    // MARK: Summary

    private func showSummary(error: HandoffCLI.Failure?) {
        guard !ended, let window = tab?.view.window else { return }
        let model = HandoffSummaryModel(scans: scans, error: error)
        model.onRelease = { [weak self] in self?.release() }
        model.onReview = { [weak self] in self?.openReview() }
        model.onContinue = { [weak self] in
            Trace.log("handoff: continue without handoff")
            self?.finish(.switchNow)
        }
        model.onStay = { [weak self] in
            Trace.log("handoff: stay on EU")
            self?.finish(.stay)
        }
        Trace.log("handoff: summary projects=\(scans.count) clean=\(scans.allSatisfy(\.clean)) "
                  + "findings=\(scans.reduce(0) { $0 + $1.findings.count }) error=\(error != nil) release=\(model.canRelease)")
        let sheet = HandoffSheet(model: model)
        self.sheet = sheet
        sheet.present(on: window)
    }

    private func openReview() {
        let pages = scans.compactMap(\.reviewPage)
        Trace.log("handoff: review page \(pages.count)")
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZEUS_APP_TEST_NO_OPEN"] == "1" { return }
        #endif
        for page in pages { NSWorkspace.shared.open(URL(fileURLWithPath: page)) }
    }

    /// Releases every handoff, then switches. A failed release keeps the EU session and says why.
    private func release() {
        guard let model = sheet?.model, model.canRelease else { return }
        model.releasing = true
        let scans = self.scans
        queue.async { [weak self] in
            var failure: HandoffCLI.Failure?
            for scan in scans {
                if case let .failure(error) = HandoffCLI.release(scan) {
                    failure = HandoffCLI.Failure(message: "\(scan.project.name): \(error.message)", fix: error.fix)
                    break
                }
                Trace.log("handoff: released \(scan.project.id)")
            }
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                model.releasing = false
                if let failure {
                    Trace.log("handoff: release failed: \(failure.message)")
                    model.error = failure
                    model.releaseFailed = true
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
        // On a switch, the new session's loading screen comes in under this one, which then fades.
        let overlay = self.overlay
        self.overlay = nil
        let completion = self.completion
        self.completion = nil
        Trace.log("handoff: outcome \(outcome)")
        completion?(outcome)
        overlay?.remove(over: outcome == .stay ? 0.3 : 0.45)
    }

    #if DEBUG
    /// Test actions: the buttons of the summary sheet.
    func testPress(_ button: String) {
        guard let model = sheet?.model else { Trace.log("handoff: no summary to press"); return }
        switch button {
        case "release": model.canRelease ? model.onRelease?() : Trace.log("handoff: release is disabled")
        case "review": model.onReview?()
        case "continue": model.onContinue?()
        case "stay": model.onStay?()
        default: break
        }
    }
    #endif
}

// MARK: - The summary sheet

final class HandoffSummaryModel: ObservableObject {
    let scans: [HandoffCLI.Scan]
    @Published var error: HandoffCLI.Failure?
    @Published var releasing = false
    @Published var releaseFailed = false
    var onRelease: (() -> Void)?
    var onReview: (() -> Void)?
    var onContinue: (() -> Void)?
    var onStay: (() -> Void)?

    init(scans: [HandoffCLI.Scan], error: HandoffCLI.Failure?) {
        self.scans = scans
        self.error = error
    }

    var findings: Int { scans.reduce(0) { $0 + $1.findings.count } }
    var canRelease: Bool { error == nil && !releaseFailed && !scans.isEmpty && scans.allSatisfy(\.clean) }
    var hasReview: Bool { scans.contains { $0.reviewPage != nil } }

    var title: String {
        if error != nil && scans.isEmpty { return "The handoff did not complete" }
        if releaseFailed { return "The release did not complete" }
        if findings > 0 || !scans.allSatisfy(\.ok) { return "The scan found sensitive values" }
        return "Handoff ready"
    }

    var subtitle: String {
        if error != nil && scans.isEmpty || releaseFailed {
            return "Nothing was released. The EU session still runs."
        }
        if findings > 0 || !scans.allSatisfy(\.ok) {
            return "Release stays off until the review page clears every finding. The EU session still runs."
        }
        return "Only structure and aggregates go to Apolix. No row values leave the EU."
    }
}

final class HandoffSheet {
    let model: HandoffSummaryModel
    private let window: NSWindow
    private weak var parent: NSWindow?

    init(model: HandoffSummaryModel) {
        self.model = model
        let hosting = NSHostingView(rootView: HandoffSummaryView(model: model))
        hosting.frame.size = hosting.fittingSize
        window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 13/255, green: 42/255, blue: 78/255, alpha: 1)
        window.contentView = hosting
    }

    func present(on parent: NSWindow) {
        self.parent = parent
        parent.beginSheet(window)
    }

    func close() {
        if let parent, parent.attachedSheet === window { parent.endSheet(window) } else { window.orderOut(nil) }
    }
}

private struct HandoffSummaryView: View {
    @ObservedObject var model: HandoffSummaryModel
    private static let ok = Color(red: 142/255, green: 227/255, blue: 200/255)
    private static let warn = Color(red: 1, green: 210/255, blue: 138/255)
    private static let bad = Color(red: 1, green: 107/255, blue: 114/255)
    private static let dim = Color(red: 169/255, green: 189/255, blue: 213/255)
    private static let card = Color(red: 11/255, green: 37/255, blue: 69/255)
    private static let line = Color(red: 26/255, green: 58/255, blue: 100/255)

    private var state: (symbol: String, color: Color) {
        if model.error != nil || model.releaseFailed { return ("exclamationmark.triangle.fill", Self.bad) }
        if !model.canRelease { return ("exclamationmark.shield.fill", Self.warn) }
        return ("checkmark.shield.fill", Self.ok)
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
                    Text(model.subtitle).foregroundStyle(Self.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.scans.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.scans) { scan in projectCard(scan) }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { errorBox(error) }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button("Open review page") { model.onReview?() }
                        .buttonStyle(ZeusButtonStyle())
                        .disabled(!model.hasReview || model.releasing)
                    Spacer()
                    Button("Stay on EU") { model.onStay?() }
                        .buttonStyle(ZeusButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.releasing)
                    Button { model.onRelease?() } label: {
                        HStack(spacing: 6) {
                            if model.releasing { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
                            Text(model.releasing ? "Releasing…" : "Release and continue on Apolix")
                        }
                    }
                    .buttonStyle(ZeusButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRelease || model.releasing)
                }
                HStack(spacing: 6) {
                    Button("Continue without handoff") { model.onContinue?() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(red: 91/255, green: 140/255, blue: 1))
                        .disabled(model.releasing)
                    Text("Apolix starts without the EU work.").foregroundStyle(Self.dim.opacity(0.8))
                }
                .font(.custom("ObjectSans-Regular", size: 12))
            }
        }
        .padding(24)
        .frame(width: 600)
        .font(.custom("ObjectSans-Regular", size: 13))
        .foregroundStyle(Brand.foreground)
        .background(Color(red: 13/255, green: 42/255, blue: 78/255))
    }

    private func projectCard(_ scan: HandoffCLI.Scan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(scan.project.name).font(.custom("PPObjectSans-Semibold", size: 14))
                Spacer()
                scanBadge(scan)
            }
            if !scan.summary.isEmpty {
                Text("Carried over").font(.custom("ObjectSans-Regular", size: 11)).foregroundStyle(Self.dim).textCase(.uppercase)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(scan.summary, id: \.name) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(item.count)").font(.custom("PPObjectSans-Semibold", size: 15)).monospacedDigit()
                            Text(Self.label(item.name)).foregroundStyle(Self.dim).lineLimit(1).fixedSize()
                        }
                    }
                }
            }
            if !scan.findings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(scan.findings.prefix(12)) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.label(finding.kind))
                                .font(.custom("PPObjectSans-Semibold", size: 11))
                                .foregroundStyle(Self.warn)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Self.warn.opacity(0.14)))
                            Text(finding.location).foregroundStyle(Self.dim).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(finding.preview).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        }
                    }
                    if scan.findings.count > 12 {
                        Text("\(scan.findings.count - 12) more on the review page").foregroundStyle(Self.dim)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 7/255, green: 29/255, blue: 56/255)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Self.line))
    }

    private func scanBadge(_ scan: HandoffCLI.Scan) -> some View {
        let clean = scan.clean
        let text = clean ? "Scan clean" : scan.findings.isEmpty ? "Scan not passed"
            : "\(scan.findings.count) finding\(scan.findings.count == 1 ? "" : "s")"
        let color = clean ? Self.ok : Self.warn
        return HStack(spacing: 5) {
            Image(systemName: clean ? "checkmark.circle.fill" : "exclamationmark.circle.fill").font(.system(size: 11, weight: .bold))
            Text(text).font(.custom("PPObjectSans-Semibold", size: 12))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
    }

    private func errorBox(_ error: HandoffCLI.Failure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.message).fixedSize(horizontal: false, vertical: true)
            if let fix = error.fix { Text(fix).foregroundStyle(Self.dim).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Self.bad.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.bad.opacity(0.4)))
    }

    /// "row_values" → "row values".
    static func label(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }
}

/// The buttons of the Zeus status pages: a card surface with a line, or Venus Blue for the main action.
struct ZeusButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom(primary ? "PPObjectSans-Semibold" : "ObjectSans-Regular", size: 13))
            .foregroundStyle(primary ? Color.white : Brand.foreground)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? Brand.accent : Color(red: 11/255, green: 37/255, blue: 69/255)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? Brand.accent : Color(red: 36/255, green: 71/255, blue: 122/255)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
