import Foundation

/// The checklist of the Zeus setup: the steps of install.sh in app mode, their states, and the result of each installer
/// run. install.sh owns the step table (`STEP_TABLE`: the keys, their order, and the titles) and sends it in the `plan`
/// line; this type owns the states and their legal transitions, from the "@@zeus" lines of one run. An event that is not
/// legal now changes nothing and returns false, so that a wrong or late line cannot show a wrong state.
///
/// Lines of a run (see `emit` in install.sh):
///
///     plan <key>...                  the first line: the steps of app mode, in order
///     state <key> ok|todo|always     check run: the result of the check of one step
///     running <key> <title>          install run: the step starts
///     done|skipped <key> <text>      install run: the step ends
///     failed <key> <message>         install run: the step fails
///     failed - <message>             a failure outside a step
///     ask <key> <question>           install run: the running step asks yes or no
///     end ok|failed                  the last line: the run result
///
/// Run phase:
///
/// | From              | Event                      | To                 |
/// |-------------------|----------------------------|--------------------|
/// | idle              | begin(kind)                | planning(kind)     |
/// | planning(kind)    | plan                       | running(kind)      |
/// | running(kind)     | end ok, end failed         | ended(kind, ok)    |
/// | planning, running | failed -                   | (same)             |
/// | any but idle      | finish(exit code)          | idle               |
///
/// Step state (only in `running(kind)`):
///
/// | From                                        | Event              | To                    |
/// |---------------------------------------------|--------------------|-----------------------|
/// | unknown                                     | state (check run)  | ok, todo, always      |
/// | not running, no result yet in this run      | running (install)  | running               |
/// | running                                     | done (install)     | done                  |
/// | running                                     | skipped (install)  | skipped               |
/// | running                                     | failed (install)   | failed                |
/// | running                                     | ask (install)      | running, with question|
/// | running, with question                      | answered           | running               |
/// | running                                     | finish, run failed | failed                |
///
/// Only one step runs at a time. A run succeeds only with `end ok`, exit code 0, and a result for each step of the plan:
/// in a check run each step is `ok`, `todo`, or `always`; in an install run each step reported `done`, `skipped`, or
/// `failed` (a failed EU step does not stop the setup). Any other end is a failure, and no step that did not report a
/// result becomes a green tick.
struct SetupSteps: Equatable {
    enum State: Equatable { case unknown, ok, todo, always, running, done, skipped, failed }

    enum RunKind: Equatable { case check, install }

    enum RunPhase: Equatable {
        case idle
        case planning(RunKind)
        case running(RunKind)
        case ended(RunKind, ok: Bool)
    }

    struct Step: Equatable {
        let key: String
        /// The place of the step in the plan, from 1: the number that install.sh shows in Terminal.
        let number: Int
        var state: State = .unknown
        /// The message of a failed step.
        var detail = ""
    }

    struct Question: Equatable {
        let key: String
        let prompt: String
    }

    enum Event: Equatable {
        case plan([String])
        /// `ok`, `todo`, or `always` only.
        case state(String, State)
        case running(String)
        case done(String, String)
        case skipped(String, String)
        /// No key: a failure outside a step.
        case failed(String?, String)
        case ask(String, String)
        case end(ok: Bool)
    }

    enum Failure: Equatable {
        /// The step failed; its detail has the message.
        case step(String)
        /// A failure outside a step, with its message.
        case installer(String)
        /// The run ended without a result for this step.
        case unreported(String)
        /// The installer stopped without a failure message, with this exit code.
        case stopped(Int32)
    }

    enum Outcome: Equatable {
        case ok
        case failed(Failure)
    }

    private(set) var steps: [Step] = []
    private(set) var phase = RunPhase.idle
    private(set) var question: Question?
    /// The steps that reported a result in this install run.
    private var finished: Set<String> = []
    /// The last failure of this run.
    private var lastFailure: Failure?

    func step(_ key: String) -> Step? { steps.first { $0.key == key } }
    func state(of key: String) -> State? { step(key)?.state }

    /// A line of install.sh, without "@@zeus ", as an event. Nil when it is not an event.
    static func parse(_ line: String) -> Event? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return nil }
        let key = parts.count > 1 ? parts[1] : ""
        let text = parts.count > 2 ? parts[2] : ""
        if kind == "plan" {
            let keys = line.split(separator: " ").dropFirst().map(String.init)
            return keys.isEmpty ? nil : .plan(keys)
        }
        if kind == "end" {
            switch key {
            case "ok": return .end(ok: true)
            case "failed": return .end(ok: false)
            default: return nil
            }
        }
        guard !key.isEmpty else { return nil }
        switch kind {
        case "state":
            switch text {
            case "ok": return .state(key, .ok)
            case "todo": return .state(key, .todo)
            case "always": return .state(key, .always)
            default: return nil
            }
        case "running": return .running(key)
        case "done": return .done(key, text)
        case "skipped": return .skipped(key, text)
        case "failed": return .failed(key == "-" ? nil : key, text)
        case "ask": return key == "-" ? nil : .ask(key, text)
        default: return nil
        }
    }

    /// Starts a run. A check run forgets the states of the last run. False when a run is not finished.
    @discardableResult
    mutating func begin(_ kind: RunKind) -> Bool {
        guard phase == .idle else { return false }
        phase = .planning(kind)
        finished = []
        lastFailure = nil
        question = nil
        if kind == .check {
            for index in steps.indices {
                steps[index].state = .unknown
                steps[index].detail = ""
            }
        }
        return true
    }

    /// Applies one event of the run. Returns false, and changes nothing, when the event is not legal now.
    @discardableResult
    mutating func apply(_ event: Event) -> Bool {
        switch (phase, event) {
        case let (.planning(kind), .plan(keys)):
            guard Set(keys).count == keys.count else { return false }
            // An install run keeps the states of the check until each step runs.
            steps = keys.enumerated().map { offset, key in
                var step = Step(key: key, number: offset + 1)
                if kind == .install, let old = self.step(key) {
                    step.state = old.state
                    step.detail = old.detail
                }
                return step
            }
            phase = .running(kind)
            return true
        case let (.planning, .failed(.none, message)), let (.running, .failed(.none, message)):
            lastFailure = .installer(message)
            question = nil
            return true
        case let (.running(.check), .state(key, value)):
            guard [.ok, .todo, .always].contains(value), let index = index(key), steps[index].state == .unknown
            else { return false }
            steps[index].state = value
            return true
        case let (.running(.install), .running(key)):
            guard let index = index(key), steps[index].state != .running, !finished.contains(key),
                  !steps.contains(where: { $0.state == .running })
            else { return false }
            steps[index].state = .running
            question = nil
            return true
        case let (.running(.install), .done(key, _)):
            return end(key, as: .done, detail: "")
        case let (.running(.install), .skipped(key, _)):
            return end(key, as: .skipped, detail: "")
        case let (.running(.install), .failed(key?, message)):
            guard end(key, as: .failed, detail: message) else { return false }
            lastFailure = .step(key)
            return true
        case let (.running(.install), .ask(key, prompt)):
            guard state(of: key) == .running else { return false }
            question = Question(key: key, prompt: prompt)
            return true
        case let (.running(kind), .end(ok)):
            phase = .ended(kind, ok: ok)
            question = nil
            return true
        default:
            return false
        }
    }

    /// The user answered the question of the running step. False when no question is open.
    @discardableResult
    mutating func answered() -> Bool {
        guard question != nil else { return false }
        question = nil
        return true
    }

    /// Ends the run when the installer exits, and gives its result. Nil, and no change, when no run was started.
    mutating func finish(exitCode: Int32) -> Outcome? {
        let kind: RunKind
        var endedOK = false
        switch phase {
        case .idle: return nil
        case let .planning(value), let .running(value): kind = value
        case let .ended(value, ok): kind = value; endedOK = ok
        }
        phase = .idle
        question = nil
        guard endedOK, exitCode == 0 else {
            if kind == .install, let index = steps.firstIndex(where: { $0.state == .running }) {
                steps[index].state = .failed
            }
            return .failed(lastFailure ?? .stopped(exitCode))
        }
        switch kind {
        case .check:
            if let step = steps.first(where: { ![.ok, .todo, .always].contains($0.state) }) {
                return .failed(.unreported(step.key))
            }
        case .install:
            if let step = steps.first(where: { !finished.contains($0.key) }) {
                if let index = index(step.key), steps[index].state == .running { steps[index].state = .failed }
                return .failed(.unreported(step.key))
            }
        }
        return .ok
    }

    private func index(_ key: String) -> Int? { steps.firstIndex { $0.key == key } }

    /// The result of the running step.
    private mutating func end(_ key: String, as state: State, detail: String) -> Bool {
        guard let index = index(key), steps[index].state == .running else { return false }
        steps[index].state = state
        // A message of an earlier run is not the result of this run.
        steps[index].detail = detail
        finished.insert(key)
        question = nil
        return true
    }
}

extension SetupSteps {
    /// The keys of the steps that the setup window gives its own prompt.
    enum Key {
        static let anaconda = "anaconda"
        static let githubLogin = "github-login"
        static let claudeLogin = "claude-login"
        static let googleSignIn = "google-sign-in"
    }

    /// The name and the note of each step in the checklist of the app. The installer owns the keys and their order; a
    /// key that is not here shows its key as its name.
    static let labels: [String: (name: String, note: String)] = [
        "xcode": ("Git", "Xcode Command Line Tools. A system window asks you to install them."),
        "anaconda": ("Python", "Anaconda. You accept its license here."),
        "gh": ("GitHub CLI", "The gh command."),
        "github-login": ("GitHub login", "Your browser opens. You enter a one-time code."),
        "repo-access": ("Access to the Zeus repos", "Checked each time. Ask Theo for access if it fails."),
        "node": ("Node.js", ""),
        "claude": ("Claude Code", "Installed or updated."),
        "content-cli": ("Celonis content-cli", ""),
        "workspace": ("Zeus workspace", "Copied to ~/Code/zeus, or updated there."),
        "editor-plugin": ("Zeus Editor plugin", "Installed or updated."),
        "zeus-command": ("The zeus command", ""),
        "skill-plugins": ("Zeus skill plugins", "YAML builder, OCPM, and PQL."),
        "claude-login": ("Claude login", "Your browser opens. You log in to Claude."),
        "gcloud": ("Google Cloud CLI", "For EU mode. Installed in ~/google-cloud-sdk."),
        "eu-plugins": ("Zeus plugins of EU mode", "Installed or updated in the EU vault, while it is open."),
        "google-sign-in": ("Google sign-in", "For EU mode. Your browser opens. You can skip it."),
    ]

    static func name(of key: String) -> String { labels[key]?.name ?? key }
    static func note(of key: String) -> String { labels[key]?.note ?? "" }
}
