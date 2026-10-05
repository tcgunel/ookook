import Foundation

/// Where one chat's reading position is. Message ids are not chronological,
/// so the cursor is a timestamp plus the ids already handled at that exact
/// second. State files from before the ZapFast support stored the WhatsApp
/// app's integer pks; decoding maps them onto the string ids used now.
struct ChatCursor: Codable, Equatable {
    var cursor: TimeInterval?
    var doneIDs: [String] = []

    enum CodingKeys: String, CodingKey { case cursor, doneIDs, donePks }

    init(cursor: TimeInterval? = nil, doneIDs: [String] = []) {
        self.cursor = cursor
        self.doneIDs = doneIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decodeIfPresent(TimeInterval.self, forKey: .cursor)
        if let ids = try c.decodeIfPresent([String].self, forKey: .doneIDs) {
            doneIDs = ids
        } else if let pks = try c.decodeIfPresent([Int].self, forKey: .donePks) {
            doneIDs = pks.map(String.init)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(cursor, forKey: .cursor)
        try c.encode(doneIDs, forKey: .doneIDs)
    }
}

/// Per-project pipeline state, one JSON file in Application Support.
struct TicketsState: Codable {
    var cursors: [String: ChatCursor] = [:]
    /// message id -> issue ref, so a re-classified message never opens a second ticket
    var issues: [String: String] = [:]
    /// "ref|kind|ids" -> ISO date, so a comment is posted once
    var comments: [String: String] = [:]
    var ocr: [String: String] = [:]
    /// message id -> transcript, so a purged voice note keeps its text
    var transcripts: [String: String] = [:]
    var usage = DeepSeekUsage()
    /// Which client the cursors were built against. When it changes, message
    /// ids stop matching and the cursors step over their last second.
    var lastSource: String?

    init() {}

    enum CodingKeys: String, CodingKey { case cursors, issues, comments, ocr, transcripts, usage, lastSource }

    // Tolerates missing keys, like the config does: a state file written by an
    // older build must not decode to nothing, which would reset every cursor.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursors = try c.decodeIfPresent([String: ChatCursor].self, forKey: .cursors) ?? [:]
        issues = try c.decodeIfPresent([String: String].self, forKey: .issues) ?? [:]
        comments = try c.decodeIfPresent([String: String].self, forKey: .comments) ?? [:]
        ocr = try c.decodeIfPresent([String: String].self, forKey: .ocr) ?? [:]
        transcripts = try c.decodeIfPresent([String: String].self, forKey: .transcripts) ?? [:]
        usage = try c.decodeIfPresent(DeepSeekUsage.self, forKey: .usage) ?? DeepSeekUsage()
        lastSource = try c.decodeIfPresent(String.self, forKey: .lastSource)
    }

    static func url(projectID: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Ookook/Tickets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = projectID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return dir.appendingPathComponent(String(safe).suffix(120) + ".json")
    }

    static func load(projectID: String) -> TicketsState {
        guard let url = url(projectID: projectID), let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(TicketsState.self, from: data) else { return TicketsState() }
        return state
    }

    func save(projectID: String) {
        guard let url = Self.url(projectID: projectID) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// What the model returns for one request in the chat.
struct ClassifiedTask {
    var type: String
    var repo: String?
    var shop: String?
    var title: String
    var body: String
    var priority: String
    var likelyFiles: [String]
    var confidence: Double
    var sourcePks: [String]
    var existingIssue: String?
    var xml: [String: Any]?

    static let types = ["bug", "feature", "xml", "integration", "ops", "question"]

    init?(_ raw: [String: Any]) {
        guard let title = raw["title"] as? String, !title.isEmpty else { return nil }
        let t = (raw["type"] as? String)?.lowercased() ?? "bug"
        type = Self.types.contains(t) ? t : "bug"
        repo = raw["repo"] as? String
        shop = (raw["shop"] as? String).flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 }
        self.title = title
        body = raw["body"] as? String ?? ""
        priority = (raw["priority"] as? String)?.lowercased() ?? "medium"
        likelyFiles = raw["likely_files"] as? [String] ?? []
        confidence = (raw["confidence"] as? NSNumber)?.doubleValue ?? 0
        sourcePks = (raw["source_pks"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.stringValue ?? ($0 as? String) }
        existingIssue = (raw["existing_issue"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        xml = raw["xml"] as? [String: Any]
    }
}

struct ClassifiedUpdate {
    var issue: String
    var kind: String
    var note: String
    var sourcePks: [String]

    init?(_ raw: [String: Any]) {
        guard let issue = raw["issue"] as? String, let kind = raw["kind"] as? String,
              ["resolved", "followup", "info"].contains(kind) else { return nil }
        self.issue = issue
        self.kind = kind
        note = raw["note"] as? String ?? ""
        sourcePks = (raw["source_pks"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.stringValue ?? ($0 as? String) }
    }
}

/// The compact issue view handed to the model.
struct BoardIssueSummary {
    var ref: String
    var title: String
    var type: String?
    var shop: String?
    var closed: Bool
}

/// Where tickets go. The real one talks to GitHub; the backtest one keeps
/// everything in memory.
protocol TicketBoard: AnyObject {
    var isDryRun: Bool { get }
    func ensureLabels() async
    func openIssues() async -> [BoardIssueSummary]
    func create(task: ClassifiedTask, title: String, body: String, labels: [String], repo: String, batch: [ChatMessage]) async -> String?
    /// Markdown to append to a new issue's body, uploading whatever media the
    /// task was raised from. Empty when there is nothing to attach.
    func attachments(for messages: [ChatMessage], repo: String) async -> String
    /// `media` is the same run of messages the comment quotes, so an update's
    /// screenshot lands on the comment that mentions it rather than only on
    /// the ticket that started it.
    func comment(ref: String, text: String, addLabels: [String], media: [ChatMessage]) async -> Bool
}

final class GitHubBoard: TicketBoard {
    let client: GitHubClient
    let config: TicketsProjectConfig
    let isDryRun: Bool
    let log: (String) -> Void
    private var cache: [BoardIssueSummary]?
    private var cacheAt = Date.distantPast
    private var pending: [BoardIssueSummary] = []
    private var labelsDone = false
    /// "repo#pk" -> URL already committed on this poll, so one screenshot
    /// cited by a new ticket and by a follow-up is uploaded once and linked
    /// from both. Scoped per poll: the board is rebuilt every cycle, so this
    /// can never outlive the branch it describes.
    private var uploadedMedia: [String: String] = [:]
    /// Issues created in this run, for notifications and the sidebar.
    private(set) var created: [TicketIssue] = []

    init(client: GitHubClient, config: TicketsProjectConfig,
         dryRun: Bool, log: @escaping (String) -> Void) {
        self.client = client
        self.config = config
        self.isDryRun = dryRun
        self.log = log
    }

    /// Image, video and document messages. Voice notes and stickers are not
    /// evidence in a bug report, and a voice note has no image to show.
    static let attachableMedia: Set<Int> = [1, 2, 8]

    func ensureLabels() async {
        guard !isDryRun, !labelsDone else { return }
        labelsDone = true
        for repo in config.repos { await client.ensureLabels(repo: repo.repo) }
    }

    func openIssues() async -> [BoardIssueSummary] {
        if let cache, Date().timeIntervalSince(cacheAt) < 300 { return cache + pending }
        var items: [BoardIssueSummary] = []
        for repo in config.repos {
            do {
                let issues = try await client.boardIssues(repo: repo.repo, lookbackDays: config.issueLookbackDays)
                items += issues.map {
                    BoardIssueSummary(ref: $0.ref, title: $0.title, type: $0.type, shop: $0.shop, closed: $0.isClosed)
                }
            } catch {
                log("issue list for \(repo.repo) failed: \(error.localizedDescription)")
            }
        }
        cache = items
        cacheAt = Date()
        return items + pending
    }

    func create(task: ClassifiedTask, title: String, body: String, labels: [String], repo: String, batch: [ChatMessage]) async -> String? {
        if isDryRun {
            let ref = "\(repo)#DRY\(pending.count + 1)"
            pending.append(BoardIssueSummary(ref: ref, title: task.title, type: task.type, shop: task.shop, closed: false))
            log("WOULD CREATE \(ref) [\(labels.joined(separator: ", "))] \(title)")
            return ref
        }
        do {
            let issue = try await client.createIssue(repo: repo, title: title, body: body, labels: labels)
            created.append(issue)
            cache = nil
            return issue.ref
        } catch {
            log("issue create failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Uploads the media behind a run of messages and returns the markdown to
    /// append to an issue body or a comment.
    ///
    /// Deliberately best-effort: a missing or oversized file is logged and
    /// skipped, never fatal. A ticket without its screenshot is still a
    /// ticket, and the OCR text is already in the body.
    func attachments(for messages: [ChatMessage], repo: String) async -> String {
        guard config.attachMedia, !isDryRun else { return "" }
        let wanted = messages.filter { Self.attachableMedia.contains($0.mediaType) }
        guard !wanted.isEmpty else { return "" }
        let budget = max(0, config.maxAttachmentsPerPost)
        let maxBytes = max(1, config.maxAttachmentMB) * 1_048_576
        func embed(_ url: String, _ message: ChatMessage) -> String {
            "![chat media \(ChatMessage.stamp.string(from: message.date))](<\(url)>)"
        }
        var links: [String] = []
        for message in wanted.prefix(budget) {
            // Already sent on this poll - a message cited by both a new issue
            // and a later follow-up. The link still belongs in both places; the
            // file does not need committing twice.
            if let seen = uploadedMedia["\(repo)#\(message.id)"] {
                links.append(embed(seen, message))
                continue
            }
            guard let local = ChatMedia.url(message.mediaPath) else {
                log("  media #\(message.id) skipped: the client already purged it")
                continue
            }
            guard let data = try? Data(contentsOf: local) else {
                log("  media #\(message.id) skipped: cannot read \(local.lastPathComponent)")
                continue
            }
            if data.count > maxBytes {
                log("  media #\(message.id) skipped: \(data.count / 1_048_576) MB is over the "
                    + "\(config.maxAttachmentMB) MB cap")
                continue
            }
            guard let ext = ChatMedia.attachmentExtension(message.mediaPath, mediaType: message.mediaType) else {
                log("  media #\(message.id) skipped: no usable file extension")
                continue
            }
            // Keyed by message id, so a re-run replaces its own file instead of
            // piling up near-duplicates.
            let stem = message.id.filter { $0.isLetter || $0.isNumber }.prefix(64)
            let path = "attachments/wa-\(stem).\(ext)"
            do {
                let url = try await client.attach(repo: repo, path: path, data: data,
                                                  message: "chat media from message \(message.id)")
                uploadedMedia["\(repo)#\(message.id)"] = url
                links.append(embed(url, message))
            } catch {
                log("  media #\(message.id) upload failed: \(error.localizedDescription)")
            }
        }
        if wanted.count > budget {
            log("  \(wanted.count - budget) more attachment(s) in this batch not uploaded (cap is \(budget))")
        }
        guard !links.isEmpty else { return "" }
        return "\n**Attachments**\n" + links.joined(separator: "\n\n") + "\n\n"
    }

    func comment(ref: String, text: String, addLabels: [String], media: [ChatMessage] = []) async -> Bool {
        if isDryRun {
            // Worth naming the media: a dry run is how the attach toggle gets
            // checked without pushing a single pixel off the machine.
            let attachable = media.filter { Self.attachableMedia.contains($0.mediaType) }
            let note = attachable.isEmpty ? "" : " +\(attachable.count) attachment(s)"
            log("WOULD COMMENT on \(ref) \(addLabels): \(text.prefix(160))\(note)")
            return true
        }
        guard let (repo, number) = Self.split(ref) else { return false }
        do {
            // Uploaded against the repo that actually holds the issue, which is
            // not always the project's first repo - a follow-up can land on a
            // ticket in ksyazilim/crm while the task routed to kolaysiparis.
            // The links are appended after redaction so they survive verbatim.
            let links = await attachments(for: media, repo: repo)
            try await client.comment(repo: repo, number: number, body: text + links)
            try? await client.addLabels(repo: repo, number: number, addLabels)
            return true
        } catch {
            log("comment on \(ref) failed: \(error.localizedDescription)")
            return false
        }
    }

    static func split(_ ref: String) -> (String, Int)? {
        let parts = ref.split(separator: "#", maxSplits: 1)
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        return (String(parts[0]), n)
    }
}

/// Backtest board: nothing touches GitHub.
final class MemoryBoard: TicketBoard {
    struct Issue {
        var ref: String
        var title: String
        var fullTitle: String
        var type: String
        var shop: String?
        var priority: String
        var confidence: Double
        var created: Date
        var labels: [String]
        var body: String
        var events: [(text: String, labels: [String])] = []
    }

    let isDryRun = false
    private(set) var issues: [Issue] = []

    func ensureLabels() async {}

    func openIssues() async -> [BoardIssueSummary] {
        issues.map { BoardIssueSummary(ref: $0.ref, title: $0.title, type: $0.type, shop: $0.shop, closed: false) }
    }

    func create(task: ClassifiedTask, title: String, body: String, labels: [String], repo: String, batch: [ChatMessage]) async -> String? {
        let ref = "\(repo)#\(issues.count + 1)"
        issues.append(Issue(ref: ref, title: task.title, fullTitle: title, type: task.type, shop: task.shop,
                            priority: task.priority, confidence: task.confidence,
                            created: batch.first?.date ?? Date(), labels: labels, body: body))
        return ref
    }

    /// A backtest never touches the repo, so there is nothing to upload.
    func attachments(for messages: [ChatMessage], repo: String) async -> String { "" }

    func comment(ref: String, text: String, addLabels: [String], media: [ChatMessage] = []) async -> Bool {
        guard let i = issues.firstIndex(where: { $0.ref == ref }) else { return false }
        issues[i].events.append((text, addLabels))
        return true
    }
}

/// The classifier loop: batches messages, asks DeepSeek, files tickets.
final class TicketPipeline {
    let projectID: String
    let config: TicketsProjectConfig
    let store: any ChatStore
    let deepSeek: DeepSeekClient
    let board: TicketBoard
    let log: (String) -> Void
    let transcriber: Transcriber?
    var state: TicketsState

    /// Set by the worker when the user turns the pipeline off mid-run.
    var isCancelled: () -> Bool = { false }

    init(projectID: String, config: TicketsProjectConfig, store: any ChatStore, deepSeek: DeepSeekClient,
         board: TicketBoard, state: TicketsState, transcriber: Transcriber? = nil, log: @escaping (String) -> Void) {
        self.projectID = projectID
        self.config = config
        self.store = store
        self.deepSeek = deepSeek
        self.board = board
        self.state = state
        self.transcriber = transcriber
        self.log = log
    }

    private func persist() {
        state.usage = deepSeek.usage
        state.save(projectID: projectID)
    }

    /// Fills in voice/video transcripts before a batch goes to the model. The
    /// cache means a message is transcribed once, no matter how often it is
    /// quoted back as context.
    private func transcribeMedia(in batch: inout [ChatMessage], context: inout [ChatMessage]) async {
        guard config.transcribeMedia, let transcriber else { return }
        let language = config.transcribeLanguage.isEmpty ? nil : config.transcribeLanguage
        await transcriber.attachTranscripts(to: &batch, cache: &state.transcripts, language: language)
        await transcriber.attachTranscripts(to: &context, cache: &state.transcripts, language: language)
        persist()
    }

    /// Screenshot text for image messages, cached in state per message id, so
    /// a screenshot either client later purges keeps its text. Vision runs
    /// here rather than in the stores because the cache outlives them.
    private func withOCR(_ messages: [ChatMessage]) -> [ChatMessage] {
        ChatMedia.applyOCR(to: messages, enabled: config.ocrScreenshots, cache: &state.ocr)
    }

    // MARK: Repo map

    private static var repoMapCache: [String: (text: String, at: Date)] = [:]

    /// Combined file list of all repos, cached for a day and kept byte-stable
    /// so DeepSeek's prefix cache keeps hitting.
    func repoMap() -> String {
        let key = config.repos.map { $0.repo + "|" + $0.localPath }.joined(separator: ";")
        if let cached = Self.repoMapCache[key], Date().timeIntervalSince(cached.at) < 86400 { return cached.text }
        let skip = ["node_modules/", "vendor/", ".lock", ".png", ".jpg", ".svg", ".min.",
                    "dist/", "build/", "storage/", "public/build", ".map"]
        var parts: [String] = []
        for repo in config.repos {
            var files = Self.gitFiles(at: repo.localPath).filter { f in !skip.contains { f.contains($0) } }
            files = Array(files.prefix(config.maxMapFilesPerRepo))
            parts.append("## \(repo.repo) (\(repo.hint))\n" + (files.isEmpty ? "(file list unavailable)" : files.joined(separator: "\n")))
        }
        let text = parts.joined(separator: "\n\n")
        Self.repoMapCache[key] = (text, Date())
        return text
    }

    private static func gitFiles(at path: String) -> [String] {
        let expanded = NSString(string: path).expandingTildeInPath
        guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", expanded, "ls-files"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(separator: "\n").map(String.init)
    }

    // MARK: Prompt

    static let systemPrompt = """
    You turn a work chat between a developer (ME) and their non-technical coworkers (named in capitals,
    e.g. ALI) into engineering tickets and ticket updates. The company runs an e-commerce platform with many
    customer shops ("mağaza"). You get: recent context, the NEW messages, the list of OPEN ISSUES, and
    file lists of the repos.

    TASKS. From the NEW messages, extract every distinct actionable request. Requests come from the coworkers;
    ME's messages are answers, questions back, or resolutions. Be exhaustive: a batch often contains
    several unrelated items (a feature ask, then a customer's error report, then a UI bug). Emit one
    ticket per distinct issue. Skip greetings, small talk, scheduling, thanks, and requests that are
    already answered or that the coworker says they handled themselves.
    A message that names a shop plus an error, an integration, or a customer complaint IS a task.
    "[image]" messages are screenshots; "(screenshot text: ...)" is OCR of them. Screenshots sent right
    after a report are evidence for THAT report: fold them in, never open a ticket for a screenshot alone.
    A short or vague complaint is still a ticket: describe what is known, list what to clarify, lower confidence.

    TYPE. Classify each task:
      bug          something in the platform is broken (code change needed)
      feature      new capability or behaviour change (code change needed)
      xml          define/map/fix a supplier XML product feed for a shop (operational: converter + import)
      integration  set up or debug a carrier / payment gateway / marketplace account for a shop
      ops          operational action: create user, change commission, delete member, DNS/IP, cache, server
      question     "how does X work", "is X possible", needs an answer not a change

    SHOP. Nearly every request concerns one shop. Find its name in the new messages or the context
    (coworkers often send it as a bare word, before or after the report). Use null if truly unknown.
    For type xml also fill "xml": {"source_url", "price_field", "brand_rule", "markup_percent", "notes"} with null for unknowns.

    PRIORITY. high when: "acil", customer threatening to complain/leave ("şikayete gider", "kriz",
    "müşteri kaybederiz"), "söz verdik", multiple customers waiting, payment or checkout broken, site down.
    low for cosmetic or "acelesi yok". Otherwise medium.

    EXISTING ISSUES. If a task is the same request as an OPEN ISSUE (same shop and problem, or a recurring
    feature ask), set "existing_issue" to that issue ref instead of describing it anew; still fill title/body briefly.

    UPDATES. Separately, report links between NEW messages and OPEN ISSUES:
      resolved  ME says it is fixed/deployed/defined ("düzeldi", "tanımlandı", "eşleşti", "güncelleme attım",
                "yayına aldım", "tamam", "bu tamam") or the coworker confirms ("oldu", "düzelmiş", "eline sağlık" after a fix)
      followup  the coworker nudges or asks for status ("bakabildin mi", "var mı gelişme", "çalışıyor musun", "ne zaman")
      info      new details, credentials handed over (never repeat secrets), scope change, customer decision
    Only reference refs that appear in OPEN ISSUES.

    Respond with JSON only:
    {"tasks": [{"type": "bug|feature|xml|integration|ops|question",
                "repo": "owner/name from the file list headers",
                "shop": "shop name or null",
                "title": "short imperative title (no shop name; it is a separate field)",
                "body": "what is asked, acceptance criteria, what to clarify; quote key original lines",
                "priority": "low|medium|high",
                "likely_files": ["paths from the repo map"],
                "confidence": 0.0-1.0,
                "source_pks": [message ids],
                "existing_issue": "owner/name#N or null",
                "xml": null or {...}}],
     "updates": [{"issue": "owner/name#N", "kind": "resolved|followup|info", "note": "one line", "source_pks": [ids]}]}
    Return {"tasks": [], "updates": []} when nothing applies. Never include passwords, codes or tokens in any field.
    """

    func classify(batch: [ChatMessage], context: [ChatMessage], repoMap: String,
                  openIssues: [BoardIssueSummary]) async throws -> ([ClassifiedTask], [ClassifiedUpdate]) {
        let issuesText = openIssues.isEmpty ? "(none)" : openIssues.map { i in
            "- \(i.ref) [\(i.type ?? "?")] \(i.title)" + (i.shop.map { " (shop: \($0))" } ?? "") + (i.closed ? " (closed)" : "")
        }.joined(separator: "\n")
        let content = Self.systemPrompt + "\n\n" + config.languageHint + "\n\n"
            + "REPO FILE LISTS:\n\(repoMap)\n\n"
            + "OPEN ISSUES:\n\(issuesText)\n\n"
            + "RECENT CONTEXT (already handled, for reference only):\n" + context.map(\.formatted).joined(separator: "\n")
            + "\n\nNEW MESSAGES:\n" + batch.map(\.formatted).joined(separator: "\n")
        let result = try await deepSeek.completeJSON(system: content)
        let tasks = (result["tasks"] as? [[String: Any]] ?? []).compactMap(ClassifiedTask.init)
        let updates = (result["updates"] as? [[String: Any]] ?? []).compactMap(ClassifiedUpdate.init)
        return (tasks, updates)
    }

    // MARK: Batching

    static func batches(_ messages: [ChatMessage], gap: TimeInterval) -> [[ChatMessage]] {
        var out: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        for m in messages {
            if let last = current.last, m.date.timeIntervalSince(last.date) > gap {
                out.append(current)
                current = []
            }
            current.append(m)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    func pickRepo(_ task: ClassifiedTask) -> String {
        let names = config.repos.map(\.repo)
        let want = (task.repo ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if !want.isEmpty, let hit = names.first(where: { $0.lowercased() == want || $0.lowercased().contains(want) }) {
            return hit
        }
        return names.first ?? "owner/name"
    }

    /// The messages a task was raised from: the ids the model cited, or the
    /// whole batch when it cited none. Shared so the quoted block and the
    /// attached media can never disagree about what the source was.
    static func sourceMessages(_ task: ClassifiedTask, in batch: [ChatMessage]) -> [ChatMessage] {
        let src = Set(task.sourcePks)
        return batch.filter { src.isEmpty || src.contains($0.id) }
    }

    /// The blockquote an issue body or comment carries.
    static func quote(_ messages: [ChatMessage]) -> String {
        messages.map { "> " + $0.formatted }.joined(separator: "\n")
    }

    static func issueBody(task: ClassifiedTask, batch: [ChatMessage]) -> String {
        let quoted = quote(sourceMessages(task, in: batch))
        let files = task.likelyFiles.prefix(10).map { "- `\($0)`" }.joined(separator: "\n")
        var xmlBlock = ""
        if task.type == "xml" {
            let xml = task.xml ?? [:]
            xmlBlock = "\n**XML mapping**\n" + ["source_url", "price_field", "brand_rule", "markup_percent", "notes"].map { k in
                let v = xml[k]
                let s = (v as? String) ?? (v as? NSNumber).map { "\($0)" } ?? "?"
                return "- \(k): \(s == "<null>" ? "?" : s)"
            }.joined(separator: "\n") + "\n"
        }
        let body = """
        \(task.body)

        **Shop:** \(task.shop ?? "unknown")
        **Type:** \(task.type)
        **Priority:** \(task.priority)
        **Confidence:** \(String(format: "%.2f", task.confidence))
        \(xmlBlock)
        **Likely files**
        \(files.isEmpty ? "- (unknown)" : files)

        **Source (WhatsApp)**
        \(quoted)

        """
        return Redactor.redact(body)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Labels a new ticket gets. Auto-approval swaps `triage` for `todo`.
    func labels(for task: ClassifiedTask) -> [String] {
        var labels = config.labels
        labels.append("type:\(task.type)")
        if task.priority == "high" { labels.append("priority:high") }
        if task.shop == nil { labels.append("shop-unknown") }
        if task.confidence < config.lowConfidenceBelow { labels.append("low-confidence") }
        if task.confidence >= config.autoApproveAbove, config.autoApproveTypes.contains(task.type),
           let i = labels.firstIndex(of: "triage") {
            labels[i] = "todo"
        }
        return labels
    }

    // MARK: Processing

    func process(batch rawBatch: [ChatMessage], context rawContext: [ChatMessage], repoMap: String) async {
        var batch = rawBatch
        var context = rawContext
        Redactor.redactSequence(&context)
        Redactor.redactSequence(&batch)
        guard let first = batch.first, let last = batch.last else { return }

        let openIssues = await board.openIssues()
        let tasks: [ClassifiedTask]
        let updates: [ClassifiedUpdate]
        do {
            (tasks, updates) = try await classify(batch: batch, context: context, repoMap: repoMap, openIssues: openIssues)
        } catch {
            log("classify failed: \(error.localizedDescription)")
            return
        }
        let range = "\(ChatMessage.stamp.string(from: first.date))..\(ChatMessage.stamp.string(from: last.date).suffix(5))"
        log("batch \(range) \(batch.count) msgs -> \(tasks.count) task(s), \(updates.count) update(s)")
        let known = Set(openIssues.map(\.ref))
        let day = Self.day.string(from: first.date)

        for task in tasks {
            if config.ignoredTypes.contains(task.type) {
                log("  skip (\(task.type) ignored): \(task.title)")
                continue
            }
            let src = task.sourcePks
            if !src.isEmpty, src.allSatisfy({ state.issues[$0] != nil }) {
                log("  skip (already ticketed \(state.issues[src[0]] ?? "")): \(task.title)")
                continue
            }
            if task.confidence < config.minConfidence {
                log("  skip (conf \(String(format: "%.2f", task.confidence))): \(task.title)")
                continue
            }
            if let existing = task.existingIssue, known.contains(existing) {
                let pks = Set(task.sourcePks)
                let cited = batch.filter { pks.contains($0.id) }
                let note = Redactor.redact("Requested again in chat (\(day)):\n\n\(Self.quote(cited))")
                if await board.comment(ref: existing, text: note, addLabels: ["requested-again"], media: cited) {
                    log("  linked to \(existing): \(task.title)")
                    for pk in src { state.issues[pk] = existing }
                }
                continue
            }
            let repo = pickRepo(task)
            let title = task.shop.map { "\($0): \(task.title)" } ?? task.title
            // issueBody redacts, so the uploaded links are appended after it:
            // they are ours, and have to survive verbatim.
            let media = await board.attachments(for: Self.sourceMessages(task, in: batch), repo: repo)
            let body = Self.issueBody(task: task, batch: batch) + media
            if let ref = await board.create(task: task, title: title, body: body, labels: labels(for: task), repo: repo, batch: batch) {
                log("  created \(ref): \(title)")
                for pk in (src.isEmpty ? batch.map(\.id) : src) { state.issues[pk] = ref }
            }
        }

        for update in updates {
            guard known.contains(update.issue) else { continue }
            let key = "\(update.issue)|\(update.kind)|\(update.sourcePks.joined(separator: ","))"
            if state.comments[key] != nil { continue }
            if update.kind == "resolved", state.comments.keys.contains(where: { $0.hasPrefix("\(update.issue)|resolved|") }) {
                continue // one resolution note per issue is enough
            }
            let pks = Set(update.sourcePks)
            let cited = batch.filter { pks.contains($0.id) }
            let head = ["resolved": "Chat suggests this is resolved",
                        "followup": "Follow-up in chat",
                        "info": "New information in chat"][update.kind] ?? update.kind
            let text = Redactor.redact("\(head) (\(day)): \(update.note)\n\n\(Self.quote(cited))")
            let labels = ["resolved": ["resolved-in-chat"], "followup": ["requested-again"], "info": []][update.kind] ?? []
            if await board.comment(ref: update.issue, text: text, addLabels: labels, media: cited) {
                log("  \(update.kind) -> \(update.issue)")
                state.comments[key] = ISO8601DateFormatter().string(from: Date())
            }
        }
    }

    /// New messages in one chat since its cursor, minus the ones already handled.
    func newMessages(chat: TicketChat) throws -> [ChatMessage] {
        guard let cursor = state.cursors[chat.jid]?.cursor else { return [] }
        let done = Set(state.cursors[chat.jid]?.doneIDs ?? [])
        let messages = try store.fetchMessages(chat: chat, since: Date(timeIntervalSince1970: cursor))
            .filter { !done.contains($0.id) }
        return withOCR(messages)
    }

    private func advanceCursor(chat: TicketChat, batch: [ChatMessage]) {
        guard let last = batch.last else { return }
        let lastTs = last.date.timeIntervalSince1970
        var c = state.cursors[chat.jid] ?? ChatCursor()
        if let cur = c.cursor, abs(cur - lastTs) < 1e-6 {
            c.doneIDs = Array(Set(c.doneIDs).union(batch.map(\.id))).sorted()
        } else {
            c.cursor = lastTs
            c.doneIDs = batch.filter { $0.date.timeIntervalSince1970 == lastTs }.map(\.id)
        }
        state.cursors[chat.jid] = c
    }

    /// Carries the cursors over when the reading source changes: ids differ
    /// between clients, and every message at a cursor's exact second was part
    /// of the batch that advanced it, so the cursor steps one second forward
    /// instead of re-reading a tail whose ids can never match.
    private func adoptSourceIfChanged() {
        guard !board.isDryRun, state.lastSource != store.label else { return }
        // A state file from before this bookkeeping (no lastSource) was written
        // by one of the clients too, so the same last-second skip applies.
        for (jid, var cursor) in state.cursors {
            guard let ts = cursor.cursor else { continue }
            cursor.cursor = ts + 1
            cursor.doneIDs = []
            state.cursors[jid] = cursor
        }
        state.lastSource = store.label
        persist()
    }

    /// One poll over every chat. Returns how many batches were classified.
    @discardableResult
    func runOnce(waitForQuiet: Bool = true) async throws -> Int {
        adoptSourceIfChanged()
        var handled = 0
        var touched = false
        for chat in config.chats {
            if state.cursors[chat.jid]?.cursor == nil {
                // First sight of this chat: start from now rather than churning through history.
                state.cursors[chat.jid] = ChatCursor(cursor: Date().timeIntervalSince1970, doneIDs: [])
                touched = true
                log("\(chat.name): cursor set to now; use Reset to backfill")
                continue
            }
            let messages = try newMessages(chat: chat)
            guard let last = messages.last else { continue }
            let quiet = min(Double(config.quietSeconds), Double(config.batchGapSeconds))
            if waitForQuiet, Date().timeIntervalSince(last.date) < quiet { continue }
            let hour = Calendar.current.component(.hour, from: Date())
            if !(config.activeHoursStart ..< max(config.activeHoursStart + 1, config.activeHoursEnd)).contains(hour) { continue }

            let map = repoMap()
            await board.ensureLabels()
            for batch in Self.batches(messages, gap: Double(config.batchGapSeconds)) {
                if isCancelled() { break }
                var batch = batch
                var context = withOCR((try? store.fetchContext(chat: chat, before: batch[0].date, count: config.contextMessages)) ?? [])
                await transcribeMedia(in: &batch, context: &context)
                await process(batch: batch, context: context, repoMap: map)
                handled += 1
                if !board.isDryRun {
                    advanceCursor(chat: chat, batch: batch)
                    persist()
                }
            }
        }
        if touched, !board.isDryRun { persist() }
        return handled
    }

    /// Moves every chat cursor back `hours`, so the next poll re-reads that window.
    func resetCursors(hours: Double) {
        let ts = Date().timeIntervalSince1970 - hours * 3600
        for chat in config.chats { state.cursors[chat.jid] = ChatCursor(cursor: ts, doneIDs: []) }
        persist()
    }

    // MARK: Backtest

    struct BacktestReport {
        var messages = 0
        var batches = 0
        var issues: [MemoryBoard.Issue] = []
        var usage = DeepSeekUsage()
        var log: [String] = []
    }

    /// Replays [start, end) against an in-memory board. No GitHub, no state changes.
    static func backtest(config: TicketsProjectConfig, deepSeek: DeepSeekClient, transcriber: Transcriber? = nil,
                         from start: Date, to end: Date,
                         progress: @escaping (String) -> Void, isCancelled: @escaping () -> Bool) async -> BacktestReport {
        var report = BacktestReport()
        let board = MemoryBoard()
        let store = ChatStoreResolver.resolve(source: config.messageSource) { line in
            report.log.append(line)
            progress(line)
        }
        defer { store.close() }
        let pipeline = TicketPipeline(projectID: "backtest", config: config, store: store, deepSeek: deepSeek,
                                      board: board, state: TicketsState(), transcriber: transcriber, log: { line in
            report.log.append(line)
            progress(line)
        })
        pipeline.isCancelled = isCancelled
        let map = pipeline.repoMap()
        for chat in config.chats {
            guard let fetched = try? store.fetchMessages(chat: chat, since: start, until: end) else {
                progress("\(chat.name): cannot read messages from \(store.label)")
                continue
            }
            let messages = pipeline.withOCR(fetched)
            let batches = Self.batches(messages, gap: Double(config.batchGapSeconds))
            report.messages += messages.count
            report.batches += batches.count
            progress("\(chat.name): \(messages.count) msgs in \(batches.count) batches")
            for batch in batches {
                if isCancelled() { break }
                var batch = batch
                var context = pipeline.withOCR((try? store.fetchContext(chat: chat, before: batch[0].date, count: config.contextMessages)) ?? [])
                await pipeline.transcribeMedia(in: &batch, context: &context)
                await pipeline.process(batch: batch, context: context, repoMap: map)
            }
        }
        report.issues = board.issues
        report.usage = deepSeek.usage
        return report
    }
}
