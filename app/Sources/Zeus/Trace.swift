import Foundation

/// A debug log, written only when ZEUS_APP_TRACE names a file: setup events, session states, page loads.
enum Trace {
    private static let file: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["ZEUS_APP_TRACE"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard let file else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        file.write(Data(line.utf8))
    }
}
