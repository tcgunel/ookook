import AppKit
import SwiftUI

/// Sidebar footer showing whether agents can reach this workspace, and the exact
/// command to connect one. Discoverability matters more than chrome here - the
/// MCP link is the reason to use Ookook over a pile of tabs.
struct MCPStatusBar: View {
    @ObservedObject var mcp: MCPServer
    @ObservedObject var resources: ResourceMonitor
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(mcp.port == nil ? Color.secondary : Color.green)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if resources.totalCPU >= 1 {
                    Text(resources.totalCPU.formattedCPU)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Total CPU used by all running processes, as a percentage of one core")
                }
                if resources.totalMemory > 0 {
                    Text(resources.totalMemory.formattedBytes)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Total memory used by all running processes")
                }
                if mcp.claudeConnectCommand != nil {
                    Menu {
                        Button("Copy Claude Code command") { copy(mcp.claudeConnectCommand) }
                        Button("Copy Codex command") { copy(mcp.codexConnectCommand) }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .menuStyle(.borderlessButton)
                    .help("Copy an MCP connection command")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .padding(.top, 2)
        }
    }

    private var statusText: String {
        if let error = mcp.lastError { return "MCP failed: \(error)" }
        if let port = mcp.port { return "MCP on :\(port)" }
        return "MCP off"
    }

    private func copy(_ command: String?) {
        guard let command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
