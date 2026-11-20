import Foundation

/// The one-time removal of EU mode from before the shared workspace and the EU vault. EU and Standard now work in the
/// same `~/Code/zeus`, and EU data is in the EU vault, mounted at `~/.zeus/eu`. What EU mode had before is test data
/// only, so the app removes it once, without a migration:
///
/// - `~/Code/zeus-eu`, the old EU workspace, when it is a copy of the zeus repo. A folder of another kind, or a link,
///   stays as it is.
/// - Everything in the plain folder `~/.zeus/eu` (the old EU Claude Code folder, EU editor state, EU data access, the
///   value salt). The vault mounts on that folder and would hide them, and the app does not make or open the vault over
///   a folder that holds files.
///
/// It never touches the vault's disk image, a mounted vault, or `~/Code/zeus`. It runs at app start, after a vault that
/// stayed open is locked and before any session starts, and writes what it removed and what it kept to
/// `~/Library/Logs/zeus-install/eu-cleanup.log`. When it is done it does not run again; a removal that fails is tried
/// again at the next app start.
enum LegacyEU {
    static var logFile: String { Paths.logDir + "/eu-cleanup.log" }

    struct Outcome: Equatable {
        var removed: [String] = []
        var kept: [String] = []
        var failed: [String] = []
    }

    /// Runs the removal when it has not run to the end before. Synchronous, at app start.
    static func removeOnce() {
        guard !Preferences.oldEURemoved else { return }
        let outcome = remove()
        if outcome.removed.isEmpty, outcome.kept.isEmpty, outcome.failed.isEmpty {
            Trace.log("old eu: nothing to remove")
        } else {
            write(outcome)
        }
        if outcome.failed.isEmpty { Preferences.oldEURemoved = true }
    }

    /// Removes the old EU workspace and the old EU state; every path that it looks at is in the outcome.
    static func remove(workspace: String = Paths.oldEUWorkspace, state: String = EUVault.mountPoint,
                       protected: [String] = [Paths.zeusDir, EUVault.bundlePath]) -> Outcome {
        var outcome = Outcome()
        let manager = FileManager.default
        func delete(_ path: String) {
            do {
                try manager.removeItem(atPath: path)
                outcome.removed.append(path)
            } catch {
                outcome.failed.append("\(path): \(error.localizedDescription)")
            }
        }
        // A path that holds or is in a protected path (the Standard workspace, the vault's disk image) is never removed.
        let protectedForms = protected.flatMap(StandardJail.forms)
        func touchesProtected(_ path: String) -> Bool {
            StandardJail.forms(path).contains { form in
                protectedForms.contains { $0 == form || $0.hasPrefix(form + "/") || form.hasPrefix($0 + "/") }
            }
        }

        switch kind(workspace) {
        case .missing: break
        case .link: outcome.kept.append("\(workspace): a link, not the old EU workspace")
        case .other: outcome.kept.append("\(workspace): not a folder")
        case .folder:
            if touchesProtected(workspace) {
                outcome.kept.append("\(workspace): it is or holds the Zeus workspace")
            } else if !isZeusClone(workspace) {
                outcome.kept.append("\(workspace): not a copy of the zeus repo")
            } else {
                delete(workspace)
            }
        }

        switch kind(state) {
        case .missing: break
        case .link: outcome.kept.append("\(state): a link, not the EU folder")
        case .other: outcome.kept.append("\(state): not a folder")
        case .folder:
            if EUVault.isMountPoint(state) {
                // The vault is mounted: what is there is the vault, never old state.
                break
            }
            let names = ((try? manager.contentsOfDirectory(atPath: state)) ?? []).sorted()
            for name in names {
                let path = state + "/" + name
                if touchesProtected(path) { outcome.kept.append("\(path): it is or holds a protected path"); continue }
                delete(path)
            }
        }
        return outcome
    }

    private enum Kind { case missing, link, folder, other }

    /// The kind of a path, without following a link.
    private static func kind(_ path: String) -> Kind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .folder
        default: return .other
        }
    }

    /// The folder is a git copy of the zeus repo: `.git/config` is a plain file and names the zeus repo as a remote URL.
    static func isZeusClone(_ folder: String) -> Bool {
        let config = folder + "/.git/config"
        guard kind(folder + "/.git") == .folder, kind(config) == .other,
              let data = FileManager.default.contents(atPath: config) else { return false }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("url") else { return false }
            let parts = text.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" else { return false }
            let url = parts[1].trimmingCharacters(in: .whitespaces)
            return url.range(of: #"[/:]theo-henry/zeus(\.git)?/?$"#, options: .regularExpression) != nil
        }
    }

    private static func write(_ outcome: Outcome) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ["\(stamp) Zeus app \(Updater.currentVersion): removal of EU mode from before the shared workspace and the EU vault"]
        lines += outcome.removed.map { "\(stamp) removed \(EUSetup.display($0))" }
        lines += outcome.kept.map { "\(stamp) kept \(EUSetup.display($0))" }
        lines += outcome.failed.map { "\(stamp) failed \(EUSetup.display($0))" }
        for line in lines.dropFirst() { Trace.log("old eu: \(line.dropFirst(stamp.count + 1))") }
        try? FileManager.default.createDirectory(atPath: Paths.logDir, withIntermediateDirectories: true)
        let text = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: logFile) {
            handle.seekToEndOfFile()
            handle.write(text)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logFile, contents: text, attributes: [.posixPermissions: 0o600])
        }
    }
}
