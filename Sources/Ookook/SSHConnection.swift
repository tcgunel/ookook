import Combine
import Foundation

/// A saved SSH destination.
///
/// Deliberately holds no password. Ookook builds an `ssh` command line and runs
/// it in a real pty, so when a host wants a password, `ssh` asks for it in the
/// terminal and the user types it there - the same as any other terminal. A
/// password stored here would have to live in plain UserDefaults, and the only
/// way to use it would be to pipe it to `sshpass`, which defeats the point of
/// having a key in the first place.
struct SSHConnection: Codable, Identifiable, Equatable, Hashable {
    enum Authentication: String, Codable, CaseIterable, Identifiable {
        /// Whatever `ssh` would do by itself: agent, then the default keys.
        case agent
        /// An explicit identity file.
        case keyFile
        /// Let the server ask; `ssh` prompts in the terminal.
        case password

        var id: String { rawValue }

        var label: String {
            switch self {
            case .agent: return "OpenSSH config and agent"
            case .keyFile: return "Key pair (identity file)"
            case .password: return "Password (typed at the prompt)"
            }
        }
    }

    var id: UUID = UUID()
    /// What the menus show. Defaults to `user@host` when left empty.
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authentication: Authentication = .agent
    /// Path to a private key, `~` allowed.
    var identityFile: String = ""
    /// Run this immediately after connecting - a `cd` into the deploy
    /// directory, say. Kept as a remote command rather than typed input so it
    /// cannot race the shell's own startup output.
    var remoteCommand: String = ""
    /// Anything else you would pass to `ssh`, e.g. `-A -J bastion`.
    var extraOptions: String = ""
    /// Whether this connection is offered for every project or just one.
    var projectID: String?

    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return destination.isEmpty ? "New Connection" : destination
    }

    /// `user@host`, or just the host when no user is set.
    var destination: String {
        let user = username.trimmingCharacters(in: .whitespaces)
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return "" }
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    var isUsable: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The command line Ookook runs in the terminal.
    ///
    /// `-t` forces a pty even when a remote command is given, without which a
    /// trailing `bash -l` would come back without job control or a prompt.
    func commandLine() -> String {
        var parts = ["ssh", "-t"]
        if port != 22 { parts += ["-p", String(port)] }
        if authentication == .keyFile {
            let path = identityFile.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                // IdentitiesOnly stops ssh offering every key in the agent
                // first, which on a host with MaxAuthTries=3 fails before it
                // ever reaches the key you named.
                parts += ["-i", Self.quote(path), "-o", "IdentitiesOnly=yes"]
            }
        }
        if authentication == .password {
            parts += ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"]
        }
        let extra = extraOptions.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { parts.append(extra) }
        parts.append(Self.quote(destination))

        let remote = remoteCommand.trimmingCharacters(in: .whitespaces)
        if !remote.isEmpty {
            // Hand the remote command to a login shell and stay interactive
            // afterwards, so a `cd` leaves you sitting in that directory rather
            // than disconnecting the moment it finishes.
            parts.append(Self.quote("\(remote); exec $SHELL -l"))
        }
        return parts.joined(separator: " ")
    }

    /// Single-quote for the shell unless it is plainly safe, so a path with a
    /// space or a `$` cannot turn into two arguments.
    static func quote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-~")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where saved connections live.
///
/// UserDefaults, like the sidebar layout: this is per-machine, and it contains
/// no secrets - hostnames, usernames and a path to a key the user already has.
@MainActor
final class SSHConnectionStore: ObservableObject {
    private static let defaultsKey = "sshConnections"

    @Published private(set) var connections: [SSHConnection] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Connections offered for a project: the global ones plus its own.
    func connections(for projectID: String?) -> [SSHConnection] {
        connections.filter { $0.projectID == nil || $0.projectID == projectID }
    }

    @discardableResult
    func add(_ connection: SSHConnection = SSHConnection()) -> SSHConnection {
        connections.append(connection)
        persist()
        return connection
    }

    func update(_ connection: SSHConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        persist()
    }

    func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        persist()
    }

    func duplicate(_ id: UUID) -> SSHConnection? {
        guard let source = connections.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = source.displayName + " copy"
        connections.append(copy)
        persist()
        return copy
    }

    /// Adds every `Host` in `~/.ssh/config` that is not already saved.
    ///
    /// Matched by host *and* user rather than by name, so importing twice does
    /// not produce duplicates, and a config entry whose name you have since
    /// changed is still recognised.
    @discardableResult
    func importSSHConfig() -> Int {
        let imported = SSHConfigFile.parse()
        var added = 0
        for entry in imported {
            let duplicate = connections.contains {
                $0.host.caseInsensitiveCompare(entry.host) == .orderedSame
                    && $0.username == entry.username
                    && $0.port == entry.port
            }
            guard !duplicate else { continue }
            connections.append(entry)
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([SSHConnection].self, from: data)
        else { return }
        connections = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Reads `~/.ssh/config` well enough to offer its hosts.
///
/// Not a full implementation of ssh_config: `Match` blocks, `Include` and
/// wildcard patterns are skipped rather than half-supported, because a
/// half-parsed pattern would produce a menu entry that cannot connect. The
/// entries it does produce are ordinary saved connections the user can edit.
enum SSHConfigFile {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    }

    static func parse(contentsOf url: URL = SSHConfigFile.url) -> [SSHConnection] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [SSHConnection] = []
        var current: SSHConnection?

        func flush() {
            if let connection = current, connection.isUsable { result.append(connection) }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // ssh_config accepts `Key value` and `Key=value`.
            let separated = line.replacingOccurrences(of: "=", with: " ")
            let parts = separated.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "host":
                flush()
                // A pattern matches many hosts and names none of them.
                guard !value.contains("*"), !value.contains("?"), !value.contains(" ") else { continue }
                var connection = SSHConnection()
                connection.name = value
                connection.host = value
                current = connection
            case "hostname":
                current?.host = value
            case "user":
                current?.username = value
            case "port":
                if let port = Int(value) { current?.port = port }
            case "identityfile":
                current?.identityFile = value
                current?.authentication = .keyFile
            case "match":
                flush()
            default:
                continue
            }
        }
        flush()
        return result
    }
}

extension ProcessSpec {
    /// An SSH session as a supervised terminal.
    ///
    /// `autostart` is false: connecting reaches out to someone else's machine,
    /// and a tile that dials out on every app launch is not what you want from
    /// a production host.
    static func ssh(_ connection: SSHConnection) -> ProcessSpec {
        ProcessSpec(name: connection.displayName,
                    command: connection.commandLine(),
                    cwd: nil,
                    autostart: false,
                    autorestart: false,
                    type: .terminal,
                    port: nil,
                    env: nil)
    }
}
