import AppKit
import Foundation

enum Preferences {
    private static let defaults = UserDefaults.standard

    static var setupDone: Bool {
        get { defaults.bool(forKey: "setupDone") }
        set { defaults.set(newValue, forKey: "setupDone") }
    }

    static var showMenuBar: Bool {
        get { defaults.bool(forKey: "showMenuBar") }
        set { defaults.set(newValue, forKey: "showMenuBar") }
    }

    // MARK: Developer Settings

    /// Posted when a developer setting changes, so that open windows follow it at once.
    static let developerSettingsChanged = Notification.Name("ZeusDeveloperSettingsChanged")

    /// Shows the Apolix | EU switch in the title bar of each chat window.
    static var developerHostSwitch: Bool {
        get { defaults.bool(forKey: "developerHostSwitch") }
        set { defaults.set(newValue, forKey: "developerHostSwitch"); changed() }
    }

    /// The host that the consultant chose last; new tabs start on it while the switch shows.
    static var lastHost: ClaudeHost {
        get { defaults.string(forKey: "lastHost").flatMap(ClaudeHost.init(rawValue:)) ?? .apolix }
        set { defaults.set(newValue.rawValue, forKey: "lastHost") }
    }

    /// Shows the session cost in the title bar of EU tabs. On until the consultant turns it off.
    static var showCostEU: Bool {
        get { defaults.object(forKey: "showCostEU") == nil ? true : defaults.bool(forKey: "showCostEU") }
        set { defaults.set(newValue, forKey: "showCostEU"); changed() }
    }

    /// Shows the API-equivalent session cost in the title bar of Apolix tabs.
    static var showCostApolix: Bool {
        get { defaults.bool(forKey: "showCostApolix") }
        set { defaults.set(newValue, forKey: "showCostApolix"); changed() }
    }

    static func showCost(on host: ClaudeHost) -> Bool {
        host == .eu ? showCostEU : showCostApolix
    }

    /// Blind build mode: every session that the app starts gets ZEUS_BLIND_MODE=1. Applies to new sessions.
    static var blindMode: Bool {
        get { defaults.bool(forKey: "blindMode") }
        set { defaults.set(newValue, forKey: "blindMode"); changed() }
    }

    private static func changed() {
        NotificationCenter.default.post(name: developerSettingsChanged, object: nil)
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
