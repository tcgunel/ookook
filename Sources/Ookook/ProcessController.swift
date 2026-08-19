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
    /// Which project this belongs to; process names are unique only per project.
    let projectID: String
    let workingDirectory: URL

    @Published private(set) var status: ProcessStatus = .idle
    /// Terminal-reported title, when the child emits one (OSC 0/2).
    @Published private(set) var title: String?

    /// Identity must be unique across projects: two projects may each have a
    /// process called `dev`, and a name-only id makes SwiftUI drop one of them
    /// from any ForEach that spans projects.
    nonisolated var id: String { ref.id }
    nonisolated var ref: ProcessRef { ProcessRef(project: projectID, process: spec.name) }

    let terminalView: LoggingTerminalView

    /// Last line of output with visible content, shown under the name in the sidebar.
    @Published private(set) var activity: String?

    var log: ProcessLog { terminalView.log }

    /// PID of the shell we launched, while it is running. Resource sampling walks
    /// its whole subtree from here.
    var pid: pid_t? {
        guard status.isRunning else { return nil }
        let shellPid = terminalView.process.shellPid
        return shellPid > 0 ? shellPid : nil
    }

    /// Consecutive crash count, reset by a clean exit or a manual start. Drives
    /// restart backoff so a process that fails instantly cannot spin the CPU.
    private var crashStreak = 0
    /// Set while we are tearing the process down on purpose, so the termination
    /// callback does not misreport a deliberate stop as a crash.
    private var stopRequested = false
    private var restartWork: DispatchWorkItem?
    private var appearanceObserver: NSObjectProtocol?
    /// Whether this process has run since the app launched.
    ///
    /// A terminal that only ever showed *restored* text must not be saved back:
    /// each snapshot would capture the replay along with its own marker, and the
    /// next launch would replay that, stacking "previous session" rules until
    /// the tile was nothing but markers.
    private var hasRunThisLaunch = false

    private static let maxRestartDelay: TimeInterval = 30

    init(spec: ProcessSpec, projectID: String, workingDirectory: URL) {
        self.spec = spec
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.terminalView = LoggingTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        terminalView.processDelegate = self
        TerminalAppearance.apply(to: terminalView)
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: TerminalAppearance.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    TerminalAppearance.apply(to: self.terminalView)
                }
            }
        terminalView.onActivity = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activity = self.terminalView.log.lastActivity
            }
        }
        restoreScrollback()
    }

    /// Replays the previous session's output into the fresh terminal, so a tile
    /// is not blank until you start the process again. Marked off with a rule
    /// so old output is never mistaken for something happening now.
    private func restoreScrollback() {
        let lines = ScrollbackStore.load(for: ref)
        guard !lines.isEmpty else { return }
        let body = lines.joined(separator: "\r\n")
        // Dim, so restored history reads as history at a glance.
        terminalView.feed(text: "\u{1B}[2m\(body)\r\n── previous session ──\u{1B}[0m\r\n")
    }

    /// Called before the app quits, when a process stops, and periodically.
    ///
    /// Agent TUIs paint with cursor positioning and emit almost no newlines, so
    /// their line log stays empty however long they run - for those, what is
    /// worth keeping is the rendered screen, the same fallback the MCP output
    /// tool uses.
    func persistScrollback() {
        guard hasRunThisLaunch else { return }
        let logged = log.tail(ScrollbackStore.maxLines)
        let meaningful = logged.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if meaningful.count >= 3 {
            ScrollbackStore.save(logged, for: ref)
        } else {
            let screen = screenText(lines: ScrollbackStore.maxLines)
            // Nothing on screen either: keep whatever was already stored rather
            // than replacing a real history with a blank file.
            guard screen.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            else { return }
            ScrollbackStore.save(screen, for: ref)
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    // MARK: - Lifecycle

    /// What the sidebar shows under the process name: live output while running,
    /// otherwise the lifecycle state.
    var subtitle: String {
        if status.isRunning, let activity, !activity.isEmpty { return activity }
        return status.label
    }

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
        // Snapshot before the terminal is torn down: a stopped process is
        // exactly the one whose last output you want to still be able to read.
        persistScrollback()
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
        hasRunThisLaunch = true
        // Run through the user's login shell so PATH, nvm, asdf, pyenv and
        // friends resolve exactly as they do in a normal terminal.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", spec.command],
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: workingDirectory.path
        )
        status = .running
    }

    /// SwiftTerm's default environment is a minimal synthetic one, which would
    /// leave children without SHELL, HOME, PATH or any tool configuration the
    /// user relies on. Inherit the real environment and set only the terminal
    /// variables the pty needs.
    private func childEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment

        // Ookook may itself have been launched from inside a Claude Code
        // session. Those variables mark the *launching* session, and an agent
        // that inherits them believes it is a child session: it turns off
        // transcript saving ("inherited CLAUDE_CODE_CHILD_SESSION marker") and
        // never registers, so the user silently loses their transcripts.
        // Every process here is a fresh top-level session, so drop them.
        for key in env.keys where Self.isInheritedSessionMarker(key) {
            env.removeValue(forKey: key)
        }

        // Lets a process (or an agent running in one) know which project and
        // process it is, without having to be told.
        env["OOKOOK_PROJECT"] = projectID
        env["OOKOOK_PROCESS"] = spec.name

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Ookook"
        // Children are supervised individually; a pager that waits for a keypress
        // would look like a hung process in the sidebar.
        env["PAGER"] = env["PAGER"] ?? "cat"

        // Anything the config asks for wins over all of the above.
        for (key, value) in spec.env ?? [:] {
            env[key] = value
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Session-scoped Claude Code variables, as opposed to a user's own
    /// CLAUDE_-prefixed settings, which are left alone.
    private static func isInheritedSessionMarker(_ key: String) -> Bool {
        key.hasPrefix("CLAUDE_CODE_")
            || key == "CLAUDECODE"
            || key == "CLAUDE_PID"
            || key == "CLAUDE_EFFORT"
            || key == "CLAUDE_PROJECT_DIR"
    }

    /// Types into the process, as if at the keyboard.
    ///
    /// This is how an agent answers another agent's prompt, or how a script
    /// drives a REPL - the pty makes no distinction between this and a person.
    func send(text: String, submit: Bool) {
        guard status.isRunning else { return }
        terminalView.send(data: Array(text.utf8)[...])
        guard submit else { return }

        // Send Enter as its own write, a beat later. A full-screen TUI that
        // reads the text and the carriage return in one burst treats the whole
        // thing as a paste, and a pasted newline inserts a line rather than
        // submitting - the text lands in the prompt and just sits there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.status.isRunning else { return }
            self.terminalView.send(data: [0x0D][...])
        }
    }

    /// The text currently rendered on screen, newest lines last.
    ///
    /// Byte-stream logs are near-useless for full-screen TUIs: they redraw with
    /// cursor positioning and emit almost no newlines, so the log stays empty
    /// while the screen is full. Reading what the terminal actually rendered is
    /// the only way to see what an agent is showing.
    func screenText(lines limit: Int) -> [String] {
        let terminal = terminalView.getTerminal()
        var rows: [String] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            rows.append(line.translateToString(trimRight: true))
        }
        // Trim the blank padding a TUI leaves around its frame.
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        while let first = rows.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeFirst()
        }
        return Array(rows.suffix(limit))
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
        Notifier.shared.processCrashed(process: spec.name, project: projectID, code: code)
        guard spec.restartsOnCrash else { return }
        crashStreak += 1
        scheduleRestart()
    }
}
