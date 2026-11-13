import AppKit
import SwiftUI

/// Runs the bundled install.sh in app mode and turns its "@@zeus" lines into a checklist.
final class SetupModel: ObservableObject {
    enum StepState: Equatable { case unknown, ok, todo, always, running, done, skipped, failed }

    struct Step: Identifiable, Equatable {
        let id: Int
        let name: String
        let note: String
        var state: StepState = .unknown
        var detail = ""
    }

    enum Phase: Equatable { case checking, ready, installing, finished, failed(String) }

    struct Question: Equatable {
        let step: Int
        let prompt: String
    }

    @Published var steps: [Step] = [
        Step(id: 0, name: "Zeus app in Applications", note: "Zeus copies itself to the Applications folder.",
             state: AppMover.isInApplications ? .ok : .todo),
        Step(id: 1, name: "Git", note: "Xcode Command Line Tools. A system window asks you to install them."),
        Step(id: 2, name: "Python", note: "Anaconda. You accept its license here."),
        Step(id: 3, name: "GitHub CLI", note: "The gh command."),
        Step(id: 4, name: "GitHub login", note: "Your browser opens. You enter a one-time code."),
        Step(id: 5, name: "Access to the Zeus repos", note: "Checked each time. Ask Theo for access if it fails."),
        Step(id: 6, name: "Node.js", note: ""),
        Step(id: 7, name: "Claude Code", note: ""),
        Step(id: 8, name: "Celonis content-cli", note: ""),
        Step(id: 9, name: "Zeus workspace", note: "Copied to ~/Code/zeus, or updated there."),
        Step(id: 10, name: "Zeus Editor plugin", note: "Installed or updated."),
        Step(id: 11, name: "The zeus command", note: ""),
        Step(id: 12, name: "Zeus skill plugins", note: "YAML builder, OCPM, and PQL."),
        Step(id: 13, name: "Claude login", note: "Your browser opens. You log in to Claude."),
    ]
    @Published var phase: Phase = .checking
    @Published var logText = ""
    @Published var question: Question?
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

    /// Step 0 (the app in Applications) is not an installer step.
    var needsInstall: Bool { steps.contains { $0.id != 0 && $0.state == .todo } }
    var isBusy: Bool { phase == .checking || phase == .installing }

    func check() {
        guard process == nil else { return }
        phase = .checking
        for index in steps.indices where steps[index].id != 0 { steps[index].state = .unknown; steps[index].detail = "" }
        run(arguments: ["--check"])
    }

    func install() {
        guard process == nil else { return }
        phase = .installing
        githubCode = nil
        lastLink = nil
        log = TerminalLog()
        run(arguments: [])
    }

    private func run(arguments: [String]) {
        guard let installer = Paths.installer else {
            phase = .failed("The installer is missing from the app. Download the Zeus app again.")
            return
        }
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

    private func handle(event: String) {
        Trace.log("setup event: \(event)")
        let parts = event.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return }
        let number = parts.count > 1 ? Int(parts[1]) : nil
        let text = parts.count > 2 ? parts[2] : ""
        func set(_ state: StepState) {
            guard let number, let index = steps.firstIndex(where: { $0.id == number }) else { return }
            steps[index].state = state
            if !text.isEmpty, state == .failed { steps[index].detail = text }
        }
        switch kind {
        case "state":
            switch text {
            case "ok": set(.ok)
            case "always": set(.always)
            default: set(.todo)
            }
        case "running": set(.running); question = nil
        case "done": set(.done); question = nil
        case "skipped": set(.skipped); question = nil
        case "failed": set(.failed); question = nil
        case "ask": if let number { question = Question(step: number, prompt: text) }
        default: break
        }
    }

    private func ended(code: Int32, check: Bool) {
        Trace.log("setup ended: check=\(check) code=\(code)")
        process = nil
        idleTimer?.invalidate()
        waitingForInput = false
        question = nil
        if check {
            phase = code == 0 ? .ready : .failed("The check of this Mac did not complete (exit code \(code)).")
            return
        }
        if code == 0 {
            phase = .finished
            for index in steps.indices where steps[index].id != 0 && [.unknown, .running, .todo, .always].contains(steps[index].state) {
                steps[index].state = .skipped
            }
            applyOptions()
            Preferences.setupDone = true
        } else {
            let failed = steps.first { $0.state == .failed }
            phase = .failed(failed.map { "Step \($0.id), \($0.name): \($0.detail)" } ?? "The installer stopped (exit code \(code)).")
            if let index = steps.firstIndex(where: { $0.state == .running }) { steps[index].state = .failed }
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
        question = nil
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
        .frame(minWidth: 860, minHeight: 640)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(model.steps) { step in
                    HStack(alignment: .top, spacing: 9) {
                        icon(step.state).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.name).fontWeight(step.state == .running ? .semibold : .regular)
                            // Instructions matter only for a step that still has to run.
                            let done = [.ok, .done, .skipped].contains(step.state)
                            let note = !step.detail.isEmpty ? step.detail : done ? "" : step.note
                            if !note.isEmpty {
                                Text(note).font(.caption)
                                    .foregroundStyle(step.state == .failed ? Color.red : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
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
        if let question = model.question, question.step == 2 {
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
        if model.phase == .installing, let code = model.githubCode, model.steps.first(where: { $0.id == 4 })?.state == .running {
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
        if model.phase == .installing, model.steps.first(where: { $0.id == 13 })?.state == .running, let link = model.lastLink {
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

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let model = SetupModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
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
