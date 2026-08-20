import Combine
import Foundation

/// A Claude Code conversation on disk, as offered in the Resume menu.
struct ClaudeSessionSummary: Identifiable, Equatable {
    let id: String
    let modified: Date
    /// First thing the user asked, which is how anyone actually recognises a
    /// session - the UUID means nothing to them.
    let firstPrompt: String
    /// Model the session was last running, so resuming can continue on it.
    /// `--resume` restores the conversation but takes the model from the
    /// current config, so a session started on Opus silently continues on
    /// whatever the default is now unless the model is passed back explicitly.
    let model: String?

    var label: String {
        let time = Self.formatter.string(from: modified)
        let prompt = firstPrompt.isEmpty ? id.prefix(8) + "…" : firstPrompt.prefix(60)
        return "\(time) · \(prompt)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// The command that resumes it.
    func command(base: String = "claude") -> String {
        var parts = [base, "--resume", id]
        if let model, !model.isEmpty { parts += ["--model", model] }
        return parts.joined(separator: " ")
    }
}

/// Finds the transcripts Claude Code keeps for a project.
///
/// Reads only the ends of each file: transcripts run to tens of megabytes, and
/// loading one to show a menu label would stall the UI for seconds.
@MainActor
final class ClaudeSessionStore: ObservableObject {
    /// Sessions per project id (the project's directory path).
    @Published private(set) var sessions: [String: [ClaudeSessionSummary]] = [:]

    /// More than this and the menu is a wall of near-identical lines.
    private static let maxSessions = 8
    /// Enough of the head to reach the first real user message past the system
    /// preamble, without reading a 80MB file.
    private static let headBytes = 512 * 1024
    /// Enough of the tail to find the last assistant message with a model on it.
    private static let tailBytes = 2 * 1024 * 1024

    private var refreshing: Set<String> = []

    func sessions(for projectID: String) -> [ClaudeSessionSummary] {
        sessions[projectID] ?? []
    }

    /// Rescans one project. Cheap to call - it coalesces concurrent refreshes.
    func refresh(projectID: String, root: URL) {
        guard !refreshing.contains(projectID) else { return }
        refreshing.insert(projectID)
        let directory = Self.transcriptDirectory(for: root)
        Task.detached(priority: .utility) {
            let found = Self.scan(directory)
            await MainActor.run {
                self.sessions[projectID] = found
                self.refreshing.remove(projectID)
            }
        }
    }

    func refresh(projects: [(id: String, root: URL)]) {
        for project in projects { refresh(projectID: project.id, root: project.root) }
    }

    /// `~/Projects/app` -> `~/.claude/projects/-Users-you-Projects-app`.
    ///
    /// Claude Code slugifies the absolute path by replacing every character
    /// that is not alphanumeric with a dash, which is why a leading slash
    /// becomes a leading dash.
    nonisolated static func transcriptDirectory(for root: URL) -> URL {
        let path = root.standardizedFileURL.path
        let slug = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects/\(slug)", isDirectory: true)
    }

    private nonisolated static func scan(_ directory: URL) -> [ClaudeSessionSummary] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let transcripts = entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date, Int)? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let date = values?.contentModificationDate else { return nil }
                return (url, date, values?.fileSize ?? 0)
            }
            // A transcript of a few hundred bytes is a session that opened and
            // was closed again; resuming it lands you nowhere.
            .filter { $0.2 > 2_000 }
            .sorted { $0.1 > $1.1 }
            .prefix(maxSessions)

        return transcripts.map { url, date, _ in
            ClaudeSessionSummary(
                id: url.deletingPathExtension().lastPathComponent,
                modified: date,
                firstPrompt: firstPrompt(in: url) ?? "",
                model: lastModel(in: url))
        }
    }

    private nonisolated static func firstPrompt(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: .newlines) {
            guard let object = json(line), object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any] else { continue }
            if let content = message["content"] as? String, !content.isEmpty {
                return clean(content)
            }
            if let parts = message["content"] as? [[String: Any]] {
                for part in parts where part["type"] as? String == "text" {
                    if let text = part["text"] as? String, !text.isEmpty { return clean(text) }
                }
            }
        }
        return nil
    }

    private nonisolated static func lastModel(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var model: String?
        for line in text.components(separatedBy: .newlines) {
            guard let object = json(line),
                  let message = object["message"] as? [String: Any],
                  let candidate = message["model"] as? String else { continue }
            // Synthetic entries are Claude Code's own bookkeeping, not a model
            // anyone can be resumed onto.
            guard !candidate.hasPrefix("<") else { continue }
            model = candidate
        }
        return model
    }

    private nonisolated static func json(_ line: String) -> [String: Any]? {
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Command-message wrappers and newlines make menu labels unreadable.
    private nonisolated static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
