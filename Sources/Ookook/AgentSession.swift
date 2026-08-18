import Foundation

/// What a Claude Code session inside one of our processes is doing.
struct AgentSession: Equatable {
    enum Activity: String, Equatable {
        case busy
        case waiting
        case idle
        case shell
        case unknown

        /// Whether the agent is blocked on the user - the thing worth surfacing.
        var needsAttention: Bool { self == .waiting }

        var label: String {
            switch self {
            case .busy: return "Working"
            case .waiting: return "Waiting for you"
            case .idle: return "Idle"
            case .shell: return "Shell"
            case .unknown: return "Running"
            }
        }
    }

    /// A sub-agent spawned inside this session (a Task/subagent or a workflow
    /// step). These are not OS processes - they run inside the one `claude`
    /// process - so they are discovered from their transcripts, not the
    /// process table.
    struct Subagent: Equatable, Identifiable {
        var id: String
        var title: String
        var contextTokens: Int?
        var model: String?
        /// Whether its transcript is still being written.
        var isActive: Bool
        /// The workflow it belongs to, when it is part of one.
        var workflow: String?
    }

    var sessionID: String
    var cwd: String
    var activity: Activity
    var model: String?
    /// Prompt size of the most recent turn, i.e. how full the context is.
    var contextTokens: Int?
    /// Known window for `model`, when we know it.
    var contextLimit: Int?
    var subagents: [Subagent] = []

    /// Fraction of the context window in use, clamped - never render past full.
    var contextFraction: Double? {
        guard let contextTokens, let contextLimit, contextLimit > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextLimit))
    }

    var contextSummary: String? {
        guard let contextTokens else { return nil }
        let used = Self.compactTokens(contextTokens)
        guard let contextLimit else { return "\(used) ctx" }
        return "\(used)/\(Self.compactTokens(contextLimit))"
    }

    static func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return "\(value / 1_000)k"
        }
        return String(value)
    }

    /// Context windows per model.
    ///
    /// Deliberately a lookup with no fallback guess: an unknown model shows a
    /// token count and no gauge, rather than a bar measured against a number we
    /// invented. Observed compaction points on this machine run past 1.1M, so a
    /// blanket 1M denominator would render over 100%.
    static func contextLimit(for model: String?) -> Int? {
        guard let model = model?.lowercased() else { return nil }
        if model.contains("opus-5") || model.contains("sonnet-5") || model.contains("fable-5") {
            return 1_000_000
        }
        if model.contains("opus-4") || model.contains("sonnet-4") || model.contains("haiku-4") {
            return 200_000
        }
        return nil
    }
}
