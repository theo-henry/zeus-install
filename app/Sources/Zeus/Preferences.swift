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
