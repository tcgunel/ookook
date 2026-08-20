import SwiftUI
import SwiftTerm

/// Hosts a controller's long-lived `LocalProcessTerminalView` in SwiftUI.
///
/// The view is owned by the controller, not created here, so switching between
/// processes in the sidebar preserves each terminal's scrollback and state.
struct TerminalPane: NSViewRepresentable {
    let controller: ProcessController
    /// Called when this terminal takes keyboard focus.
    var onFocus: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> LoggingTerminalView {
        let view = controller.terminalView
        context.coordinator.attach(to: view)
        view.onBecomeFirstResponder = onFocus
        return view
    }

    func updateNSView(_ nsView: LoggingTerminalView, context: Context) {
        // The view outlives any one pane - the same terminal appears in the
        // grid and in single-pane - so the callback is refreshed rather than
        // set once.
        nsView.onBecomeFirstResponder = onFocus
    }

    /// Notices clicks into the terminal without consuming them.
    ///
    /// `becomeFirstResponder` cannot be overridden - SwiftTerm declares it
    /// public, not open - so focus is detected with a click recogniser instead.
    /// `delaysPrimaryMouseButtonEvents = false` is the whole point: the click
    /// still reaches the terminal, so selecting text and placing the cursor
    /// keep working, and we merely hear about it.
    @MainActor
    final class Coordinator: NSObject {
        private let controller: ProcessController
        private weak var attached: LoggingTerminalView?

        init(controller: ProcessController) {
            self.controller = controller
        }

        func attach(to view: LoggingTerminalView) {
            guard attached !== view else { return }
            attached = view
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
            click.delaysPrimaryMouseButtonEvents = false
            view.addGestureRecognizer(click)
        }

        @objc private func clicked() {
            attached?.onBecomeFirstResponder?()
            controller.focusTerminal()
        }
    }
}

struct StatusDot: View {
    let status: ProcessStatus

    var body: some View {
        Circle()
            .fill(Color(nsColor: status.tint))
            .frame(width: 8, height: 8)
    }
}
