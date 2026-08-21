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

    /// Processes the user added from the UI; merged with whatever the config
    /// declares so a plain folder with no ookook.yml is still a usable project.
    private weak var localProcesses: LocalProcessStore?

    init(configURL: URL, localProcesses: LocalProcessStore? = nil) {
        self.configURL = configURL
        self.id = configURL.deletingLastPathComponent().standardizedFileURL.path
        self.localProcesses = localProcesses
        load()
    }

    /// Reads the config and builds controllers.
    ///
    /// A process whose spec is unchanged keeps its controller, and so keeps
    /// running: reloading is how you pick up an edit to `ookook.yml`, not a
    /// reason to kill the agent you have been talking to for an hour. Only
    /// processes that changed or disappeared are stopped.
    func load() {
        var config: ProjectConfig
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                config = try ProjectConfig.load(from: configURL)
                self.loadError = nil
            } catch {
                // A config that exists but does not parse is a real error worth
                // showing; a folder with no config at all is not.
                stopAll()
                self.config = nil
                self.controllers = []
                self.loadError = error.localizedDescription
                return
            }
        } else {
            config = ProjectConfig(name: rootURL.lastPathComponent, processes: [])
            config.rootURL = rootURL
            self.loadError = nil
        }

        self.config = config
        let specs = config.processes + (localProcesses?.specs(for: id) ?? [])
        let previous = controllers
        var kept: [ObjectIdentifier: Bool] = [:]
        var started: [ProcessController] = []
        self.controllers = specs.map { spec in
            let directory = config.workingDirectory(for: spec)
            if let existing = previous.first(where: {
                $0.spec == spec && $0.workingDirectory == directory
            }) {
                kept[ObjectIdentifier(existing)] = true
                return existing
            }
            let controller = ProcessController(spec: spec,
                                               projectID: id,
                                               workingDirectory: directory)
            started.append(controller)
            return controller
        }
        // Whatever the reload dropped or replaced has no tile any more, so it
        // would otherwise keep running with nowhere to see it.
        for controller in previous where kept[ObjectIdentifier(controller)] != true {
            controller.stop()
        }
        for controller in started where controller.spec.startsAutomatically {
            controller.start()
        }
    }

    /// Adds a process at runtime and starts it, without touching ookook.yml.
    func add(_ spec: ProcessSpec) {
        guard let store = localProcesses else { return }
        let added = store.add(spec, to: id, existing: controllers.map(\.spec.name))
        guard let config else { return }
        let controller = ProcessController(spec: added,
                                           projectID: id,
                                           workingDirectory: config.workingDirectory(for: added))
        controllers.append(controller)
        if added.startsAutomatically { controller.start() }
    }

    /// Removes a process the user added. Config-declared processes are left
    /// alone - those belong to ookook.yml, not to the UI.
    func removeLocal(process: String) {
        guard let store = localProcesses, store.isLocal(projectID: id, process: process) else { return }
        controllers.first { $0.spec.name == process }?.stop()
        controllers.removeAll { $0.spec.name == process }
        store.remove(process: process, from: id)
    }

    func isLocal(process: String) -> Bool {
        localProcesses?.isLocal(projectID: id, process: process) ?? false
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
