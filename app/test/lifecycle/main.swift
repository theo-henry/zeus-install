import Foundation

// The window of the quit question (NSWindow in the app).
final class Window {}
typealias Lifecycle = AppLifecycle<Window>

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  PASS \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

// MARK: App phase

let allEvents: [AppEvent] = [.launchUpdateStarted, .zeusStarted, .updateCheckStarted, .updateFound, .updateNone,
                             .updateReady, .installStarted, .tabsBusyAgain, .installFailed]

// Each phase, with the events that reach it from the start.
let phases: [(AppPhase, [AppEvent])] = [
    (.launching, []),
    (.launchUpdate, [.launchUpdateStarted]),
    (.running(update: nil), [.zeusStarted]),
    (.running(update: .checking), [.zeusStarted, .updateCheckStarted]),
    (.running(update: .downloading), [.zeusStarted, .updateCheckStarted, .updateFound]),
    (.running(update: .waiting), [.zeusStarted, .updateCheckStarted, .updateFound, .updateReady]),
    (.running(update: .installing), [.zeusStarted, .updateCheckStarted, .updateFound, .updateReady, .installStarted]),
]

// The legal transitions (the table of AppLifecycle.swift). Every other pair is refused.
let legal: [(AppPhase, AppEvent, AppPhase)] = [
    (.launching, .launchUpdateStarted, .launchUpdate),
    (.launching, .zeusStarted, .running(update: nil)),
    (.launchUpdate, .zeusStarted, .running(update: nil)),
    (.running(update: nil), .updateCheckStarted, .running(update: .checking)),
    (.running(update: .checking), .updateFound, .running(update: .downloading)),
    (.running(update: .checking), .updateNone, .running(update: nil)),
    (.running(update: .downloading), .updateNone, .running(update: nil)),
    (.running(update: .checking), .updateReady, .running(update: .waiting)),
    (.running(update: .downloading), .updateReady, .running(update: .waiting)),
    (.running(update: .waiting), .installStarted, .running(update: .installing)),
    (.running(update: .installing), .tabsBusyAgain, .running(update: .waiting)),
    (.running(update: .installing), .installFailed, .running(update: nil)),
]

func lifecycle(at phase: AppPhase, by events: [AppEvent]) -> Lifecycle {
    var value = Lifecycle()
    for event in events { _ = value.apply(event) }
    return value
}

print("App phase")
for (phase, path) in phases {
    let start = lifecycle(at: phase, by: path)
    check("the events \(path.map(\.rawValue)) reach \(phase)", start.app == phase)
    for event in allEvents {
        var value = start
        let applied = value.apply(event)
        if let target = legal.first(where: { $0.0 == phase && $0.1 == event })?.2 {
            check("\(phase) + \(event.rawValue) -> \(target)", applied && value.app == target)
        } else {
            check("\(phase) refuses \(event.rawValue) and stays", !applied && value.app == phase)
        }
    }
}

// One value for the update: what blocks the sessions and the step of a page update come from the same phase, so the
// two cannot disagree (before, AppDelegate.updating and AppUpdate.phase were two values).
let blocking = phases.filter { $0.0.blocksSessions }.map { "\($0.0)" }
check("only the update at launch and the install of a page update block the sessions (\(blocking))",
      blocking == ["launch-update", "running/installing"])
check("the update at launch is no page update step", AppPhase.launchUpdate.updateStep == nil)
check("a page update shows its step", AppPhase.running(update: .waiting).updateStep == .waiting)
check("the steps are the states of app-update-progress",
      [UpdateStep.checking, .downloading, .waiting, .installing].map(\.rawValue) == ["checking", "downloading", "waiting", "installing"])

// MARK: Quit phase

print("Quit phase")
let window = Window()
let other = Window()

func idle() -> Lifecycle { Lifecycle() }
func checking() -> Lifecycle {
    var value = Lifecycle()
    _ = value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: false)
    return value
}
func asking() -> Lifecycle {
    var value = checking()
    _ = value.tabsChecked(unsafeWindow: window)
    return value
}
func approved() -> Lifecycle {
    var value = checking()
    _ = value.tabsChecked(unsafeWindow: nil)
    return value
}
func stopping() -> Lifecycle {
    var value = approved()
    _ = value.terminate(sessionsAlive: true, vaultMounted: true, byMacOS: false)
    return value
}
func locking() -> Lifecycle {
    var value = Lifecycle()
    _ = value.terminate(sessionsAlive: false, vaultMounted: true, byMacOS: false)
    return value
}
let quitStates: [(String, () -> Lifecycle, QuitPhase<Window>)] = [
    ("idle", idle, .idle), ("checking-tabs", checking, .checkingTabs), ("asking", asking, .asking(window)),
    ("approved", approved, .approved), ("stopping", stopping, .stopping), ("locking-vault", locking, .lockingVault),
]
for (name, make, phase) in quitStates {
    check("the quit reaches \(name)", make().quit == phase)
}

// terminate: no session runs.
for (name, make, _) in quitStates where name != "locking-vault" {
    var value = make()
    check("\(name): a terminate without a session and without an EU vault quits now",
          value.terminate(sessionsAlive: false, vaultMounted: false, byMacOS: false) == .now)
    value = make()
    check("\(name): a terminate without a session locks the mounted EU vault",
          value.terminate(sessionsAlive: false, vaultMounted: true, byMacOS: false) == .lockVault && value.quit == .lockingVault)
}
do {
    var value = locking()
    check("locking-vault: a second terminate waits for the lock and does not lock again",
          value.terminate(sessionsAlive: false, vaultMounted: true, byMacOS: false) == .wait && value.quit == .lockingVault)
}

// terminate: sessions run.
do {
    var value = idle()
    check("idle: a user quit checks the tabs and cancels the terminate",
          value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: false) == .checkTabs && value.quit == .checkingTabs)
    value = checking()
    check("checking-tabs: a second user quit only cancels",
          value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: false) == .cancel && value.quit == .checkingTabs)
    value = asking()
    check("asking: a second user quit only cancels",
          value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: false) == .cancel && value.quit == .asking(window))
    value = approved()
    check("approved: the terminate stops the sessions",
          value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: false) == .stopSessions(endQuestion: nil)
              && value.quit == .stopping)
    value = stopping()
    check("stopping: a later terminate waits and does not stop again",
          value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: true) == .wait && value.quit == .stopping)
    value = locking()
    check("locking-vault: a terminate waits for the lock",
          value.terminate(sessionsAlive: true, vaultMounted: true, byMacOS: false) == .wait && value.quit == .lockingVault)
}
for (name, make) in [("idle", idle), ("checking-tabs", checking)] {
    var value = make()
    check("\(name): a quit of macOS asks nothing and stops the sessions",
          value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: true) == .stopSessions(endQuestion: nil)
              && value.quit == .stopping)
}
do {
    var value = asking()
    check("asking: a quit of macOS ends the question and stops the sessions",
          value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: true) == .stopSessions(endQuestion: window)
              && value.quit == .stopping)
}

// tabsChecked.
do {
    var value = checking()
    check("checking-tabs: every tab safe approves the quit",
          value.tabsChecked(unsafeWindow: nil) == .approved(endQuestion: nil) && value.quit == .approved)
    value = checking()
    check("checking-tabs: an unsafe tab asks on its window",
          value.tabsChecked(unsafeWindow: window) == .ask(window) && value.quit == .asking(window))
}
for (name, make, phase) in quitStates where name != "checking-tabs" {
    var value = make()
    check("\(name): a late tab check is ignored", value.tabsChecked(unsafeWindow: window) == .ignored && value.quit == phase)
}

// answered.
do {
    var value = asking()
    check("asking: Quit Anyway approves the quit", value.answered(quitAnyway: true, on: window) == .approved(endQuestion: nil)
        && value.quit == .approved)
    value = asking()
    check("asking: Cancel ends the quit", value.answered(quitAnyway: false, on: window) == .cancelled && value.quit == .idle)
    value = asking()
    check("asking: an answer on another window is ignored",
          value.answered(quitAnyway: true, on: other) == .ignored && value.quit == .asking(window))
}
for (name, make, phase) in quitStates where name != "asking" {
    var value = make()
    check("\(name): an answer after the question ended (the sheet that the app ends) is ignored",
          value.answered(quitAnyway: false, on: window) == .ignored && value.quit == phase)
}

// questionWindowClosed: the defect. AppKit does not call the sheet's completion handler when its window closes; before,
// the quit stayed "checking" and each later user quit was cancelled with nothing shown.
do {
    var value = asking()
    check("asking: the window of the question closes, and the quit ends",
          value.questionWindowClosed(window) == .cancelled && value.quit == .idle)
    check("after the closed window, a later user quit checks the tabs again",
          value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: false) == .checkTabs && value.quit == .checkingTabs)
    value = asking()
    check("asking: another window that closes changes nothing",
          value.questionWindowClosed(other) == .ignored && value.quit == .asking(window))
}
for (name, make, phase) in quitStates where name != "asking" {
    var value = make()
    check("\(name): a closed window is ignored", value.questionWindowClosed(window) == .ignored && value.quit == phase)
}

// approve (power off while a user quit checks or asks, the test action).
for (name, make) in [("idle", idle), ("checking-tabs", checking)] {
    var value = make()
    check("\(name): approve approves the quit", value.approve() == .approved(endQuestion: nil) && value.quit == .approved)
}
do {
    var value = asking()
    check("asking: approve ends the question and approves the quit",
          value.approve() == .approved(endQuestion: window) && value.quit == .approved)
}
for (name, make, phase) in quitStates where ["approved", "stopping", "locking-vault"].contains(name) {
    var value = make()
    check("\(name): approve is ignored", value.approve() == .ignored && value.quit == phase)
}
check("a power-off warning approves only a user quit that checks or asks",
      quitStates.filter { $0.1().quit.isUserQuit }.map(\.0) == ["checking-tabs", "asking"])

// The two phases are independent: a quit does not change the app phase, and an update does not change the quit phase.
do {
    var value = lifecycle(at: .running(update: .installing), by: phases[6].1)
    _ = value.terminate(sessionsAlive: true, vaultMounted: false, byMacOS: false)
    check("a quit during an install keeps the app phase", value.app == .running(update: .installing) && value.quit == .checkingTabs)
    _ = value.apply(.tabsBusyAgain)
    check("an update step during a quit keeps the quit phase", value.quit == .checkingTabs)
}

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("All checks passed")
