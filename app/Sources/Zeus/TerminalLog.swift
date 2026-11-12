import Foundation

/// Turns raw terminal output into plain text lines: removes colour and cursor codes, and applies
/// carriage returns, so that progress bars overwrite their line. Lines that start with "@@zeus "
/// are events from the installer; they are passed to `onEvent` and not shown.
final class TerminalLog {
    private(set) var lines: [String] = []
    private var current = ""
    private var pending = Data()
    private var escape: EscapeState = .none
    private let maxLines: Int

    var onEvent: ((String) -> Void)?
    var onChange: (() -> Void)?

    private enum EscapeState { case none, escape, csi, osc, oscEscape }

    init(maxLines: Int = 3000) {
        self.maxLines = maxLines
    }

    /// All text, including the line that is not finished yet.
    var text: String {
        (lines + (current.isEmpty ? [] : [current])).joined(separator: "\n")
    }

    /// The unfinished last line, such as a prompt that waits for an answer.
    var currentLine: String { current }

    func append(_ data: Data) {
        pending.append(data)
        // Keep an incomplete UTF-8 sequence at the end for the next chunk.
        let bytes = [UInt8](pending)
        var cut = bytes.count
        var index = bytes.count - 1
        while index >= 0, bytes.count - index <= 4 {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 { index -= 1; continue } // Continuation byte.
            if byte & 0x80 != 0 {
                let need = byte & 0xE0 == 0xC0 ? 2 : byte & 0xF0 == 0xE0 ? 3 : 4
                if bytes.count - index < need { cut = index }
            }
            break
        }
        let chunk = Data(bytes[0 ..< cut])
        pending = Data(bytes[cut...])
        let string = String(decoding: chunk, as: UTF8.self)
        for scalar in string.unicodeScalars { consume(scalar) }
        onChange?()
    }

    func appendLine(_ line: String) {
        if !current.isEmpty { finishLine() }
        current = line
        finishLine()
        onChange?()
    }

    private func consume(_ c: Unicode.Scalar) {
        switch escape {
        case .escape:
            escape = c == "[" ? .csi : c == "]" ? .osc : .none
            return
        case .csi:
            if (0x40 ... 0x7E).contains(c.value) { escape = .none }
            return
        case .osc:
            if c.value == 0x07 { escape = .none } else if c.value == 0x1B { escape = .oscEscape }
            return
        case .oscEscape:
            escape = .none
            return
        case .none:
            break
        }
        switch c.value {
        case 0x1B: escape = .escape
        case 0x0A: finishLine()
        case 0x0D: pendingCarriageReturn = true; return
        case 0x08: if !current.isEmpty { current.removeLast() }
        case 0x07, 0x00: break
        default:
            if pendingCarriageReturn { current = "" }
            current.unicodeScalars.append(c)
        }
        pendingCarriageReturn = false
    }

    private var pendingCarriageReturn = false

    private func finishLine() {
        let line = current
        current = ""
        pendingCarriageReturn = false
        if line.hasPrefix("@@zeus ") {
            onEvent?(String(line.dropFirst(7)))
            return
        }
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}
