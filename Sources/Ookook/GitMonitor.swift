import Combine
import Foundation

/// Tracks branch, dirtiness and ahead/behind for each open project.
///
/// Branch comes from parsing `.git/HEAD`, which costs a file read and is
/// therefore sampled freely; dirty and ahead/behind need a real `git status`
/// and are throttled. On this machine that command measured 10-45ms across
/// repos of very different sizes, so a few seconds between samples keeps the
/// cost near zero while still feeling live.
///
/// The whole thing is best-effort: a directory that is not a repository, or a
/// machine with no usable git, simply produces no state and no error UI.
@MainActor
final class GitMonitor: ObservableObject {
    /// Keyed by project id.
    @Published private(set) var states: [String: GitState] = [:]

    private var timer: Timer?
    private var targets: [(id: String, root: URL)] = []
    private var isSampling = false
    private let queue = DispatchQueue(label: "com.tolga.ookook.git", qos: .utility)

    /// Replaces the set of checkouts being watched. Safe to call on every
    /// project list change - state for projects that went away is dropped.
    func watch(_ targets: [(id: String, root: URL)]) {
        self.targets = targets
        let live = Set(targets.map(\.id))
        states = states.filter { live.contains($0.key) }
        sample()
    }

    func start(interval: TimeInterval = 5) {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Forces a refresh, for when the app knows something changed (a commit ran
    /// in one of the terminals, say) rather than waiting out the interval.
    func refresh() { sample() }

    private func sample() {
        let targets = self.targets
        guard !targets.isEmpty else {
            if !states.isEmpty { states = [:] }
            return
        }
        // A slow repository must not queue up a backlog of git invocations.
        guard !isSampling else { return }
        isSampling = true

        queue.async {
            var results: [String: GitState] = [:]
            for target in targets {
                if let state = Self.state(of: target.root) {
                    results[target.id] = state
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSampling = false
                if self.states != results { self.states = results }
            }
        }
    }

    // MARK: - Sampling

    private nonisolated static func state(of root: URL) -> GitState? {
        guard let gitDirectory = GitPaths.gitDirectory(for: root),
              let head = GitPaths.head(in: gitDirectory) else { return nil }

        var state = GitState(branch: head.branch, isDetached: head.isDetached)
        if let status = runStatus(in: root) {
            state.isDirty = status.isDirty
            state.ahead = status.ahead
            state.behind = status.behind
            // git is authoritative about the branch mid-rebase, where HEAD is
            // detached onto the replayed commits.
            if let branch = status.branch {
                state.branch = branch
                state.isDetached = false
            }
        }
        return state
    }

    private nonisolated static func runStatus(in root: URL)
        -> (branch: String?, isDirty: Bool, ahead: Int?, behind: Int?)? {
        guard let git = gitExecutable else { return nil }

        let process = Process()
        process.executableURL = git
        process.arguments = ["status", "--porcelain=v2", "--branch", "--untracked-files=normal"]
        process.currentDirectoryURL = root
        // Without a terminal git must never try to prompt for credentials.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }

        return parse(status: output)
    }

    /// Splits porcelain v2 output. Header lines start with `#`; any other line
    /// is a changed, untracked or unmerged path, so one is enough to be dirty.
    nonisolated static func parse(status output: String)
        -> (branch: String?, isDirty: Bool, ahead: Int?, behind: Int?) {
        var branch: String?
        var isDirty = false
        var ahead: Int?
        var behind: Int?

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("#") else {
                isDirty = true
                continue
            }
            let fields = line.split(separator: " ")
            guard fields.count >= 3 else { continue }
            switch fields[1] {
            case "branch.head":
                // Detached checkouts report the literal "(detached)", which is
                // not a name we want to show - HEAD already gave us the hash.
                let name = String(fields[2])
                if name != "(detached)" { branch = name }
            case "branch.ab":
                for field in fields.dropFirst(2) {
                    if field.hasPrefix("+") { ahead = Int(field.dropFirst()) }
                    if field.hasPrefix("-") { behind = Int(field.dropFirst()) }
                }
            default:
                continue
            }
        }
        return (branch, isDirty, ahead, behind)
    }

    // MARK: - Locating git

    /// A real git binary, or nil.
    ///
    /// Deliberately never `/usr/bin/git`: that is the xcode-select shim, and on
    /// a machine without Command Line Tools it puts up its own modal installer
    /// before returning an exit status we could inspect. Resolving the
    /// developer directory ourselves means we either find a genuine binary or
    /// quietly do nothing.
    private nonisolated static let gitExecutable: URL? = {
        // `xcode_select_link` is the symlink `xcode-select -p` reports, so this
        // follows the user's actual choice of toolchain first.
        let candidates = [
            "/var/db/xcode_select_link/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return nil
    }()
}
