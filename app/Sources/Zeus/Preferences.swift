import AppKit
import Foundation

enum Preferences {
    private static let defaults: UserDefaults = {
        #if DEBUG
        // The tests give each run its own settings domain, so that runs do not share the settings of the user.
        if let suite = ProcessInfo.processInfo.environment["ZEUS_APP_DEFAULTS_SUITE"], !suite.isEmpty,
           let suiteDefaults = UserDefaults(suiteName: suite) {
            return suiteDefaults
        }
        #endif
        return UserDefaults.standard
    }()

    static var setupDone: Bool {
        get { defaults.bool(forKey: "setupDone") }
        set { defaults.set(newValue, forKey: "setupDone") }
    }

    static var showMenuBar: Bool {
        get { defaults.bool(forKey: "showMenuBar") }
        set { defaults.set(newValue, forKey: "showMenuBar") }
    }

    /// The mode of the app, "standard" or "eu" (`ZeusMode.current`).
    static var zeusMode: String? {
        get { defaults.string(forKey: "zeusMode") }
        set { defaults.set(newValue, forKey: "zeusMode") }
    }

    /// The first switch to EU mode showed the note about the shared clipboard.
    static var euClipboardNoteShown: Bool {
        get { defaults.bool(forKey: "euClipboardNoteShown") }
        set { defaults.set(newValue, forKey: "euClipboardNoteShown") }
    }

    /// The dictation settings (see `DictationSettings`).
    static var dictationModel: String? {
        get { defaults.string(forKey: "dictationModel") }
        set { defaults.set(newValue, forKey: "dictationModel") }
    }

    static var dictationLanguage: String? {
        get { defaults.string(forKey: "dictationLanguage") }
        set { defaults.set(newValue, forKey: "dictationLanguage") }
    }

    static var dictationCustomWords: [String] {
        get { defaults.stringArray(forKey: "dictationCustomWords") ?? [] }
        set { defaults.set(newValue, forKey: "dictationCustomWords") }
    }
}

/// Keeps the app in the Dock: adds it to the Dock's list of kept apps, then restarts the Dock.
/// Does nothing when the app is already in the list.
enum DockPin {
    static var appURL: URL { Bundle.main.bundleURL.standardizedFileURL }

    static func isPinned() -> Bool {
        guard let output = run("/usr/bin/defaults", ["read", "com.apple.dock", "persistent-apps"]) else { return false }
        let path = appURL.path
        return output.contains("file://" + path + "/") || output.contains("file://" + path + "\"")
            || output.contains(appURL.absoluteString)
    }

    static func pin() {
        // A copy that runs from a disk image or the Downloads folder must not be kept in the Dock.
        guard appURL.path.hasPrefix("/Applications/") || appURL.path.hasPrefix(Paths.home + "/Applications/") else { return }
        guard !isPinned() else { return }
        let tile = """
        <dict><key>tile-data</key><dict><key>file-data</key><dict>\
        <key>_CFURLString</key><string>\(appURL.absoluteString)</string>\
        <key>_CFURLStringType</key><integer>15</integer></dict>\
        <key>file-label</key><string>Zeus</string></dict>\
        <key>tile-type</key><string>file-tile</string></dict>
        """
        guard run("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", tile]) != nil else { return }
        _ = run("/usr/bin/killall", ["Dock"])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
