import CPTY
import Darwin
import Foundation

/// A command that runs in its own hidden pseudo-terminal, as if it ran in a Terminal window.
/// Output and exit are delivered on the main queue.
final class PTYProcess {
    let pid: pid_t
    private let master: Int32
    private let ioQueue: DispatchQueue
    // Input waits here while the terminal's input queue is full. Only touched on ioQueue.
    private var pendingInput = Data()
    private var pendingOffset = 0
    private var writeSuspended = true
    private var ioClosed = false
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
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
        ioQueue = queue
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
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
        writeSource.setEventHandler { [weak self] in self?.flushInput() }
        writeSource.setCancelHandler { [fd] in close(fd) }
        readSource.setCancelHandler { [weak self] in
            guard let self else { return }
            self.ioClosed = true
            self.pendingInput = Data()
            self.pendingOffset = 0
            // The write source closes the file descriptor when it ends.
            self.writeSource.cancel()
            if self.writeSuspended {
                self.writeSuspended = false
                self.writeSource.resume()
            }
        }

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
        ioQueue.async { [weak self] in
            guard let self, !self.ioClosed else { return }
            self.pendingInput.append(data)
            if self.writeSuspended { self.flushInput() }
        }
    }

    /// Writes waiting input without blocking the UI or the PTY reader. When the terminal's input
    /// queue is full, the write source calls this again as soon as the queue has room.
    private func flushInput() {
        guard !ioClosed else { return }
        while pendingOffset < pendingInput.count {
            let written = pendingInput.withUnsafeBytes { raw in
                Darwin.write(master, raw.baseAddress! + pendingOffset, raw.count - pendingOffset)
            }
            if written > 0 { pendingOffset += written; continue }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN {
                if writeSuspended {
                    writeSuspended = false
                    writeSource.resume()
                }
                return
            }
            break // The terminal is gone; the read source ends the session.
        }
        pendingInput = Data()
        pendingOffset = 0
        if !writeSuspended {
            writeSuspended = true
            writeSource.suspend()
        }
    }

    deinit {
        // A suspended dispatch source must not be released.
        if writeSuspended { writeSource.resume() }
    }

    func resize(rows: UInt16, cols: UInt16) {
        ioQueue.async { [weak self] in
            guard let self, !self.ioClosed else { return }
            _ = zeus_pty_resize(self.master, rows, cols)
        }
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
