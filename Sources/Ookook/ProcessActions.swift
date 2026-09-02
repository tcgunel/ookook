import SwiftUI

/// The actions that apply to one process, in one place.
///
/// The sidebar row and the grid tile both offer them, and they must not drift:
/// two lists of the same commands is exactly the sort of thing that ends with
/// "Remove" existing in one place and not the other.
struct ProcessActionItems: View {
    @ObservedObject var controller: ProcessController
    let isHidden: Bool
    let onToggleHidden: () -> Void
    let onRename: () -> Void
    /// Present only when the process is showing a user-given name.
    let onResetName: (() -> Void)?
    /// Absent only when there is nothing safe to remove - the last process a
    /// config declares, since an empty `processes` list does not load.
    let onRemove: (() -> Void)?
    /// True when removing edits ookook.yml rather than this Mac's own list, so
    /// the menu can say which file is about to change.
    var removeEditsConfig: Bool = false
    /// Recent Claude Code conversations for this process's project. Empty for
    /// anything that is not an agent, which is why the submenu is absent there
    /// rather than present and disabled.
    var sessions: [AgentSessionSummary] = []
    var onResume: ((AgentSessionSummary) -> Void)?
    var onClearResume: (() -> Void)?
    var isResuming: Bool = false

    var body: some View {
        Button(isHidden ? "Show in Grid" : "Hide from Grid", action: onToggleHidden)
        Divider()
        Button("Rename…", action: onRename)
        if let onResetName {
            Button("Use Name from ookook.yml", action: onResetName)
        }
        Divider()
        Button(controller.status.isRunning ? "Stop" : "Start") {
            controller.status.isRunning ? controller.stop() : controller.start()
        }
        Button("Restart") { controller.restart() }
        if let onResume, !sessions.isEmpty {
            Menu("Resume Session") {
                ForEach(sessions) { session in
                    Button(session.label) { onResume(session) }
                }
                if isResuming, let onClearResume {
                    Divider()
                    Button("Start Fresh Instead", action: onClearResume)
                }
            }
        }
        if let onRemove {
            Divider()
            Button(removeEditsConfig ? "Remove from ookook.yml" : "Remove",
                   role: .destructive, action: onRemove)
        }
    }
}
