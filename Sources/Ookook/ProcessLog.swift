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
    /// Bytes received since the last line break, held as raw UTF-8. Working in
    /// bytes rather than `String` matters: this runs on the main thread for
    /// every pty read, and a TUI that redraws with cursor positioning emits
    /// almost no newlines, so the pending buffer is rescanned on each chunk.
    /// Grapheme-aware `String` scans made that the most expensive thing the app
    /// did while agents were busy.
    private var partial: [UInt8] = []
    private let lock = NSLock()

    /// Most recent complete line with visible content, for the sidebar subtitle.
    private(set) var lastActivity: String?

    init(maxLines: Int = 5_000) {
        self.maxLines = maxLines
    }

    func append(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        partial.append(contentsOf: bytes)

        var lineStart = 0
        var index = 0
        while index < partial.count {
            guard partial[index] == 0x0A else {
                index += 1
                continue
            }
            // A "\r\n" is one break, not a carriage return inside the line -
            // progress-bar redraws must not reach the sidebar as text.
            var lineEnd = index
            if lineEnd > lineStart, partial[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            append(line: partial[lineStart..<lineEnd])
            lineStart = index + 1
            index += 1
        }
        if lineStart > 0 {
            partial.removeFirst(lineStart)
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        // A long line with no newline yet (a prompt, a progress bar) still counts
        // as activity, but must not be allowed to grow unbounded.
        if partial.count > 8_192 {
            partial.removeFirst(partial.count - 4_096)
        }
    }

    /// Records one complete line. Control sequences are only stripped when the
    /// line has any: most lines are plain text, and skipping the scan for those
    /// is the common case.
    private func append(line bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else {
            lines.append("")
            return
        }
        // Every byte of a multi-byte UTF-8 sequence is 0x80 or above, so a byte
        // below 0x20 is always a control character - and a plain text line has
        // none of those beyond the tab the loop below keeps.
        let needsStripping = bytes.contains { $0 == 0x1B || ($0 < 0x20 && $0 != 0x09) }
        let text = String(decoding: bytes, as: UTF8.self)
        let line = needsStripping ? Self.strippingControlSequences(text) : text
        lines.append(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            lastActivity = trimmed
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
        partial.removeAll()
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
