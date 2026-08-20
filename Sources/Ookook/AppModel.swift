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
    let layout = SidebarLayoutStore()
    let localProcesses = LocalProcessStore()
    let ssh = SSHConnectionStore()
    let claudeSessions = ClaudeSessionStore()
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
        // `visibleControllers` reads the layout store, but views observe the
        // AppModel - without forwarding, hiding a process repainted the
        // sidebar and left the grid showing the tile it just hid.
        layout.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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

    /// Everything the grid should draw: hidden processes keep running and stay
    /// in the sidebar, they just stop taking up a tile.
    /// Grid order, and the order the sidebar shows. Reading it through the
    /// layout store is what makes a sidebar drag reorder the grid too - before,
    /// the grid used the raw `ookook.yml` order and ignored every arrangement
    /// the user made.
    var visibleControllers: [ProcessController] {
        projects.flatMap { project in
            layout.sections(projectID: project.id, controllers: project.controllers)
                .flatMap(\.controllers)
                .filter { !layout.isHidden(projectID: project.id, process: $0.spec.name) }
        }
    }

    /// Reorders whole projects. A grid mixes tiles from every open project, so
    /// a drag between two of them cannot mean "reorder within a project" -
    /// there is no shared list to reorder. Moving the source project's block to
    /// the target's position is the only reading that leaves the tiles where
    /// the user dropped them.
    func moveProject(_ id: String, before targetID: String) {
        guard id != targetID,
              let from = projects.firstIndex(where: { $0.id == id }),
              let target = projects.firstIndex(where: { $0.id == targetID }) else { return }
        let project = projects.remove(at: from)
        let insertion = projects.firstIndex(where: { $0.id == targetID }) ?? target
        projects.insert(project, at: insertion)
        persistOpenProjects()
    }

    /// Only processes added from the UI can be removed; the rest belong to an
    /// ookook.yml and would come straight back on the next reload.
    func isLocal(_ ref: ProcessRef) -> Bool {
        project(id: ref.project)?.isLocal(process: ref.process) ?? false
    }

    func removeLocal(_ ref: ProcessRef) {
        project(id: ref.project)?.removeLocal(process: ref.process)
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
        let project = Project(configURL: configURL, localProcesses: localProcesses)
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
        // A folder with no ookook.yml still opens: it becomes an empty project
        // the user can add agents and terminals to.
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
        claudeSessions.refresh(projects: projects.map { (id: $0.id, root: $0.rootURL) })
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
        for path in paths {
            // A project without an ookook.yml is legitimate - the config path is
            // still where one would go, so what has to still exist is the
            // project directory, not the file.
            let configURL = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            let root = configURL.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            open(configURL: configURL)
        }
    }

    func startServices() {
        mcp.start()
        resources.start()
        agents.start()
        syncGitWatchList()
        git.start()
        startScrollbackSnapshots()
        startSessionRefresh()
    }

    /// A SIGTERM - which is what `pkill`, a crash, or a forced logout sends -
    /// never runs `applicationWillTerminate`, so relying on quit alone loses
    /// everything. Snapshotting on a slow timer bounds that loss to one period.
    private var scrollbackTimer: Timer?

    /// Transcripts change as agents work, so the Resume menu is rescanned on a
    /// slow timer. Slow because it only ever matters when a menu is opened.
    private var sessionTimer: Timer?

    private func startSessionRefresh(interval: TimeInterval = 60) {
        sessionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.claudeSessions.refresh(projects: self.projects.map { (id: $0.id, root: $0.rootURL) })
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionTimer = timer
    }

    private func startScrollbackSnapshots(interval: TimeInterval = 30) {
        scrollbackTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.persistScrollback() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollbackTimer = timer
    }

    /// Called on quit, on a timer, and when a process stops.
    func persistScrollback() {
        projects.flatMap(\.controllers).forEach { $0.persistScrollback() }
    }

    func stopServices() {
        scrollbackTimer?.invalidate()
        scrollbackTimer = nil
        sessionTimer?.invalidate()
        sessionTimer = nil
        git.stop()
        agents.stop()
        resources.stop()
        mcp.stop()
    }
}
