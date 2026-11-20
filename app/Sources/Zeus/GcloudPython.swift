import Foundation

/// A Python 3.10 or later for gcloud. gcloud 593 has no Python of its own: without `CLOUDSDK_PYTHON` it uses the first
/// python3.14 ... python3 on the PATH, and the Python of macOS (3.9) makes it stop at once ("gcloud failed to load ...
/// Python 3.9"). Then the Google sign-in button and the EU start check fail. The app gives the commands that it starts a
/// Python that it knows, in the same places as the installer (install.sh `find_gcloud_python`), so gcloud does not depend
/// on the login PATH. A `CLOUDSDK_PYTHON` of the user stays.
enum GcloudPython {
    static let minimum = (major: 3, minor: 10)

    /// The folders that the app looks in first: Anaconda (or Miniconda, Miniforge) of the home folder, then the system.
    static func folders(home: String, system: [String] = ["/opt/anaconda3/bin", "/opt/miniconda3/bin", "/opt/homebrew/bin", "/usr/local/bin"]) -> [String] {
        [home + "/anaconda3/bin", home + "/miniconda3/bin", home + "/miniforge3/bin"] + system
    }

    /// The first Python 3.10 or later: `python3` in `folders`, then python3.14 ... python3 in the PATH folders. Nil when
    /// there is none. It runs each candidate once to ask its version.
    static func find(folders: [String], path: String) -> String? {
        let manager = FileManager.default
        let named = folders.map { $0 + "/python3" }
        let pathFolders = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let fromPath = ["3.14", "3.13", "3.12", "3.11", "3.10", "3"].flatMap { version in pathFolders.map { "\($0)/python\(version)" } }
        for candidate in named + fromPath where manager.isExecutableFile(atPath: candidate) {
            if supported(candidate) { return candidate }
        }
        return nil
    }

    /// The Python answers that it is 3.10 or later, within 5 seconds.
    static func supported(_ python: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (\(minimum.major), \(minimum.minor)) else 1)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20000) }
        if process.isRunning { process.terminate(); return false }
        return process.terminationStatus == 0
    }
}
