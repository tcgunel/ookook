import Foundation

/// Remembers which Claude Code conversation each process was resumed into.
///
/// Kept out of `ookook.yml` for the same reason as the sidebar layout: the
/// config file is committed and shared, and "which of my conversations this
/// tile is currently in" is personal, per-machine state that would be noise in
/// a teammate's diff.
enum ResumeStore {
    private static let defaultsKey = "resumedCommands"

    static func command(for ref: ProcessRef) -> String? {
        all()[ref.id]
    }

    static func set(_ command: String?, for ref: ProcessRef) {
        var map = all()
        if let command, !command.isEmpty {
            map[ref.id] = command
        } else {
            map.removeValue(forKey: ref.id)
        }
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    private static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}
