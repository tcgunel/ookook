import Foundation

/// Launch options applied to supported coding-agent sessions Ookook starts.
///
/// These are Ookook's, not Claude Code's: `~/.claude/settings.json` has no
/// equivalent of `--dangerously-skip-permissions`, it is a command-line flag
/// only, so "always start with it" has to mean "add it to the command line
/// every time we launch".
enum ClaudeLaunchOptions {
    static let skipPermissionsKey = "claudeSkipPermissions"
    static let codexBypassApprovalsAndSandboxKey = "codexBypassApprovalsAndSandbox"

    static let skipPermissionsFlag = "--dangerously-skip-permissions"
    static let codexBypassApprovalsAndSandboxFlag = "--yolo"

    static var skipsPermissions: Bool {
        // Ookook sessions are meant to run unattended, so an unset preference
        // means enabled; only an explicit opt-out saved by the user turns the
        // flag off. Without it Claude Code falls back to whatever
        // `permissions.defaultMode` says in `~/.claude/settings.json`.
        guard UserDefaults.standard.object(forKey: skipPermissionsKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: skipPermissionsKey)
    }

    static var bypassesCodexApprovalsAndSandbox: Bool {
        // Codex agents have always been intended to run unattended in Ookook.
        // Treat an unset preference as enabled while preserving an explicit
        // opt-out saved by the user.
        guard UserDefaults.standard.object(forKey: codexBypassApprovalsAndSandboxKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: codexBypassApprovalsAndSandboxKey)
    }

    /// Adds the flag to a Claude Code command line, if the user asked for it.
    ///
    /// Applied at launch rather than baked into the stored command, so the
    /// preference reaches sessions that already exist - including resumed ones,
    /// whose command line is rebuilt from the same base - and turning it off
    /// takes effect the same way. Only commands that actually run `claude` are
    /// touched: a project's `ookook.yml` may well start something else.
    static func applied(to command: String) -> String {
        if skipsPermissions,
           !command.contains(skipPermissionsFlag),
           runs(command, executable: "claude") {
            return "\(command) \(skipPermissionsFlag)"
        }
        if bypassesCodexApprovalsAndSandbox,
           !command.contains(codexBypassApprovalsAndSandboxFlag),
           runs(command, executable: "codex") {
            return "\(command) \(codexBypassApprovalsAndSandboxFlag)"
        }
        return command
    }

    /// True when the command's first word is the `claude` binary. Deliberately
    /// narrow: `claude`, or a path ending in `/claude`, and nothing else - not
    /// `claude-something`, and not a shell one-liner that mentions claude
    /// somewhere in the middle.
    private static func runs(_ command: String, executable: String) -> Bool {
        guard let first = command.split(separator: " ", maxSplits: 1).first else { return false }
        let word = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return word == executable || word.hasSuffix("/\(executable)")
    }
}
