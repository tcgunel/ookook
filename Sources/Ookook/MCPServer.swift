import Foundation

/// Exposes the running workspace to AI agents over MCP.
///
/// Transport is JSON-RPC over HTTP on loopback, so a client connects with
/// `claude mcp add --transport http ookook http://127.0.0.1:<port>/mcp` and
/// needs no helper binary - the app itself is the server.
@MainActor
final class MCPServer: ObservableObject {
    static let defaultPort: UInt16 = 4517

    private weak var app: AppModel?
    private var http: HTTPServer?

    @Published private(set) var port: UInt16?
    @Published private(set) var lastError: String?

    init(app: AppModel) {
        self.app = app
    }

    func start(preferredPort: UInt16 = MCPServer.defaultPort) {
        let server = HTTPServer { [weak self] request, respond in
            // Hop to the main actor: everything the tools touch is UI state.
            Task { @MainActor in
                guard let self else { return respond(.empty(status: 503)) }
                respond(self.handle(request))
            }
        }
        do {
            try server.start(preferredPort: preferredPort)
            self.http = server
            self.port = server.port
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func stop() {
        http?.stop()
        http = nil
        port = nil
    }

    /// The line to paste into a terminal to connect Claude Code.
    var connectCommand: String? {
        guard let port else { return nil }
        return "claude mcp add --transport http ookook http://127.0.0.1:\(port)/mcp"
    }

    /// A per-project endpoint, for an agent that should always mean one project.
    func connectCommand(for project: Project) -> String? {
        guard let port else { return nil }
        let slug = Self.slug(for: project)
        return "claude mcp add --transport http ookook-\(slug) http://127.0.0.1:\(port)/mcp/\(slug)"
    }

    /// Short, URL-safe, human-recognisable project handle.
    static func slug(for project: Project) -> String {
        let allowed = project.name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Request handling

    private func handle(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard request.method == "POST" else { return .empty(status: 405) }

        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .json(Self.error(id: nil, code: -32700, message: "Parse error"))
        }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        // /mcp/<slug> pins every call on this connection to one project.
        let pinnedSlug = Self.pinnedSlug(from: request.path)

        // Notifications carry no id and take no response body.
        guard let id else {
            return HTTPServer.Response(status: 202, contentType: "application/json", body: Data())
        }

        switch method {
        case "initialize":
            return .json(Self.result(id: id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "ookook", "version": "0.1.0"],
            ]))

        case "ping":
            return .json(Self.result(id: id, [:] as [String: Any]))

        case "tools/list":
            return .json(Self.result(id: id, ["tools": Self.toolDefinitions]))

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try callTool(named: name, arguments: arguments, pinnedSlug: pinnedSlug)
                return .json(Self.result(id: id, [
                    "content": [["type": "text", "text": text]],
                ]))
            } catch {
                // Tool failures are reported in-band so the agent can react,
                // rather than as protocol errors.
                return .json(Self.result(id: id, [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true,
                ]))
            }

        default:
            return .json(Self.error(id: id, code: -32601, message: "Unknown method: \(method)"))
        }
    }

    // MARK: - Tools

    /// Every tool takes an optional `project`; it is only required when several
    /// projects are open and the client did not connect to a pinned endpoint.
    private static let projectArgument: [String: Any] = [
        "type": "string",
        "description": "Which open project, by name or slug (see list_projects). Optional when only one project is open.",
    ]

    private static var toolDefinitions: [[String: Any]] {
        func named(_ name: String, _ description: String, extra: [String: Any] = [:]) -> [String: Any] {
            var properties: [String: Any] = [
                "name": ["type": "string", "description": "Process name as shown by list_processes."],
                "project": projectArgument,
            ]
            properties.merge(extra) { current, _ in current }
            return [
                "name": name,
                "description": description,
                "inputSchema": [
                    "type": "object",
                    "properties": properties,
                    "required": ["name"],
                ],
            ]
        }

        return [
            [
                "name": "list_projects",
                "description": "List every project currently open in Ookook, with how many of its processes are running. Call this first when you do not know which projects exist.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "list_processes",
                "description": "List the processes of a project with status, kind, command, port and memory use. Use this before assuming the state of the dev stack.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["project": projectArgument],
                ],
            ],
            named("get_process_output",
                  "Read the most recent output of one process. Use this to find out why something crashed or what a dev server is reporting, instead of guessing.",
                  extra: ["lines": ["type": "integer", "description": "How many trailing lines to return (default 100)."]]),
            named("start_process", "Start a stopped process."),
            named("stop_process", "Stop a running process."),
            named("restart_process",
                  "Restart a process - the usual way to pick up a config change or clear a wedged dev server."),
        ]
    }

    private static func pinnedSlug(from path: String) -> String? {
        // "/mcp/sitesoft" -> "sitesoft"; "/mcp" -> nil
        let parts = path.split(separator: "?")[0].split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "mcp" else { return nil }
        return parts[1]
    }

    /// Which project a tool call is about.
    ///
    /// An explicit argument wins, then the endpoint the client connected to,
    /// then - only when it is unambiguous - the single open project. With
    /// several projects open and no hint, the agent is told what to pick from
    /// rather than being silently pointed at the wrong stack.
    private func resolveProject(arguments: [String: Any],
                                pinnedSlug: String?,
                                in app: AppModel) throws -> Project {
        if let requested = arguments["project"] as? String, !requested.isEmpty {
            if let match = app.projects.first(where: { Self.slug(for: $0) == requested.lowercased() })
                ?? app.projects.first(where: { $0.name.lowercased() == requested.lowercased() })
                ?? app.projects.first(where: { $0.id == requested }) {
                return match
            }
            throw ToolError.message("No open project named \"\(requested)\". Open projects: \(Self.names(of: app))")
        }
        if let pinnedSlug,
           let match = app.projects.first(where: { Self.slug(for: $0) == pinnedSlug.lowercased() }) {
            return match
        }
        if app.projects.count == 1, let only = app.projects.first { return only }
        if app.projects.isEmpty { throw ToolError.message("No projects are open in Ookook.") }
        throw ToolError.message(
            "Several projects are open, so a `project` argument is required. Open projects: \(Self.names(of: app))")
    }

    private static func names(of app: AppModel) -> String {
        app.projects.map { "\($0.name) (\(slug(for: $0)))" }.joined(separator: ", ")
    }

    private func callTool(named name: String, arguments: [String: Any], pinnedSlug: String?) throws -> String {
        guard let app else { throw ToolError.message("Ookook is not ready.") }

        switch name {
        case "list_projects":
            guard !app.projects.isEmpty else { return "No projects are open in Ookook." }
            return app.projects.map { project in
                let running = project.controllers.filter { $0.status.isRunning }.count
                var row = "- \(project.name) (\(Self.slug(for: project))): \(running)/\(project.controllers.count) running"
                row += "\n    path: \(project.rootURL.path)"
                if let error = project.loadError { row += "\n    config error: \(error)" }
                return row
            }.joined(separator: "\n")

        case "list_processes":
            let workspace = try resolveProject(arguments: arguments, pinnedSlug: pinnedSlug, in: app)
            guard !workspace.controllers.isEmpty else { return "No processes are defined in ookook.yml." }
            let rows = workspace.controllers.map { controller -> String in
                var row = "- \(controller.spec.name) [\(controller.spec.kind.rawValue)]: \(controller.status.label)"
                if let port = controller.spec.port { row += " port=\(port)" }
                if let memory = app.resources.memoryByProcess[controller.ref.id], memory > 0 {
                    row += " memory=\(memory.formattedBytes)"
                }
                row += "\n    command: \(controller.spec.command)"
                if let activity = controller.activity, !activity.isEmpty {
                    row += "\n    last output: \(activity)"
                }
                return row
            }
            var header = "Project: \(workspace.name)"
            let projectMemory = workspace.controllers.reduce(UInt64(0)) { total, controller in
                total + (app.resources.memoryByProcess[controller.ref.id] ?? 0)
            }
            if projectMemory > 0 { header += " (total memory: \(projectMemory.formattedBytes))" }
            return header + "\n" + rows.joined(separator: "\n")

        case "get_process_output":
            let project = try resolveProject(arguments: arguments, pinnedSlug: pinnedSlug, in: app)
            let controller = try self.controller(named: arguments["name"], in: project)
            let lines = arguments["lines"] as? Int ?? 100
            let output = controller.log.tail(lines)
            guard !output.isEmpty else {
                return "\(controller.spec.name) has produced no output yet (status: \(controller.status.label))."
            }
            return "\(controller.spec.name) - last \(output.count) lines (status: \(controller.status.label)):\n"
                + output.joined(separator: "\n")

        case "start_process":
            let project = try resolveProject(arguments: arguments, pinnedSlug: pinnedSlug, in: app)
            let controller = try self.controller(named: arguments["name"], in: project)
            controller.start()
            return "Started \(controller.spec.name)."

        case "stop_process":
            let project = try resolveProject(arguments: arguments, pinnedSlug: pinnedSlug, in: app)
            let controller = try self.controller(named: arguments["name"], in: project)
            controller.stop()
            return "Stopped \(controller.spec.name)."

        case "restart_process":
            let project = try resolveProject(arguments: arguments, pinnedSlug: pinnedSlug, in: app)
            let controller = try self.controller(named: arguments["name"], in: project)
            controller.restart()
            return "Restarted \(controller.spec.name)."

        default:
            throw ToolError.message("Unknown tool: \(name)")
        }
    }

    private func controller(named name: Any?, in workspace: Project) throws -> ProcessController {
        guard let name = name as? String, !name.isEmpty else {
            throw ToolError.message("A `name` argument is required.")
        }
        // Exact match first, then case-insensitive, so agents are not tripped by casing.
        if let match = workspace.controller(named: name) { return match }
        let available = workspace.controllers.map(\.spec.name).joined(separator: ", ")
        throw ToolError.message("No process named \"\(name)\". Available: \(available)")
    }

    // MARK: - JSON-RPC envelopes

    private static func result(id: Any, _ value: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        var payload: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        payload["id"] = id ?? NSNull()
        return payload
    }

    enum ToolError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }
}
