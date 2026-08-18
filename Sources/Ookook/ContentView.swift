import SwiftUI

struct ContentView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle(workspace.projectName)
        .toolbar {
            ToolbarItemGroup {
                if let selected = workspace.selected {
                    Button {
                        selected.status.isRunning ? selected.stop() : selected.start()
                    } label: {
                        Image(systemName: selected.status.isRunning ? "stop.fill" : "play.fill")
                    }
                    .help(selected.status.isRunning ? "Stop" : "Start")

                    Button { selected.restart() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Restart")
                }
                Button { workspace.reload() } label: {
                    Image(systemName: "doc.badge.gearshape")
                }
                .help("Reload ookook.yml")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $workspace.selectedID) {
            Section("Processes") {
                ForEach(workspace.controllers) { controller in
                    ProcessRow(controller: controller)
                        .tag(controller.id)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
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

private struct ProcessRow: View {
    @ObservedObject var controller: ProcessController

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: controller.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.spec.name)
                Text(controller.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
