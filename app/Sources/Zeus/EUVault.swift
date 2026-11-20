import Foundation
import LocalAuthentication
import Security

/// The EU vault: one encrypted APFS disk image (a sparse bundle, AES-256) per user, in
/// `~/Library/Application Support/Zeus/eu-vault.sparsebundle`, mounted at `~/.zeus/eu` without a Finder icon. EU data
/// is kept in it (the EU Claude Code folder with the EU chats and plugins, EU editor state, EU data access, the project
/// vaults), so that it is encrypted when the vault is locked. While it is open, Standard sessions can not read it
/// (`StandardJail`). The app opens it before the first EU session (`open`): it makes it on the first use of EU mode.
///
/// The key is a random password in the user's login keychain. The app creates the item, so the item trusts only the
/// Zeus app: another program that asks for it makes macOS ask the user for the login password. The app reads it only
/// after Touch ID (or the login password), keeps it only in its memory, and gives it to `hdiutil` on standard input:
/// never in an environment, an argument, a log, or a file. No Claude session ever gets it.
///
/// The app is ad-hoc signed, so the keychain knows it by the hash of its code, which changes with each version: after
/// an app update, macOS asks once for the login password before the new Zeus can read the key ("Always Allow").
///
/// The vault locks when the app quits, after the EU sessions stopped. A vault that stays open after a crash is locked
/// at the next app start, before anything else.
final class EUVault {
    enum Failure: Error, Equatable, LocalizedError {
        /// The user cancelled Touch ID or the login password.
        case cancelled
        case notAuthenticated(String)
        case noVault
        case alreadyExists
        /// The keychain has no key of the vault.
        case noKey
        /// The key in the keychain does not open the vault.
        case wrongPassword
        /// `~/.zeus/eu` holds files that the vault would hide (the EU folders from before the vault).
        case folderNotEmpty
        /// A program still has a file of the vault open.
        case busy
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "The EU vault stays locked: Touch ID was cancelled."
            case let .notAuthenticated(words): return "The EU vault stays locked: \(words)"
            case .noVault: return "There is no EU vault on this Mac."
            case .alreadyExists: return "The EU vault already exists."
            case .noKey: return "The key of the EU vault is not in your login keychain."
            case .wrongPassword: return "The key in your login keychain does not open the EU vault."
            case .folderNotEmpty: return "\(EUSetup.display(EUVault.mountPoint)) holds files of the EU mode from before the vault."
            case .busy: return "A program still uses a file in the EU vault."
            case let .failed(words): return words
            }
        }

        /// The word for the trace.
        var traceName: String {
            switch self {
            case .cancelled: return "cancelled"
            case .notAuthenticated: return "not authenticated"
            case .noVault: return "no vault"
            case .alreadyExists: return "already exists"
            case .noKey: return "no key"
            case .wrongPassword: return "wrong password"
            case .folderNotEmpty: return "folder not empty"
            case .busy: return "busy"
            case let .failed(words): return "failed: \(words)"
            }
        }
    }

    static let shared = EUVault()

    /// The mount folder: the EU folders of the EU profile are in it (`~/.zeus/eu/claude`, `~/.zeus/eu/editor`).
    static var mountPoint: String { Paths.home + "/.zeus/eu" }
    static var bundlePath: String { Paths.appSupport + "/eu-vault.sparsebundle" }
    /// The marker file in the vault: the vault is mounted and is the Zeus vault (zeus `eu_mode` checks it).
    static let markerName = ".zeus-vault"
    static let volumeName = "Zeus EU"
    /// The largest size of the vault; the sparse bundle takes only the space of its files.
    static let maximumSize = "100g"
    static let keychainService = "io.github.theo-henry.zeus.eu-vault"
    static let keychainAccount = "eu-vault"

    let authenticator: VaultAuthenticator
    let keys: VaultKeyStore
    private let queue = DispatchQueue(label: "zeus.eu-vault")

    init(authenticator: VaultAuthenticator? = nil, keys: VaultKeyStore? = nil) {
        #if DEBUG
        if authenticator == nil, let answer = DebugEnvironment.value("ZEUS_APP_TEST_VAULT_AUTH") {
            self.authenticator = TestVaultAuthenticator(answer: answer)
        } else {
            self.authenticator = authenticator ?? TouchIDAuthenticator()
        }
        #else
        self.authenticator = authenticator ?? TouchIDAuthenticator()
        #endif
        self.keys = keys ?? KeychainVaultKeyStore.standard()
    }

    var exists: Bool { FileManager.default.fileExists(atPath: Self.bundlePath) }

    /// A volume is mounted at the mount folder.
    var isMounted: Bool { Self.isMountPoint(Self.mountPoint) }

    /// The Zeus vault is open: a volume is mounted at the mount folder, with the marker of a Zeus vault. A quick check
    /// for the start of an EU session; `unlock` checks that the marker names the mounted volume.
    static var isOpen: Bool {
        isMountPoint(mountPoint) && markerData()?["kind"] as? String == "zeus-eu-vault"
    }

    // MARK: Create, unlock, lock

    /// Creates the vault and its key after Touch ID, and leaves it mounted. Main queue in, main queue out.
    func create(completion: @escaping (Result<Void, Failure>) -> Void) {
        if exists || isMounted { finish(.failure(.alreadyExists), "create", completion); return }
        if !Self.mountFolderIsFree() { finish(.failure(.folderNotEmpty), "create", completion); return }
        authenticator.authenticate(reason: "create the EU vault") { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result { self.finish(.failure(error), "create", completion); return }
            self.queue.async {
                let outcome = self.createNow()
                DispatchQueue.main.async { self.finish(outcome, "create", completion) }
            }
        }
    }

    /// Opens the vault for EU mode: makes it on the first use, else unlocks it, each after Touch ID. An open vault needs no
    /// Touch ID. Main queue in, main queue out.
    func open(completion: @escaping (Result<Void, Failure>) -> Void) {
        if isMounted || exists { unlock(completion: completion) } else { create(completion: completion) }
    }

    /// Mounts the vault after Touch ID. An open vault needs no Touch ID. Main queue in, main queue out.
    func unlock(completion: @escaping (Result<Void, Failure>) -> Void) {
        if isMounted {
            queue.async {
                let outcome: Result<Void, Failure> = Self.markerIsValid() ? .success(()) : .failure(.failed("The volume at \(EUSetup.display(Self.mountPoint)) is not the Zeus EU vault."))
                DispatchQueue.main.async { self.finish(outcome, "unlock", completion) }
            }
            return
        }
        if !exists { finish(.failure(.noVault), "unlock", completion); return }
        if !Self.mountFolderIsFree() { finish(.failure(.folderNotEmpty), "unlock", completion); return }
        authenticator.authenticate(reason: "unlock the EU vault") { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result { self.finish(.failure(error), "unlock", completion); return }
            self.queue.async {
                let outcome = self.unlockNow()
                DispatchQueue.main.async { self.finish(outcome, "unlock", completion) }
            }
        }
    }

    /// Unmounts the vault. With `force`, a vault that a program still uses is unmounted anyway: only after every EU
    /// session stopped. Main queue in, main queue out.
    func lock(force: Bool, completion: @escaping (Result<Void, Failure>) -> Void) {
        queue.async {
            let outcome = self.lockNow(force: force)
            DispatchQueue.main.async { self.finish(outcome, force ? "lock (force)" : "lock", completion) }
        }
    }

    /// The lock of an app quit, after the sessions stopped: it forces the unmount when a program still uses a file, and
    /// calls `completion` within `limit` seconds also when `hdiutil` takes longer (the next start then locks the vault).
    func lockForQuit(limit: TimeInterval = 4, completion: @escaping () -> Void) {
        guard isMounted else { completion(); return }
        var done = false
        let end = {
            guard !done else { return }
            done = true
            completion()
        }
        lock(force: true) { _ in end() }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            if !done { Trace.log("vault: lock at quit not finished after \(limit) s") }
            end()
        }
    }

    /// At app start, before anything else: unmounts a Zeus vault that is still mounted (after a crash, or a force quit).
    /// No session runs yet, so it forces the unmount. Synchronous; it does nothing on a Mac without a vault.
    func lockAtStart() {
        func detach(_ target: String) {
            let result = Self.run("/usr/bin/hdiutil", ["detach", "-force", target], timeout: 20)
            Trace.log("vault: detached at start: \(result.status == 0 ? "ok" : "failed (exit \(result.status))")")
        }
        if isMounted, Self.markerData() != nil { detach(Self.mountPoint) }
        // The disk image of the vault, attached somewhere else (asked after the detach above, which detaches it too).
        if exists { Self.attachedDevices(of: Self.bundlePath).forEach(detach) }
    }

    // MARK: Work on the vault queue

    private func createNow() -> Result<Void, Failure> {
        var key = Self.newKey()
        defer { Self.wipe(&key) }
        let manager = FileManager.default
        let create = Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", Self.maximumSize, "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                                    "-encryption", "AES-256", "-stdinpass", "-volname", Self.volumeName, Self.bundlePath],
                              secret: key, timeout: 120)
        guard create.status == 0 else {
            try? manager.removeItem(atPath: Self.bundlePath)
            return .failure(.failed("hdiutil could not create the EU vault (exit \(create.status)): \(create.lastLine)"))
        }
        chmod(Self.bundlePath, 0o700)
        do { try keys.save(key) } catch let failure as Failure {
            try? manager.removeItem(atPath: Self.bundlePath)
            return .failure(failure)
        } catch {
            try? manager.removeItem(atPath: Self.bundlePath)
            return .failure(.failed(error.localizedDescription))
        }
        if case let .failure(failure) = attach(key: key) { return .failure(failure) }
        // The first mount makes the vault's own folder rules: owner only, no Spotlight index, and the marker.
        chmod(Self.mountPoint, 0o700)
        manager.createFile(atPath: Self.mountPoint + "/.metadata_never_index", contents: nil, attributes: [.posixPermissions: 0o600])
        guard let uuid = Self.volumeUUID() else {
            _ = lockNow(force: true)
            return .failure(.failed("The EU vault has no volume ID."))
        }
        let marker: [String: Any] = ["schema": 1, "kind": "zeus-eu-vault", "volume_uuid": uuid]
        guard let data = try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]),
              manager.createFile(atPath: Self.mountPoint + "/" + Self.markerName, contents: data + Data("\n".utf8),
                                 attributes: [.posixPermissions: 0o600])
        else {
            _ = lockNow(force: true)
            return .failure(.failed("The app could not write the marker of the EU vault."))
        }
        Self.turnOffSpotlight()
        return .success(())
    }

    private func unlockNow() -> Result<Void, Failure> {
        var key: [UInt8]
        do {
            guard let stored = try keys.read() else { return .failure(.noKey) }
            key = stored
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        defer { Self.wipe(&key) }
        if case let .failure(failure) = attach(key: key) { return .failure(failure) }
        guard Self.markerIsValid() else {
            _ = lockNow(force: true)
            return .failure(.failed("The disk image in \(EUSetup.display(Self.bundlePath)) is not the Zeus EU vault."))
        }
        Self.turnOffSpotlight()
        return .success(())
    }

    private func attach(key: [UInt8]) -> Result<Void, Failure> {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: Paths.home + "/.zeus", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.createDirectory(atPath: Self.mountPoint, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard Handover.isDirectory(Self.mountPoint) else {
            return .failure(.failed("\(EUSetup.display(Self.mountPoint)) is not a plain folder."))
        }
        let result = Self.run("/usr/bin/hdiutil", ["attach", "-stdinpass", "-nobrowse", "-owners", "on", "-noautoopen",
                                                    "-mountpoint", Self.mountPoint, Self.bundlePath],
                              secret: key, timeout: 60)
        if result.status == 0, isMounted { return .success(()) }
        if result.errors.localizedCaseInsensitiveContains("authentication error") { return .failure(.wrongPassword) }
        return .failure(.failed("hdiutil could not open the EU vault (exit \(result.status)): \(result.lastLine)"))
    }

    private func lockNow(force: Bool) -> Result<Void, Failure> {
        guard isMounted else { return .success(()) }
        // A forced lock comes only when no session uses the vault, so it detaches with -force at once: a plain detach
        // first would only add the time of a refused unmount (a quit has 4 s for the lock).
        let result = Self.run("/usr/bin/hdiutil", force ? ["detach", "-force", Self.mountPoint] : ["detach", Self.mountPoint], timeout: 30)
        if result.status == 0, !isMounted { return .success(()) }
        if !force, result.status == 16 || result.errors.localizedCaseInsensitiveContains("busy") { return .failure(.busy) }
        return .failure(.failed("hdiutil could not close the EU vault (exit \(result.status)): \(result.lastLine)"))
    }

    private func finish(_ outcome: Result<Void, Failure>, _ action: String, _ completion: (Result<Void, Failure>) -> Void) {
        switch outcome {
        case .success: Trace.log("vault: \(action) ok")
        case let .failure(failure): Trace.log("vault: \(action) failed: \(failure.traceName)")
        }
        completion(outcome)
    }

    // MARK: Helpers

    /// The mount folder is missing or empty: a mount there hides nothing.
    static func mountFolderIsFree() -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: mountPoint) else { return true }
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0, let real = realpath(path, nil) else { return false }
        defer { free(real) }
        let mountedOn = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == String(cString: real)
    }

    static func markerData() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: mountPoint + "/" + markerName) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The marker is there, of a Zeus vault, and names the mounted volume.
    static func markerIsValid() -> Bool {
        guard let marker = markerData(), marker["kind"] as? String == "zeus-eu-vault",
              let uuid = marker["volume_uuid"] as? String, let mounted = volumeUUID() else { return false }
        return uuid == mounted
    }

    static func volumeUUID() -> String? {
        let result = run("/usr/sbin/diskutil", ["info", "-plist", mountPoint], timeout: 20)
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any]
        else { return nil }
        return plist["VolumeUUID"] as? String
    }

    /// The devices of the disk image at `path` that are attached now (`hdiutil info`).
    static func attachedDevices(of path: String) -> [String] {
        let result = run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 20)
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        let wanted = StandardJail.forms(path)
        var devices: [String] = []
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  !Set(StandardJail.forms(imagePath)).isDisjoint(with: wanted) else { continue }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            // The whole disk: detaching it detaches its volumes.
            if let whole = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) { devices.append(whole) }
        }
        return devices
    }

    /// Spotlight must not index the vault. `-nobrowse` and the `.metadata_never_index` file of the vault keep it out;
    /// `mdutil -i off` also needs administrator rights, so the app only tries it.
    private static func turnOffSpotlight() {
        let result = run("/usr/bin/mdutil", ["-i", "off", mountPoint], timeout: 10)
        if result.status != 0 { Trace.log("vault: mdutil -i off not applied (exit \(result.status))") }
    }

    /// A new random key: 32 random bytes as 64 hex characters (hdiutil takes a text password).
    static func newKey() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("No random bytes for the EU vault key")
        }
        let hex = Array("0123456789abcdef".utf8)
        var key = [UInt8]()
        key.reserveCapacity(64)
        for byte in bytes { key.append(hex[Int(byte >> 4)]); key.append(hex[Int(byte & 0x0F)]) }
        wipe(&bytes)
        return key
    }

    /// Overwrites a key in memory.
    static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
    }

    struct Output {
        let status: Int32
        let output: String
        let errors: String
        /// The last line of the error output, for a message (hdiutil never prints the password).
        var lastLine: String { errors.split(separator: "\n").last.map(String.init) ?? "no message" }
    }

    /// Runs a tool and waits. `secret` goes to its standard input, ended by a zero byte (`hdiutil -stdinpass`), and
    /// the app's copy of it is overwritten after the write.
    static func run(_ tool: String, _ arguments: [String], secret: [UInt8]? = nil, timeout: TimeInterval) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = secret == nil ? FileHandle.nullDevice : input
        do { try process.run() } catch { return Output(status: -1, output: "", errors: error.localizedDescription) }
        if var secret {
            var data = Data(secret + [0])
            input.fileHandleForWriting.write(data)
            data.resetBytes(in: 0 ..< data.count)
            wipe(&secret)
            try? input.fileHandleForWriting.close()
        }
        var errorData = Data()
        let errorsRead = DispatchGroup()
        errorsRead.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            errorsRead.leave()
        }
        let deadline = DispatchTime.now() + timeout
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        errorsRead.wait()
        process.waitUntilExit()
        killer.cancel()
        return Output(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
                      errors: String(decoding: errorData, as: UTF8.self))
    }
}

/// Asks the user to confirm before the app reads the vault key.
protocol VaultAuthenticator {
    /// Calls `completion` on the main queue.
    func authenticate(reason: String, completion: @escaping (Result<Void, EUVault.Failure>) -> Void)
}

/// Touch ID, or the login password on a Mac without Touch ID (`deviceOwnerAuthentication`).
final class TouchIDAuthenticator: VaultAuthenticator {
    func authenticate(reason: String, completion: @escaping (Result<Void, EUVault.Failure>) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(.failure(.notAuthenticated(error?.localizedDescription ?? "This Mac can not confirm that it is you.")))
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            DispatchQueue.main.async {
                if ok { completion(.success(())); return }
                let code = (error as? LAError)?.code
                if code == .userCancel || code == .appCancel || code == .systemCancel {
                    completion(.failure(.cancelled))
                } else {
                    completion(.failure(.notAuthenticated(error?.localizedDescription ?? "macOS did not confirm that it is you.")))
                }
            }
        }
    }
}

#if DEBUG
/// Debug builds, for tests: answers as the test says (`ZEUS_APP_TEST_VAULT_AUTH`, then the test action
/// "test-vault-auth:<allow|cancel|fail>"), without a Touch ID window.
final class TestVaultAuthenticator: VaultAuthenticator {
    var answer: String
    init(answer: String) { self.answer = answer }

    func authenticate(reason: String, completion: @escaping (Result<Void, EUVault.Failure>) -> Void) {
        Trace.log("vault: test authentication (\(reason)): \(answer)")
        let outcome: Result<Void, EUVault.Failure>
        switch answer {
        case "allow": outcome = .success(())
        case "cancel": outcome = .failure(.cancelled)
        default: outcome = .failure(.notAuthenticated("test"))
        }
        DispatchQueue.main.async { completion(outcome) }
    }
}
#endif

/// Where the vault key is kept.
protocol VaultKeyStore {
    /// The key, or nil when there is none.
    func read() throws -> [UInt8]?
    /// Replaces the key.
    func save(_ key: [UInt8]) throws
}

/// The key in the login keychain (a file-based keychain item), whose access list trusts only the app that created it.
final class KeychainVaultKeyStore: VaultKeyStore {
    /// A keychain file, or nil for the default keychain (the login keychain).
    private let keychain: SecKeychain?

    init(keychain: SecKeychain? = nil) { self.keychain = keychain }

    /// The login keychain. Debug builds: `ZEUS_APP_TEST_KEYCHAIN` names a keychain file of a test instead.
    static func standard() -> KeychainVaultKeyStore {
        #if DEBUG
        if let path = DebugEnvironment.value("ZEUS_APP_TEST_KEYCHAIN"), !path.isEmpty {
            var keychain: SecKeychain?
            if SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain { return KeychainVaultKeyStore(keychain: keychain) }
        }
        #endif
        return KeychainVaultKeyStore()
    }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: EUVault.keychainService,
                                    kSecAttrAccount as String: EUVault.keychainAccount]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] as CFArray }
        return query
    }

    func read() throws -> [UInt8]? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard var data = item as? Data else { return nil }
            let key = [UInt8](data)
            data.resetBytes(in: 0 ..< data.count)
            return key
        case errSecItemNotFound: return nil
        case errSecUserCanceled: throw EUVault.Failure.cancelled
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw EUVault.Failure.notAuthenticated("the keychain did not give the key (\(status)).")
        default: throw EUVault.Failure.failed("The keychain did not give the key of the EU vault (\(status)).")
        }
    }

    func save(_ key: [UInt8]) throws {
        SecItemDelete(query as CFDictionary)
        // Only this app may read the item without a question: the access list trusts only the calling app.
        var me: SecTrustedApplication?
        var access: SecAccess?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me,
              SecAccessCreate("Zeus EU vault" as CFString, [me] as CFArray, &access) == errSecSuccess, let access
        else { throw EUVault.Failure.failed("The app could not make the keychain access list of the EU vault key.") }
        var data = Data(key)
        defer { data.resetBytes(in: 0 ..< data.count) }
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: EUVault.keychainService,
                                   kSecAttrAccount as String: EUVault.keychainAccount,
                                   kSecAttrLabel as String: "Zeus EU vault",
                                   kSecAttrDescription as String: "Key of the Zeus EU vault",
                                   kSecAttrAccess as String: access,
                                   kSecValueData as String: data]
        if let keychain { item[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw EUVault.Failure.failed("The keychain did not keep the key of the EU vault (\(status)).") }
    }
}
