import Foundation

/// A bounded, line-oriented record of a process's output.
///
/// The terminal view keeps its own scrollback for display; this exists so the
/// MCP tools (and the sidebar's activity line) can read recent output without
/// scraping the render buffer. Bounded so a chatty dev server cannot grow
/// without limit.
final class ProcessLog {
    private let maxLines: Int
    private var lines: [String] = []
    private var partial = ""
    private let lock = NSLock()

    /// Most recent complete line with visible content, for the sidebar subtitle.
    private(set) var lastActivity: String?

    init(maxLines: Int = 5_000) {
        self.maxLines = maxLines
    }

    func append(_ bytes: ArraySlice<UInt8>) {
        guard let chunk = String(bytes: bytes, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }

        partial += chunk
        // Carriage returns are progress-bar redraws, not new lines; keep only
        // the final state of the line so spinners do not flood the log.
        partial = partial.replacingOccurrences(of: "\r\n", with: "\n")
        while let newline = partial.firstIndex(of: "\n") {
            let raw = String(partial[partial.startIndex..<newline])
            partial = String(partial[partial.index(after: newline)...])
            let line = Self.strippingControlSequences(raw)
            lines.append(line)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lastActivity = line.trimmingCharacters(in: .whitespaces)
            }
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        // A long line with no newline yet (a prompt, a progress bar) still counts
        // as activity, but must not be allowed to grow unbounded.
        if partial.count > 8_192 {
            partial = String(partial.suffix(4_096))
        }
    }

    /// The last `count` lines, oldest first.
    func tail(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(max(0, count)))
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
        partial = ""
        lastActivity = nil
    }

    /// Strips ANSI escape sequences so logs read as plain text.
    static func strippingControlSequences(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var iterator = input.makeIterator()
        var pending: Character? = nil

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                // Drop other C0 controls, keep tabs.
                if character == "\t" || !character.unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
                    output.append(character)
                }
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "[":
                // CSI: parameters then a final byte in @-~
                while let byte = iterator.next() {
                    if ("\u{40}"..."\u{7E}").contains(byte) { break }
                }
            case "]":
                // OSC: runs until BEL or ST (ESC \)
                while let byte = iterator.next() {
                    if byte == "\u{07}" { break }
                    if byte == "\u{1B}" {
                        if let following = iterator.next(), following == "\\" { break }
                        pending = nil
                        break
                    }
                }
            default:
                break
            }
        }
        return output
    }
}
