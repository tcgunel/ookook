import Foundation

/// Cached parses of agent transcript files, keyed by path and invalidated by
/// the file's modification date and size.
///
/// The sidebar's monitors rescan on short timers, and a workflow sweep leaves
/// hundreds of sub-agent transcripts in a session's directory. Reading each of
/// them on every tick - 512 KB a pop, JSON-parsed line by line - was the most
/// expensive thing the app did while agents worked: a stack sample from a busy
/// sweep had Ookook burning 90 seconds of CPU per 101, nearly all of it here,
/// and the churn grew the app's malloc zone by tens of gigabytes over a night.
///
/// A transcript that has not changed cannot answer differently, so the answer
/// is kept until the file's fingerprint moves. A file that is still being
/// written is read again on every tick, which is exactly the frequency its
/// answer can change at.
final class TranscriptCache: @unchecked Sendable {
    struct Usage {
        var model: String?
        var tokens: Int?
    }

    private let usages = Memo<Usage?>()
    private let titles = Memo<String?>()
    private let prompts = Memo<String?>()
    private let models = Memo<String?>()

    /// Context size and model of a transcript's newest turn.
    func usage(for url: URL, compute: (URL) -> Usage?) -> Usage? {
        usages.value(for: url, compute: compute)
    }

    /// First line of a sub-agent's prompt, used as its name.
    func title(for url: URL, compute: (URL) -> String?) -> String? {
        titles.value(for: url, compute: compute)
    }

    /// First real user message of a session, for the resume menu.
    func firstPrompt(for url: URL, compute: (URL) -> String?) -> String? {
        prompts.value(for: url, compute: compute)
    }

    /// Model the newest turn of a session ran on.
    func lastModel(for url: URL, compute: (URL) -> String?) -> String? {
        models.value(for: url, compute: compute)
    }
}

/// One memo table. The cache is read from the agent queue and from detached
/// scans, so it carries its own lock; a duplicate parse under a race is
/// harmless, which is why parsing happens outside it.
private final class Memo<Value> {
    private struct Entry {
        var fingerprint: FileFingerprint
        var value: Value
    }

    /// Entries are small; this only bounds a pathological tree that keeps
    /// minting new paths.
    private static var limit: Int { 4_000 }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func value(for url: URL, compute: (URL) -> Value) -> Value {
        guard let fingerprint = FileFingerprint(url: url) else {
            // No fingerprint, no way to know when it changes: read it.
            return compute(url)
        }
        lock.lock()
        if let entry = entries[url.path], entry.fingerprint == fingerprint {
            let value = entry.value
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = compute(url)

        lock.lock()
        entries[url.path] = Entry(fingerprint: fingerprint, value: value)
        if entries.count > Self.limit { prune() }
        lock.unlock()
        return value
    }

    /// Drops entries whose files are gone; a session deleted from disk will
    /// never be asked about again, and the cache should shrink with it.
    private func prune() {
        let manager = FileManager.default
        entries = entries.filter { manager.fileExists(atPath: $0.key) }
        if entries.count > Self.limit { entries.removeAll() }
    }
}

private struct FileFingerprint: Equatable {
    var modified: Date
    var size: Int

    /// `attributesOfItem` stats the path afresh; `URL.resourceValues` would
    /// serve values the URL object cached at first read, which is exactly the
    /// staleness this cache exists to avoid.
    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int else { return nil }
        self.modified = modified
        self.size = size
    }
}
