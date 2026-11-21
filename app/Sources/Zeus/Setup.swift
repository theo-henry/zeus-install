import AppKit
import SwiftUI

/// Runs the bundled install.sh in app mode and turns its "@@zeus" lines into a checklist (`SetupSteps`).
final class SetupModel: ObservableObject {
    typealias StepState = SetupSteps.State

    /// One row of the checklist.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let note: String
        let state: StepState
        let detail: String
    }

    enum Phase: Equatable { case checking, ready, installing, finished, failed(String) }

    /// The key of the first row: the app in Applications. It is not an installer step.
    static let applicationsRow = "applications"

    /// The installer steps and their states. install.sh gives the steps (the "plan" line).
    @Published private(set) var checklist = SetupSteps()
    let inApplications = AppMover.isInApplications
    @Published var phase: Phase = .checking
    @Published var logText = ""
    @Published var githubCode: String?
    @Published var lastLink: URL?
    @Published var licenseURL: URL?
    @Published var waitingForInput = false
    @Published var input = ""
    @Published var keepInDock = true
    @Published var showMenuBar = Preferences.showMenuBar

    var onFinished: (() -> Void)?
    var onOptionsApplied: (() -> Void)?

    private var process: PTYProcess?
    private var log = TerminalLog()
    private var lastOutput = Date()
    private var idleTimer: Timer?

    var question: SetupSteps.Question? { checklist.question }

    /// The rows of the checklist: the app in Applications, then the installer steps in the order of install.sh.
    var rows: [Row] {
        [Row(id: Self.applicationsRow, name: "Zeus app in Applications", note: "Zeus copies itself to the Applications folder.",
             state: inApplications ? .ok : .todo, detail: "")] +
            checklist.steps.map { step in
                Row(id: step.key, name: SetupSteps.name(of: step.key), note: SetupSteps.note(of: step.key),
                    state: step.state, detail: step.detail)
            }
    }

    var needsInstall: Bool { checklist.steps.contains { $0.state == .todo } }
    var isBusy: Bool { phase == .checking || phase == .installing }

    func check() {
        guard process == nil else { return }
        phase = .checking
        run(.check, arguments: ["--check"])
    }

    func install() {
        guard process == nil else { return }
        phase = .installing
        githubCode = nil
        lastLink = nil
        log = TerminalLog()
        run(.install, arguments: [])
    }

    private func run(_ kind: SetupSteps.RunKind, arguments: [String]) {
        guard let installer = Paths.installer else {
            phase = .failed("The installer is missing from the app. Download the Zeus app again.")
            return
        }
        checklist.begin(kind)
        ShellEnvironment.reset()
        let env = ShellEnvironment.make(extra: ["ZEUS_INSTALL_APP": "1"])
        log.onEvent = { [weak self] event in self?.handle(event: event) }
        log.onChange = { [weak self] in self?.outputChanged() }
        do {
            let process = try PTYProcess(executable: "/bin/bash", arguments: [installer] + arguments,
                                         environment: env, directory: Paths.home)
            process.onOutput = { [weak self] data in self?.log.append(data) }
            process.onExit = { [weak self] code in self?.ended(code: code, check: arguments.contains("--check")) }
            self.process = process
            startIdleTimer()
        } catch {
            _ = checklist.finish(exitCode: -1)
            phase = .failed(error.localizedDescription)
        }
    }

    private func outputChanged() {
        lastOutput = Date()
        waitingForInput = false
        logText = log.lines.suffix(400).joined(separator: "\n") + (log.currentLine.isEmpty ? "" : "\n" + log.currentLine)
        // gh prints: "! First copy your one-time code: ABCD-1234"
        for line in log.lines.suffix(20) + [log.currentLine] {
            if let range = line.range(of: "one-time code: ") {
                githubCode = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if let range = line.range(of: "Anaconda license: ") {
                licenseURL = URL(string: String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
            if let match = line.range(of: #"https://[^\s'"]+"#, options: .regularExpression) {
                lastLink = URL(string: String(line[match]))
            }
        }
    }

    /// A prompt that waits for an answer shows no new output, and its line has no line break yet.
    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.phase == .installing else { return }
            let waiting = !self.log.currentLine.trimmingCharacters(in: .whitespaces).isEmpty &&
                Date().timeIntervalSince(self.lastOutput) > 1.5
            if waiting != self.waitingForInput { self.waitingForInput = waiting }
        }
    }

    private func handle(event line: String) {
        Trace.log("setup event: \(line)")
        guard let event = SetupSteps.parse(line), checklist.apply(event) else {
            Trace.log("setup event refused: \(line)")
            return
        }
        // A link of an earlier step (such as the Claude login) is not the link of this step.
        if case .running = event { lastLink = nil }
    }

    private func ended(code: Int32, check: Bool) {
        Trace.log("setup ended: check=\(check) code=\(code)")
        for step in checklist.steps where !step.detail.isEmpty { Trace.log("setup detail \(step.key): \(step.detail)") }
        process = nil
        idleTimer?.invalidate()
        waitingForInput = false
        guard let outcome = checklist.finish(exitCode: code) else { return }
        Trace.log("setup result: \(outcome)")
        Trace.log("setup states: " + checklist.steps.map { "\($0.key)=\($0.state)" }.joined(separator: " "))
        switch outcome {
        case .ok where check:
            phase = .ready
        case .ok:
            phase = .finished
            applyOptions()
            Preferences.setupDone = true
        case let .failed(failure):
            phase = .failed(message(failure, check: check, code: code))
        }
    }

    /// The text of a failed run.
    private func message(_ failure: SetupSteps.Failure, check: Bool, code: Int32) -> String {
        func title(_ key: String) -> String {
            let number = checklist.step(key).map { "Step \($0.number), " } ?? ""
            return number + SetupSteps.name(of: key)
        }
        switch failure {
        case let .unreported(key) where check:
            return "The check of this Mac gave no result for \(SetupSteps.name(of: key))."
        case let .unreported(key):
            return "\(title(key)): the installer gave no result for this step."
        case _ where check:
            return "The check of this Mac did not complete (exit code \(code))."
        case let .step(key):
            return "\(title(key)): \(checklist.step(key)?.detail ?? "")"
        case let .installer(text):
            return text
        case let .stopped(exitCode):
            return "The installer stopped (exit code \(exitCode))."
        }
    }

    func applyOptions() {
        Preferences.showMenuBar = showMenuBar
        if keepInDock { DockPin.pin() }
        onOptionsApplied?()
    }

    func send(_ text: String) {
        process?.write(text + "\n")
        input = ""
        waitingForInput = false
    }

    func answerQuestion(_ yes: Bool) {
        send(yes ? "y" : "n")
        checklist.answered()
    }

    func stop() {
        process?.terminate(grace: 2)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 16) {
                checklist.frame(width: 300)
                VStack(alignment: .leading, spacing: 10) {
                    prompts
                    googleSignIn
                    output
                }
            }
            footer
        }
        .padding(24)
        .font(.custom("ObjectSans-Regular", size: 13))
        .background(Brand.background)
        .foregroundStyle(Brand.foreground)
        .tint(Brand.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 700)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let logo = Brand.logoImage {
                Image(nsImage: logo).resizable().frame(width: 52, height: 52).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up Zeus").font(.custom("PPObjectSans-Semibold", size: 22))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .checking: return "Checking what is already on this Mac…"
        case .ready: return model.needsInstall ? "Zeus needs the tools that are not ticked yet. Steps that are done are skipped."
            : "Everything is installed. You can start Zeus."
        case .installing: return "Installing. Follow the questions on the right when they appear."
        case .finished: return "Zeus is ready."
        case let .failed(message): return message
        }
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            steps
            // The dictation model downloads next to the installer: always in view, below the steps.
            Divider().overlay(Color.primary.opacity(0.12))
            DictationSetupRow(models: DictationModels.shared)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }

    private var steps: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(model.rows) { step in
                        HStack(alignment: .top, spacing: 9) {
                            icon(step.state).frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.name).fontWeight(step.state == .running ? .semibold : .regular)
                                // Instructions matter only for a step that still has to run.
                                let done = [.ok, .done, .skipped].contains(step.state)
                                let note = !step.detail.isEmpty ? step.detail : done ? "" : step.note
                                if !note.isEmpty {
                                    Text(note).font(.caption)
                                        // Red only for the message of a failure, not for the instructions of the step.
                                        .foregroundStyle(step.state == .failed && !step.detail.isEmpty ? Color.red : Color.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .id(step.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The step that runs, or else the last failed step, stays in view (the list can be longer than the window).
            .onChange(of: model.rows) { steps in
                guard let step = steps.first(where: { $0.state == .running }) ?? steps.last(where: { $0.state == .failed })
                else { return }
                withAnimation { proxy.scrollTo(step.id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func icon(_ state: SetupModel.StepState) -> some View {
        switch state {
        case .ok, .done, .skipped:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .running:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .always:
            Image(systemName: "arrow.triangle.2.circlepath.circle").foregroundStyle(.secondary)
        case .todo:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .unknown:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var prompts: some View {
        if let question = model.question, question.key == SetupSteps.Key.anaconda {
            promptBox {
                Text("Do you accept the Anaconda license?").fontWeight(.semibold)
                Text("Zeus uses Anaconda for Python and the GitHub CLI.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    if let url = model.licenseURL { Button("Read the license") { NSWorkspace.shared.open(url) } }
                    Spacer()
                    Button("Decline") { model.answerQuestion(false) }
                    Button("Accept") { model.answerQuestion(true) }.keyboardShortcut(.defaultAction)
                }
            }
        } else if let question = model.question, question.key == SetupSteps.Key.googleSignIn {
            promptBox {
                Text("Sign in to Google for EU mode?").fontWeight(.semibold)
                Text("EU mode runs Claude on Google Cloud in the EU. Sign in with your work email. If you do not use EU mode, skip it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Skip") { model.answerQuestion(false) }
                    Button("Sign in to Google") { model.answerQuestion(true) }.keyboardShortcut(.defaultAction)
                }
            }
        } else if let question = model.question {
            promptBox {
                Text(question.prompt).fontWeight(.semibold)
                HStack {
                    Spacer()
                    Button("No") { model.answerQuestion(false) }
                    Button("Yes") { model.answerQuestion(true) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        if model.phase == .installing, let code = model.githubCode, model.checklist.state(of: SetupSteps.Key.githubLogin) == .running {
            promptBox {
                Text("GitHub login").fontWeight(.semibold)
                Text("Copy this code, then open GitHub and paste it there.").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text(code).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    Spacer()
                    Button("Open GitHub") { model.send("") }.keyboardShortcut(.defaultAction)
                }
            }
        }
        if model.phase == .installing, model.checklist.state(of: SetupSteps.Key.claudeLogin) == .running, let link = model.lastLink {
            promptBox {
                Text("Claude login").fontWeight(.semibold)
                Text("Log in to Claude in your browser. If no browser window opened, open the link.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open the login page") { NSWorkspace.shared.open(link) }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var googleSignIn: some View {
        if model.phase == .installing, model.question == nil, model.checklist.state(of: SetupSteps.Key.googleSignIn) == .running,
           let link = model.lastLink {
            promptBox {
                Text("Google sign-in").fontWeight(.semibold)
                Text("Sign in to Google in your browser and allow the access. If no browser window opened, open the link.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open the sign-in page") { NSWorkspace.shared.open(link) }
                    Spacer()
                }
            }
        }
    }

    private func promptBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.5)))
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Installer output").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logText.isEmpty ? "The installer output appears here when the install runs." : model.logText)
                        .foregroundStyle(model.logText.isEmpty ? Color.secondary : Color.primary)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Brand.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                .onChange(of: model.logText) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            if model.phase == .installing {
                HStack {
                    TextField(model.waitingForInput ? "The installer waits for an answer. Type it here." : "Answer to the installer",
                              text: $model.input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.send(model.input) }
                    Button("Send") { model.send(model.input) }
                    Button("Press Enter") { model.send("") }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Keep Zeus in the Dock", isOn: $model.keepInDock)
            Toggle("Show Zeus in the menu bar", isOn: $model.showMenuBar)
            Spacer()
            switch model.phase {
            case .checking:
                ProgressView().controlSize(.small)
            case .ready:
                if model.needsInstall {
                    Button("Install") { model.install() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Update and check again") { model.install() }
                    Button("Start Zeus") {
                        model.applyOptions()
                        Preferences.setupDone = true
                        model.onFinished?()
                    }.keyboardShortcut(.defaultAction)
                }
            case .installing:
                Button("Stop") { model.stop() }
            case .finished:
                Button("Start Zeus") {
                    model.applyOptions()
                    model.onFinished?()
                }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("Copy the output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                Button("Try again") { model.install() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The dictation model in the setup checklist. It downloads next to the installer and never stops the setup:
/// after a download failure, Zeus tries again in the background, and dictation uses Apple's recognizer until the model is ready.
struct DictationSetupRow: View {
    @ObservedObject var models: DictationModels

    var body: some View {
        let model = models.model(for: DictationSettings.shared.role)
        let state = model.map { models.state(of: $0) } ?? .missing
        HStack(alignment: .top, spacing: 9) {
            icon(state).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(state)).fontWeight(isActive(state) ? .semibold : .regular)
                if case let .downloading(received, total) = state, total > 0 {
                    ProgressView(value: Double(received), total: Double(total)).controlSize(.small)
                }
                Text(note(state, model)).font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func isActive(_ state: DictationModels.State) -> Bool {
        switch state {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    private func title(_ state: DictationModels.State) -> String {
        isActive(state) ? "Downloading dictation model" : "Dictation model"
    }

    private func note(_ state: DictationModels.State, _ model: DictationModel?) -> String {
        let size = model.map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) } ?? ""
        switch state {
        case let .downloading(received, total):
            let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(done) of \(all). Speech to text stays on this Mac."
        case .verifying: return "Checking the download."
        case .downloaded: return "\(model?.name ?? "The") model (\(size)) is on this Mac."
        case let .failed(message):
            guard let model, models.retryAt[model.id] != nil else { return message }
            return "\(message) Zeus tries again in the background."
        case .cancelled: return "Stopped. Zeus downloads it at the next start."
        case .missing: return "Downloads in the background (\(size))."
        }
    }

    @ViewBuilder
    private func icon(_ state: DictationModels.State) -> some View {
        switch state {
        case .downloaded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading, .verifying: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
        case .missing, .cancelled: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let model = SetupModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = "Zeus Setup"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 11/255, green: 37/255, blue: 69/255, alpha: 1)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        window.center()
        model.check()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.phase == .installing else { return true }
        let alert = NSAlert()
        alert.messageText = "Stop the Zeus setup?"
        alert.informativeText = "The step that runs now stops. Run the setup again later; completed steps are skipped."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Continue")
        if alert.runModal() == .alertFirstButtonReturn {
            model.stop()
            return true
        }
        return false
    }
}
