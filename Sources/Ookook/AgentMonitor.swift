import Combine
import Darwin
import Foundation

/// Discovers Claude Code sessions running inside supervised processes and
/// reports what each one is doing and how full its context is.
///
/// A session is found by walking a process's descendants and looking for
/// `~/.claude/sessions/<pid>.json`. Going pid-first matters: those records are
/// left behind when a session dies, so enumerating the directory would surface
/// sessions that ended days ago. Starting from pids we know are alive makes the
/// staleness question disappear.
@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var sessions: [String: AgentSession] = [:]

    /// Supplies (process ref id, pid) for everything currently running.
    var pidProvider: (() -> [(id: String, pid: pid_t)])?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.tolga.ookook.agents", qos: .utility)

    private static let sessionsDirectory = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    private static let projectsDirectory = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    func start(interval: TimeInterval = 3) {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let targets = pidProvider?(), !targets.isEmpty else {
            sessions = [:]
            return
        }
        queue.async {
            let children = ProcessTree.childrenByParent()
            var found: [String: AgentSession] = [:]
            for target in targets {
                for pid in ProcessTree.descendants(of: target.pid, children: children) {
                    if let session = Self.readSession(pid: pid) {
                        found[target.id] = session
                        break
                    }
                }
            }
            Task { @MainActor [weak self] in
                self?.apply(found)
            }
        }
    }

    /// Called when an agent's activity changes; carries the process ref id.
    var onActivityChange: ((String, AgentSession.Activity, AgentSession.Activity) -> Void)?

    /// Publishes the new sample and reports transitions worth alerting on.
    private func apply(_ found: [String: AgentSession]) {
        for (id, session) in found {
            let previous = sessions[id]?.activity
            if let previous, previous != session.activity {
                onActivityChange?(id, previous, session.activity)
            }
        }
        sessions = found
        Notifier.shared.updateBadge(waiting: found.values.filter { $0.activity.needsAttention }.count)
    }

    // MARK: - Reading Claude Code state

    private static func readSession(pid: pid_t) -> AgentSession? {
        let url = sessionsDirectory.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["sessionId"] as? String,
              let cwd = object["cwd"] as? String
        else { return nil }

        let activity = AgentSession.Activity(rawValue: object["status"] as? String ?? "") ?? .unknown
        var session = AgentSession(sessionID: sessionID, cwd: cwd, activity: activity)

        if let transcript = transcriptURL(sessionID: sessionID, cwd: cwd) {
            if let usage = usage(in: transcript) {
                session.model = usage.model
                session.contextTokens = usage.tokens
                session.contextLimit = AgentSession.contextLimit(for: usage.model)
            }
            session.subagents = subagents(besides: transcript)
        }
        return session
    }

    /// Context size of the most recent assistant turn.
    ///
    /// Each assistant line reports the *whole* prompt it was sent, so the latest
    /// line is the current context size - summing turns would multiply it many
    /// times over. Compaction resets the figure, which is why the last line is
    /// right and the maximum is not.
    private static func usage(in url: URL) -> (model: String?, tokens: Int)? {
        guard let tail = readTail(of: url, bytes: 512 * 1024) else { return nil }

        // The end of the file is bookkeeping (attachments, titles, modes), so
        // scan backwards for the newest line that actually carries usage.
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("\"usage\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let total = input + cacheRead + cacheCreation
            guard total > 0 else { continue }
            return (message["model"] as? String, total)
        }
        return nil
    }

    /// Sub-agent transcripts sit in a `subagents` directory beside the parent's
    /// transcript, nested a further level when they belong to a workflow.
    ///
    /// Only recently-written files are considered: a long-lived session
    /// accumulates hundreds of finished sub-agents, and listing them all would
    /// bury the handful that are actually live.
    private static func subagents(besides transcript: URL) -> [AgentSession.Subagent] {
        let root = transcript.deletingPathExtension()
            .appendingPathComponent("subagents")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = Date().addingTimeInterval(-recentWindow)
        var found: [(date: Date, subagent: AgentSession.Subagent)] = []

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard url.lastPathComponent.hasPrefix("agent-") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified > cutoff else { continue }

            let workflow = url.deletingLastPathComponent().lastPathComponent
            let usage = usage(in: url)
            let subagent = AgentSession.Subagent(
                id: url.deletingPathExtension().lastPathComponent,
                title: title(of: url) ?? "Sub-agent",
                contextTokens: usage?.tokens,
                model: usage?.model,
                isActive: modified > Date().addingTimeInterval(-activeWindow),
                workflow: workflow == "subagents" ? nil : workflow)
            found.append((modified, subagent))
        }

        return found
            .sorted { $0.date > $1.date }
            .prefix(maxSubagents)
            .map(\.subagent)
    }

    /// Sub-agents carry no name, so the first line of the prompt they were given
    /// is the closest thing to one.
    private static func title(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8 * 1024),
              let text = String(data: head, encoding: .utf8),
              let firstLine = text.split(separator: "\n").first,
              let data = firstLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }

        let firstMeaningfulLine = content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return firstMeaningfulLine.isEmpty
            ? nil
            : String(firstMeaningfulLine.prefix(72))
    }

    private static let recentWindow: TimeInterval = 30 * 60
    private static let activeWindow: TimeInterval = 20
    private static let maxSubagents = 12

    /// Transcripts live under a slug of the directory the session was *started*
    /// in, which is not necessarily the directory it works on - so the slug is a
    /// hint, and the whole tree is searched by session id if it misses.
    private static func transcriptURL(sessionID: String, cwd: String) -> URL? {
        let direct = projectsDirectory
            .appendingPathComponent(slug(for: cwd))
            .appendingPathComponent("\(sessionID).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries {
            let candidate = entry.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Every character outside [A-Za-z0-9-] becomes `-`; case is preserved.
    static func slug(for path: String) -> String {
        String(path.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
    }

    /// Transcripts reach tens of megabytes; only the tail is ever needed.
    private static func readTail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        // A partial first line is expected when seeking into the middle; it is
        // simply skipped by the JSON parse.
        return String(data: data, encoding: .utf8)
    }
}

/// Shared process-tree walking, used for both memory and agent discovery.
enum ProcessTree {
    static func childrenByParent() -> [pid_t: [pid_t]] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }

        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&name, 4, &table, &size, nil, 0) == 0 else { return [:] }

        var map: [pid_t: [pid_t]] = [:]
        for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            map[table[index].kp_eproc.e_ppid, default: []].append(table[index].kp_proc.p_pid)
        }
        return map
    }

    static func descendants(of root: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        guard root > 0 else { return [] }
        var result: [pid_t] = []
        var stack = [root]
        var visited = Set<pid_t>()
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            result.append(pid)
            if let next = children[pid] { stack.append(contentsOf: next) }
        }
        return result
    }
}
