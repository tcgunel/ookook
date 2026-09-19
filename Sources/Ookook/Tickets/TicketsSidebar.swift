import SwiftUI
import AppKit

/// The "Tickets" group under a project in the sidebar: Triage / Todo / In
/// Progress with approve, close and open actions, plus the worker's status.
struct TicketsSidebarSection: View {
    @ObservedObject var worker: TicketsWorker
    let projectID: String
    let projectName: String
    let onOpenSettings: () -> Void
    @State private var expanded = true
    @State private var showColumn: Set<String> = ["triage", "todo", "in-progress"]

    private var status: TicketsProjectStatus { worker.status[projectID] ?? TicketsProjectStatus() }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            column("Triage", key: "triage", icon: "tray.full", accent: .yellow)
            column("Todo", key: "todo", icon: "circle", accent: .green)
            column("In Progress", key: "in-progress", icon: "circle.lefthalf.filled", accent: .blue)
            if let error = status.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 11))
                Text("Tickets").font(.system(size: 11, weight: .semibold))
                if status.isBusy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 4)
                let triage = status.issues(in: "triage").count
                if triage > 0 {
                    Text("\(triage)")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.yellow.opacity(0.35)))
                        .help("\(triage) waiting for your approval")
                }
                Circle()
                    .fill(status.isRunning ? (status.lastError == nil ? Color.green : .orange) : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .help(statusHelp)
            }
            .contextMenu {
                Button("Refresh") { Task { await worker.refreshIssues(projectID) } }
                Button("Classify Pending Now") { Task { await worker.runNow(projectID) } }
                Divider()
                Button("Ticket Settings…") { onOpenSettings() }
            }
        }
    }

    private var statusHelp: String {
        var parts: [String] = [status.isRunning ? "Pipeline running" : "Pipeline off"]
        if let poll = status.lastPoll { parts.append("polled " + poll.formatted(date: .omitted, time: .shortened)) }
        if let batch = status.lastBatch { parts.append("last batch " + batch.formatted(date: .omitted, time: .shortened)) }
        parts.append(status.usage.summary)
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private func column(_ title: String, key: String, icon: String, accent: Color) -> some View {
        let issues = status.issues(in: key)
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(accent)
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(issues.count)").font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button {
                if showColumn.contains(key) { showColumn.remove(key) } else { showColumn.insert(key) }
            } label: {
                Image(systemName: showColumn.contains(key) ? "chevron.down" : "chevron.right").font(.system(size: 8))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
        if showColumn.contains(key) {
            if issues.isEmpty {
                Text("none").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 14)
            }
            ForEach(issues.prefix(12)) { issue in
                TicketRow(issue: issue, column: key, worker: worker, projectID: projectID)
            }
            if issues.count > 12 {
                Text("+\(issues.count - 12) more on GitHub").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 14)
            }
        }
    }
}

private struct TicketRow: View {
    let issue: TicketIssue
    let column: String
    @ObservedObject var worker: TicketsWorker
    let projectID: String
    @State private var hovering = false

    private var typeColor: Color {
        switch issue.type {
        case "bug": return .red
        case "feature": return .cyan
        case "xml": return .indigo
        case "integration": return .mint
        case "ops": return .orange
        case "question": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(typeColor)
                .frame(width: 3, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if issue.isHighPriority {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.red)
                    }
                    Text(issue.shortTitle).font(.system(size: 11)).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(issue.shop ?? "shop?").font(.system(size: 9)).foregroundStyle(issue.shop == nil ? .orange : .secondary)
                    Text("·").foregroundStyle(.tertiary).font(.system(size: 9))
                    Text(issue.type ?? "?").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary).font(.system(size: 9))
                    Text("#\(issue.number)").font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
                    if issue.labels.contains("requested-again") {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 8)).foregroundStyle(.orange)
                            .help("Requested again in chat")
                    }
                    if issue.labels.contains("resolved-in-chat") {
                        Image(systemName: "checkmark.bubble").font(.system(size: 8)).foregroundStyle(.purple)
                            .help("Chat suggests this is resolved")
                    }
                    if issue.comments > 0 {
                        Text("\(issue.comments)").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Image(systemName: "bubble.left").font(.system(size: 7)).foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 2)
            if hovering {
                if column == "triage" {
                    actionButton("checkmark", help: "Approve: move to todo") { Task { await worker.move(issue, to: "todo", projectID: projectID) } }
                }
                if column == "todo" {
                    actionButton("arrow.uturn.left", help: "Back to triage") { Task { await worker.move(issue, to: "triage", projectID: projectID) } }
                }
                if column == "in-progress" {
                    actionButton("arrow.uturn.left", help: "Back to todo") { Task { await worker.move(issue, to: "todo", projectID: projectID) } }
                }
                actionButton("xmark", help: "Close issue") { Task { await worker.close(issue, projectID: projectID) } }
            }
        }
        .padding(.leading, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { open() }
        .help(issue.title)
        .contextMenu {
            Button("Open on GitHub") { open() }
            Button("Copy Reference") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.ref, forType: .string)
            }
            Divider()
            if column != "todo" { Button("Move to Todo") { Task { await worker.move(issue, to: "todo", projectID: projectID) } } }
            if column != "triage" { Button("Move to Triage") { Task { await worker.move(issue, to: "triage", projectID: projectID) } } }
            if column != "in-progress" { Button("Move to In Progress") { Task { await worker.move(issue, to: "in-progress", projectID: projectID) } } }
            Divider()
            Button("Close Issue", role: .destructive) { Task { await worker.close(issue, projectID: projectID) } }
        }
    }

    private func open() {
        if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
