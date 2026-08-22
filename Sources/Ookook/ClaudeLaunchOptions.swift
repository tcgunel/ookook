import Foundation

/// Launch options applied to every Claude Code session Ookook starts.
///
/// These are Ookook's, not Claude Code's: `~/.claude/settings.json` has no
/// equivalent of `--dangerously-skip-permissions`, it is a command-line flag
/// only, so "always start with it" has to mean "add it to the command line
/// every time we launch".
enum ClaudeLaunchOptions {
    static let skipPermissionsKey = "claudeSkipPermissions"

    static let skipPermissionsFlag = "--dangerously-skip-permissions"

    static var skipsPermissions: Bool {
        UserDefaults.standard.bool(forKey: skipPermissionsKey)
    }

    /// Adds the flag to a Claude Code command line, if the user asked for it.
    ///
    /// Applied at launch rather than baked into the stored command, so the
    /// preference reaches sessions that already exist - including resumed ones,
    /// whose command line is rebuilt from the same base - and turning it off
    /// takes effect the same way. Only commands that actually run `claude` are
    /// touched: a project's `ookook.yml` may well start something else.
    static func applied(to command: String) -> String {
        guard skipsPermissions,
              !command.contains(skipPermissionsFlag),
              runsClaude(command)
        else { return command }
        return "\(command) \(skipPermissionsFlag)"
    }

    /// True when the command's first word is the `claude` binary. Deliberately
    /// narrow: `claude`, or a path ending in `/claude`, and nothing else - not
    /// `claude-something`, and not a shell one-liner that mentions claude
    /// somewhere in the middle.
    private static func runsClaude(_ command: String) -> Bool {
        guard let first = command.split(separator: " ", maxSplits: 1).first else { return false }
        let word = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return word == "claude" || word.hasSuffix("/claude")
    }
}
