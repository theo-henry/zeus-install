import Darwin
import Foundation

/// The handoff of an app update between the waiting process and the new copy of the app, in
/// `~/Library/Application Support/Zeus/update.json`. The waiting process is the old copy of the app (`Updater.install`) or
/// install.sh (an update of an installed app). It puts the new app in place of the old app, keeps the old app, and waits
/// for the new copy to confirm its start; when the new copy does not confirm, it puts the old app back.
///
/// This type owns the stages of the handoff and its legal transitions. The old copy, the new copy, and install.sh all use
/// them: the app through this type, install.sh through the same stage names in the same file (see `install.sh`,
/// `write_app_pending` and `app_pending_stage`). A transition happens under a lock (`UpdateHandoffFile.apply`), so the
/// confirmation of the new copy and the roll back of the waiting process cannot both win.
///
/// Stages and transitions (each other transition is refused):
///
///     swapped ──new copy starts──▶ newCopyStarted(pid) ──the same copy confirms──▶ confirmed ──▶ (file removed)
///        │                            │      ▲  └─another copy starts: it replaces pid
///        └──────waiter rolls back─────┴──────┴──▶ rolledBack(until) ──after until──▶ (file removed)
///
/// It is pure Foundation code (no AppKit), so that a unit test compiles it alone (app/test/update-handoff).
struct UpdateHandoff: Equatable {
    enum Stage: Equatable {
        /// The new app is in the place of the old app, and the waiting process waits for the new copy.
        case swapped
        /// The new copy with this process ID runs its first launch step, before any Zeus session.
        case newCopyStarted(pid: Int32)
        /// The new copy confirmed its start. The waiting process removes the old app and the file.
        case confirmed
        /// The waiting process put the old app back (or does so now). Until `until`, while the waiting process runs, a copy
        /// that starts is a late start of the new copy and quits at once: macOS can start it after the roll back, from the
        /// app path that holds the old app again, and without this mark that copy would update again at launch.
        case rolledBack(until: Date)
    }

    /// An event of the handoff: it moves the stage, or it is refused.
    enum Event: Equatable {
        case newCopyStarts(pid: Int32)
        case newCopyConfirms(pid: Int32)
        case waiterRollsBack(until: Date)
    }

    /// The time that the roll back mark stays after a roll back.
    static let lateStartWindow: TimeInterval = 120

    /// The end of a roll back mark made at `now`: `lateStartWindow` later, in whole seconds since 1970, so that it is the
    /// same after the file round trip.
    static func rollBackEnd(now: Date) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 + lateStartWindow).rounded())
    }

    var from: String
    var to: String
    var appPath: String
    /// The old app, kept until the new copy confirms.
    var backupPath: String
    /// The folder of the update files, removed at the end.
    var workPath: String
    /// The old copy of the app, or install.sh, which waits for the confirmation.
    var waitingPID: Int32
    var stage: Stage

    // MARK: Transitions

    /// The stage after `event`, or nil when the transition is not legal.
    static func next(_ stage: Stage, _ event: Event) -> Stage? {
        switch (stage, event) {
        case (.swapped, .newCopyStarts(let pid)), (.newCopyStarted, .newCopyStarts(let pid)):
            return .newCopyStarted(pid: pid)
        case (.newCopyStarted(let started), .newCopyConfirms(let pid)) where started == pid:
            return .confirmed
        case (.swapped, .waiterRollsBack(let until)), (.newCopyStarted, .waiterRollsBack(let until)):
            return .rolledBack(until: until)
        default:
            return nil
        }
    }

    // MARK: The role of a copy that starts

    enum Role: Equatable {
        /// No update for this copy; the file stays.
        case normal
        /// The roll back mark has ended: the file is removed, and the copy starts normally.
        case removeMark
        /// An update that stopped (the waiting process does not run): the update files are removed, and the copy starts normally.
        case removeStopped
        /// The new copy, while the waiting process runs: it starts and confirms.
        case newCopy
        /// The new copy, after the waiting process stopped: it finishes the update itself (removes the old app and the file).
        case newCopyAlone
        /// A late start of the new copy after a roll back: it quits at once.
        case late
    }

    /// The role of a copy of the app that starts, at its first launch step. `pid` is its process ID, `version` and
    /// `bundlePath` (standardized) are its own. `isAlive` tells whether a process runs, `exists` whether a path exists.
    static func role(_ handoff: UpdateHandoff?, version: String, bundlePath: String, pid: Int32, now: Date,
                     isAlive: (Int32) -> Bool, exists: (String) -> Bool) -> Role {
        guard let handoff else { return .normal }
        // A process ID that is this copy's own is a reused process ID: the waiting process has ended.
        let waiterRuns = handoff.waitingPID != pid && isAlive(handoff.waitingPID)
        if case .rolledBack(let until) = handoff.stage {
            return waiterRuns && now < until ? .late : .removeMark
        }
        if handoff.to == version, handoff.appPath == bundlePath {
            if !waiterRuns { return .newCopyAlone }
            // Another copy of the new version already confirmed; this one is not the new copy of the update.
            if handoff.stage == .confirmed { return .normal }
            return .newCopy
        }
        if !waiterRuns {
            // A stopped update: the app is the old copy again, or the update files are left from an earlier launch.
            // Without an app at the app path, the kept old app is the only app, so nothing is removed.
            return exists(handoff.appPath) ? .removeStopped : .normal
        }
        return .normal
    }

    // MARK: The waiting process

    enum WaiterStep: Equatable {
        case wait
        /// The new copy confirmed: remove the old app and the file.
        case finish
        /// Put the old app back, for this reason.
        case rollBack(String)
    }

    /// One poll of the waiting process. `deadline` is the end of the time that the new copy has to confirm.
    static func waiterStep(_ handoff: UpdateHandoff?, now: Date, deadline: Date, isAlive: (Int32) -> Bool) -> WaiterStep {
        switch handoff?.stage {
        case .confirmed?:
            return .finish
        case .rolledBack?:
            return .rollBack("the update was rolled back")
        case .newCopyStarted(let pid)? where !isAlive(pid):
            return .rollBack("the new app stopped")
        default:
            return now > deadline ? .rollBack("the new app did not confirm") : .wait
        }
    }

    // MARK: The file

    /// The fields on disk. `stage`, `newPID`, and `rolledBackUntil` are the handoff. `confirmed` and `rolledBack` are the
    /// fields of app versions before the stage (0.1.x): they stay written, because such an app can be the new copy
    /// (install.sh installs the newest release, which can be older than install.sh) or the waiting process. Such an
    /// app also writes the file without `stage`; the stage then comes from the old fields.
    private struct Record: Codable {
        var from: String
        var to: String
        var appPath: String
        var backupPath: String
        var workPath: String
        var waitingPID: Int32
        var stage: String?
        var newPID: Int32?
        var rolledBackUntil: Double?
        /// Always written: the app versions before the stage cannot read a file without it.
        var confirmed: Bool?
        var rolledBack: Bool?
    }

    /// Decodes the file. `modified` is its modification time: a roll back mark without an end (an app version before
    /// the stage) ends `lateStartWindow` after it. An unknown stage is no handoff.
    static func decode(_ data: Data, modified: Date) -> UpdateHandoff? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        let stage: Stage
        switch record.stage {
        case "swapped"?: stage = .swapped
        case "newCopyStarted"?:
            guard let pid = record.newPID else { return nil }
            stage = .newCopyStarted(pid: pid)
        case "confirmed"?: stage = .confirmed
        case "rolledBack"?:
            stage = .rolledBack(until: record.rolledBackUntil.map(Date.init(timeIntervalSince1970:))
                ?? modified.addingTimeInterval(lateStartWindow))
        case nil:
            if record.rolledBack == true {
                stage = .rolledBack(until: modified.addingTimeInterval(lateStartWindow))
            } else if record.confirmed == true {
                stage = .confirmed
            } else if let pid = record.newPID {
                stage = .newCopyStarted(pid: pid)
            } else {
                stage = .swapped
            }
        default:
            return nil
        }
        return UpdateHandoff(from: record.from, to: record.to, appPath: record.appPath, backupPath: record.backupPath,
                             workPath: record.workPath, waitingPID: record.waitingPID, stage: stage)
    }

    func encoded() throws -> Data {
        var record = Record(from: from, to: to, appPath: appPath, backupPath: backupPath, workPath: workPath,
                            waitingPID: waitingPID, confirmed: false)
        switch stage {
        case .swapped:
            record.stage = "swapped"
        case .newCopyStarted(let pid):
            record.stage = "newCopyStarted"
            record.newPID = pid
        case .confirmed:
            record.stage = "confirmed"
            record.confirmed = true
        case .rolledBack(let until):
            record.stage = "rolledBack"
            record.rolledBackUntil = until.timeIntervalSince1970
            record.rolledBack = true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
}

/// The handoff file, and the lock of its transitions: `update.lock` in the same folder, with flock(2). install.sh takes the
/// same lock (`lock_app_pending`).
struct UpdateHandoffFile {
    let url: URL

    var lockURL: URL { url.deletingLastPathComponent().appendingPathComponent("update.lock") }

    enum Transition: Equatable {
        case applied(previous: UpdateHandoff, next: UpdateHandoff)
        /// The event is not legal in the current stage, or there is no handoff (nil).
        case refused(current: UpdateHandoff?)
    }

    func read() -> UpdateHandoff? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        return UpdateHandoff.decode(data, modified: modified)
    }

    func write(_ handoff: UpdateHandoff) throws {
        try handoff.encoded().write(to: url, options: .atomic)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    /// Removes the file when it still holds `handoff` (another update did not start since).
    func remove(ifStill handoff: UpdateHandoff) {
        withLock { if read() == handoff { remove() } }
    }

    /// Applies `event` to the handoff in the file, under the lock.
    func apply(_ event: UpdateHandoff.Event) -> Transition {
        withLock {
            let found = read()
            guard let current = found, let stage = UpdateHandoff.next(current.stage, event) else {
                return .refused(current: found)
            }
            var next = current
            next.stage = stage
            guard (try? write(next)) != nil else { return .refused(current: current) }
            return .applied(previous: current, next: next)
        }
    }

    /// Runs `body` while this process holds the lock. Without a lock file (no access), it runs without the lock.
    func withLock<T>(_ body: () -> T) -> T {
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }
}
