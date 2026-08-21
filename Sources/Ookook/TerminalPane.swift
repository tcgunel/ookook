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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        update(host, context: context)
        return host
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        update(nsView, context: context)
    }

    private func update(_ host: TerminalHostView, context: Context) {
        // Reloading a project builds fresh controllers, and with them fresh
        // terminal views, while SwiftUI keeps this pane - same project, same
        // process name, same identity - and so never calls makeNSView again.
        // Hosting the terminal in a container instead of *being* it means the
        // pane can swap in the current one; otherwise the tile keeps showing
        // the dead terminal of the process that was just replaced, and the
        // process that actually started is invisible.
        host.host(controller.terminalView)
        context.coordinator.attach(to: controller.terminalView, controller: controller)
        // The view outlives any one pane - the same terminal appears in the
        // grid and in single-pane - so the callback is refreshed rather than
        // set once.
        controller.terminalView.onBecomeFirstResponder = onFocus
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
        private var controller: ProcessController?
        private weak var attached: LoggingTerminalView?

        func attach(to view: LoggingTerminalView, controller: ProcessController) {
            self.controller = controller
            guard attached !== view else { return }
            attached = view
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
            click.delaysPrimaryMouseButtonEvents = false
            view.addGestureRecognizer(click)
        }

        @objc private func clicked() {
            attached?.onBecomeFirstResponder?()
            controller?.focusTerminal()
        }
    }
}

/// A plain container whose only job is to hold whichever terminal view is
/// current, so the terminal can be replaced without replacing the pane.
final class TerminalHostView: NSView {
    private weak var hosted: LoggingTerminalView?

    func host(_ view: LoggingTerminalView) {
        guard hosted !== view else { return }
        hosted?.removeFromSuperview()
        hosted = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        // A swap usually means the old process just died under the user's
        // cursor; put the keyboard back where they were looking.
        if window?.firstResponder == nil || window?.firstResponder === self {
            window?.makeFirstResponder(view)
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
