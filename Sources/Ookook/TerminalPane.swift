import SwiftUI
import SwiftTerm

/// Hosts a controller's long-lived `LocalProcessTerminalView` in SwiftUI.
///
/// The view is owned by the controller, not created here, so switching between
/// processes in the sidebar preserves each terminal's scrollback and state.
struct TerminalPane: NSViewRepresentable {
    let controller: ProcessController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

struct StatusDot: View {
    let status: ProcessStatus

    var body: some View {
        Circle()
            .fill(Color(nsColor: status.tint))
            .frame(width: 8, height: 8)
    }
}
