import Combine
import Foundation

/// Processes the user added from the UI rather than from `ookook.yml`.
///
/// Kept out of the config file on purpose: `ookook.yml` is committed and shared,
/// so a personal extra agent or scratch shell would otherwise show up as a diff
/// on a teammate's checkout. These live per machine, alongside the sidebar
/// layout and the open-project list.
@MainActor
final class LocalProcessStore: ObservableObject {
    private static let defaultsKey = "localProcesses"

    @Published private var specs: [String: [ProcessSpec]] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func specs(for projectID: String) -> [ProcessSpec] {
        specs[projectID] ?? []
    }

    func isLocal(projectID: String, process: String) -> Bool {
        specs(for: projectID).contains { $0.name == process }
    }

    /// Adds a process, giving it a name that does not collide with anything the
    /// project already has - names are the identity everywhere else.
    @discardableResult
    func add(_ spec: ProcessSpec, to projectID: String, existing: [String]) -> ProcessSpec {
        var spec = spec
        var name = spec.name
        var suffix = 2
        while existing.contains(name) {
            name = "\(spec.name) \(suffix)"
            suffix += 1
        }
        spec.name = name
        specs[projectID, default: []].append(spec)
        persist()
        return spec
    }

    func remove(process: String, from projectID: String) {
        specs[projectID]?.removeAll { $0.name == process }
        if specs[projectID]?.isEmpty == true { specs.removeValue(forKey: projectID) }
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [ProcessSpec]].self, from: data)
        else { return }
        specs = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(specs) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

extension ProcessSpec {
    /// A fresh Claude Code session in the project directory.
    static func claudeAgent(named name: String = "Claude Code") -> ProcessSpec {
        ProcessSpec(name: name,
                    command: "claude",
                    cwd: nil,
                    autostart: true,
                    autorestart: false,
                    type: .agent,
                    port: nil,
                    env: nil)
    }

    /// An interactive login shell. `-i` matters: without it the shell exits
    /// immediately even on a pty.
    static func shell(named name: String = "shell") -> ProcessSpec {
        ProcessSpec(name: name,
                    command: "exec $SHELL -i -l",
                    cwd: nil,
                    autostart: true,
                    autorestart: false,
                    type: .terminal,
                    port: nil,
                    env: nil)
    }

    static func command(named name: String, command: String) -> ProcessSpec {
        ProcessSpec(name: name,
                    command: command,
                    cwd: nil,
                    autostart: true,
                    autorestart: false,
                    type: .command,
                    port: nil,
                    env: nil)
    }
}
