import Foundation

/// Exposes the running workspace to AI agents over MCP.
///
/// Transport is JSON-RPC over HTTP on loopback, so a client connects with
/// `claude mcp add --transport http ookook http://127.0.0.1:<port>/mcp` and
/// needs no helper binary - the app itself is the server.
@MainActor
final class MCPServer: ObservableObject {
    static let defaultPort: UInt16 = 4517

    private weak var workspace: Workspace?
    private var http: HTTPServer?

    @Published private(set) var port: UInt16?
    @Published private(set) var lastError: String?

    init(workspace: Workspace) {
        self.workspace = workspace
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

    // MARK: - Request handling

    private func handle(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard request.method == "POST" else { return .empty(status: 405) }

        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .json(Self.error(id: nil, code: -32700, message: "Parse error"))
        }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

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
                let text = try callTool(named: name, arguments: arguments)
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

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_processes",
            "description": "List every process in the current Ookook project with its status, kind, command and port. Use this first to see what is running before assuming the state of the dev stack.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "get_process_output",
            "description": "Read the most recent output of one process. Use this to check why something crashed or what a dev server is reporting, instead of guessing.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Process name as shown by list_processes."],
                    "lines": ["type": "integer", "description": "How many trailing lines to return (default 100)."],
                ],
                "required": ["name"],
            ],
        ],
        [
            "name": "start_process",
            "description": "Start a stopped process.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ],
        ],
        [
            "name": "stop_process",
            "description": "Stop a running process.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ],
        ],
        [
            "name": "restart_process",
            "description": "Restart a process - the usual way to pick up a config change or clear a wedged dev server.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ],
        ],
    ]

    private func callTool(named name: String, arguments: [String: Any]) throws -> String {
        guard let workspace else { throw ToolError.message("No project is loaded.") }

        switch name {
        case "list_processes":
            guard !workspace.controllers.isEmpty else { return "No processes are defined in ookook.yml." }
            let rows = workspace.controllers.map { controller -> String in
                var row = "- \(controller.spec.name) [\(controller.spec.kind.rawValue)]: \(controller.status.label)"
                if let port = controller.spec.port { row += " port=\(port)" }
                if let memory = workspace.resources.memoryByProcess[controller.id], memory > 0 {
                    row += " memory=\(memory.formattedBytes)"
                }
                row += "\n    command: \(controller.spec.command)"
                if let activity = controller.activity, !activity.isEmpty {
                    row += "\n    last output: \(activity)"
                }
                return row
            }
            var header = "Project: \(workspace.projectName)"
            if workspace.resources.totalMemory > 0 {
                header += " (total memory: \(workspace.resources.totalMemory.formattedBytes))"
            }
            return header + "\n" + rows.joined(separator: "\n")

        case "get_process_output":
            let controller = try self.controller(named: arguments["name"], in: workspace)
            let lines = arguments["lines"] as? Int ?? 100
            let output = controller.log.tail(lines)
            guard !output.isEmpty else {
                return "\(controller.spec.name) has produced no output yet (status: \(controller.status.label))."
            }
            return "\(controller.spec.name) - last \(output.count) lines (status: \(controller.status.label)):\n"
                + output.joined(separator: "\n")

        case "start_process":
            let controller = try self.controller(named: arguments["name"], in: workspace)
            controller.start()
            return "Started \(controller.spec.name)."

        case "stop_process":
            let controller = try self.controller(named: arguments["name"], in: workspace)
            controller.stop()
            return "Stopped \(controller.spec.name)."

        case "restart_process":
            let controller = try self.controller(named: arguments["name"], in: workspace)
            controller.restart()
            return "Restarted \(controller.spec.name)."

        default:
            throw ToolError.message("Unknown tool: \(name)")
        }
    }

    private func controller(named name: Any?, in workspace: Workspace) throws -> ProcessController {
        guard let name = name as? String, !name.isEmpty else {
            throw ToolError.message("A `name` argument is required.")
        }
        // Exact match first, then case-insensitive, so agents are not tripped by casing.
        if let match = workspace.controllers.first(where: { $0.spec.name == name }) { return match }
        if let match = workspace.controllers.first(where: { $0.spec.name.lowercased() == name.lowercased() }) {
            return match
        }
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
