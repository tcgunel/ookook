import Foundation

/// The Claude Code conversation each terminal was in when the app last closed.
///
/// Deliberately an *offer*, not a setting: reopening the app does not put a
/// terminal back into its conversation, it says which one it was in and lets
/// the user decide, per terminal. Silently resuming would be worse than
/// silently starting fresh - a resumed session costs a full context re-upload
/// on its first message, and some of those conversations are finished.
enum LastSessionStore {
    private static let defaultsKey = "lastSessions"

    struct Entry: Codable, Equatable {
        var sessionID: String
        var model: String?
        var endedAt: Date
    }

    static func entry(for ref: ProcessRef) -> Entry? {
        all()[ref.id]
    }

    static func set(_ entry: Entry?, for ref: ProcessRef) {
        var map = all()
        if let entry {
            map[ref.id] = entry
        } else {
            map.removeValue(forKey: ref.id)
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func record(sessionID: String, model: String?, for ref: ProcessRef) {
        set(Entry(sessionID: sessionID, model: model, endedAt: Date()), for: ref)
    }

    private static func all() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }
}
