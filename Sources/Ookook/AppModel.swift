import Combine
import Foundation

/// The app: every open project, the selection, and the services shared across
/// them (MCP, resource sampling).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selection: ProcessRef?

    let resources = ResourceMonitor()
    let agents = AgentMonitor()
    let git = GitMonitor()
    private(set) lazy var mcp: MCPServer = MCPServer(app: self)

    private var cancellables: [AnyCancellable] = []

    init() {
        agents.pidProvider = { [weak self] in
            self?.runningPIDs() ?? []
        }
        agents.onActivityChange = { [weak self] id, previous, current in
            self?.reportAgentTransition(id: id, from: previous, to: current)
        }
        resources.pidProvider = { [weak self] in
            guard let self else { return [] }
            return self.runningPIDs()
        }
    }

    /// Only two transitions are worth interrupting for: an agent that stopped
    /// working, and one that is now blocked on the user. Everything else is
    /// noise that would train you to ignore the alerts.
    private func reportAgentTransition(id: String,
                                       from previous: AgentSession.Activity,
                                       to current: AgentSession.Activity) {
        guard previous == .busy else { return }
        guard let (project, controller) = locate(refID: id) else { return }

        if current.needsAttention {
            Notifier.shared.agentNeedsAttention(process: controller.spec.name, project: project.name)
        } else if current == .idle {
            Notifier.shared.agentFinished(process: controller.spec.name, project: project.name)
        }
    }

    private func locate(refID: String) -> (Project, ProcessController)? {
        for project in projects {
            if let controller = project.controllers.first(where: { $0.ref.id == refID }) {
                return (project, controller)
            }
        }
        return nil
    }

    private func runningPIDs() -> [(id: String, pid: pid_t)] {
        projects.flatMap { project in
            project.controllers.compactMap { controller in
                controller.pid.map { (id: controller.ref.id, pid: $0) }
            }
        }
    }

    // MARK: - Projects

    var selectedController: ProcessController? {
        guard let selection else { return nil }
        return project(id: selection.project)?.controller(named: selection.process)
    }

    func project(id: String) -> Project? {
        projects.first { $0.id == id }
    }

    /// Opens a project, or focuses it if it is already open.
    @discardableResult
    func open(configURL: URL) -> Project {
        let id = configURL.deletingLastPathComponent().standardizedFileURL.path
        if let existing = project(id: id) {
            selection = existing.controllers.first.map(\.ref)
            return existing
        }
        let project = Project(configURL: configURL)
        projects.append(project)
        observe(project)
        if selection == nil {
            selection = project.controllers.first.map(\.ref)
        }
        persistOpenProjects()
        syncGitWatchList()
        return project
    }

    /// Resolves a directory or config file to a config path and opens it.
    @discardableResult
    func open(path url: URL) -> Project {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let configURL = isDirectory.boolValue
            ? (Project.findConfig(startingAt: url) ?? url.appendingPathComponent("ookook.yml"))
            : url
        return open(configURL: configURL)
    }

    func close(_ project: Project) {
        project.stopAll()
        projects.removeAll { $0.id == project.id }
        if selection?.project == project.id {
            selection = projects.first?.controllers.first.map(\.ref)
        }
        persistOpenProjects()
        syncGitWatchList()
    }

    func startAll() { projects.forEach { $0.startAll() } }
    func stopAll() { projects.forEach { $0.stopAll() } }

    func reloadAll() {
        projects.forEach { $0.load() }
        syncGitWatchList()
    }

    private func syncGitWatchList() {
        git.watch(projects.map { (id: $0.id, root: $0.rootURL) })
    }

    /// Child `ObservableObject`s do not propagate through `@Published` arrays,
    /// so republish their changes to keep the sidebar live.
    private func observe(_ project: Project) {
        project.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Session persistence

    private static let openProjectsKey = "openProjects"

    private func persistOpenProjects() {
        let paths = projects.map(\.configURL.path)
        UserDefaults.standard.set(paths, forKey: Self.openProjectsKey)
    }

    /// Reopens whatever was open last time. Paths that have since disappeared
    /// are dropped silently rather than surfacing as errors on launch.
    func restoreOpenProjects() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.openProjectsKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            open(configURL: URL(fileURLWithPath: path))
        }
    }

    func startServices() {
        mcp.start()
        resources.start()
        agents.start()
        syncGitWatchList()
        git.start()
    }

    func stopServices() {
        git.stop()
        agents.stop()
        resources.stop()
        mcp.stop()
    }
}
