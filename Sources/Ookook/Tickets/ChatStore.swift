import Foundation
import Vision
import ImageIO

/// Which local client's message history the ticket pipeline reads.
///
/// `auto` follows whichever client is actually live: both ZapFast and the
/// official app record the same conversations while linked, so the freshest
/// database is the one the user (and WhatsApp's sync) is currently feeding.
enum TicketMessageSource: String, Codable, CaseIterable, Identifiable {
    case auto
    case whatsapp
    case zapfast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .whatsapp: return "WhatsApp app"
        case .zapfast: return "ZapFast"
        }
    }
}

/// One chat message as the pipeline sees it. `text` is the raw text; the
/// redactor rewrites it before anything leaves the machine.
///
/// `id` is stable within its source and is what cursors, OCR/transcript
/// caches and ticket state key on: the official app uses its Z_PK, ZapFast
/// the WhatsApp message id. `mediaPath` is an absolute path - each store
/// resolves its own layout before handing the message over.
struct ChatMessage {
    let id: String
    let fromMe: Bool
    let date: Date
    var text: String
    let chatJID: String
    /// WhatsApp-style type: 1 image, 2 video, 3 voice, 8 document, 14 sticker.
    let mediaType: Int
    /// Absolute path of the media file, when the message carries one.
    let mediaPath: String?
    /// What the model sees before the colon: ME or the coworker's name.
    var speaker: String

    /// Message line as sent to the model and quoted in issue bodies.
    var formatted: String {
        "[\(id)] \(Self.stamp.string(from: date)) \(speaker): \(text)"
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

/// One chat as the settings picker lists it.
struct ChatSummary: Identifiable, Hashable {
    let jid: String
    let name: String
    let isGroup: Bool
    let messageCount: Int
    let lastMessage: Date?
    /// Which client the row came from, when more than one is readable.
    var sourceLabel: String?
    var id: String { jid }
}

enum ChatStoreError: LocalizedError {
    case noSource(String)

    var errorDescription: String? {
        switch self {
        case .noSource(let why): return why
        }
    }
}

/// Read-only access to one client's local message history.
protocol ChatStore: AnyObject {
    /// Human-readable name of the client, for logs and the picker.
    var label: String { get }
    func close()
    func listChats(limit: Int) throws -> [ChatSummary]
    func hasChat(_ jid: String) throws -> Bool
    /// Messages in one chat with `since <= date < until`, oldest first.
    func fetchMessages(chat: TicketChat, since: Date, until: Date?) throws -> [ChatMessage]
    /// The `count` messages before `date`, oldest first, for context.
    func fetchContext(chat: TicketChat, before: Date, count: Int) throws -> [ChatMessage]
}

extension ChatStore {
    func listChats() throws -> [ChatSummary] { try listChats(limit: 80) }
    func fetchMessages(chat: TicketChat, since: Date) throws -> [ChatMessage] {
        try fetchMessages(chat: chat, since: since, until: nil)
    }
}

/// File-level helpers both stores share: both hand the pipeline absolute
/// paths, so media resolution does not need to know where a message came from.
enum ChatMedia {
    /// Absolute URL of a media file, or nil when the message has no path or
    /// the client has already purged the file.
    static func url(_ absolutePath: String?) -> URL? {
        guard let absolutePath, absolutePath.hasPrefix("/") else { return nil }
        return FileManager.default.fileExists(atPath: absolutePath) ? URL(fileURLWithPath: absolutePath) : nil
    }

    /// The file extension a media path should keep when it is committed to a
    /// repo: the original one where it is plainly safe, otherwise the usual
    /// extension for that message type. Returns nil for anything that would
    /// not survive a commit path, so a hostile filename cannot steer the write.
    static func attachmentExtension(_ path: String?, mediaType: Int) -> String? {
        let original = URL(fileURLWithPath: path ?? "").pathExtension.lowercased()
        let safe = original.count <= 5 && original.allSatisfy { $0.isLetter || $0.isNumber }
        if safe, !original.isEmpty { return original }
        return [1: "jpg", 2: "mp4", 8: "pdf"][mediaType]
    }

    /// Text in a screenshot, via Vision. Local and on-device; the caller
    /// caches per message, so an image both clients later purge stays read.
    static func recognizeText(at url: URL, limit: Int = 700) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["tr-TR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: " | ").prefix(limit))
    }

    /// Applies OCR to the image messages, caching per message id, so a
    /// screenshot either client later purges keeps its text. Shared by the
    /// pipeline and the headless commands.
    static func applyOCR(to messages: [ChatMessage], enabled: Bool,
                         cache: inout [String: String]) -> [ChatMessage] {
        guard enabled else { return messages }
        return messages.map { message in
            guard message.mediaType == 1 else { return message }
            var message = message
            let text: String
            if let cached = cache[message.id] {
                text = cached
            } else {
                text = url(message.mediaPath).map { recognizeText(at: $0) } ?? ""
                cache[message.id] = text
            }
            if !text.isEmpty { message.text += " (screenshot text: \(text))" }
            return message
        }
    }
}

/// Reads from the primary client, falling back per chat when the primary has
/// never seen that conversation (a freshly linked ZapFast has less history
/// than the app it replaces).
final class CompositeChatStore: ChatStore {
    let primary: any ChatStore
    let backup: any ChatStore?

    init(primary: any ChatStore, backup: any ChatStore?) {
        self.primary = primary
        self.backup = backup
    }

    var label: String {
        guard let backup else { return primary.label }
        return "\(primary.label) (fallback: \(backup.label))"
    }

    func close() {
        primary.close()
        backup?.close()
    }

    private func store(with chat: String) -> (any ChatStore)? {
        if (try? primary.hasChat(chat)) == true { return primary }
        if let backup, (try? backup.hasChat(chat)) == true { return backup }
        return nil
    }

    func listChats(limit: Int) throws -> [ChatSummary] {
        var rows: [String: ChatSummary] = [:]
        var firstError: Error?
        for store in [primary, backup].compactMap({ $0 }) {
            do {
                for var chat in try store.listChats(limit: limit) {
                    chat.sourceLabel = store.label
                    if let existing = rows[chat.jid],
                       (existing.lastMessage ?? .distantPast) >= (chat.lastMessage ?? .distantPast) {
                        continue
                    }
                    rows[chat.jid] = chat
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if rows.isEmpty, let firstError { throw firstError }
        return rows.values.sorted { ($0.lastMessage ?? .distantPast) > ($1.lastMessage ?? .distantPast) }
    }

    func hasChat(_ jid: String) throws -> Bool {
        store(with: jid) != nil
    }

    func fetchMessages(chat: TicketChat, since: Date, until: Date?) throws -> [ChatMessage] {
        if let store = store(with: chat.jid) {
            return try store.fetchMessages(chat: chat, since: since, until: until)
        }
        // Neither client has the chat: let the primary produce its own
        // "no such chat" emptiness or error, so callers keep one behaviour.
        return try primary.fetchMessages(chat: chat, since: since, until: until)
    }

    func fetchContext(chat: TicketChat, before: Date, count: Int) throws -> [ChatMessage] {
        if let store = store(with: chat.jid) {
            return try store.fetchContext(chat: chat, before: before, count: count)
        }
        return try primary.fetchContext(chat: chat, before: before, count: count)
    }
}

/// Returned when nothing is readable, so every call fails with the combined
/// reason instead of a misleading half-truth from one client.
final class UnavailableChatStore: ChatStore {
    let label = "none"
    private let why: String

    init(why: String) { self.why = why }
    func close() {}
    func listChats(limit: Int) throws -> [ChatSummary] { throw ChatStoreError.noSource(why) }
    func hasChat(_ jid: String) throws -> Bool { throw ChatStoreError.noSource(why) }
    func fetchMessages(chat: TicketChat, since: Date, until: Date?) throws -> [ChatMessage] {
        throw ChatStoreError.noSource(why)
    }
    func fetchContext(chat: TicketChat, before: Date, count: Int) throws -> [ChatMessage] {
        throw ChatStoreError.noSource(why)
    }
}

/// Picks the client to read from. With `auto`, both clients are probed and
/// the one whose newest message is actually newer wins; ZapFast breaks ties,
/// because it receives the same conversations without a browser engine in
/// the middle. A per-project setting pins the choice when the guess is wrong.
enum ChatStoreResolver {
    static func resolve(source: TicketMessageSource, log: @escaping (String) -> Void = { _ in }) -> any ChatStore {
        switch source {
        case .whatsapp:
            return WhatsAppStore()
        case .zapfast:
            switch ZapFastStore.make() {
            case .success(let store): return store
            case .failure(let error): return UnavailableChatStore(why: error.localizedDescription)
            }
        case .auto:
            let zapfast = ZapFastStore.make()
            let whatsapp = WhatsAppStore()
            let whatsappReadable = (try? whatsapp.listChats(limit: 1)) != nil

            switch (zapfast, whatsappReadable) {
            case (.success(let zap), true):
                let zapLatest = (try? zap.listChats(limit: 1))?.first?.lastMessage ?? .distantPast
                let whatsappLatest = (try? whatsapp.listChats(limit: 1))?.first?.lastMessage ?? .distantPast
                // Ties (both receive the same messages seconds apart) go to
                // ZapFast; a client that stopped updating falls behind and
                // hands the pipeline back to the app that still receives.
                let zapFirst = zapLatest >= whatsappLatest.addingTimeInterval(-60)
                log("auto source: reading \(zapFirst ? "ZapFast" : "WhatsApp app") (ZapFast \(Self.describe(zapLatest)), WhatsApp \(Self.describe(whatsappLatest)))")
                return CompositeChatStore(primary: zapFirst ? zap : whatsapp, backup: zapFirst ? whatsapp : zap)
            case (.success(let zap), false):
                return zap
            case (.failure, true):
                return whatsapp
            case (.failure(let zapError), false):
                let waError = WhatsAppStore.canRead().failureMessage
                return UnavailableChatStore(why: """
                    No readable message source. \(zapError.localizedDescription) WhatsApp app: \(waError)
                    """)
            }
        }
    }

    private static func describe(_ date: Date?) -> String {
        guard let date else { return "never" }
        return ChatMessage.stamp.string(from: date)
    }
}

extension Result where Failure == WhatsAppError {
    var failureMessage: String {
        if case .failure(let error) = self { return error.localizedDescription }
        return "readable"
    }
}
