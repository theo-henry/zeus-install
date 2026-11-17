import Foundation

/// The read block of Standard sessions: the app starts every Standard `zeus` through `/usr/bin/sandbox-exec` with a
/// small macOS sandbox profile that allows everything except reading and writing the EU folders. The Standard Claude
/// Code, its hooks, its Bash commands, and every program that they start inherit it, so no Standard chat reads EU data:
/// not with Claude's Read tool, `cat`, Python, or a child shell. The profile does not limit the network, the keychain,
/// or any other folder, so content-cli and every other Standard tool work as without it.
///
/// The read block applies only on a Mac with an EU vault (its disk image, or a mounted vault with its marker), whether
/// the vault is open or locked. Without a vault, Standard starts exactly as before: people who never use EU see no change.
///
/// The app writes the profile from the EU folders of the EU profile of Zeus Editor (`eu-profile.json`) at start and
/// again before each Standard start, so that a new EU folder of a Zeus Editor update is in it. EU sessions do not use it.
enum StandardJail {
    static let sandboxExec = "/usr/bin/sandbox-exec"

    /// The folder of the profile, owner only. The profile denies Standard sessions writes in it, so that no Standard
    /// chat can change the profile of the next Standard session.
    static var folder: String { Paths.appSupport + "/jail" }
    static var profilePath: String { folder + "/standard.sb" }

    /// The command that starts a Standard `zeus`: in the jail, or as it is when the jail can not apply.
    struct Launch: Equatable {
        let executable: String
        let arguments: [String]
        /// Why the session runs without the jail, or nil when it runs in it.
        let unjailedReason: String?
    }

    /// The folders that Standard sessions may not read or write: the EU vault (its mount folder and its disk image), the
    /// EU folders of the EU profile (Claude Code folder, editor state, workspace, temporary folder), and the app's
    /// handover folder. A folder that holds the home folder, the Standard workspace, or the app folder is left out:
    /// Standard could not run without them (a schema 2 EU profile can share the Standard workspace).
    static func deniedFolders(profile: EUProfile = .load()) -> [String] {
        let candidates = [EUVault.mountPoint, EUVault.bundlePath, profile.configDir, profile.editorStateDir, profile.workspace,
                          profile.tmpDir, Handover.root]
        let needed = [Paths.home, Paths.zeusDir, Paths.appSupport].flatMap(forms)
        var result: [String] = []
        for folder in candidates.flatMap(forms) where !result.contains(folder) {
            if needed.contains(where: { contains(folder, $0) }) { continue }
            result.append(folder)
        }
        return result
    }

    /// The profile text. `(allow default)` keeps everything that Standard does today; the denies cover each folder and
    /// everything in it, for the session and every process that it starts.
    static func profileText(denied: [String], protected: [String]) throws -> String {
        var lines = [
            "(version 1)",
            "; The Zeus app writes this file. Standard Zeus sessions run in it: they may not read or write the EU folders.",
            "(allow default)",
        ]
        if !denied.isEmpty {
            lines.append("(deny file-read* file-write*")
            for folder in denied { lines.append("  (subpath \(try quoted(folder)))") }
            lines.append(")")
        }
        if !protected.isEmpty {
            lines.append("(deny file-write*")
            for folder in protected { lines.append("  (subpath \(try quoted(folder)))") }
            lines.append(")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the profile when its text changed, and gives its path. The folder is owner only and is not a link.
    static func prepare(profile: EUProfile = .load()) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard Handover.isDirectory(folder) else { throw failure("The jail folder of the app (\(EUSetup.display(folder))) is not a plain folder.") }
        chmod(folder, 0o700)
        let text = try profileText(denied: deniedFolders(profile: profile), protected: forms(folder))
        let path = profilePath
        if manager.contents(atPath: path) != Data(text.utf8) {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            chmod(path, 0o600)
        }
        return path
    }

    /// The command of a Standard `zeus`. It throws when the jail should apply but its profile can not be written: a
    /// Standard session then does not start.
    static func launch(command: String, arguments: [String]) throws -> Launch {
        guard vaultExists else { return Launch(executable: command, arguments: arguments, unjailedReason: "no EU vault on this Mac") }
        guard FileManager.default.isExecutableFile(atPath: sandboxExec) else {
            return Launch(executable: command, arguments: arguments, unjailedReason: "macOS has no \(sandboxExec)")
        }
        if editorSandboxesStandard() {
            return Launch(executable: command, arguments: arguments,
                          unjailedReason: "the installed Zeus Editor runs Standard commands in the Claude Code sandbox, which can not run in the jail")
        }
        let path = try prepare()
        return Launch(executable: sandboxExec, arguments: ["-f", path, command] + arguments, unjailedReason: nil)
    }

    /// A Zeus Editor from build 108 to the fix of zeus-editor PR 139 runs Standard Bash commands in the Claude Code
    /// sandbox, with `failIfUnavailable`. A macOS sandbox can not start inside another one, so that Standard Claude Code
    /// would not start in the jail. That Zeus Editor has the excluded command below in its `dist` (it ran
    /// `--via browser` queries outside the sandbox); no later or earlier one has it. The answer is kept until the folder changes.
    static func editorSandboxesStandard(root: String? = EUProfile.newestEditorRoot()) -> Bool {
        guard let root else { return false }
        let dist = root + "/dist"
        let changed = (try? FileManager.default.attributesOfItem(atPath: dist))?[.modificationDate] as? Date
        if let cached = sandboxCheck, cached.root == root, cached.changed == changed { return cached.result }
        let marker = Data("python3 scripts/zeus.py * --via browser*".utf8)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dist)) ?? []).filter { $0.hasSuffix(".mjs") }
        let result = files.contains { name in
            FileManager.default.contents(atPath: dist + "/" + name).map { $0.range(of: marker) != nil } ?? false
        }
        sandboxCheck = (root, changed, result)
        return result
    }

    /// This Mac has an EU vault: its disk image, or a mounted Zeus vault.
    static var vaultExists: Bool {
        #if DEBUG
        // Debug builds, for a test with the real home folder: the read block as on a Mac with a vault.
        if DebugEnvironment.value("ZEUS_APP_TEST_JAIL") == "1" { return true }
        #endif
        return FileManager.default.fileExists(atPath: EUVault.bundlePath) || (EUVault.isMountPoint(EUVault.mountPoint) && EUVault.markerData() != nil)
    }

    private static var sandboxCheck: (root: String, changed: Date?, result: Bool)?

    /// A path as given and as the macOS sandbox compares it: the real path of its longest existing part (on macOS
    /// `/tmp` is `/private/tmp`), with the rest of the path after it.
    static func forms(_ path: String) -> [String] {
        let given = (path as NSString).standardizingPath
        var existing = given
        var rest: [String] = []
        while existing != "/", !FileManager.default.fileExists(atPath: existing) {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var real = existing
        if let resolved = realpath(existing, nil) {
            real = String(cString: resolved)
            free(resolved)
        }
        let full = rest.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
        return full == given ? [given] : [given, full]
    }

    /// `outer` is `inner` or a folder that holds it.
    private static func contains(_ outer: String, _ inner: String) -> Bool {
        outer == "/" || inner == outer || inner.hasPrefix(outer + "/")
    }

    /// A path as a sandbox profile string. A path with a control character is refused.
    private static func quoted(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw failure("The EU folder \(path.debugDescription) can not be in the sandbox profile.")
        }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Zeus", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
