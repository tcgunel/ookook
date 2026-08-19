import SwiftUI
import AppKit

/// Single pane keeps one big terminal in focus; grid watches everything at once.
enum ViewMode: String {
    case single
    case grid
}

struct ContentView: View {
    @ObservedObject var app: AppModel
    /// Remembered across launches - which layout you work in is a lasting preference.
    @AppStorage("viewMode") private var storedMode: String = ViewMode.single.rawValue
    /// 0 = fit as many columns as the window allows.
    @AppStorage("gridColumns") private var gridColumns: Int = 0
    /// Grid row height, set by dragging a tile's bottom edge.
    @AppStorage("gridTileHeight") private var gridTileHeight: Double = 300

    private var mode: ViewMode {
        get { ViewMode(rawValue: storedMode) ?? .single }
        nonmutating set { storedMode = newValue.rawValue }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: Binding(get: { mode }, set: { mode = $0 })) {
                    Image(systemName: "rectangle").tag(ViewMode.single)
                    Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .help("Single pane or grid of every process")

                if mode == .grid {
                    Picker("Columns", selection: $gridColumns) {
                        Text("Auto").tag(0)
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                        Text("4").tag(4)
                        Text("5").tag(5)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                    .help("How many tiles per row")
                }

                Divider()

                if let selected = app.selectedController {
                    Button {
                        selected.status.isRunning ? selected.stop() : selected.start()
                    } label: {
                        Image(systemName: selected.status.isRunning ? "stop.fill" : "play.fill")
                    }
                    .help(selected.status.isRunning ? "Stop \(selected.spec.name)" : "Start \(selected.spec.name)")

                    Button { selected.restart() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Restart \(selected.spec.name)")

                    Divider()
                }

                Button { app.startAll() } label: { Image(systemName: "play.circle") }
                    .help("Start everything, in every project")
                Button { app.stopAll() } label: { Image(systemName: "stop.circle") }
                    .help("Stop everything, in every project")
                Button { app.reloadAll() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .help("Reload every ookook.yml")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $app.selection) {
            ForEach(app.projects) { project in
                ProjectSection(project: project,
                               ssh: app.ssh,
                               resources: app.resources,
                               agents: app.agents,
                               git: app.git,
                               layout: app.layout,
                               onClose: { app.close(project) })
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 250)
        // Right-clicking the empty part of the sidebar is where people reach
        // for "add a folder", so put it there as well as in the menu bar.
        .contextMenu {
            Button("Add Project Folder…") { addProject() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    addProject()
                } label: {
                    Label("Add Project Folder…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .help("Open a folder as a project (⌘O)")

                MCPStatusBar(mcp: app.mcp, resources: app.resources)
            }
        }
    }

    /// Same panel the File menu uses - a folder with no ookook.yml is fine,
    /// you add terminals to it by right-clicking the project afterwards.
    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a project folder or an ookook.yml file."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = app.open(path: url) }
    }

    @ViewBuilder
    private var detail: some View {
        if app.projects.isEmpty {
            ContentUnavailableMessage(
                title: "No project open",
                message: "Right-click the sidebar, or press ⌘O, to add a project folder. An ookook.yml is optional - without one you add terminals by right-clicking the project.",
                systemImage: "folder.badge.plus")
        } else if mode == .grid {
            GridView(controllers: app.visibleControllers,
                     projectNames: Dictionary(uniqueKeysWithValues: app.projects.map { ($0.id, $0.name) }),
                     selection: $app.selection,
                     onFocus: { ref in
                         app.selection = ref
                         mode = .single
                     },
                     columnCount: gridColumns,
                     tileHeight: $gridTileHeight,
                     layout: app.layout,
                     controllersByProject: Dictionary(uniqueKeysWithValues: app.projects.map { ($0.id, $0.controllers) }),
                     onMoveProject: { app.moveProject($0, before: $1) },
                     canRemove: { app.isLocal($0) },
                     onRemove: { app.removeLocal($0) })
        } else if let controller = app.selectedController {
            TerminalPane(controller: controller)
                .id(controller.ref.id)
        } else if let error = app.projects.compactMap(\.loadError).first {
            ContentUnavailableMessage(
                title: "Couldn't load ookook.yml",
                message: error,
                systemImage: "exclamationmark.triangle")
        } else {
            ContentUnavailableMessage(
                title: "No processes",
                message: "Add a `processes:` list to ookook.yml.",
                systemImage: "terminal")
        }
    }
}

/// A project and everything under it. Collapsing one is how you get a dozen
/// projects into a sidebar without scrolling forever.
private struct ProjectSection: View {
    @ObservedObject var project: Project
    @ObservedObject var ssh: SSHConnectionStore
    @ObservedObject var resources: ResourceMonitor
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var git: GitMonitor
    @ObservedObject var layout: SidebarLayoutStore
    let onClose: () -> Void

    /// What the rename sheet is currently editing.
    @State private var renaming: RenameTarget?

    private func openSSHSettings() {
        SettingsWindowController.shared.show(projectRoot: project.rootURL,
                                             ssh: ssh,
                                             projects: [(id: project.id, name: project.name)])
    }
    @State private var addingCommand = false

    var body: some View {
        Section(isExpanded: $project.isExpanded) {
            if let error = project.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if project.loadError == nil && project.controllers.isEmpty {
                Button("Add Claude Code here") { project.add(.claudeAgent()) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(layout.sections(projectID: project.id, controllers: project.controllers)) { section in
                SidebarGroupView(project: project,
                                 section: section,
                                 resources: resources,
                                 agents: agents,
                                 layout: layout,
                                 onRename: { renaming = $0 })
            }
        } header: {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                if let state = git.states[project.id] {
                    GitBadge(state: state)
                }
                Spacer(minLength: 4)
                Text("\(project.controllers.filter(\.status.isRunning).count)/\(project.controllers.count)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .help(project.rootURL.path)
            .sheet(isPresented: $addingCommand) {
                NewCommandSheet { name, command in
                    project.add(.command(named: name, command: command))
                }
            }
            .sheet(item: $renaming) { target in
                RenameSheet(target: target) { newName in
                    switch target {
                    case .process(let projectID, let process, _):
                        layout.rename(projectID: projectID, process: process, to: newName)
                    case .group(let projectID, let id, _):
                        layout.renameGroup(projectID: projectID, id: id, to: newName)
                    }
                }
            }
            .contextMenu {
                Button("Add Claude Code") { project.add(.claudeAgent()) }
                Button("Add Terminal") { project.add(.shell()) }
                Button("Add Command…") { addingCommand = true }
                Menu("New SSH Session") {
                    let available = ssh.connections(for: project.id).filter(\.isUsable)
                    if available.isEmpty {
                        Button("No connections saved") {}
                            .disabled(true)
                    } else {
                        ForEach(available) { connection in
                            Button(connection.displayName) { project.add(.ssh(connection)) }
                        }
                    }
                    Divider()
                    Button("Manage Connections…") { openSSHSettings() }
                }
                Divider()
                Button("New Group…") {
                    let id = layout.createGroup(projectID: project.id,
                                                named: "New Group",
                                                controllers: project.controllers)
                    renaming = .group(project: project.id, id: id, current: "New Group")
                }
                Button("Reset Sidebar Layout") { layout.resetLayout(projectID: project.id) }
                Divider()
                Button("Reload Config") { project.load() }
                Button("Start All in \(project.name)") { project.startAll() }
                Button("Stop All in \(project.name)") { project.stopAll() }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                }
                Button("Close Project") { onClose() }
            }
        }
    }
}

/// One sidebar group: a user-defined group when the project has a custom
/// layout, otherwise one of the agent/command/terminal kinds.
private struct SidebarGroupView: View {
    @ObservedObject var project: Project
    let section: SidebarSection
    @ObservedObject var resources: ResourceMonitor
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var layout: SidebarLayoutStore
    let onRename: (RenameTarget) -> Void

    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(section.controllers) { controller in
                ProcessRow(controller: controller,
                           label: layout.displayName(projectID: project.id,
                                                     process: controller.spec.name),
                           memory: resources.memoryByProcess[controller.ref.id],
                           cpu: resources.cpuByProcess[controller.ref.id],
                           session: agents.sessions[controller.ref.id],
                           onRename: {
                               onRename(.process(project: project.id,
                                                 process: controller.spec.name,
                                                 current: layout.displayName(projectID: project.id,
                                                                             process: controller.spec.name)))
                           },
                           onResetName: layout.hasCustomName(projectID: project.id,
                                                             process: controller.spec.name)
                               ? { layout.rename(projectID: project.id,
                                                 process: controller.spec.name,
                                                 to: "") }
                               : nil,
                           onRemove: project.isLocal(process: controller.spec.name)
                               ? { project.removeLocal(process: controller.spec.name) }
                               : nil,
                           isHidden: layout.isHidden(projectID: project.id,
                                                     process: controller.spec.name),
                           onToggleHidden: {
                               layout.setHidden(!layout.isHidden(projectID: project.id,
                                                                 process: controller.spec.name),
                                                projectID: project.id,
                                                process: controller.spec.name)
                           })
                    .tag(controller.ref)
                    .processDraggable(controller.ref)
                    .processDropTarget(before: controller.ref,
                                       in: section.groupID,
                                       projectID: project.id) { ref, placement in
                        drop(ref, placement)
                    }
            }
        } label: {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: section.symbolName)
                .font(.system(size: 9))
            Text(section.title)
            Spacer(minLength: 4)
            Text("\(section.runningCount)/\(section.controllers.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10, weight: .semibold))
        .contentShape(Rectangle())
        .modifier(GroupDropTarget(groupID: section.groupID, projectID: project.id, drop: drop))
        .contextMenu {
            if let groupID = section.groupID {
                Button("Rename Group…") {
                    onRename(.group(project: project.id, id: groupID, current: section.title.capitalized))
                }
                Button("Delete Group") {
                    layout.deleteGroup(projectID: project.id, id: groupID)
                }
            } else {
                // Kind sections are derived, not stored; there is nothing to
                // rename until the project has a layout of its own.
                Button("Customise Groups") {
                    layout.adoptKindLayout(projectID: project.id, controllers: project.controllers)
                }
            }
        }
    }

    private func drop(_ ref: ProcessRef, _ placement: DropPlacement) {
        // The first drag converts the derived kind grouping into a real layout,
        // so the user starts from what they were already looking at.
        layout.adoptKindLayout(projectID: project.id, controllers: project.controllers)
        let groups = layout.layout(for: project.id).groups
        switch placement {
        case .before(let target):
            let groupID = section.groupID
                ?? groups.first(where: { $0.members.contains(target.process) })?.id
            layout.move(ref, toGroup: groupID, before: target,
                        in: project.id, controllers: project.controllers)
        case .intoGroup(let groupID):
            layout.move(ref, toGroup: groupID, before: nil,
                        in: project.id, controllers: project.controllers)
        }
    }
}

/// Only a real group can be an append target; a derived kind section has no id
/// to append into until the layout is adopted.
private struct GroupDropTarget: ViewModifier {
    let groupID: UUID?
    let projectID: String
    let drop: (ProcessRef, DropPlacement) -> Void

    func body(content: Content) -> some View {
        if let groupID {
            content.processDropTarget(intoGroup: groupID, projectID: projectID, perform: drop)
        } else {
            content
        }
    }
}

private struct ProcessRow: View {
    @ObservedObject var controller: ProcessController
    let label: String
    let memory: UInt64?
    let cpu: Double?
    let session: AgentSession?
    let onRename: () -> Void
    /// Present only when the row is showing a user-given name.
    let onResetName: (() -> Void)?
    /// Present only for processes added from the UI; config-declared ones
    /// belong to ookook.yml and cannot be deleted from here.
    let onRemove: (() -> Void)?
    let isHidden: Bool
    let onToggleHidden: () -> Void

    /// An agent's own state beats the last line it printed - "Waiting for you"
    /// is more useful than whatever it last rendered to the terminal.
    private var subtitle: String {
        if let session, session.activity != .unknown, controller.status.isRunning {
            return session.activity.label
        }
        return controller.subtitle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(status: controller.status)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label)
                        .lineLimit(1)
                    // An agent blocked on you is the one thing worth
                    // interrupting for, so it gets the only coloured glyph.
                    if session?.activity.needsAttention == true {
                        AttentionBell()
                    }
                    if isHidden {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .help("Hidden from the grid; still running")
                    }
                    Spacer(minLength: 4)
                    if let port = controller.spec.port {
                        Text(String(port))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    // Only worth the width when it is actually doing something;
                    // a column of "0%" on idle agents is noise.
                    if let cpu, cpu >= 1 {
                        Text(cpu.formattedCPU)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(cpu >= 90 ? .orange : .secondary)
                            .help("CPU, as a percentage of one core")
                    }
                    if let memory, memory > 0 {
                        Text(memory.formattedBytes)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(controller.subtitle)

                if let session, let fraction = session.contextFraction,
                   let summary = session.contextSummary {
                    ContextGauge(fraction: fraction, summary: summary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isHidden ? 0.55 : 1)
        .contextMenu {
            ProcessActionItems(controller: controller,
                               isHidden: isHidden,
                               onToggleHidden: onToggleHidden,
                               onRename: onRename,
                               onResetName: onResetName,
                               onRemove: onRemove)
        }
    }
}

/// A pulsing bell for an agent that is blocked on you. It animates rather than
/// sitting still because the whole point is to catch your eye in a sidebar you
/// are not currently looking at.
private struct AttentionBell: View {
    @State private var pulsing = false

    var body: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 8))
            .foregroundStyle(.orange)
            .opacity(pulsing ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .onDisappear { pulsing = false }
            .help("This agent is waiting for you")
    }
}

private struct SubagentRow: View {
    let subagent: AgentSession.Subagent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
            Circle()
                .fill(subagent.isActive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(subagent.title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let tokens = subagent.contextTokens {
                    Text(detail(tokens: tokens))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.vertical, 1)
        .help(subagent.title)
    }

    private func detail(tokens: Int) -> String {
        var parts = ["\(AgentSession.compactTokens(tokens)) ctx"]
        if let workflow = subagent.workflow { parts.append(workflow) }
        return parts.joined(separator: " · ")
    }
}

/// What a rename sheet is editing. Renaming a process only sets a label: the
/// name in `ookook.yml` stays the identity, so a rename cannot break the MCP
/// tools, the layout, or a teammate's checkout.
enum RenameTarget: Identifiable {
    case process(project: String, process: String, current: String)
    case group(project: String, id: UUID, current: String)

    var id: String {
        switch self {
        case .process(let project, let process, _): return "p\u{1F}\(project)\u{1F}\(process)"
        case .group(_, let id, _): return "g\u{1F}\(id.uuidString)"
        }
    }

    var current: String {
        switch self {
        case .process(_, _, let current), .group(_, _, let current): return current
        }
    }

    var title: String {
        switch self {
        case .process: return "Rename Process"
        case .group: return "Rename Group"
        }
    }

    var footnote: String? {
        switch self {
        case .process: return "Only changes the label here. The name in ookook.yml is unchanged."
        case .group: return nil
        }
    }
}

/// Adding an arbitrary command needs two fields; agents and shells are
/// one-click because their command is always the same.
private struct NewCommandSheet: View {
    let onCommit: (String, String) -> Void

    @State private var name = ""
    @State private var command = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Command").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Command", text: $command)
                .textFieldStyle(.roundedBorder)
            Text("Runs in the project folder, through your login shell.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onCommit(name.isEmpty ? "command" : name, command)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Shared by the sidebar and the grid, so a rename works the same in both.
struct RenameSheet: View {
    let target: RenameTarget
    let onCommit: (String) -> Void

    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(target: RenameTarget, onCommit: @escaping (String) -> Void) {
        self.target = target
        self.onCommit = onCommit
        _name = State(initialValue: target.current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(commit)
            if let footnote = target.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func commit() {
        onCommit(name)
        dismiss()
    }
}

/// Small stand-in for `ContentUnavailableView`, which needs macOS 14.
private struct ContentUnavailableMessage: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
