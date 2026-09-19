import Foundation
import SQLite3

/// Reads opencode's session history: the conversations offered for Resume and
/// the live state shown in the sidebar.
///
/// opencode keeps its sessions in a SQLite database rather than transcript
/// files. The database is opened read-only and asked one short question per
/// project scan; Ookook never writes to it. The schema is opencode's own, so
/// the contract here is deliberately forgiving - anything unexpected reads as
/// "nothing to offer", never as an error the user has to care about.
enum OpenCodeSessions {
    /// Where opencode says its database lives (`opencode debug paths`), with
    /// `XDG_DATA_HOME` honoured the way opencode itself honours it.
    static var databaseURL: URL {
        let environment = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? ""
        let base = environment.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
            : URL(fileURLWithPath: (environment as NSString).expandingTildeInPath,
                  isDirectory: true)
        return base.appendingPathComponent("opencode/opencode.db")
    }

    /// Top-level sessions at the project root or in a directory beneath it.
    ///
    /// `directory = root` covers sessions started at the project root - how
    /// Ookook launches them - and the prefix test covers a process with a
    /// `cwd` of its own. The trailing slash keeps `/code/app` from matching
    /// `/code/app-old`.
    private static let projectSessions = """
        session.parent_id IS NULL
          AND session.time_archived IS NULL
          AND (rtrim(session.directory, '/') = ?1
               OR instr(rtrim(session.directory, '/'), ?2) = 1)
        """

    /// Top-level sessions started in `projectRoot` or anywhere below it, newest
    /// first. Child sessions (subagents), archived sessions and rows with
    /// nothing to show are left out.
    static func summaries(projectRoot: URL, limit: Int) -> [AgentSessionSummary] {
        let root = projectRoot.standardizedFileURL.path
        guard limit > 0,
              FileManager.default.fileExists(atPath: databaseURL.path),
              let database = openDatabase() else { return [] }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT session.id, session.slug, session.title, session.model,
                   session.time_updated,
                   (SELECT json_extract(message.data, '$.text')
                      FROM session_message AS message
                     WHERE message.session_id = session.id AND message.type = 'user'
                     ORDER BY message.seq
                     LIMIT 1) AS first_prompt
              FROM session_v2 AS session
             WHERE \(projectSessions)
             ORDER BY session.time_updated DESC
             LIMIT ?3
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, root, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, root + "/", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var found: [AgentSessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), !id.isEmpty else { continue }
            // The title opencode generates is what its own session list shows;
            // the first user message and the slug are fallbacks for a session
            // whose title has not been written yet.
            let label = [text(statement, 2), text(statement, 5), text(statement, 1)]
                .compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            // A session opened and abandoned without a single message has
            // nothing to resume; offering it would only be a dead end.
            guard let label else { continue }
            found.append(AgentSessionSummary(
                id: id,
                provider: .opencode,
                modified: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1000),
                firstPrompt: label,
                model: model(from: text(statement, 3))))
        }
        return found
    }

    /// What the newest opencode session in a project is doing, for the sidebar.
    ///
    /// opencode writes a `session_message` row of type `idle` when a turn
    /// finishes, so the newest row is the state: anything after the last
    /// `idle` means a turn is in flight. Recent writes would be the wrong
    /// signal - the database goes quiet for the length of a tool call, which
    /// can be minutes.
    static func status(projectRoot: URL) -> AgentSession? {
        let root = projectRoot.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let database = openDatabase() else { return nil }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT session.id, session.directory, session.model,
                   (SELECT message.type
                      FROM session_message AS message
                     WHERE message.session_id = session.id
                     ORDER BY message.seq DESC
                     LIMIT 1) AS last_message
              FROM session_v2 AS session
             WHERE \(projectSessions)
             ORDER BY session.time_updated DESC
             LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, root, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, root + "/", -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = text(statement, 0), !id.isEmpty else { return nil }
        // A session with no messages yet is sitting at a prompt, not working.
        let last = text(statement, 3)?.lowercased()
        let activity: AgentSession.Activity = (last == nil || last == "idle") ? .idle : .busy
        return AgentSession(sessionID: id,
                            cwd: text(statement, 1) ?? root,
                            activity: activity,
                            model: model(from: text(statement, 2)))
    }

    /// `{"id":"…","providerID":"…"}` -> `providerID/id`.
    private static func model(from json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else { return nil }
        guard let provider = object["providerID"] as? String, !provider.isEmpty else { return id }
        return "\(provider)/\(id)"
    }

    private static func openDatabase() -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        // opencode may be mid-write when a menu is about to open; a short wait
        // beats showing no history because of one unlucky instant.
        sqlite3_busy_timeout(database, 250)
        return database
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
