import CPTY
import Darwin
import Foundation

/// A command that runs in its own hidden pseudo-terminal, as if it ran in a Terminal window.
/// Output and exit are delivered on the main queue.
final class PTYProcess {
    let pid: pid_t
    private let master: Int32
    private let readSource: DispatchSourceRead
    private let exitSource: DispatchSourceProcess
    private(set) var exitStatus: Int32?

    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    enum SpawnError: LocalizedError {
        case failed(String, Int32)
        var errorDescription: String? {
            switch self {
            case let .failed(path, code): return "Could not start \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    init(executable: String, arguments: [String], environment: [String: String], directory: String,
         rows: UInt16 = 30, cols: UInt16 = 110) throws {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var fd: Int32 = -1
        let child = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in
                zeus_pty_spawn(executable, a.baseAddress, e.baseAddress, directory, rows, cols, &fd)
            }
        }
        if child < 0 { throw SpawnError.failed(executable, errno) }
        pid = child
        master = fd

        let queue = DispatchQueue(label: "zeus.pty.\(child)")
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)

        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = read(self.master, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0 ..< count])
                DispatchQueue.main.async { self.onOutput?(data) }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // EIO: every process on the terminal has closed it.
                self.readSource.cancel()
            }
        }
        readSource.setCancelHandler { [fd] in close(fd) }

        exitSource.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(child, &status, 0)
            let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            self.exitSource.cancel()
            // Let the last output arrive before the exit is reported.
            queue.asyncAfter(deadline: .now() + 0.2) {
                DispatchQueue.main.async {
                    self.exitStatus = code
                    self.onExit?(code)
                }
            }
        }
        readSource.resume()
        exitSource.resume()
    }

    var isRunning: Bool { exitStatus == nil }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(master, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        _ = zeus_pty_resize(master, rows, cols)
    }

    /// Asks the process to stop (SIGTERM), then forces it (SIGKILL) after `grace` seconds.
    func terminate(grace: TimeInterval = 5) {
        guard isRunning else { return }
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, self.isRunning else { return }
            kill(-self.pid, SIGKILL) // The whole process group on the terminal.
            kill(self.pid, SIGKILL)
        }
    }
}
