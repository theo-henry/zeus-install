import Foundation

// Unit test of UpdateHandoff (app/Sources/Zeus/UpdateHandoff.swift): the stages of an app update handoff, its legal
// transitions, the role of a copy that starts, the step of the waiting process, and the file on disk.
// Without arguments it runs the tables. With arguments, run.sh uses it as the app side of the file contract:
//   decode <file>                     prints the handoff that the app reads in the file
//   write <file> <stage> [pid]        writes a handoff as the app does (stage: swapped, newCopyStarted, confirmed, rolledBack)
//   confirm <file> <pid>              the new copy confirms, under the lock; prints "applied" or "refused <stage>"
//   hold-lock <file> <seconds>        holds the lock of the file

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  PASS \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

func describe(_ stage: UpdateHandoff.Stage?) -> String {
    switch stage {
    case nil: return "none"
    case .swapped?: return "swapped"
    case .newCopyStarted(let pid)?: return "newCopyStarted \(pid)"
    case .confirmed?: return "confirmed"
    case .rolledBack(let until)?: return "rolledBack \(Int(until.timeIntervalSince1970))"
    }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let later = now.addingTimeInterval(UpdateHandoff.lateStartWindow)
let waiter: Int32 = 100
let newCopy: Int32 = 200
let other: Int32 = 300
func handoff(_ stage: UpdateHandoff.Stage, waitingPID: Int32 = waiter) -> UpdateHandoff {
    UpdateHandoff(from: "1.0.0", to: "1.1.0", appPath: "/Applications/Zeus.app",
                  backupPath: "/tmp/work/previous/Zeus.app", workPath: "/tmp/work", waitingPID: waitingPID, stage: stage)
}

// The app side of run.sh.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first {
    let file = UpdateHandoffFile(url: URL(fileURLWithPath: arguments[1]))
    switch command {
    case "decode":
        guard let read = file.read() else { print("none"); exit(0) }
        print("\(describe(read.stage)) from=\(read.from) to=\(read.to) appPath=\(read.appPath) backupPath=\(read.backupPath) "
              + "workPath=\(read.workPath) waitingPID=\(read.waitingPID)")
    case "write":
        let pid = arguments.count > 3 ? Int32(arguments[3])! : newCopy
        let stages: [String: UpdateHandoff.Stage] = ["swapped": .swapped, "newCopyStarted": .newCopyStarted(pid: pid),
                                                     "confirmed": .confirmed, "rolledBack": .rolledBack(until: later)]
        try! file.write(handoff(stages[arguments[2]]!))
    case "confirm":
        switch file.apply(.newCopyConfirms(pid: Int32(arguments[2])!)) {
        case .applied: print("applied")
        case .refused(let current): print("refused \(describe(current?.stage))")
        }
    case "hold-lock":
        file.withLock {
            print("locked")
            fflush(stdout)
            Thread.sleep(forTimeInterval: Double(arguments[2])!)
        }
    default:
        print("unknown command \(command)")
        exit(2)
    }
    exit(0)
}

print("Transitions")
typealias Row = (String, UpdateHandoff.Stage, UpdateHandoff.Event, UpdateHandoff.Stage?)
let transitions: [Row] = [
    ("swapped: the new copy starts", .swapped, .newCopyStarts(pid: newCopy), .newCopyStarted(pid: newCopy)),
    ("newCopyStarted: another copy starts and replaces it", .newCopyStarted(pid: newCopy), .newCopyStarts(pid: other),
     .newCopyStarted(pid: other)),
    ("newCopyStarted: the same copy confirms", .newCopyStarted(pid: newCopy), .newCopyConfirms(pid: newCopy), .confirmed),
    ("swapped: the waiter rolls back", .swapped, .waiterRollsBack(until: later), .rolledBack(until: later)),
    ("newCopyStarted: the waiter rolls back", .newCopyStarted(pid: newCopy), .waiterRollsBack(until: later),
     .rolledBack(until: later)),
    ("refused: newCopyStarted, another copy confirms", .newCopyStarted(pid: newCopy), .newCopyConfirms(pid: other), nil),
    ("refused: swapped, a copy confirms without a start", .swapped, .newCopyConfirms(pid: newCopy), nil),
    ("refused: confirmed, the waiter rolls back (its time ran out in the same tick)", .confirmed,
     .waiterRollsBack(until: later), nil),
    ("refused: confirmed, a copy starts", .confirmed, .newCopyStarts(pid: other), nil),
    ("refused: confirmed, a copy confirms again", .confirmed, .newCopyConfirms(pid: newCopy), nil),
    ("refused: rolledBack, a late new copy starts (the loop of #22)", .rolledBack(until: later), .newCopyStarts(pid: newCopy), nil),
    ("refused: rolledBack, a late new copy confirms", .rolledBack(until: later), .newCopyConfirms(pid: newCopy), nil),
    ("refused: rolledBack, a second roll back", .rolledBack(until: later), .waiterRollsBack(until: later), nil),
]
for (name, stage, event, expected) in transitions {
    check(name, UpdateHandoff.next(stage, event) == expected)
}

print("Role of a copy that starts")
let runs: (Int32) -> Bool = { _ in true }
let stopped: (Int32) -> Bool = { _ in false }
let onlyWaiterRuns: (Int32) -> Bool = { $0 == waiter }
let present: (String) -> Bool = { _ in true }
let absent: (String) -> Bool = { _ in false }
func role(_ handoff: UpdateHandoff?, version: String = "1.1.0", path: String = "/Applications/Zeus.app", pid: Int32 = newCopy,
          at time: Date = now, isAlive: @escaping (Int32) -> Bool = runs,
          exists: @escaping (String) -> Bool = present) -> UpdateHandoff.Role {
    UpdateHandoff.role(handoff, version: version, bundlePath: path, pid: pid, now: time, isAlive: isAlive, exists: exists)
}
check("no file: normal", role(nil) == .normal)
check("swapped, the new version at the app path, the waiter runs: new copy", role(handoff(.swapped)) == .newCopy)
check("newCopyStarted by another copy, the waiter runs: new copy (it replaces the start)",
      role(handoff(.newCopyStarted(pid: other))) == .newCopy)
check("swapped, the waiter stopped: the new copy finishes alone", role(handoff(.swapped), isAlive: stopped) == .newCopyAlone)
check("confirmed, the waiter stopped before it finished: the new copy finishes alone",
      role(handoff(.confirmed), isAlive: stopped) == .newCopyAlone)
check("confirmed, the waiter runs: a second copy of the new version is not the new copy",
      role(handoff(.confirmed)) == .normal)
check("swapped, the waiting PID is this copy's own (reused): the waiter has ended",
      role(handoff(.swapped, waitingPID: newCopy), isAlive: runs) == .newCopyAlone)
check("swapped, another version: normal", role(handoff(.swapped), version: "1.0.0") == .normal)
check("swapped, another app path: normal", role(handoff(.swapped), path: "/Users/x/Applications/Zeus.app") == .normal)
check("swapped, another version, the waiter stopped: the files of the stopped update go",
      role(handoff(.swapped), version: "1.0.0", isAlive: stopped) == .removeStopped)
check("a stopped update without an app at the app path: nothing goes (the kept old app is the only app)",
      role(handoff(.swapped), version: "1.0.0", isAlive: stopped, exists: absent) == .normal)
check("rolledBack, the waiter runs, before the end of the mark: a late copy quits (the loop of #22)",
      role(handoff(.rolledBack(until: later)), version: "1.0.0", isAlive: onlyWaiterRuns) == .late)
check("rolledBack, a late copy of the new version: it quits", role(handoff(.rolledBack(until: later))) == .late)
check("rolledBack, the waiter stopped: the mark goes", role(handoff(.rolledBack(until: later)), isAlive: stopped) == .removeMark)
check("rolledBack, after the end of the mark, a process with the waiting PID runs (a reused PID): the mark goes",
      role(handoff(.rolledBack(until: later)), at: later.addingTimeInterval(1), isAlive: runs) == .removeMark)
check("rolledBack, the waiting PID is this copy's own: the mark goes",
      role(handoff(.rolledBack(until: later), waitingPID: newCopy)) == .removeMark)

print("Step of the waiting process")
let deadline = now.addingTimeInterval(20)
func step(_ handoff: UpdateHandoff?, at time: Date = now, isAlive: @escaping (Int32) -> Bool = runs) -> UpdateHandoff.WaiterStep {
    UpdateHandoff.waiterStep(handoff, now: time, deadline: deadline, isAlive: isAlive)
}
let afterDeadline = deadline.addingTimeInterval(0.1)
check("swapped, before the deadline: wait", step(handoff(.swapped)) == .wait)
check("newCopyStarted and running, before the deadline: wait", step(handoff(.newCopyStarted(pid: newCopy))) == .wait)
check("confirmed: finish", step(handoff(.confirmed)) == .finish)
check("confirmed after the deadline (the same tick): finish, no roll back", step(handoff(.confirmed), at: afterDeadline) == .finish)
check("newCopyStarted and stopped: roll back", step(handoff(.newCopyStarted(pid: newCopy)), isAlive: stopped)
      == .rollBack("the new app stopped"))
check("swapped after the deadline: roll back", step(handoff(.swapped), at: afterDeadline) == .rollBack("the new app did not confirm"))
check("newCopyStarted after the deadline: roll back",
      step(handoff(.newCopyStarted(pid: newCopy)), at: afterDeadline) == .rollBack("the new app did not confirm"))
check("no file before the deadline: wait", step(nil) == .wait)
check("no file after the deadline: roll back", step(nil, at: afterDeadline) == .rollBack("the new app did not confirm"))
check("rolledBack: roll back", step(handoff(.rolledBack(until: later))) == .rollBack("the update was rolled back"))

print("The file on disk")
let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zeus-update-handoff-\(getpid())")
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let file = UpdateHandoffFile(url: work.appendingPathComponent("update.json"))

for stage: UpdateHandoff.Stage in [.swapped, .newCopyStarted(pid: newCopy), .confirmed, .rolledBack(until: later)] {
    try! file.write(handoff(stage))
    check("\(describe(stage)): the app reads what it wrote", file.read() == handoff(stage))
}

// The handoff of app versions before the stage (0.1.x): what they read and write.
struct LegacyPending: Codable {
    var from: String
    var to: String
    var appPath: String
    var backupPath: String
    var workPath: String
    var waitingPID: Int32
    var newPID: Int32?
    var confirmed = false
    var rolledBack: Bool?
}
func legacyRead() -> LegacyPending? {
    (try? Data(contentsOf: file.url)).flatMap { try? JSONDecoder().decode(LegacyPending.self, from: $0) }
}
try! file.write(handoff(.swapped))
check("swapped: an older app reads it, not confirmed", legacyRead().map { !$0.confirmed && $0.newPID == nil && $0.rolledBack != true } == true)
try! file.write(handoff(.newCopyStarted(pid: newCopy)))
check("newCopyStarted: an older waiting app reads the process ID of the new copy", legacyRead()?.newPID == newCopy)
try! file.write(handoff(.confirmed))
check("confirmed: an older waiting app reads the confirmation", legacyRead()?.confirmed == true)
try! file.write(handoff(.rolledBack(until: later)))
check("rolledBack: an older new copy reads the roll back mark", legacyRead()?.rolledBack == true)

let modified = now
func legacy(_ fields: String) -> UpdateHandoff? {
    let json = #"{"from":"1.0.0","to":"1.1.0","appPath":"\/Applications\/Zeus.app","backupPath":"\/tmp\/work\/previous\/Zeus.app","#
        + #""workPath":"\/tmp\/work","waitingPID":100"# + fields + "}"
    return UpdateHandoff.decode(Data(json.utf8), modified: modified)
}
check("a file of an older app, swapped", legacy(#","confirmed":false"#) == handoff(.swapped))
check("a file of an older app, with the new copy's process ID", legacy(#","newPID":200,"confirmed":false"#)
      == handoff(.newCopyStarted(pid: newCopy)))
check("a file of an older app, confirmed", legacy(#","newPID":200,"confirmed":true"#) == handoff(.confirmed))
check("a file of an older app, rolled back: the mark ends 120 s after the file was written",
      legacy(#","confirmed":false,"rolledBack":true"#) == handoff(.rolledBack(until: modified.addingTimeInterval(120))))
check("a file with a stage and without the older fields is read", legacy(#","stage":"swapped""#) == handoff(.swapped))
check("an unknown stage is not a handoff", legacy(#","stage":"other","confirmed":false"#) == nil)
check("a stage newCopyStarted without a process ID is not a handoff", legacy(#","stage":"newCopyStarted","confirmed":false"#) == nil)
check("the stage wins over the older fields", legacy(#","stage":"swapped","newPID":200,"confirmed":false"#) == handoff(.swapped))

print("Transitions in the file, under the lock")
try! file.write(handoff(.swapped))
check("the new copy starts", file.apply(.newCopyStarts(pid: newCopy))
      == .applied(previous: handoff(.swapped), next: handoff(.newCopyStarted(pid: newCopy))))
check("the new copy confirms", file.apply(.newCopyConfirms(pid: newCopy))
      == .applied(previous: handoff(.newCopyStarted(pid: newCopy)), next: handoff(.confirmed)))
check("the deadline race: the waiter's roll back after the confirmation is refused, and the waiter sees the confirmation",
      file.apply(.waiterRollsBack(until: later)) == .refused(current: handoff(.confirmed)))
check("the file still says confirmed", file.read() == handoff(.confirmed))
try! file.write(handoff(.newCopyStarted(pid: newCopy)))
check("the waiter rolls back first; it gets the process ID of the new copy to stop",
      file.apply(.waiterRollsBack(until: later))
      == .applied(previous: handoff(.newCopyStarted(pid: newCopy)), next: handoff(.rolledBack(until: later))))
check("the new copy's confirmation after the roll back is refused (it quits as a late copy)",
      file.apply(.newCopyConfirms(pid: newCopy)) == .refused(current: handoff(.rolledBack(until: later))))
file.remove()
check("no file: a transition is refused", file.apply(.newCopyStarts(pid: newCopy)) == .refused(current: nil))
try! file.write(handoff(.rolledBack(until: later)))
file.remove(ifStill: handoff(.swapped))
check("remove(ifStill:) keeps a file that changed", file.read() == handoff(.rolledBack(until: later)))
file.remove(ifStill: handoff(.rolledBack(until: later)))
check("remove(ifStill:) removes the same file", file.read() == nil)

print(failures == 0 ? "All checks passed." : "\(failures) checks failed.")
exit(failures == 0 ? 0 : 1)
