import Foundation
import Yams

/// Where Claude Code keeps the things this window edits.
///
/// Grounded in what is actually on disk here, not in documentation:
/// - `~/.claude/settings.json` - user settings. Real top-level keys observed:
///   `permissions`, `model`, `hooks`, `statusLine`, `enabledPlugins`,
///   `effortLevel`, `autoCompactWindow`, `tui`, `voice`, `theme`, `editorMode`,
///   and a dozen more booleans. Only a handful are exposed for editing; the
///   rest must survive untouched.
/// - `~/.claude/settings.local.json` - same schema, machine-local overrides.
///   Here it holds only `permissions.allow`.
/// - `<project>/.claude/settings.json` - same schema again, checked in.
/// - `~/.claude.json` - the CLI's own state blob (`numStartups`, `projects`, …)
///   which also carries `mcpServers`. Huge and rewritten constantly by the CLI,
///   so Ookook reads it and never writes it.
/// - `<project>/.mcp.json` - `{ "mcpServers": { name: {...} } }`.
enum ClaudeConfigPaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeDirectory: URL { home.appendingPathComponent(".claude") }
    static var userSettings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    static var userLocalSettings: URL { claudeDirectory.appendingPathComponent("settings.local.json") }
    static var userAgents: URL { claudeDirectory.appendingPathComponent("agents") }
    static var cliState: URL { home.appendingPathComponent(".claude.json") }

    static func projectSettings(root: URL) -> URL {
        root.appendingPathComponent(".claude/settings.json")
    }

    static func projectLocalSettings(root: URL) -> URL {
        root.appendingPathComponent(".claude/settings.local.json")
    }

    static func projectAgents(root: URL) -> URL {
        root.appendingPathComponent(".claude/agents")
    }

    static func projectMCP(root: URL) -> URL {
        root.appendingPathComponent(".mcp.json")
    }
}

// MARK: - Settings document

/// One `settings.json`-shaped file, loaded whole so unrelated keys survive a save.
///
/// The document deliberately holds the *entire* parsed tree, not a struct of the
/// fields we understand. Every accessor reads and writes through that tree, so a
/// key Ookook has never heard of - a `hooks` array, a future setting - comes back
/// out of `save()` byte-identical apart from indentation.
struct ClaudeSettingsDocument: Equatable {
    let url: URL
    /// False when the file does not exist yet; saving creates it.
    private(set) var exists: Bool
    private var root: JSONObject

    /// Non-fatal load problems. A malformed file is reported, never overwritten.
    enum LoadFailure: Error, LocalizedError {
        case unreadable
        case notAnObject
        case malformed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read."
            case .notAnObject: return "The file's top level is not a JSON object."
            case .malformed: return "The file is not valid JSON. Ookook will not overwrite it."
            }
        }
    }

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.exists = false
            self.root = JSONObject()
            return
        }
        self.exists = true
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw LoadFailure.unreadable }
        // An empty file is a legitimate starting point; anything else that fails
        // to parse is someone else's data and stays where it is.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.root = JSONObject()
            return
        }
        guard let value = try? JSONValue.parse(text) else { throw LoadFailure.malformed }
        guard let object = value.objectValue else { throw LoadFailure.notAnObject }
        self.root = object
    }

    // MARK: Editable surface

    /// `"opus"`, `"sonnet"`, a full model id - Claude Code accepts an alias or an
    /// id, so this stays free text rather than an enum that would reject a new one.
    var model: String {
        get { root["model"]?.stringValue ?? "" }
        set { root["model"] = newValue.isEmpty ? nil : .string(newValue) }
    }

    /// `permissions.defaultMode`; observed value here is `"auto"`.
    var defaultMode: String {
        get { root["permissions"]?.objectValue?["defaultMode"]?.stringValue ?? "" }
        set {
            let value = newValue
            root.withObject("permissions") { $0["defaultMode"] = value.isEmpty ? nil : .string(value) }
        }
    }

    /// Permission rules such as `Bash(brew list *)` or `WebSearch`, exactly as
    /// they appear in `permissions.allow` / `.deny` / `.ask`.
    func permissionRules(_ list: PermissionList) -> [String] {
        root["permissions"]?.objectValue?[list.rawValue]?.stringArray ?? []
    }

    mutating func setPermissionRules(_ list: PermissionList, _ rules: [String]) {
        let cleaned = rules.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        root.withObject("permissions") {
            $0[list.rawValue] = cleaned.isEmpty ? nil : .array(cleaned.map { .string($0) })
        }
    }

    enum PermissionList: String, CaseIterable, Identifiable {
        case allow, ask, deny
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var help: String {
            switch self {
            case .allow: return "Runs without asking."
            case .ask: return "Always prompts, even in auto mode."
            case .deny: return "Blocked outright."
            }
        }
    }

    /// `env` - environment variables Claude Code exports into every tool call.
    /// Absent from this machine's settings, so the shape is taken from the
    /// documented string-to-string map and written as such.
    var environment: [(key: String, value: String)] {
        (root["env"] ?? .null).stringMap.map { (key: $0.0, value: $0.1) }
    }

    mutating func setEnvironment(_ pairs: [(key: String, value: String)]) {
        var object = JSONObject()
        for pair in pairs where !pair.key.trimmingCharacters(in: .whitespaces).isEmpty {
            object[pair.key.trimmingCharacters(in: .whitespaces)] = .string(pair.value)
        }
        root["env"] = object.keys.isEmpty ? nil : .object(object)
    }

    /// Keys present in the file that this UI does not surface. Shown so the user
    /// can see what they are *not* editing rather than assuming it was lost.
    var untouchedKeys: [String] {
        root.keys.filter { $0 != "model" && $0 != "permissions" && $0 != "env" }
    }

    // MARK: Saving

    /// Re-reads the file, replays this document's edits onto whatever is there
    /// now, and writes the result atomically after taking a one-time backup.
    ///
    /// The re-read matters: Claude Code may have rewritten the file while the
    /// window sat open, and clobbering that with a stale in-memory tree is the
    /// exact failure this whole type exists to avoid.
    func save() throws {
        var target = try ClaudeSettingsDocument(url: url)
        target.root = Self.merge(edited: root, onto: target.root)
        let text = JSONValue.object(target.root).serialized()
        try Self.backupIfNeeded(url: url)
        try Self.writeAtomically(text, to: url)
    }

    /// Keys the editor owns win; everything else on disk is kept, including keys
    /// added since this document was loaded.
    private static func merge(edited: JSONObject, onto disk: JSONObject) -> JSONObject {
        var out = disk
        for key in ["model", "env"] { out[key] = edited[key] }
        var permissions = disk["permissions"]?.objectValue ?? JSONObject()
        let editedPermissions = edited["permissions"]?.objectValue ?? JSONObject()
        for key in ["defaultMode", "allow", "ask", "deny"] { permissions[key] = editedPermissions[key] }
        out["permissions"] = permissions.keys.isEmpty ? nil : .object(permissions)
        return out
    }

    /// One `.bak` per file, taken before the first write of the app's lifetime.
    /// Refreshing it on every save would eventually leave the backup identical to
    /// the file it is meant to rescue.
    private static var backedUp: Set<String> = []
    private static let backupLock = NSLock()

    private static func backupIfNeeded(url: URL) throws {
        backupLock.lock()
        defer { backupLock.unlock() }
        guard !backedUp.contains(url.path) else { return }
        backedUp.insert(url.path)
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        try data.write(to: URL(fileURLWithPath: url.path + ".bak"))
    }

    /// Temp file in the same directory, then `replaceItemAt` - a crash mid-write
    /// leaves the old file intact rather than a truncated one.
    private static func writeAtomically(_ text: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).ookook-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        // Preserve the original mode; `replaceItemAt` otherwise hands the file
        // the temp file's permissions.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attributes[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}

// MARK: - Custom subagents

/// A custom subagent from `~/.claude/agents/*.md` or `<project>/.claude/agents/*.md`.
///
/// Frontmatter fields actually present across the 33 agents on this machine:
/// `name` (33), `model` (33), `description` (33), `tools` (24), and one
/// `llm_service`. `tools` appears as a YAML flow list - `tools: [Read, Grep,
/// Glob, Bash]` - not the comma-separated string the docs also allow, so both
/// are accepted.
struct ClaudeAgent: Identifiable, Equatable {
    let url: URL
    var name: String
    var description: String
    var model: String
    var tools: [String]
    /// Frontmatter keys beyond the four above, so an unusual file still shows
    /// everything it declares instead of silently hiding it.
    var extraFields: [(key: String, value: String)]
    /// True for agents living under a project rather than `~/.claude`.
    var isProjectScoped: Bool

    var id: URL { url }

    static func == (lhs: ClaudeAgent, rhs: ClaudeAgent) -> Bool { lhs.url == rhs.url }

    /// Parses the `---` frontmatter block. Returns nil for a file without one,
    /// which is how a stray README in the agents folder gets ignored.
    static func load(url: URL, isProjectScoped: Bool) -> ClaudeAgent? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let frontmatter = lines[..<end].joined(separator: "\n")
        guard let parsed = try? Yams.load(yaml: frontmatter) as? [String: Any] else { return nil }

        let known = ["name", "description", "model", "tools"]
        let extras = parsed.keys.filter { !known.contains($0) }.sorted().map {
            (key: $0, value: String(describing: parsed[$0] ?? ""))
        }
        return ClaudeAgent(
            url: url,
            name: parsed["name"] as? String ?? url.deletingPathExtension().lastPathComponent,
            description: parsed["description"] as? String ?? "",
            model: parsed["model"] as? String ?? "",
            tools: toolList(parsed["tools"]),
            extraFields: extras,
            isProjectScoped: isProjectScoped)
    }

    private static func toolList(_ raw: Any?) -> [String] {
        if let list = raw as? [Any] { return list.map { String(describing: $0) } }
        if let text = raw as? String {
            return text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    static func loadAll(in directory: URL, isProjectScoped: Bool) -> [ClaudeAgent] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension == "md" }
            .compactMap { load(url: $0, isProjectScoped: isProjectScoped) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - MCP servers

/// One entry from an `mcpServers` map. Both real shapes on this machine are
/// covered: HTTP servers - `{"type": "http", "url": "http://127.0.0.1:4517/mcp"}` -
/// and stdio servers, which carry `command` plus an `args` array.
struct MCPServerInfo: Identifiable, Equatable {
    var name: String
    var transport: String
    var url: String?
    var command: String?
    var args: [String]
    /// Only the names. Values are routinely API tokens and must never be rendered.
    var environmentKeys: [String]
    /// Which file it came from, since the same name can appear in several.
    var source: String

    var id: String { source + "/" + name }

    var summary: String {
        if let url { return url }
        guard let command else { return transport }
        return ([command] + args).joined(separator: " ")
    }

    static func load(from url: URL, source: String) -> [MCPServerInfo] {
        guard let root = try? JSONValue.parse(contentsOf: url).objectValue,
              let servers = root["mcpServers"]?.objectValue else { return [] }
        return servers.keys.compactMap { name in
            guard let entry = servers[name]?.objectValue else { return nil }
            let args = entry["args"]?.stringArray ?? []
            let command = entry["command"]?.stringValue
            return MCPServerInfo(
                name: name,
                transport: entry["type"]?.stringValue ?? (command == nil ? "http" : "stdio"),
                url: entry["url"]?.stringValue,
                command: command,
                args: args,
                environmentKeys: entry["env"]?.objectValue?.keys ?? [],
                source: source)
        }
    }
}

// MARK: - Store

/// Everything the settings window shows, loaded off the main thread and
/// published back on it.
@MainActor
final class ClaudeConfigStore: ObservableObject {
    /// The project whose `.claude` folder is shown alongside the user's own.
    @Published private(set) var projectRoot: URL?

    @Published var userSettings: ClaudeSettingsDocument?
    @Published var userLocalSettings: ClaudeSettingsDocument?
    @Published var projectSettings: ClaudeSettingsDocument?

    @Published private(set) var agents: [ClaudeAgent] = []
    @Published private(set) var mcpServers: [MCPServerInfo] = []

    /// Surfaced in the UI instead of an alert; a config window that refuses to
    /// open because one file is malformed would be worse than one that says so.
    @Published private(set) var loadErrors: [String] = []
    @Published var saveError: String?
    @Published private(set) var isLoading = false

    private let ioQueue = DispatchQueue(label: "ookook.claude-settings", qos: .userInitiated)

    init(projectRoot: URL? = nil) {
        self.projectRoot = projectRoot
    }

    func setProjectRoot(_ url: URL?) {
        guard url != projectRoot else { return }
        projectRoot = url
        reload()
    }

    /// Reloads are ordered by generation, not by arrival: several can be in
    /// flight at once (opening the window reloads, setting a project root
    /// reloads, the view's onAppear reloads), and unstructured Tasks have no
    /// ordering guarantee - so without this, reopening for a different project
    /// can end up showing the previous project's settings.
    private var generation = 0

    func reload() {
        isLoading = true
        generation += 1
        let generation = generation
        let root = projectRoot
        ioQueue.async {
            let snapshot = Self.loadSnapshot(projectRoot: root)
            Task { @MainActor in
                guard generation == self.generation else { return }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        userSettings = snapshot.userSettings
        userLocalSettings = snapshot.userLocalSettings
        projectSettings = snapshot.projectSettings
        agents = snapshot.agents
        mcpServers = snapshot.mcpServers
        loadErrors = snapshot.errors
        isLoading = false
    }

    /// Saves one document and reloads, so the UI always shows what is on disk
    /// rather than what the user typed.
    func save(_ document: ClaudeSettingsDocument) {
        do {
            try document.save()
            saveError = nil
            reload()
        } catch {
            saveError = "Could not save \(document.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private struct Snapshot {
        var userSettings: ClaudeSettingsDocument?
        var userLocalSettings: ClaudeSettingsDocument?
        var projectSettings: ClaudeSettingsDocument?
        var agents: [ClaudeAgent] = []
        var mcpServers: [MCPServerInfo] = []
        var errors: [String] = []
    }

    private nonisolated static func loadSnapshot(projectRoot: URL?) -> Snapshot {
        var snapshot = Snapshot()

        func open(_ url: URL) -> ClaudeSettingsDocument? {
            do {
                return try ClaudeSettingsDocument(url: url)
            } catch {
                snapshot.errors.append("\(url.path): \(error.localizedDescription)")
                return nil
            }
        }

        snapshot.userSettings = open(ClaudeConfigPaths.userSettings)
        snapshot.userLocalSettings = open(ClaudeConfigPaths.userLocalSettings)
        snapshot.agents = ClaudeAgent.loadAll(in: ClaudeConfigPaths.userAgents, isProjectScoped: false)
        snapshot.mcpServers = MCPServerInfo.load(from: ClaudeConfigPaths.cliState, source: "~/.claude.json")

        if let root = projectRoot {
            snapshot.projectSettings = open(ClaudeConfigPaths.projectSettings(root: root))
            snapshot.agents += ClaudeAgent.loadAll(in: ClaudeConfigPaths.projectAgents(root: root), isProjectScoped: true)
            snapshot.mcpServers += MCPServerInfo.load(
                from: ClaudeConfigPaths.projectMCP(root: root),
                source: "\(root.lastPathComponent)/.mcp.json")
        }
        return snapshot
    }
}
