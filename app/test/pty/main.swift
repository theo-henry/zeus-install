import CryptoKit
import Foundation

// Exercise real PTY backpressure, byte delivery, resize, and main-thread responsiveness.
let payload = String(repeating: "Z", count: 1_048_576)
let hash = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
let process = try PTYProcess(executable: "/bin/sh", arguments: ["-c",
    "stty raw -echo; printf READY; dd bs=1 count=6 of=/dev/null 2>/dev/null; stty size; head -c 1048576 | shasum -a 256"],
    environment: ProcessInfo.processInfo.environment, directory: NSTemporaryDirectory())
var output = ""
var sent = false
var code: Int32?
var ticks = 0
let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in ticks += 1 }
process.onOutput = { data in
    output += String(decoding: data, as: UTF8.self)
    if !sent, output.contains("READY") {
        sent = true
        process.resize(rows: 41, cols: 132)
        process.write("probe\n" + payload)
    }
}
process.onExit = { code = $0 }
let deadline = Date().addingTimeInterval(20)
while code == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
heartbeat.invalidate()
guard code == 0, output.contains(hash), output.contains("41 132"), ticks > 0 else {
    process.terminate(grace: 0.1)
    fputs("PTY test failed: code=\(String(describing: code)), ticks=\(ticks), output=\(output)\n", stderr)
    exit(1)
}
print("PASS: 1 MiB input delivered intact, terminal resized to 41x132, UI run loop remained responsive")
