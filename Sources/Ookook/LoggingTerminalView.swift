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

    /// Cmd-clicking a path in the output opens it.
    ///
    /// SwiftTerm's default hands the raw text to `URL(string:)`, so a relative
    /// path like `thoughts/listing/preview.png` becomes a schemeless URL and
    /// `NSWorkspace.open` fails with -50. Resolve it as a file first.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
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
