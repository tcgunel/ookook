import Foundation
import AppKit
import SwiftTerm

/// A terminal view that tees everything the child writes into a `ProcessLog`.
///
/// `dataReceived` is the one place all child output passes through, which makes
/// it the right tap for both the sidebar's activity line and the MCP log tools.
final class LoggingTerminalView: LocalProcessTerminalView {
    let log = ProcessLog()

    /// Called on the main queue, coalesced, when new output has arrived.
    var onActivity: (() -> Void)?

    /// Called when this terminal is clicked, so clicking into a tile selects
    /// it. Selection has to follow the click rather than the click following
    /// selection: a SwiftUI tap gesture big enough to select the tile would
    /// have to cover the terminal, and then it swallows the click that gives
    /// the terminal its keyboard focus.
    var onBecomeFirstResponder: (() -> Void)?

    /// The click recogniser that reports focus, owned by the view rather than
    /// by whichever pane is currently showing it.
    ///
    /// One terminal outlives many panes: it is hosted by a grid tile, then by
    /// the single-pane view, then by a fresh tile after a reload, and each of
    /// those builds its own coordinator. A coordinator that simply added a
    /// recogniser left the previous one attached for good, so they piled up on
    /// the same long-lived view - invisibly, and without bound. Enough of them
    /// and mouse handling degrades until clicking a terminal no longer focuses
    /// it, which reads as a terminal that has stopped accepting the keyboard.
    private var focusClick: NSGestureRecognizer?

    /// Installs the focus recogniser, replacing any previous one.
    func installFocusClick(target: AnyObject, action: Selector) {
        if let focusClick { removeGestureRecognizer(focusClick) }
        let click = NSClickGestureRecognizer(target: target, action: action)
        // The click must still reach the terminal, so selecting text and
        // placing the cursor keep working; we merely hear about it.
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
        focusClick = click
    }

    /// Cmd-clicking a path in the output opens it.
    ///
    /// SwiftTerm's default hands the raw text to `URL(string:)`, so a relative
    /// path like `thoughts/listing/preview.png` becomes a schemeless URL and
    /// `NSWorkspace.open` fails with -50. Resolve it as a file first.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // A path we already resolved from the buffer wins: SwiftTerm's own
        // match for the same click is the truncated one we are working around.
        guard !suppressLinkOpen else { return }

        let trimmed = link.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'`<>()[]{},"))
        guard !trimmed.isEmpty else { return }

        if let url = URL(string: trimmed), let scheme = url.scheme, scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }
        if let file = resolveFile(trimmed) {
            NSWorkspace.shared.open(file)
            return
        }
        // Nothing we can open - stay quiet rather than raising a -50 alert.
        NSSound.beep()
    }

    /// Set while `super.mouseUp` runs for a click we have already resolved
    /// ourselves, so SwiftTerm's own link does not open a second thing.
    private var suppressLinkOpen = false

    /// Cmd-click resolves the path out of the terminal buffer first.
    ///
    /// SwiftTerm's link detection stops at the row it matched on, so a path
    /// long enough to wrap opens as its first line only, and a bare relative
    /// name like `Package.swift` never matches its pattern at all. Reading the
    /// cells around the click and asking the filesystem covers both; anything
    /// we cannot resolve falls through to SwiftTerm untouched, which is what
    /// still opens `https://` links.
    override func mouseUp(with event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              let url = fileURL(underClick: event) else {
            super.mouseUp(with: event)
            return
        }
        suppressLinkOpen = true
        super.mouseUp(with: event)
        suppressLinkOpen = false
        NSWorkspace.shared.open(url)
    }

    /// Characters a path can be made of. Deliberately narrower than the shell
    /// allows: a space or a quote is far more often the end of the path than
    /// part of it, and guessing wide turns "open this file" into "open the
    /// rest of the sentence".
    private static let pathCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/~+@%$:#=")

    private func fileURL(underClick event: NSEvent) -> URL? {
        guard let hit = gridPosition(of: event) else { return nil }
        guard let (text, cells) = wrappedText(around: hit.row) else { return nil }
        guard let index = cells.firstIndex(where: { $0.row == hit.row && $0.col == hit.col })
        else { return nil }

        let characters = Array(text)
        guard index < characters.count, isPathCharacter(characters[index]) else { return nil }

        var start = index
        while start > 0 && isPathCharacter(characters[start - 1]) { start -= 1 }
        var end = index
        while end + 1 < characters.count && isPathCharacter(characters[end + 1]) { end += 1 }

        var candidate = String(characters[start...end])
        while let last = candidate.last, ".,:;".contains(last), candidate.count > 1 {
            candidate.removeLast()
        }
        return resolveFile(candidate)
    }

    private func isPathCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { Self.pathCharacters.contains($0) }
    }

    /// The screen cell under the pointer.
    ///
    /// SwiftTerm computes this internally but does not expose it, so this
    /// mirrors its arithmetic: cells are laid out from the top-left with no
    /// padding, and their size comes from the font's line metrics and the
    /// advancement of `W`, snapped to the pixel grid.
    private func gridPosition(of event: NSEvent) -> (col: Int, row: Int)? {
        let terminal = getTerminal()
        let point = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2

        let ctFont = font as CTFont
        let lineHeight = CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)
        let cellHeight = max(1, ceil(ceil(lineHeight) * scale) / scale)
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellWidth = max(1, (advance * scale).rounded() / scale)

        let col = Int(point.x / cellWidth)
        let row = Int((frame.height - point.y) / cellHeight)
        guard row >= 0, row < terminal.rows else { return nil }
        return (col: min(max(0, col), terminal.cols - 1), row: row)
    }

    private struct CellRef {
        let row: Int
        let col: Int
    }

    /// The text of the wrapped line group `row` belongs to, with the screen
    /// cell each character came from.
    ///
    /// A path wider than the terminal is one string split across rows, and the
    /// only way to open it is to put it back together before matching.
    private func wrappedText(around row: Int) -> (String, [CellRef])? {
        let terminal = getTerminal()
        guard terminal.getLine(row: row) != nil else { return nil }

        var startRow = row
        while startRow > 0, isContinuation(row: startRow) { startRow -= 1 }
        var endRow = row
        while endRow + 1 < terminal.rows, isContinuation(row: endRow + 1) { endRow += 1 }

        var text = ""
        var cells: [CellRef] = []
        for current in startRow...endRow {
            guard let line = terminal.getLine(row: current) else { continue }
            let limit = min(terminal.cols, line.count)
            guard limit > 0 else { continue }
            // Continuation rows may be indented by whatever drew them; the
            // path resumes at the first thing that is not a space.
            var col = 0
            if current != startRow {
                while col < limit, line[col].getCharacter() == " " { col += 1 }
            }
            while col < limit {
                var character = line[col].getCharacter()
                if character == "\u{0}" { character = " " }
                text.append(character)
                cells.append(CellRef(row: current, col: col))
                col += 1
            }
        }
        return text.isEmpty ? nil : (text, cells)
    }

    /// Whether `row` continues the row above it - either because the terminal
    /// wrapped it, or because the row above ran to the edge and the seam reads
    /// as one unbroken path (which is how a program that wraps its own output
    /// leaves a long path behind).
    private func isContinuation(row: Int) -> Bool {
        let terminal = getTerminal()
        guard row > 0, let line = terminal.getLine(row: row) else { return false }
        if line.isWrapped { return true }
        guard let above = terminal.getLine(row: row - 1) else { return false }

        let aboveLimit = min(terminal.cols, above.count)
        var lastCol = aboveLimit - 1
        while lastCol >= 0, above[lastCol].getCharacter() == " " { lastCol -= 1 }
        guard lastCol >= terminal.cols - 2, isPathCharacter(above[lastCol].getCharacter()) else {
            return false
        }

        let limit = min(terminal.cols, line.count)
        var firstCol = 0
        while firstCol < limit, line[firstCol].getCharacter() == " " { firstCol += 1 }
        guard firstCol < limit else { return false }
        return isPathCharacter(line[firstCol].getCharacter())
    }

    private func resolveFile(_ text: String) -> URL? {
        var path = text
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        // Compiler- and grep-style suffixes: path:12 and path:12:34.
        var candidates = [path]
        while let colon = path.lastIndex(of: ":"),
              path[path.index(after: colon)...].allSatisfy(\.isNumber),
              colon != path.startIndex {
            path = String(path[path.startIndex..<colon])
            candidates.append(path)
        }

        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            let url: URL
            if expanded.hasPrefix("/") {
                url = URL(fileURLWithPath: expanded)
            } else if let base = baseDirectory {
                url = base.appendingPathComponent(expanded)
            } else {
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                return url.standardizedFileURL
            }
        }
        return nil
    }

    /// Where relative paths in this terminal's output live. Set to the
    /// process's working directory, and kept current if the shell reports a
    /// directory change.
    var baseDirectory: URL?

    private var activityPending = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        log.append(slice)

        // Output can arrive in a flood; coalesce UI notifications to one per
        // runloop turn rather than one per read.
        guard !activityPending else { return }
        activityPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activityPending = false
            self.onActivity?()
        }
    }
}

// MARK: - Files: dropping them in, and opening them out

extension LoggingTerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(from: sender).isEmpty ? [] : .copy
    }

    /// Dropping files types their paths at the prompt, the way Terminal.app
    /// and iTerm do - which is what makes dragging a file onto a Claude Code
    /// prompt work.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let text = urls.map { Self.shellQuoted($0.path) }.joined(separator: " ") + " "
        send(data: Array(text.utf8)[...])
        window?.makeFirstResponder(self)
        return true
    }

    private func droppedURLs(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    static func shellQuoted(_ path: String) -> String {
        // Bare paths only stay bare while they have nothing the shell reacts
        // to; anything else goes in single quotes, with embedded quotes
        // spliced back in the usual '\'' way.
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+/=@:,")
        if !path.isEmpty && path.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
