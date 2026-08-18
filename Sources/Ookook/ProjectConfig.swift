import Foundation
import Yams

/// One supervised process, as declared in `ookook.yml`.
struct ProcessSpec: Codable, Identifiable, Equatable {
    var name: String
    /// Shell command line, run through the login shell so PATH/nvm/asdf behave
    /// the way they do in the user's own terminal.
    var command: String
    /// Working directory, relative to the config file unless absolute.
    var cwd: String?
    var autostart: Bool?
    var autorestart: Bool?

    var id: String { name }

    var startsAutomatically: Bool { autostart ?? true }
    var restartsOnCrash: Bool { autorestart ?? false }
}

struct ProjectConfig: Codable, Equatable {
    var name: String?
    var processes: [ProcessSpec]

    /// Directory the config was loaded from; every relative `cwd` resolves against it.
    var rootURL: URL = URL(fileURLWithPath: ".")

    private enum CodingKeys: String, CodingKey { case name, processes }

    static func load(from url: URL) throws -> ProjectConfig {
        let text = try String(contentsOf: url, encoding: .utf8)
        var config = try YAMLDecoder().decode(ProjectConfig.self, from: text)
        config.rootURL = url.deletingLastPathComponent()
        try config.validate()
        return config
    }

    private func validate() throws {
        guard !processes.isEmpty else {
            throw ConfigError.message("`processes` is empty - nothing to run.")
        }
        let names = processes.map(\.name)
        let duplicates = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        guard duplicates.isEmpty else {
            throw ConfigError.message(
                "Duplicate process names: \(duplicates.sorted().joined(separator: ", "))")
        }
    }

    /// Absolute working directory for a spec.
    func workingDirectory(for spec: ProcessSpec) -> URL {
        guard let cwd = spec.cwd, !cwd.isEmpty else { return rootURL }
        let expanded = (cwd as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return rootURL.appendingPathComponent(expanded).standardizedFileURL
    }
}

enum ConfigError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
