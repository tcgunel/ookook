import Foundation

/// Every searchable row in Settings › Tickets: its pane, the label it shows
/// and the other words someone might type for it ("whisper" for
/// transcription, "cursor" for re-read). Rows render behind `shows(id)`, so
/// the sidebar's match counts and the visible rows come from one list.
enum TicketsSettingsIndex {
    struct Entry {
        let id: String
        let pane: TicketsSettingsPane
        let title: String
        let keywords: String
    }

    static let entries: [Entry] = [
        Entry(id: "enabled", pane: .status, title: "Turn WhatsApp chats into GitHub tickets", keywords: "on off enable disable pipeline running status"),
        Entry(id: "run", pane: .status, title: "Run Now / Dry Run", keywords: "run dry classify now manual trigger"),
        Entry(id: "reread", pane: .status, title: "Re-read last hours", keywords: "reset cursor reread backfill again reprocess hours"),
        Entry(id: "log", pane: .status, title: "Log", keywords: "log output history errors"),

        Entry(id: "source", pane: .sources, title: "Read messages from", keywords: "zapfast whatsapp client automatic source database"),
        Entry(id: "access", pane: .sources, title: "Access", keywords: "full disk access keychain permission readable zapfast whatsapp"),
        Entry(id: "chats", pane: .sources, title: "Chats", keywords: "whatsapp group contact add chat conversation customer shop"),

        Entry(id: "repos", pane: .tickets, title: "Repositories", keywords: "github repo repository clone local path hint target"),
        Entry(id: "labels", pane: .tickets, title: "Labels on new tickets", keywords: "label triage ai-generated issue"),
        Entry(id: "autoApprove", pane: .tickets, title: "Auto-approve confident tickets", keywords: "approve todo confidence threshold automatic claude"),
        Entry(id: "neverFile", pane: .tickets, title: "Never file", keywords: "ignore skip types bug feature xml integration ops question"),

        Entry(id: "ocr", pane: .media, title: "Read text in screenshots", keywords: "ocr vision image screenshot photo text"),
        Entry(id: "transcribe", pane: .media, title: "Transcribe voice notes and videos", keywords: "whisper transcription audio voice video speech"),
        Entry(id: "whisperModel", pane: .media, title: "Whisper model", keywords: "whisper model large turbo small tiny download"),
        Entry(id: "language", pane: .media, title: "Spoken language", keywords: "language turkish english auto detect whisper"),
        Entry(id: "mediaWait", pane: .media, title: "Wait for media to download", keywords: "wait download zapfast missing video screenshot minutes"),
        Entry(id: "attach", pane: .media, title: "Attach files to tickets", keywords: "attach attachment upload branch privacy file size limit"),

        Entry(id: "activeHours", pane: .schedule, title: "Active hours", keywords: "hours night schedule time quiet off"),
        Entry(id: "notify", pane: .schedule, title: "Notifications", keywords: "notify notification banner sound alert"),
        Entry(id: "pricing", pane: .schedule, title: "DeepSeek peak hours", keywords: "cost price pricing peak off-peak deepseek billing"),

        Entry(id: "deepseekKey", pane: .keys, title: "DeepSeek key", keywords: "api key deepseek secret token project"),
        Entry(id: "sharedKey", pane: .keys, title: "Shared DeepSeek key", keywords: "api key deepseek shared fallback global"),
        Entry(id: "githubToken", pane: .keys, title: "GitHub token", keywords: "github token gh auth pat credential"),

        Entry(id: "model", pane: .advanced, title: "Model", keywords: "deepseek llm model chat classifier"),
        Entry(id: "baseURL", pane: .advanced, title: "Base URL", keywords: "endpoint api url host"),
        Entry(id: "languageHint", pane: .advanced, title: "Language hint", keywords: "language prompt turkish english instructions"),
        Entry(id: "poll", pane: .advanced, title: "Poll every", keywords: "poll interval seconds frequency"),
        Entry(id: "quiet", pane: .advanced, title: "Wait for quiet", keywords: "quiet silence wait seconds"),
        Entry(id: "batchGap", pane: .advanced, title: "Batch gap", keywords: "batch gap minutes group messages"),
        Entry(id: "context", pane: .advanced, title: "Context messages", keywords: "context history earlier messages"),
        Entry(id: "minConfidence", pane: .advanced, title: "Minimum confidence", keywords: "confidence threshold drop minimum"),
        Entry(id: "lowConfidence", pane: .advanced, title: "Low-confidence label below", keywords: "confidence label low-confidence threshold"),
        Entry(id: "lookback", pane: .advanced, title: "Closed issues stay visible", keywords: "closed issues lookback days duplicate"),
        Entry(id: "mapFiles", pane: .advanced, title: "Map files per repo", keywords: "file map repo files limit"),

        Entry(id: "backtest", pane: .backtest, title: "Backtest", keywords: "backtest replay history dates simulate test"),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    /// Every word of the query appears in the label, the keywords or the
    /// pane name. Case- and diacritic-insensitive, so "turkce" finds Turkish
    /// labels and "İ" folds like "i".
    static func matches(_ id: String, query: String) -> Bool {
        guard let entry = byID[id] else { return true }
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = fold("\(entry.title) \(entry.keywords) \(entry.pane.title)")
        return words.allSatisfy { haystack.contains($0) }
    }

    static func matchCount(_ pane: TicketsSettingsPane, query: String) -> Int {
        entries.filter { $0.pane == pane && matches($0.id, query: query) }.count
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
