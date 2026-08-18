import SwiftUI

struct ContentView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                if let selected = workspace.selected {
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
                Button { workspace.startAll() } label: {
                    Image(systemName: "play.circle")
                }
                .help("Start all")

                Button { workspace.stopAll() } label: {
                    Image(systemName: "stop.circle")
                }
                .help("Stop all")

                Button { workspace.reload() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Reload ookook.yml")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $workspace.selectedID) {
            ForEach(workspace.sections) { section in
                ProcessSection(section: section)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 230)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MCPStatusBar(mcp: workspace.mcp)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let error = workspace.loadError {
            ContentUnavailableMessage(
                title: "Couldn't load ookook.yml",
                message: error,
                systemImage: "exclamationmark.triangle")
        } else if let controller = workspace.selected {
            TerminalPane(controller: controller)
                .id(controller.id)
        } else {
            ContentUnavailableMessage(
                title: "No processes",
                message: "Add a `processes:` list to ookook.yml.",
                systemImage: "terminal")
        }
    }
}

/// One collapsible group of processes, titled by kind and counting how many of
/// its members are currently running.
private struct ProcessSection: View {
    let section: ProcessSection_Model
    @State private var expanded = true

    var body: some View {
        Section(isExpanded: $expanded) {
            ForEach(section.controllers) { controller in
                ProcessRow(controller: controller)
                    .tag(controller.id)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: section.kind.symbolName)
                    .font(.system(size: 9))
                Text(section.kind.sectionTitle)
                Spacer()
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(status: controller.status)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(controller.spec.name)
                        .lineLimit(1)
                    if let port = controller.spec.port {
                        Spacer(minLength: 4)
                        Text(String(port))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(controller.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(controller.subtitle)
            }
        }
        .padding(.vertical, 2)
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
