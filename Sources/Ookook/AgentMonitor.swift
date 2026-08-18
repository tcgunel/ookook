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
                self?.sessions = found
            }
        }
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

        if let usage = transcriptUsage(sessionID: sessionID, cwd: cwd) {
            session.model = usage.model
            session.contextTokens = usage.tokens
            session.contextLimit = AgentSession.contextLimit(for: usage.model)
        }
        return session
    }

    /// Context size of the most recent assistant turn.
    ///
    /// Each assistant line reports the *whole* prompt it was sent, so the latest
    /// line is the current context size - summing turns would multiply it many
    /// times over. Compaction resets the figure, which is why the last line is
    /// right and the maximum is not.
    private static func transcriptUsage(sessionID: String, cwd: String) -> (model: String?, tokens: Int)? {
        guard let url = transcriptURL(sessionID: sessionID, cwd: cwd) else { return nil }
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
