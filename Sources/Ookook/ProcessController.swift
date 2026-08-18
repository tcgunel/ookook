import AppKit
import Combine
import SwiftTerm

enum ProcessStatus: Equatable {
    case idle           // never started, or deliberately stopped
    case running
    case exited(Int32)  // finished on its own with this code
    case crashed(Int32) // non-zero exit we did not ask for
    case restarting

    var isRunning: Bool { self == .running }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .exited(let code): return "Exited (\(code))"
        case .crashed(let code): return "Crashed (\(code))"
        case .restarting: return "Restarting…"
        }
    }

    var tint: NSColor {
        switch self {
        case .idle: return .systemGray
        case .running: return .systemGreen
        case .exited: return .systemGray
        case .crashed: return .systemRed
        case .restarting: return .systemOrange
        }
    }
}

/// Owns one supervised process and the terminal view it renders into.
///
/// The terminal view is created once and kept for the controller's lifetime so
/// scrollback survives switching between processes in the sidebar.
@MainActor
final class ProcessController: NSObject, ObservableObject, Identifiable {
    let spec: ProcessSpec
    let workingDirectory: URL

    @Published private(set) var status: ProcessStatus = .idle
    /// Terminal-reported title, when the child emits one (OSC 0/2).
    @Published private(set) var title: String?

    nonisolated var id: String { spec.name }

    let terminalView: LocalProcessTerminalView

    /// Consecutive crash count, reset by a clean exit or a manual start. Drives
    /// restart backoff so a process that fails instantly cannot spin the CPU.
    private var crashStreak = 0
    /// Set while we are tearing the process down on purpose, so the termination
    /// callback does not misreport a deliberate stop as a crash.
    private var stopRequested = false
    private var restartWork: DispatchWorkItem?

    private static let maxRestartDelay: TimeInterval = 30

    init(spec: ProcessSpec, workingDirectory: URL) {
        self.spec = spec
        self.workingDirectory = workingDirectory
        self.terminalView = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        terminalView.processDelegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard !status.isRunning else { return }
        cancelPendingRestart()
        stopRequested = false
        crashStreak = 0
        launch()
    }

    func stop() {
        cancelPendingRestart()
        guard status.isRunning else {
            status = .idle
            return
        }
        stopRequested = true
        terminalView.terminate()
    }

    func restart() {
        cancelPendingRestart()
        guard status.isRunning else {
            start()
            return
        }
        // Relaunch from the termination callback rather than racing the kill.
        stopRequested = true
        pendingManualRestart = true
        terminalView.terminate()
    }

    private var pendingManualRestart = false

    private func launch() {
        // Run through the user's login shell so PATH, nvm, asdf, pyenv and
        // friends resolve exactly as they do in a normal terminal.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", spec.command],
            environment: Self.childEnvironment(),
            execName: nil,
            currentDirectory: workingDirectory.path
        )
        status = .running
    }

    /// SwiftTerm's default environment is a minimal synthetic one, which would
    /// leave children without SHELL, HOME, PATH or any tool configuration the
    /// user relies on. Inherit the real environment and set only the terminal
    /// variables the pty needs.
    private static func childEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Ookook"
        // Children are supervised individually; a pager that waits for a keypress
        // would look like a hung process in the sidebar.
        env["PAGER"] = env["PAGER"] ?? "cat"
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Restart policy

    private func scheduleRestart() {
        // 1s, 2s, 4s … capped, so a command that dies on launch backs off
        // instead of hammering.
        let delay = min(pow(2, Double(crashStreak - 1)), Self.maxRestartDelay)
        status = .restarting
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.status == .restarting else { return }
                self.launch()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRestart() {
        restartWork?.cancel()
        restartWork = nil
    }
}

// MARK: - LocalProcessTerminalViewDelegate

extension ProcessController: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            self.title = title.isEmpty ? nil : title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.handleTermination(exitCode: exitCode)
        }
    }

    @MainActor
    private func handleTermination(exitCode: Int32?) {
        let code = exitCode ?? -1

        if pendingManualRestart {
            pendingManualRestart = false
            stopRequested = false
            crashStreak = 0
            launch()
            return
        }

        if stopRequested {
            stopRequested = false
            status = .idle
            return
        }

        if code == 0 {
            crashStreak = 0
            status = .exited(0)
            return
        }

        status = .crashed(code)
        guard spec.restartsOnCrash else { return }
        crashStreak += 1
        scheduleRestart()
    }
}
