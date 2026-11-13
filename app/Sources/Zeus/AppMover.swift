import AppKit
import Foundation

/// Puts the app in /Applications (or ~/Applications without administrator rights) at the first start,
/// so that it is found in Launchpad and Spotlight and can be kept in the Dock.
enum AppMover {
    static var bundleURL: URL { Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath() }

    static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         URL(fileURLWithPath: Paths.home + "/Applications")]
    }

    static var isInApplications: Bool {
        let parent = bundleURL.deletingLastPathComponent().path
        return applicationFolders.contains { $0.path == parent }
    }

    /// A development build, or a test run, stays where it is.
    static var shouldMove: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["ZEUS_APP_NO_MOVE"] == "1" || env["ZEUS_APP_TRACE"] != nil { return false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if version.contains("dev") { return false }
        return Bundle.main.bundleURL.pathExtension == "app" && !isInApplications
    }

    /// Copies the app to an Applications folder, opens the copy, and quits this one.
    /// Returns false when the copy fails; the app then runs from where it is.
    static func moveAndRelaunch() -> Bool {
        let fileManager = FileManager.default
        let system = URL(fileURLWithPath: "/Applications")
        let folder = fileManager.isWritableFile(atPath: system.path) ? system : applicationFolders[1]
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("Zeus.app")

        // A Zeus that already runs from there: use it.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.bundleURL?.standardizedFileURL.path == target.path }
        if running == nil {
            do {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.trashItem(at: target, resultingItemURL: nil)
                }
                try copy(from: bundleURL, to: target)
            } catch {
                Trace.log("app move failed: \(error.localizedDescription)")
                return false
            }
            // The copy runs from a folder of the user; the mark of a browser download is not needed again.
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
            trashOriginalIfDownloaded()
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = running == nil
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Trace.log("app relaunch failed: \(error.localizedDescription)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
        return true
    }

    /// ditto keeps the bundle as it is: signature, permissions, and extended attributes.
    private static func copy(from source: URL, to target: URL) throws {
        guard run("/usr/bin/ditto", [source.path, target.path]) else {
            throw NSError(domain: "Zeus", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not copy the app to \(target.path)."])
        }
    }

    /// A copy in Downloads is not needed after the move. Other places (for example a build folder) stay.
    private static func trashOriginalIfDownloaded() {
        let downloads = Paths.home + "/Downloads/"
        let original = bundleURL
        guard original.path.hasPrefix(downloads) else { return }
        try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
