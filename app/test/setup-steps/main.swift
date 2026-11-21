import Foundation

// Unit test of SetupSteps (app/Sources/Zeus/SetupSteps.swift). The arguments are the keys of the step table of install.sh in
// app mode, in order (run.sh reads them from install.sh).

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  PASS \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

typealias Steps = SetupSteps
typealias State = SetupSteps.State
typealias Event = SetupSteps.Event

let installerKeys = Array(CommandLine.arguments.dropFirst())
let keys = ["one", "two", "three"]

/// A checklist in a run of this kind, after the plan and these events.
func run(_ kind: Steps.RunKind, from start: Steps = Steps(), _ events: [Event] = []) -> Steps {
    var value = start
    value.begin(kind)
    value.apply(.plan(keys))
    for event in events { value.apply(event) }
    return value
}

/// A checklist after a whole run (the plan, these events, end, and exit).
func finished(_ kind: Steps.RunKind, from start: Steps = Steps(), _ events: [Event], ok: Bool = true, code: Int32 = 0)
    -> (Steps, Steps.Outcome?) {
    var value = run(kind, from: start, events)
    value.apply(.end(ok: ok))
    let outcome = value.finish(exitCode: code)
    return (value, outcome)
}

func states(_ value: Steps) -> [State] { value.steps.map(\.state) }

// MARK: Lines

print("Lines")
let lines: [(String, Event?)] = [
    ("plan xcode anaconda gh", .plan(["xcode", "anaconda", "gh"])),
    ("state gh ok", .state("gh", .ok)),
    ("state gh todo", .state("gh", .todo)),
    ("state gh always", .state("gh", .always)),
    ("running gh GitHub CLI", .running("gh")),
    ("done gh GitHub CLI", .done("gh", "GitHub CLI")),
    ("skipped gh GitHub CLI (up to date)", .skipped("gh", "GitHub CLI (up to date)")),
    ("failed gh The GitHub CLI install failed.", .failed("gh", "The GitHub CLI install failed.")),
    ("failed - Do not run this installer with sudo.", .failed(nil, "Do not run this installer with sudo.")),
    ("ask anaconda Do you accept? (y/n)", .ask("anaconda", "Do you accept? (y/n)")),
    ("end ok", .end(ok: true)),
    ("end failed", .end(ok: false)),
    // Not events: no key, an unknown check result, a question outside a step, the lines of the old protocol.
    ("plan", nil),
    ("state gh", nil),
    ("state gh done", nil),
    ("running", nil),
    ("ask - Go on?", nil),
    ("end", nil),
    ("end maybe", nil),
    ("finished", nil),
    ("checked", nil),
    ("", nil),
]
for (line, event) in lines {
    check("\"\(line)\" -> \(event.map { "\($0)" } ?? "no event")", Steps.parse(line) == event)
}

// MARK: Run phase

print("Run phase")
do {
    var value = Steps()
    check("a new checklist is idle", value.phase == .idle)
    check("finish without a run gives no result", value.finish(exitCode: 0) == nil && value.phase == .idle)
    check("no event is legal while idle", !value.apply(.plan(keys)) && !value.apply(.end(ok: true)) && !value.apply(.failed(nil, "x")))
    check("idle + begin(check) -> planning(check)", value.begin(.check) && value.phase == .planning(.check))
    check("planning refuses a second begin", !value.begin(.install) && value.phase == .planning(.check))
    let early: [Event] = [.state("one", .ok), .running("one"), .done("one", ""), .skipped("one", ""), .failed("one", "x"),
                          .ask("one", "?"), .end(ok: true)]
    for event in early { check("planning refuses \(event)", !value.apply(event) && value.phase == .planning(.check)) }
    check("planning accepts a failure outside a step", value.apply(.failed(nil, "early")) && value.phase == .planning(.check))
    check("planning refuses a plan with a key two times", !value.apply(.plan(["one", "one"])) && value.steps.isEmpty)
    check("planning(check) + plan -> running(check)", value.apply(.plan(keys)) && value.phase == .running(.check))
    check("the plan gives the steps in order, numbered from 1",
          value.steps.map(\.key) == keys && value.steps.map(\.number) == [1, 2, 3] && states(value) == [.unknown, .unknown, .unknown])
    check("running refuses a second plan", !value.apply(.plan(["four"])) && value.steps.map(\.key) == keys)
    check("running refuses begin", !value.begin(.install))
    check("running(check) + end ok -> ended(check, ok)", value.apply(.end(ok: true)) && value.phase == .ended(.check, ok: true))
    let late: [Event] = [.plan(keys), .state("one", .ok), .running("one"), .failed(nil, "x"), .end(ok: false)]
    for event in late { check("ended refuses \(event)", !value.apply(event) && value.phase == .ended(.check, ok: true)) }
    check("ended refuses begin", !value.begin(.install))
    _ = value.finish(exitCode: 0)
    check("finish -> idle", value.phase == .idle)

    var install = Steps()
    install.begin(.install)
    check("idle + begin(install) -> planning(install)", install.phase == .planning(.install))
    install.apply(.plan(keys))
    check("planning(install) + plan -> running(install)", install.phase == .running(.install))
    install.apply(.end(ok: false))
    check("running(install) + end failed -> ended(install, failed)", install.phase == .ended(.install, ok: false))
    for phase in [Steps.RunPhase.planning(.install), .running(.install)] {
        var value = Steps()
        value.begin(.install)
        if phase == .running(.install) { value.apply(.plan(keys)) }
        check("finish in \(phase) -> idle", value.finish(exitCode: 1) != nil && value.phase == .idle)
    }
}

// MARK: Step state, check run

print("Step state, check run")
for result in [State.ok, .todo, .always] {
    var value = run(.check)
    check("unknown + state \(result) -> \(result)", value.apply(.state("one", result)) && value.state(of: "one") == result)
    for again in [State.ok, .todo, .always] {
        var copy = value
        check("\(result) refuses state \(again)", !copy.apply(.state("one", again)) && copy.state(of: "one") == result)
    }
}
do {
    var value = run(.check)
    check("a check result outside ok, todo, always is refused",
          !value.apply(.state("one", .done)) && !value.apply(.state("one", .running)) && value.state(of: "one") == .unknown)
    check("a check result for a key outside the plan is refused", !value.apply(.state("four", .ok)))
    let install: [Event] = [.running("one"), .done("one", ""), .skipped("one", ""), .failed("one", "x"), .ask("one", "?")]
    for event in install { check("the check run refuses \(event)", !value.apply(event) && value.state(of: "one") == .unknown) }
}

// MARK: Step state, install run

print("Step state, install run")
// The state of a step at the start of an install run: from no check, from the check, or from an earlier install run.
let starts: [(State, Steps)] = {
    var list: [(State, Steps)] = [(.unknown, Steps())]
    for result in [State.ok, .todo, .always] {
        let (value, _) = finished(.check, keys.map { .state($0, result) })
        list.append((result, value))
    }
    let earlier: [(State, Event)] = [(.done, .done("one", "")), (.skipped, .skipped("one", "")), (.failed, .failed("one", "x"))]
    for (state, event) in earlier {
        var value = run(.install, [.running("one"), event])
        _ = value.finish(exitCode: 1)
        list.append((state, value))
    }
    return list
}()
for (start, before) in starts {
    var value = run(.install, from: before)
    check("an install run keeps the state \(start) until the step runs", value.state(of: "one") == start)
    for event in [Event.done("one", ""), .skipped("one", ""), .failed("one", "x"), .ask("one", "?"), .state("one", .ok)] {
        var copy = value
        check("\(start) refuses \(event)", !copy.apply(event) && copy.state(of: "one") == start)
    }
    check("\(start) + running -> running", value.apply(.running("one")) && value.state(of: "one") == .running)
}
for (event, result) in [(Event.done("one", "Done"), State.done), (.skipped("one", "Skipped"), .skipped), (.failed("one", "Broken"), .failed)] {
    var value = run(.install, [.running("one")])
    check("running + \(event) -> \(result)", value.apply(event) && value.state(of: "one") == result)
    check("the detail of \(result) is \(result == .failed ? "its message" : "empty")",
          value.step("one")?.detail == (result == .failed ? "Broken" : ""))
    for again in [Event.running("one"), .done("one", ""), .skipped("one", ""), .failed("one", "x")] {
        var copy = value
        check("a step with a result in this run refuses \(again)", !copy.apply(again) && copy.state(of: "one") == result)
    }
}
do {
    var value = run(.install, [.running("one")])
    check("running refuses running", !value.apply(.running("one")))
    check("running refuses a check result", !value.apply(.state("one", .ok)))
    check("a second step cannot start while one runs", !value.apply(.running("two")) && value.state(of: "two") == .unknown)
    check("a result for a step that does not run is refused", !value.apply(.done("two", "")) && value.state(of: "two") == .unknown)
    check("a key outside the plan is refused", !value.apply(.running("four")) && !value.apply(.done("four", "")))
    check("running + ask -> running, with the question",
          value.apply(.ask("one", "Go on?")) && value.question == .init(key: "one", prompt: "Go on?") && value.state(of: "one") == .running)
    check("answered closes the question", value.answered() && value.question == nil && value.state(of: "one") == .running)
    check("answered without a question is refused", !value.answered())
    check("a question of a step that does not run is refused", !value.apply(.ask("two", "?")) && value.question == nil)
    value.apply(.ask("one", "Again?"))
    check("the result of the step closes its question", value.apply(.done("one", "")) && value.question == nil)
    value.apply(.running("two"))
    value.apply(.ask("two", "?"))
    check("a failure outside a step closes the question", value.apply(.failed(nil, "x")) && value.question == nil)
}
do {
    // The plan of an install run keeps the check results and the messages of the last run.
    var value = run(.install, [.running("one"), .failed("one", "Broken")])
    _ = value.finish(exitCode: 1)
    let kept = run(.install, from: value)
    check("an install run keeps the message of a failed step until it runs again", kept.step("one")?.detail == "Broken")
    var again = kept
    again.apply(.running("one"))
    again.apply(.done("one", ""))
    check("a new result removes the old message", again.step("one")?.detail == "")
    let checked = run(.check, from: value)
    check("a check run forgets the states and messages of the last run",
          states(checked) == [.unknown, .unknown, .unknown] && checked.step("one")?.detail == "")
}

// MARK: Run result

print("Run result")
let allDone: [Event] = keys.flatMap { [Event.running($0), .done($0, "")] }
do {
    let (_, ok) = finished(.check, keys.map { .state($0, .todo) })
    check("check: end ok, exit 0, and a result for each step -> ok", ok == .ok)
    let (value, partial) = finished(.check, [.state("one", .ok), .state("two", .ok)])
    check("check: a step without a result -> failed, and it stays unknown",
          partial == .failed(.unreported("three")) && value.state(of: "three") == .unknown)
    var noEnd = run(.check, keys.map { .state($0, .ok) })
    check("check: exit 0 without end -> failed", noEnd.finish(exitCode: 0) == .failed(.stopped(0)))
    let (_, stopped) = finished(.check, [], ok: false, code: 1)
    check("check: end failed -> failed with the exit code", stopped == .failed(.stopped(1)))
}
do {
    let (_, ok) = finished(.install, allDone)
    check("install: end ok, exit 0, and a result for each step -> ok", ok == .ok)
    let euFailed: [Event] = [.running("one"), .done("one", ""), .running("two"), .skipped("two", ""),
                             .running("three"), .failed("three", "EU mode is not ready")]
    let (value, withEU) = finished(.install, euFailed)
    check("install: a failed step that does not stop the setup (EU) -> ok, and the step stays failed",
          withEU == .ok && value.state(of: "three") == .failed)
    let (_, notOK) = finished(.install, allDone, ok: true, code: 1)
    check("install: end ok with exit 1 -> failed", notOK == .failed(.stopped(1)))
    var noEnd = run(.install, allDone)
    check("install: exit 0 without end -> failed, not ok", noEnd.finish(exitCode: 0) == .failed(.stopped(0)))
    let (failed, stop) = finished(.install, [.running("one"), .done("one", ""), .running("two"), .failed("two", "No access")],
                                  ok: false, code: 1)
    check("install: a failed step stops the setup -> failed with that step",
          stop == .failed(.step("two")) && failed.step("two")?.detail == "No access" && failed.state(of: "three") == .unknown)
    var killed = run(.install, [.running("one")])
    check("install: the installer stops while a step runs -> failed, and the step is failed",
          killed.finish(exitCode: 143) == .failed(.stopped(143)) && killed.state(of: "one") == .failed)
}

// The wrong states of SM-14: at exit 0, a step that is still unknown, running, todo, or always became skipped, a green
// tick. Now the run fails and no such step is skipped.
print("Run result, steps without a result (the old green ticks)")
for state in [State.unknown, .todo, .always] {
    let before = state == .unknown ? Steps() : finished(.check, keys.map { .state($0, state) }).0
    let (value, outcome) = finished(.install, from: before, [.running("one"), .done("one", "")])
    check("install: steps left \(state) at exit 0 -> failed, and they stay \(state), not skipped",
          outcome == .failed(.unreported("two")) && value.state(of: "two") == state && value.state(of: "three") == state)
}
do {
    let (value, outcome) = finished(.install, [.running("one"), .done("one", ""), .running("two")])
    check("install: a step left running at exit 0 -> failed, and the step is failed, not skipped",
          outcome == .failed(.unreported("two")) && value.state(of: "two") == .failed)
    // A failed step of an earlier run that this run did not run again is not a result of this run.
    var earlier = run(.install, [.running("one"), .done("one", ""), .running("two"), .done("two", ""),
                                 .running("three"), .failed("three", "x")])
    earlier.apply(.end(ok: false))
    _ = earlier.finish(exitCode: 1)
    let (_, again) = finished(.install, from: earlier, [.running("one"), .done("one", ""), .running("two"), .done("two", "")])
    check("install: a result of an earlier run does not count for this run", again == .failed(.unreported("three")))
}

// The failure outside a step: "failed 0" of the old protocol marked step 0, the app in Applications, as failed.
print("Run result, a failure outside a step")
do {
    var value = Steps()
    value.begin(.install)
    value.apply(.failed(nil, "These folders belong to another user"))
    value.apply(.plan(keys))
    value.apply(.end(ok: false))
    check("install: a failure before the first step -> failed with its message, and no step is failed",
          value.finish(exitCode: 1) == .failed(.installer("These folders belong to another user")) && !value.steps.contains { $0.state == .failed })
    check("the old line \"failed 0 <message>\" is no failure outside a step", Steps.parse("failed 0 x") == .failed("0", "x"))
    var old = run(.install)
    check("and no step has the key 0", !old.apply(.failed("0", "x")))
}

// MARK: Labels

print("Labels of the installer steps")
check("run.sh gives the keys of the step table of install.sh", !installerKeys.isEmpty)
check("the installer keys are each one time in the table", Set(installerKeys).count == installerKeys.count)
for key in installerKeys {
    check("the app has a name and a note for the step \(key)", Steps.labels[key] != nil)
}
check("the app has no label for a key that is not in the step table", Set(Steps.labels.keys) == Set(installerKeys))
for key in [Steps.Key.anaconda, Steps.Key.githubLogin, Steps.Key.claudeLogin, Steps.Key.googleSignIn] {
    check("the key \(key) of the setup window is in the step table", installerKeys.contains(key))
}

print(failures == 0 ? "All checks passed." : "\(failures) checks failed.")
exit(failures == 0 ? 0 : 1)
