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

    /// Replaced on every relaunch, so no process ever runs on a `LocalProcess`
    /// that has been terminated. Published so the pane hosting it swaps to the
    /// new one rather than going on showing a terminal nothing is attached to.
    @Published private(set) var terminalView: LoggingTerminalView

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
        configure(terminalView)
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: TerminalAppearance.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    TerminalAppearance.apply(to: self.terminalView)
                }
            }
        resumeOffer = LastSessionStore.entry(for: ref)
        restoreScrollback()
    }

    /// Wires a terminal view up to this controller. Applied to the first one
    /// and to every replacement, so a relaunched process is indistinguishable
    /// from a freshly created one.
    private func configure(_ view: LoggingTerminalView) {
        view.processDelegate = self
        view.baseDirectory = workingDirectory
        TerminalAppearance.apply(to: view)
        view.onActivity = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activity = self.terminalView.log.lastActivity
            }
        }
    }

    /// Whether the current view's process has already been started once.
    ///
    /// SwiftTerm's `LocalProcess` is not reusable after `terminate()`: closing
    /// the pty leaves callbacks in flight that clear `running` and the write
    /// descriptor *again*, moments after the replacement child is up. The new
    /// process then reads and paints perfectly while `send` discards every
    /// byte, because it opens with a `running` guard and returns in silence.
    /// That is a terminal you can watch but never talk to, and no number of
    /// retries escapes it - the second launch wedges exactly like the first.
    ///
    /// So a view is used for one process only. Replacing it costs the live
    /// scrollback, which is why the text on screen is carried across.
    private var viewHasLaunched = false

    /// Swaps in a terminal whose process has never been terminated.
    private func replaceTerminalViewIfUsed() {
        guard viewHasLaunched else { return }
        let previous = terminalView
        let replacement = LoggingTerminalView(frame: previous.frame)
        configure(replacement)
        // Carry the callbacks the panes installed, so the tile hosting this
        // controller keeps selecting and focusing as it did before.
        replacement.onBecomeFirstResponder = previous.onBecomeFirstResponder
        // And carry what was on screen: a restart is not a reason for the
        // history above it to vanish.
        let history = screenText(lines: ScrollbackStore.maxLines)
        if !history.isEmpty {
            replacement.feed(text: "\u{1B}[2m\(history.joined(separator: "\r\n"))\r\n"
                             + "── restarted ──\u{1B}[0m\r\n")
        }
        terminalView = replacement
        previous.terminate()
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
        wedgeRecoveries = 0
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
        settleAfterDeliberateTermination(relaunch: false)
    }

    func restart() {
        cancelPendingRestart()
        guard status.isRunning else {
            start()
            return
        }
        stopRequested = true
        pendingManualRestart = true
        terminalView.terminate()
        settleAfterDeliberateTermination(relaunch: true)
    }

    /// Finishes a stop or restart that we asked for.
    ///
    /// SwiftTerm's `terminate()` calls `childStopped()`, which cancels the
    /// child-exit DispatchSource that would otherwise have called
    /// `processTerminated`. So for a termination *we* initiate the delegate
    /// never fires: the process really is dead, but the UI keeps showing it as
    /// running, and a restart would kill without ever relaunching. Settling it
    /// here is the fix; `handleTermination` stays for the case that still
    /// reports back - a process that exits on its own.
    private func settleAfterDeliberateTermination(relaunch: Bool) {
        guard stopRequested || pendingManualRestart else { return }
        stopRequested = false
        pendingManualRestart = false
        status = .idle
        guard relaunch else { return }
        crashStreak = 0
        // A beat for the old child to actually die. The new process no longer
        // shares a terminal with it - `launch` swaps in a fresh one - so this
        // is now only about not tearing down and forking in the same instant.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.status.isRunning else { return }
            self.launch()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private var pendingManualRestart = false

    /// Command used instead of `spec.command` from here on.
    ///
    /// Held for this launch only. Within a run it has to stick - a Restart
    /// click or a crash-restart on a resumed tile belongs in the conversation
    /// the user put it in, not in a fresh one - but reopening the app is a new
    /// decision, which `resumeOffer` asks about rather than making for them.
    private(set) var commandOverride: String?

    /// The conversation this terminal was in when the app last closed, offered
    /// until the user resumes it or waves it away.
    @Published private(set) var resumeOffer: LastSessionStore.Entry?

    /// Relaunches this process into an existing Claude Code conversation.
    func resume(_ session: AgentSessionSummary) {
        commandOverride = session.command(base: spec.command)
        resumeOffer = nil
        if status.isRunning { restart() } else { start() }
        takeKeyboard()
    }

    /// Relaunches into a conversation known only by id - which is all the
    /// previous-session offer has.
    func resume(sessionID: String, model: String?) {
        var parts: [String]
        switch spec.agentProvider {
        case .codex: parts = [spec.command, "resume", sessionID]
        default: parts = [spec.command, "--resume", sessionID]
        }
        if let model, !model.isEmpty { parts += ["--model", model] }
        commandOverride = parts.joined(separator: " ")
        resumeOffer = nil
        if status.isRunning {
            restart()
        } else {
            start()
        }
        takeKeyboard()
    }

    /// Puts the keyboard into this terminal after the click that started it.
    ///
    /// Resuming is a button press, so the button - not the terminal - is what
    /// holds focus when the session comes back. The user's next act is always
    /// to type into the conversation they just restored, and a terminal that
    /// is visibly alive but silently unfocused reads as one that has stopped
    /// accepting the keyboard entirely. Deferred a turn so it lands after the
    /// SwiftUI update the resume itself triggers, which would otherwise take
    /// first responder straight back.
    private func takeKeyboard() {
        DispatchQueue.main.async { [weak self] in
            self?.focusTerminal()
        }
    }

    /// "No thanks" on the previous-session offer: this terminal is a fresh one.
    func dismissResumeOffer() {
        resumeOffer = nil
        LastSessionStore.set(nil, for: ref)
    }

    /// Remembers the conversation this terminal is in, so the next launch can
    /// offer it. Called on a timer and at quit, since a SIGTERM never reaches
    /// `applicationWillTerminate`.
    func rememberSession(_ session: AgentSession) {
        guard spec.kind == .agent, !session.sessionID.isEmpty else { return }
        LastSessionStore.record(sessionID: session.sessionID, model: session.model, for: ref)
    }

    /// Records a transcript discovered directly on disk. Codex does not keep
    /// Claude's per-PID session-state files, so its current conversation is
    /// identified from its most recently updated rollout instead.
    func rememberSession(_ session: AgentSessionSummary) {
        guard spec.kind == .agent, !session.id.isEmpty else { return }
        LastSessionStore.record(sessionID: session.id, model: session.model, for: ref)
    }

    /// True when the child is alive and still painting, but nothing typed at
    /// it can ever arrive.
    ///
    /// SwiftTerm marks its side of the pty stopped when a read comes back
    /// empty, which clears the descriptor writes go to - but the read loop
    /// re-arms itself without consulting that flag, so output carries on. The
    /// result is a terminal that looks completely healthy and silently drops
    /// every keystroke, because `LocalProcess.send` returns early and says
    /// nothing. Restarting the process relaunches it into the same
    /// conversation, so the wedge is recoverable once it is visible at all.
    var isInputWedged: Bool {
        status.isRunning && !terminalView.process.running
    }

    /// Puts the keyboard into this terminal.
    func focusTerminal() {
        guard let window = terminalView.window else { return }
        window.makeFirstResponder(terminalView)
    }

    /// Drops back to the command from `ookook.yml`.
    func clearResume() {
        commandOverride = nil
        LastSessionStore.set(nil, for: ref)
        if status.isRunning { restart() }
    }

    private func launch() {
        hasRunThisLaunch = true
        replaceTerminalViewIfUsed()
        viewHasLaunched = true
        // Run through the user's login shell so PATH, nvm, asdf, pyenv and
        // friends resolve exactly as they do in a normal terminal.
        //
        // `-i` is not optional. A login shell sources .zprofile/.zlogin but
        // *not* .zshrc, and .zshrc is where a Mac dev's PATH actually gets
        // built - nvm, asdf, pyenv, ~/.local/bin. Without it the command dies
        // with "command not found" and exit 127, which surfaces as a crash
        // with status 32512 and looks like the program is broken rather than
        // missing from PATH. It only shows up when the app is launched from
        // the Dock or Finder, because launching it from a terminal inherits a
        // PATH that already has everything.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = ClaudeLaunchOptions.applied(to: commandOverride ?? spec.command)
        terminalView.startProcess(
            executable: shell,
            args: ["-i", "-l", "-c", command],
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: workingDirectory.path
        )
        status = .running
        syncWindowSize()
        watchForStartupWedge()
    }

    /// Relaunches a process that came up with no way to type into it.
    ///
    /// The wedge is set at birth: a read on the pty master can come back empty
    /// in the instant between `forkpty` and the child opening the slave, and
    /// SwiftTerm reads that as end-of-file for good - so the terminal spends
    /// its whole life printing normally and discarding every keystroke. It is
    /// a race, so the same command usually starts fine the second time.
    ///
    /// Caught this early it costs nothing: a second in, the agent has printed
    /// a banner and done no work, and the relaunch carries the same resume
    /// command, so it lands back in the same conversation. A wedge that shows
    /// up later is left alone deliberately - by then the process may be deep
    /// in a task, and killing real work to restore the keyboard is a trade
    /// only the user can make, which is what the badge on the tile is for.
    private func watchForStartupWedge() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.status.isRunning, self.isInputWedged else { return }
            // Bounded: if relaunching cannot escape it, the cause is not the
            // race and retrying forever would only churn the conversation.
            guard self.wedgeRecoveries < Self.maxWedgeRecoveries else { return }
            self.wedgeRecoveries += 1
            self.restart()
        }
    }

    /// Relaunches spent escaping a startup wedge, reset by a deliberate start.
    private var wedgeRecoveries = 0
    private static let maxWedgeRecoveries = 3

    /// Tells the new child how big its terminal actually is.
    ///
    /// SwiftTerm only forwards a resize to the pty while a process is running,
    /// so every resize a terminal saw while it was stopped was dropped on the
    /// floor - and a terminal is stopped for its whole life until the moment
    /// someone starts or resumes it. The size the child inherits is whatever
    /// the view last computed, which for a tile the layout has not reached yet
    /// is still the placeholder frame from `init`. A full-screen TUI then
    /// paints itself for a terminal of the wrong shape and draws half off the
    /// edge of the tile, and nothing corrects it until the window is resized
    /// by hand.
    ///
    /// Deferred a turn so the tile has been laid out before the size is read.
    private func syncWindowSize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status.isRunning else { return }
            self.terminalView.layoutSubtreeIfNeeded()
            let terminal = self.terminalView.getTerminal()
            // A tile that has not been laid out yet reports nothing, and
            // telling the child its terminal is 0x0 is worse than telling it
            // nothing at all - it leaves the pty with no screen to draw on
            // until something else happens to resize it. Wait for a real size.
            guard terminal.cols > 0, terminal.rows > 0 else { return }
            self.terminalView.sizeChanged(source: self.terminalView,
                                          newCols: terminal.cols,
                                          newRows: terminal.rows)
        }
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

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        Task { @MainActor in
            // Keep Cmd-click resolving relative paths against wherever the
            // shell actually is, not just where it started.
            self.terminalView.baseDirectory = URL(fileURLWithPath: directory)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.handleTermination(exitCode: exitCode)
        }
    }

    @MainActor
    private func handleTermination(exitCode: Int32?) {
        // A termination for a process we have already settled is nothing to
        // report - without this, a late callback after a manual stop would be
        // read as a crash and could trigger a restart.
        guard status.isRunning || pendingManualRestart else { return }
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
