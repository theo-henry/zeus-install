import Foundation

/// A debug log, written only when ZEUS_APP_TRACE names a file: setup events, session states, page loads.
enum Trace {
    private static let file: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["ZEUS_APP_TRACE"], !path.isEmpty else { return nil }
        // Appends, so that the new copy of an updated app writes after the old copy into the same file.
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        return descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard let file else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        file.write(Data(line.utf8))
    }
}
