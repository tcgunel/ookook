import Foundation

/// Keeps the tail of each process's output across app restarts.
///
/// What is replayed is the *plain text* log, not the raw byte stream. Replaying
/// raw bytes would preserve colour, but agent TUIs drive the alternate screen
/// buffer and absolute cursor positioning - feeding those escape sequences back
/// into a fresh terminal repaints a UI that no longer exists and leaves the
/// view wedged in whatever mode the last byte set. Plain lines cannot corrupt
/// the terminal state.
///
/// Files live in Application Support rather than UserDefaults: this is
/// potentially megabytes of text, and a preferences plist that size is read in
/// full on every launch by anything that touches defaults.
enum ScrollbackStore {
    /// Enough to see how a dev server died without keeping a session's history
    /// forever.
    static let maxLines = 400

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("Ookook/Scrollback", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return url
    }

    /// A process name can contain anything the user typed into `ookook.yml`,
    /// and the project part is a path, so neither is safe as a filename.
    private static func fileName(for ref: ProcessRef) -> String {
        let allowed = CharacterSet.alphanumerics
        let safe = ref.id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(safe).prefix(120) + ".log"
    }

    static func save(_ lines: [String], for ref: ProcessRef) {
        guard let directory else { return }
        let url = directory.appendingPathComponent(fileName(for: ref))
        let text = lines.suffix(maxLines).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    static func load(for ref: ProcessRef) -> [String] {
        guard let directory else { return [] }
        let url = directory.appendingPathComponent(fileName(for: ref))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }

    static func clear(for ref: ProcessRef) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName(for: ref)))
    }
}
