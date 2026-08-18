import SwiftUI

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
                               resources: app.resources,
                               agents: app.agents,
                               onClose: { app.close(project) })
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 250)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MCPStatusBar(mcp: app.mcp, resources: app.resources)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if app.projects.isEmpty {
            ContentUnavailableMessage(
                title: "No project open",
                message: "Open a project folder with ⌘O. Ookook looks for an ookook.yml inside it.",
                systemImage: "folder.badge.plus")
        } else if mode == .grid {
            GridView(controllers: app.projects.flatMap(\.controllers),
                     projectNames: Dictionary(uniqueKeysWithValues: app.projects.map { ($0.id, $0.name) }),
                     selection: $app.selection,
                     onFocus: { ref in
                         app.selection = ref
                         mode = .single
                     },
                     columnCount: gridColumns)
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
    @ObservedObject var resources: ResourceMonitor
    @ObservedObject var agents: AgentMonitor
    let onClose: () -> Void

    var body: some View {
        Section(isExpanded: $project.isExpanded) {
            if let error = project.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            ForEach(project.sections) { section in
                KindGroup(section: section, resources: resources, agents: agents)
            }
        } header: {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(project.controllers.filter(\.status.isRunning).count)/\(project.controllers.count)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .help(project.rootURL.path)
            .contextMenu {
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

/// One kind of process (agents / commands / terminals) inside a project.
private struct KindGroup: View {
    let section: ProcessSection_Model
    @ObservedObject var resources: ResourceMonitor
    @ObservedObject var agents: AgentMonitor
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(section.controllers) { controller in
                ProcessRow(controller: controller,
                           memory: resources.memoryByProcess[controller.ref.id],
                           session: agents.sessions[controller.ref.id])
                    .tag(controller.ref)

                // Sub-agents run inside the agent process rather than as
                // children of it, so they are listed under it but are not
                // themselves selectable processes.
                ForEach(agents.sessions[controller.ref.id]?.subagents ?? []) { subagent in
                    SubagentRow(subagent: subagent)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: section.kind.symbolName)
                    .font(.system(size: 9))
                Text(section.kind.sectionTitle)
                Spacer(minLength: 4)
                Text("\(section.runningCount)/\(section.controllers.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .semibold))
        }
    }
}

private struct ProcessRow: View {
    @ObservedObject var controller: ProcessController
    let memory: UInt64?
    let session: AgentSession?

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
                    Text(controller.spec.name)
                        .lineLimit(1)
                    // An agent blocked on you is the one thing worth
                    // interrupting for, so it gets the only coloured glyph.
                    if session?.activity.needsAttention == true {
                        AttentionBell()
                    }
                    Spacer(minLength: 4)
                    if let port = controller.spec.port {
                        Text(String(port))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
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
        .contextMenu {
            Button(controller.status.isRunning ? "Stop" : "Start") {
                controller.status.isRunning ? controller.stop() : controller.start()
            }
            Button("Restart") { controller.restart() }
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
