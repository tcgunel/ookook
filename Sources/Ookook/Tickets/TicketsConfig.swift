import Foundation
import Security

/// One WhatsApp chat a project listens to.
struct TicketChat: Codable, Hashable, Identifiable {
    var jid: String
    var name: String
    var id: String { jid }

    /// The label the model sees for messages from this person. First name in
    /// capitals reads well next to "ME" in the transcript.
    var speakerLabel: String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        let cleaned = first.isEmpty ? "COWORKER" : first
        return cleaned.uppercased()
    }
}

/// A GitHub repo tickets may land in, plus where its clone is for the file map.
struct TicketRepo: Codable, Hashable, Identifiable {
    var id = UUID()
    var repo: String = "owner/name"
    var localPath: String = ""
    var hint: String = ""

    enum CodingKeys: String, CodingKey { case id, repo, localPath, hint }
}

/// Everything the ticket pipeline needs for one project.
///
/// This is personal, per-machine configuration (chat partners, API keys,
/// local clone paths), so it lives in UserDefaults keyed by project id, never
/// in the committed `ookook.yml`. The DeepSeek key is stored in the Keychain
/// and only referenced here.
struct TicketsProjectConfig: Codable, Equatable {
    var enabled = false
    var chats: [TicketChat] = []
    var repos: [TicketRepo] = []

    var model = "deepseek-chat"
    var baseURL = "https://api.deepseek.com"

    var pollSeconds = 30
    /// Messages closer than this form one batch.
    var batchGapSeconds = 900
    /// Wait for the chat to go quiet this long before classifying a batch.
    var quietSeconds = 120
    var contextMessages = 20
    var minConfidence = 0.45
    var lowConfidenceBelow = 0.7
    var issueLookbackDays = 45
    var maxMapFilesPerRepo = 300
    var labels = ["triage", "ai-generated"]
    var languageHint = "Messages are mostly Turkish, sometimes English. Write issues in English."

    // Quality-of-life options
    var notifyOnNewTicket = true
    var ocrScreenshots = true
    /// Tasks at or above this confidence skip triage and go straight to `todo`.
    /// 1.0 (or anything above 1) disables it.
    var autoApproveAbove = 1.01
    /// Only these types are auto-approved; ops/xml/integration always wait for a human.
    var autoApproveTypes = ["bug", "feature"]
    /// Types that never become tickets (the model still sees them as context).
    var ignoredTypes: [String] = []
    /// Skip classifying overnight, when the chat is mostly small talk.
    var activeHoursStart = 0
    var activeHoursEnd = 24

    var isConfigured: Bool { !chats.isEmpty && !repos.isEmpty }

    init() {}

    // Decoding tolerates missing keys so older stored configs still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TicketsProjectConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        chats = try c.decodeIfPresent([TicketChat].self, forKey: .chats) ?? d.chats
        repos = try c.decodeIfPresent([TicketRepo].self, forKey: .repos) ?? d.repos
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? d.pollSeconds
        batchGapSeconds = try c.decodeIfPresent(Int.self, forKey: .batchGapSeconds) ?? d.batchGapSeconds
        quietSeconds = try c.decodeIfPresent(Int.self, forKey: .quietSeconds) ?? d.quietSeconds
        contextMessages = try c.decodeIfPresent(Int.self, forKey: .contextMessages) ?? d.contextMessages
        minConfidence = try c.decodeIfPresent(Double.self, forKey: .minConfidence) ?? d.minConfidence
        lowConfidenceBelow = try c.decodeIfPresent(Double.self, forKey: .lowConfidenceBelow) ?? d.lowConfidenceBelow
        issueLookbackDays = try c.decodeIfPresent(Int.self, forKey: .issueLookbackDays) ?? d.issueLookbackDays
        maxMapFilesPerRepo = try c.decodeIfPresent(Int.self, forKey: .maxMapFilesPerRepo) ?? d.maxMapFilesPerRepo
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? d.labels
        languageHint = try c.decodeIfPresent(String.self, forKey: .languageHint) ?? d.languageHint
        notifyOnNewTicket = try c.decodeIfPresent(Bool.self, forKey: .notifyOnNewTicket) ?? d.notifyOnNewTicket
        ocrScreenshots = try c.decodeIfPresent(Bool.self, forKey: .ocrScreenshots) ?? d.ocrScreenshots
        autoApproveAbove = try c.decodeIfPresent(Double.self, forKey: .autoApproveAbove) ?? d.autoApproveAbove
        autoApproveTypes = try c.decodeIfPresent([String].self, forKey: .autoApproveTypes) ?? d.autoApproveTypes
        ignoredTypes = try c.decodeIfPresent([String].self, forKey: .ignoredTypes) ?? d.ignoredTypes
        activeHoursStart = try c.decodeIfPresent(Int.self, forKey: .activeHoursStart) ?? d.activeHoursStart
        activeHoursEnd = try c.decodeIfPresent(Int.self, forKey: .activeHoursEnd) ?? d.activeHoursEnd
    }
}

/// Per-project ticket configs, persisted like the SSH connections.
@MainActor
final class TicketsConfigStore: ObservableObject {
    private static let defaultsKey = "ticketsProjectConfigs"

    @Published private(set) var configs: [String: TicketsProjectConfig] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: TicketsProjectConfig].self, from: data) {
            configs = decoded
        }
    }

    func config(for projectID: String) -> TicketsProjectConfig {
        configs[projectID] ?? TicketsProjectConfig()
    }

    func set(_ config: TicketsProjectConfig, for projectID: String) {
        configs[projectID] = config
        guard let data = try? JSONEncoder().encode(configs) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Projects with the pipeline switched on and enough config to run.
    var activeProjectIDs: [String] {
        configs.filter { $0.value.enabled && $0.value.isConfigured }.map(\.key).sorted()
    }
}

/// API keys live in the login keychain, one item per project, plus one shared
/// default used when a project has no key of its own.
enum TicketsKeychain {
    private static let service = "com.tolga.ookook.tickets"
    static let sharedAccount = "deepseek:shared"

    static func deepSeekAccount(projectID: String) -> String { "deepseek:" + projectID }
    static func gitHubAccount(projectID: String) -> String { "github:" + projectID }
    static let sharedGitHubAccount = "github:shared"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func set(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(account); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// The project's own key, else the shared one.
    static func deepSeekKey(projectID: String) -> String? {
        get(deepSeekAccount(projectID: projectID)) ?? get(sharedAccount)
    }
}
