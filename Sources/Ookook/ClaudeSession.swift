import Combine
import Foundation

/// A supported coding-agent conversation on disk, as offered in Resume menus.
struct AgentSessionSummary: Identifiable, Equatable {
    let id: String
    let provider: AgentProvider
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

    /// The providers place `resume` differently in their CLI grammars.
    func command(base: String) -> String {
        var parts: [String]
        switch provider {
        case .claude: parts = [base, "--resume", id]
        case .codex: parts = [base, "resume", id]
        }
        if let model, !model.isEmpty { parts += ["--model", model] }
        return parts.joined(separator: " ")
    }
}

/// Finds the transcripts Claude Code and Codex keep for a project.
///
/// Reads only the ends of each file: transcripts run to tens of megabytes, and
/// loading one to show a menu label would stall the UI for seconds.
@MainActor
final class AgentSessionStore: ObservableObject {
    /// Sessions per project id (the project's directory path).
    @Published private(set) var sessions: [String: [AgentSessionSummary]] = [:]

    /// More than this and the menu is a wall of near-identical lines.
    private nonisolated static let maxSessions = 8
    /// Enough of the head to reach the first real user message past the system
    /// preamble, without reading a 80MB file.
    private nonisolated static let headBytes = 512 * 1024
    /// Enough of the tail to find the last assistant message with a model on it.
    private nonisolated static let tailBytes = 2 * 1024 * 1024
    /// A transcript of a few hundred bytes is a session that opened and was
    /// closed again; resuming it lands you nowhere.
    nonisolated static let minimumTranscriptBytes = 2_000

    private var refreshing: Set<String> = []

    func sessions(for projectID: String, provider: AgentProvider?) -> [AgentSessionSummary] {
        guard let provider else { return [] }
        return (sessions[projectID] ?? []).filter { $0.provider == provider }
    }

    func sessions(for projectID: String) -> [AgentSessionSummary] {
        sessions[projectID] ?? []
    }

    /// Rescans one project. Cheap to call - it coalesces concurrent refreshes.
    func refresh(projectID: String, root: URL) {
        guard !refreshing.contains(projectID) else { return }
        refreshing.insert(projectID)
        Task.detached(priority: .utility) {
            let claude = Self.scanClaude(Self.claudeTranscriptDirectory(for: root))
            let codex = Self.scanCodex(projectRoot: root)
            let found = (claude + codex)
                .sorted { $0.modified > $1.modified }
                .prefix(Self.maxSessions)
            await MainActor.run {
                self.sessions[projectID] = Array(found)
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
    nonisolated static func claudeTranscriptDirectory(for root: URL) -> URL {
        let path = root.standardizedFileURL.path
        let slug = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects/\(slug)", isDirectory: true)
    }

    private nonisolated static func scanClaude(_ directory: URL) -> [AgentSessionSummary] {
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
            .filter { $0.2 > minimumTranscriptBytes }
            .sorted { $0.1 > $1.1 }
            .prefix(maxSessions)

        return transcripts.map { url, date, _ in
            AgentSessionSummary(
                id: url.deletingPathExtension().lastPathComponent,
                provider: .claude,
                modified: date,
                firstPrompt: firstPrompt(in: url) ?? "",
                model: lastModel(in: url))
        }
    }

    /// Codex rollouts are date-partitioned under ~/.codex/sessions. Read only
    /// recent files and accept one when its session metadata names this root.
    private nonisolated static func scanCodex(projectRoot: URL) -> [AgentSessionSummary] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var files: [(URL, Date, Int)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values?.contentModificationDate else { continue }
            files.append((url, date, values?.fileSize ?? 0))
        }

        let wantedRoot = projectRoot.standardizedFileURL.path
        return files.sorted { $0.1 > $1.1 }.prefix(100).compactMap { url, date, size in
            guard size > 500,
                  let head = readHead(of: url, bytes: headBytes),
                  let metadata = head.first(where: { $0["type"] as? String == "session_meta" }),
                  let payload = metadata["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String,
                  URL(fileURLWithPath: cwd).standardizedFileURL.path == wantedRoot,
                  let id = (payload["session_id"] ?? payload["id"]) as? String
            else { return nil }

            return AgentSessionSummary(
                id: id,
                provider: .codex,
                modified: date,
                firstPrompt: codexFirstPrompt(in: head) ?? "",
                model: codexLastModel(in: url))
        }
    }

    private nonisolated static func readHead(of url: URL, bytes: Int) -> [[String: Any]]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.components(separatedBy: .newlines).compactMap(json)
    }

    private nonisolated static func codexFirstPrompt(in lines: [[String: Any]]) -> String? {
        for object in lines where object["type"] as? String == "event_msg" {
            guard let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message",
                  let message = payload["message"] as? String,
                  !message.hasPrefix("<command-name>") else { continue }
            return clean(message)
        }
        return nil
    }

    private nonisolated static func codexLastModel(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var model: String?
        for line in text.components(separatedBy: .newlines) {
            guard let object = json(line), object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any],
                  let candidate = payload["model"] as? String else { continue }
            model = candidate
        }
        return model
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
