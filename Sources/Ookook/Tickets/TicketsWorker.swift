import Foundation
import AppKit

/// Live status of one project's pipeline, for the sidebar.
struct TicketsProjectStatus: Equatable {
    var isRunning = false
    var isBusy = false
    var lastPoll: Date?
    var lastBatch: Date?
    var lastError: String?
    var usage = DeepSeekUsage()
    var issues: [TicketIssue] = []
    var issuesFetchedAt: Date?

    func issues(in column: String) -> [TicketIssue] {
        issues.filter { $0.column == column }
            .sorted { a, b in
                if a.isHighPriority != b.isHighPriority { return a.isHighPriority }
                return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
            }
    }
}

/// Runs the ticket pipeline for every enabled project, on a timer, inside the
/// app. Replaces the launchd Python daemon.
@MainActor
final class TicketsWorker: ObservableObject {
    @Published private(set) var status: [String: TicketsProjectStatus] = [:]
    @Published private(set) var log: [String] = []
    /// Backtest output, keyed by project.
    @Published var backtest: [String: BacktestRun] = [:]

    final class BacktestRun: ObservableObject {
        @Published var lines: [String] = []
        @Published var report: TicketPipeline.BacktestReport?
        @Published var isRunning = false
        var cancelled = false
    }

    let configs: TicketsConfigStore
    private var timers: [String: Timer] = [:]
    private var pipelines: [String: TicketPipeline] = [:]
    private var stores: [String: WhatsAppStore] = [:]
    private var inFlight: Set<String> = []
    private var stopped: Set<String> = []
    private var cancelFlags: [String: CancelFlag] = [:]

    /// Read from the pipeline's background work, set from the main actor.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    init(configs: TicketsConfigStore) {
        self.configs = configs
    }

    func start() {
        reconcile()
    }

    func stop() {
        for id in Array(timers.keys) { stopProject(id) }
    }

    /// Starts and stops per-project loops to match the config store. Call
    /// after any settings change.
    func reconcile() {
        let wanted = Set(configs.activeProjectIDs)
        for id in Array(timers.keys) where !wanted.contains(id) { stopProject(id) }
        for id in wanted where timers[id] == nil { startProject(id) }
    }

    private func startProject(_ id: String) {
        let config = configs.config(for: id)
        stopped.remove(id)
        var s = status[id] ?? TicketsProjectStatus()
        s.isRunning = true
        s.lastError = nil
        status[id] = s
        let timer = Timer.scheduledTimer(withTimeInterval: Double(max(10, config.pollSeconds)), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
        Task { await poll(id) }
        Task { await refreshIssues(id) }
    }

    private func stopProject(_ id: String) {
        timers[id]?.invalidate()
        timers[id] = nil
        stopped.insert(id)
        cancelFlags[id]?.set()
        cancelFlags[id] = nil
        pipelines[id] = nil
        stores[id]?.close()
        stores[id] = nil
        status[id]?.isRunning = false
        status[id]?.isBusy = false
    }

    private func append(_ line: String, project: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        log.append("\(stamp) [\(project)] \(line)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    /// Builds the pipeline for a project from the current config and state.
    private func makePipeline(_ id: String, dryRun: Bool = false) throws -> TicketPipeline {
        let config = configs.config(for: id)
        guard let key = TicketsKeychain.deepSeekKey(projectID: id) else { throw DeepSeekError.noKey }
        guard let token = GitHubClient.resolveToken(projectID: id) else { throw GitHubError.noToken }
        let store = stores[id] ?? WhatsAppStore()
        stores[id] = store
        let name = projectName(id)
        let logger: (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.append(line, project: name) }
        }
        let deepSeek = DeepSeekClient(apiKey: key, model: config.model, baseURL: config.baseURL)
        let board = GitHubBoard(client: GitHubClient(token: token), config: config, dryRun: dryRun, log: logger)
        let state = TicketsState.load(projectID: id)
        deepSeek.usage = state.usage
        let pipeline = TicketPipeline(projectID: id, config: config, store: store, deepSeek: deepSeek,
                                      board: board, state: state, log: logger)
        let flag = CancelFlag()
        cancelFlags[id] = flag
        pipeline.isCancelled = { flag.isSet }
        return pipeline
    }

    var projectNames: [String: String] = [:]
    private func projectName(_ id: String) -> String {
        projectNames[id] ?? URL(fileURLWithPath: id).lastPathComponent
    }

    func poll(_ id: String, waitForQuiet: Bool = true) async {
        guard timers[id] != nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        status[id]?.isBusy = true
        defer {
            inFlight.remove(id)
            status[id]?.isBusy = false
        }
        do {
            // Rebuilt each poll so settings edits apply without a restart; the
            // WhatsApp connection and state file carry over.
            let pipeline = try makePipeline(id)
            pipelines[id] = pipeline
            let handled = try await pipeline.runOnce(waitForQuiet: waitForQuiet)
            status[id]?.lastPoll = Date()
            status[id]?.lastError = nil
            status[id]?.usage = pipeline.deepSeek.usage
            if handled > 0 {
                status[id]?.lastBatch = Date()
                if let board = pipeline.board as? GitHubBoard {
                    notify(created: board.created, projectID: id)
                }
                await refreshIssues(id)
            }
        } catch {
            status[id]?.lastError = error.localizedDescription
            append("error: \(error.localizedDescription)", project: projectName(id))
        }
    }

    private func notify(created: [TicketIssue], projectID: String) {
        guard configs.config(for: projectID).notifyOnNewTicket, !created.isEmpty else { return }
        let first = created[0]
        let title = created.count == 1 ? "New ticket: \(first.shortTitle)" : "\(created.count) new tickets"
        let body = created.count == 1
            ? "\(projectName(projectID)) · \(first.shop ?? "shop unknown") · \(first.type ?? "?")"
            : created.map(\.title).joined(separator: "\n")
        Notifier.shared.ticketCreated(title: title, body: body)
    }

    // MARK: Board view

    /// Loads the board columns for the sidebar. Cheap enough to call on demand.
    func refreshIssues(_ id: String) async {
        let config = configs.config(for: id)
        guard let token = GitHubClient.resolveToken(projectID: id) else { return }
        let client = GitHubClient(token: token)
        var all: [TicketIssue] = []
        for repo in config.repos {
            if let issues = try? await client.boardIssues(repo: repo.repo, lookbackDays: 7) {
                all += issues
            }
        }
        var s = status[id] ?? TicketsProjectStatus()
        s.issues = all
        s.issuesFetchedAt = Date()
        status[id] = s
    }

    func move(_ issue: TicketIssue, to column: String, projectID: String) async {
        guard let token = GitHubClient.resolveToken(projectID: projectID) else { return }
        let client = GitHubClient(token: token)
        do {
            try await client.move(repo: issue.repo, number: issue.number, to: column)
            if let i = status[projectID]?.issues.firstIndex(of: issue) {
                status[projectID]?.issues[i].labels.removeAll { ["triage", "todo", "in-progress"].contains($0) }
                status[projectID]?.issues[i].labels.append(column)
            }
        } catch {
            append("move \(issue.ref) failed: \(error.localizedDescription)", project: projectName(projectID))
        }
    }

    func close(_ issue: TicketIssue, projectID: String) async {
        guard let token = GitHubClient.resolveToken(projectID: projectID) else { return }
        let client = GitHubClient(token: token)
        do {
            try await client.setState(repo: issue.repo, number: issue.number, closed: true)
            if let i = status[projectID]?.issues.firstIndex(of: issue) {
                status[projectID]?.issues[i].isClosed = true
            }
        } catch {
            append("close \(issue.ref) failed: \(error.localizedDescription)", project: projectName(projectID))
        }
    }

    // MARK: Manual actions

    /// Classifies pending messages now, without waiting for the chat to go quiet.
    func runNow(_ id: String) async {
        if timers[id] == nil { startProject(id) }
        await poll(id, waitForQuiet: false)
    }

    /// Moves cursors back so the next poll re-reads the last `hours`.
    func reset(_ id: String, hours: Double) {
        do {
            let pipeline = try makePipeline(id)
            pipeline.resetCursors(hours: hours)
            append("cursor moved back \(hours)h", project: projectName(id))
        } catch {
            // Reset needs no API keys, so fall back to a bare state edit.
            var state = TicketsState.load(projectID: id)
            let ts = Date().timeIntervalSince1970 - hours * 3600
            for chat in configs.config(for: id).chats { state.cursors[chat.jid] = ChatCursor(cursor: ts, donePks: []) }
            state.save(projectID: id)
            append("cursor moved back \(hours)h", project: projectName(id))
        }
    }

    /// Runs the classifier over pending messages and logs what it would do.
    func dryRun(_ id: String) async {
        do {
            let pipeline = try makePipeline(id, dryRun: true)
            let handled = try await pipeline.runOnce(waitForQuiet: false)
            append("dry run: \(handled) batch(es); \(pipeline.deepSeek.usage.summary)", project: projectName(id))
        } catch {
            append("dry run failed: \(error.localizedDescription)", project: projectName(id))
        }
    }

    func startBacktest(_ id: String, from: Date, to: Date) {
        let config = configs.config(for: id)
        guard let key = TicketsKeychain.deepSeekKey(projectID: id) else {
            let run = BacktestRun()
            run.lines = [DeepSeekError.noKey.localizedDescription]
            backtest[id] = run
            return
        }
        let run = BacktestRun()
        run.isRunning = true
        backtest[id] = run
        let deepSeek = DeepSeekClient(apiKey: key, model: config.model, baseURL: config.baseURL)
        Task.detached {
            let report = await TicketPipeline.backtest(
                config: config, deepSeek: deepSeek, from: from, to: to,
                progress: { line in Task { @MainActor in run.lines.append(line) } },
                isCancelled: { run.cancelled })
            await MainActor.run {
                run.report = report
                run.isRunning = false
            }
        }
    }
}
