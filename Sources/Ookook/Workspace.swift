import Combine
import Foundation

/// The loaded project: its config and one controller per declared process.
@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var config: ProjectConfig?
    @Published private(set) var controllers: [ProcessController] = []
    @Published var selectedID: String?
    @Published var loadError: String?
    /// Serves this workspace to AI agents; created once and kept for the app's life.
    private(set) lazy var mcp: MCPServer = MCPServer(workspace: self)
    let resources = ResourceMonitor()

    private(set) var configURL: URL?

    var projectName: String {
        config?.name ?? configURL?.deletingLastPathComponent().lastPathComponent ?? "Ookook"
    }

    var selected: ProcessController? {
        controllers.first { $0.id == selectedID }
    }

    /// Controllers grouped for the sidebar, in a stable kind order, skipping
    /// kinds the project does not use.
    var sections: [ProcessSection_Model] {
        ProcessKind.allCases.compactMap { kind in
            let members = controllers.filter { $0.spec.kind == kind }
            guard !members.isEmpty else { return nil }
            return ProcessSection_Model(kind: kind, controllers: members)
        }
    }

    /// Loads `ookook.yml` and builds controllers. Existing processes are stopped
    /// first so a reload never leaks an orphaned child.
    func load(configURL url: URL) {
        stopAll()
        do {
            let config = try ProjectConfig.load(from: url)
            self.config = config
            self.configURL = url
            self.loadError = nil
            self.controllers = config.processes.map { spec in
                ProcessController(spec: spec, workingDirectory: config.workingDirectory(for: spec))
            }
            self.selectedID = controllers.first?.id
            for controller in controllers where controller.spec.startsAutomatically {
                controller.start()
            }
        } catch {
            self.config = nil
            self.controllers = []
            self.selectedID = nil
            self.loadError = error.localizedDescription
        }
    }

    func reload() {
        guard let configURL else { return }
        load(configURL: configURL)
    }

    func startAll() { controllers.forEach { $0.start() } }
    func stopAll() { controllers.forEach { $0.stop() } }

    /// Searches upward from `directory` for an `ookook.yml`, the way git finds `.git`.
    /// Wires resource sampling to whatever is currently running.
    func startMonitoring() {
        resources.pidProvider = { [weak self] in
            guard let self else { return [] }
            return self.controllers.compactMap { controller in
                controller.pid.map { (id: controller.id, pid: $0) }
            }
        }
        resources.start()
    }

    nonisolated static func findConfig(startingAt directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while true {
            for name in ["ookook.yml", "ookook.yaml"] {
                let candidate = current.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { return nil }
            current = parent
        }
    }
}
