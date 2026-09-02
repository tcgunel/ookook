import Foundation
import Yams

/// How a process is grouped in the sidebar. Purely presentational, but it is
/// what makes a stack of ten processes readable at a glance.
enum ProcessKind: String, Codable, CaseIterable {
    case agent
    case command
    case terminal

    var sectionTitle: String {
        switch self {
        case .agent: return "AGENTS"
        case .command: return "COMMANDS"
        case .terminal: return "TERMINALS"
        }
    }

    var symbolName: String {
        switch self {
        case .agent: return "sparkles"
        case .command: return "square.stack.3d.up"
        case .terminal: return "terminal"
        }
    }
}

/// The interactive coding agent a process launches, when it is one Ookook
/// understands well enough to offer provider-specific actions such as Resume.
enum AgentProvider: String, Codable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// One supervised process, as declared in `ookook.yml`.
struct ProcessSpec: Codable, Identifiable, Equatable {
    var name: String
    /// Shell command line, run through the login shell so PATH/nvm/asdf behave
    /// the way they do in the user's own terminal.
    var command: String
    /// Working directory, relative to the config file unless absolute.
    var cwd: String?
    var autostart: Bool?
    var autorestart: Bool?
    /// Sidebar grouping; defaults to `command`.
    var type: ProcessKind?
    /// Purely informational - shown in the sidebar so you can find the port
    /// without digging through the log.
    var port: Int?
    /// Extra environment for this process, overriding what it inherits.
    var env: [String: String]?

    var id: String { name }

    var kind: ProcessKind { type ?? .command }

    /// Inferred from the executable so existing ookook.yml files need no new
    /// field and commands such as `/opt/homebrew/bin/codex` still work.
    var agentProvider: AgentProvider? {
        guard kind == .agent,
              let first = command.split(separator: " ", maxSplits: 1).first else { return nil }
        let executable = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "claude": return .claude
        case "codex": return .codex
        default: return nil
        }
    }

    var startsAutomatically: Bool { autostart ?? true }
    var restartsOnCrash: Bool { autorestart ?? false }
}

struct ProjectConfig: Codable, Equatable {
    var name: String?
    var processes: [ProcessSpec]

    /// Directory the config was loaded from; every relative `cwd` resolves against it.
    var rootURL: URL = URL(fileURLWithPath: ".")

    private enum CodingKeys: String, CodingKey { case name, processes }

    static func load(from url: URL) throws -> ProjectConfig {
        let text = try String(contentsOf: url, encoding: .utf8)
        var config = try YAMLDecoder().decode(ProjectConfig.self, from: text)
        config.rootURL = url.deletingLastPathComponent()
        try config.validate()
        return config
    }

    private func validate() throws {
        guard !processes.isEmpty else {
            throw ConfigError.message("`processes` is empty - nothing to run.")
        }
        let names = processes.map(\.name)
        let duplicates = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        guard duplicates.isEmpty else {
            throw ConfigError.message(
                "Duplicate process names: \(duplicates.sorted().joined(separator: ", "))")
        }
    }

    /// Deletes one process entry from the config file, in place.
    ///
    /// This edits the text rather than re-encoding the decoded config: a
    /// round-trip through Yams would reformat the whole file and throw away
    /// every comment in it, which is a rude thing to do to a file the user
    /// wrote by hand just because they removed one process.
    static func removeProcess(named name: String, from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")

        func itemIndent(_ line: String) -> Int? {
            let trimmed = line.drop(while: { $0 == " " })
            guard trimmed.hasPrefix("- ") || trimmed == "-" else { return nil }
            return line.count - trimmed.count
        }
        func declaredName(_ line: String) -> String? {
            guard itemIndent(line) != nil else { return nil }
            let body = line.drop(while: { $0 == " " }).dropFirst().drop(while: { $0 == " " })
            guard body.hasPrefix("name:") else { return nil }
            let value = body.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        guard let start = lines.firstIndex(where: { declaredName($0) == name }),
              let indent = itemIndent(lines[start])
        else {
            throw ConfigError.message("`\(name)` is not declared in \(url.lastPathComponent).")
        }

        // The entry runs until the next list item at the same indent, or until
        // something dedents out of the list entirely.
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { end += 1; continue }
            let leading = line.count - line.drop(while: { $0 == " " }).count
            if leading <= indent { break }
            end += 1
        }
        // Blank lines and the comments that introduce the entry belong to it.
        var first = start
        while first > 0 {
            let previous = lines[first - 1].trimmingCharacters(in: .whitespaces)
            guard previous.hasPrefix("#") || previous.isEmpty else { break }
            first -= 1
        }
        // ... but not a blank line that only separates it from what came
        // before, which the following entry now needs.
        if first > 0, lines[first].trimmingCharacters(in: .whitespaces).isEmpty { first += 1 }

        lines.removeSubrange(first..<end)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Absolute working directory for a spec.
    func workingDirectory(for spec: ProcessSpec) -> URL {
        guard let cwd = spec.cwd, !cwd.isEmpty else { return rootURL }
        let expanded = (cwd as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return rootURL.appendingPathComponent(expanded).standardizedFileURL
    }
}

enum ConfigError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
