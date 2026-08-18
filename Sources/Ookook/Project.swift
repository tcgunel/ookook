import Combine
import Foundation

/// One open project: its config, its processes, and their lifecycle.
///
/// Previously this was the whole app (`Workspace`); it becomes a member of
/// `AppModel` so several can be open at once.
@MainActor
final class Project: ObservableObject, Identifiable {
    /// Stable across launches - derived from the config's directory, so a
    /// reopened project keeps its persisted expansion and selection state.
    let id: String
    let configURL: URL

    @Published private(set) var config: ProjectConfig?
    @Published private(set) var controllers: [ProcessController] = []
    @Published private(set) var loadError: String?
    @Published var isExpanded = true

    var rootURL: URL { configURL.deletingLastPathComponent() }

    var name: String {
        config?.name ?? rootURL.lastPathComponent
    }

    init(configURL: URL) {
        self.configURL = configURL
        self.id = configURL.deletingLastPathComponent().standardizedFileURL.path
        load()
    }

    /// Reads the config and builds controllers. Existing processes are stopped
    /// first so a reload never leaks an orphaned child.
    func load() {
        stopAll()
        do {
            let config = try ProjectConfig.load(from: configURL)
            self.config = config
            self.loadError = nil
            self.controllers = config.processes.map { spec in
                ProcessController(spec: spec,
                                  projectID: id,
                                  workingDirectory: config.workingDirectory(for: spec))
            }
            for controller in controllers where controller.spec.startsAutomatically {
                controller.start()
            }
        } catch {
            self.config = nil
            self.controllers = []
            self.loadError = error.localizedDescription
        }
    }

    func startAll() { controllers.forEach { $0.start() } }
    func stopAll() { controllers.forEach { $0.stop() } }

    func controller(named name: String) -> ProcessController? {
        controllers.first { $0.spec.name == name }
            ?? controllers.first { $0.spec.name.lowercased() == name.lowercased() }
    }

    /// Controllers grouped by kind, skipping kinds this project does not use.
    var sections: [ProcessSection_Model] {
        ProcessKind.allCases.compactMap { kind in
            let members = controllers.filter { $0.spec.kind == kind }
            guard !members.isEmpty else { return nil }
            return ProcessSection_Model(kind: kind, controllers: members)
        }
    }

    /// Searches upward from `directory` for a config, the way git finds `.git`.
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
