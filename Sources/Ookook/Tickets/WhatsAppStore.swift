import Foundation
import SQLite3
import Vision
import ImageIO

/// One chat message as the pipeline sees it. `text` is the raw text; the
/// redactor rewrites it before anything leaves the machine.
struct ChatMessage {
    let pk: Int
    let fromMe: Bool
    let date: Date
    var text: String
    let chatJID: String
    /// What the model sees before the colon: ME or the coworker's name.
    var speaker: String

    /// Message line as sent to the model and quoted in issue bodies.
    var formatted: String {
        "[\(pk)] \(Self.stamp.string(from: date)) \(speaker): \(text)"
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

struct WhatsAppChat: Identifiable, Hashable {
    let jid: String
    let name: String
    let isGroup: Bool
    let messageCount: Int
    let lastMessage: Date?
    var id: String { jid }
}

enum WhatsAppError: LocalizedError {
    case missing(String)
    case cannotOpen(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): return "WhatsApp database not found at \(path)."
        case .cannotOpen(let why): return "Cannot open the WhatsApp database (\(why)). Grant Ookook Full Disk Access in System Settings › Privacy & Security."
        case .query(let why): return "WhatsApp query failed: \(why)"
        }
    }
}

/// Read-only access to the WhatsApp desktop app's Core Data store.
///
/// Text lives in ZTEXT for text (0) and link (7) messages; image and video
/// captions in ZWAMEDIAITEM.ZTITLE. Z_PK is NOT chronological (history sync
/// assigns ids out of order), so every cursor is on ZMESSAGEDATE.
final class WhatsAppStore {
    static let coreDataEpoch: TimeInterval = 978_307_200
    static let defaultDatabase = NSString(string:
        "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite").expandingTildeInPath
    static let mediaRoot = NSString(string:
        "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message").expandingTildeInPath

    private static let mediaTag: [Int: String] = [1: "[image]", 2: "[video]", 3: "[voice]", 8: "[document]", 14: "[sticker]"]

    let path: String
    private var db: OpaquePointer?

    /// OCR text per message pk. Bound to the pipeline state so a screenshot
    /// WhatsApp later purges from disk keeps its text.
    var ocrCache: [String: String] = [:]
    var ocrEnabled = true

    init(path: String = WhatsAppStore.defaultDatabase) {
        self.path = path
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func open() throws -> OpaquePointer {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: path) else { throw WhatsAppError.missing(path) }
        var handle: OpaquePointer?
        let uri = "file:" + path + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            let why = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw WhatsAppError.cannotOpen(why)
        }
        // A read that fails with "authorization denied" only surfaces on the
        // first query, so probe now and turn it into the FDA hint.
        var probe: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM ZWACHATSESSION", -1, &probe, nil) != SQLITE_OK {
            let why = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw WhatsAppError.cannotOpen(why)
        }
        let rc = sqlite3_step(probe)
        sqlite3_finalize(probe)
        if rc != SQLITE_ROW {
            let why = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw WhatsAppError.cannotOpen(why)
        }
        db = handle
        return handle
    }

    /// Whether the database can be read at all - the settings pane shows this
    /// next to the Full Disk Access button.
    static func canRead(path: String = defaultDatabase) -> Result<Void, WhatsAppError> {
        let store = WhatsAppStore(path: path)
        defer { store.close() }
        do { _ = try store.open(); return .success(()) }
        catch let error as WhatsAppError { return .failure(error) }
        catch { return .failure(.cannotOpen(error.localizedDescription)) }
    }

    // MARK: Chats

    func listChats(limit: Int = 80) throws -> [WhatsAppChat] {
        let db = try open()
        let sql = """
            SELECT ZCONTACTJID, ZPARTNERNAME, ZSESSIONTYPE, ZMESSAGECOUNTER, ZLASTMESSAGEDATE
            FROM ZWACHATSESSION
            WHERE (ZREMOVED = 0 OR ZREMOVED IS NULL) AND ZCONTACTJID IS NOT NULL
            ORDER BY ZLASTMESSAGEDATE DESC LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WhatsAppError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var chats: [WhatsAppChat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let jid = Self.text(stmt, 0) ?? ""
            let name = Self.text(stmt, 1) ?? jid
            let type = Int(sqlite3_column_int(stmt, 2))
            let count = Int(sqlite3_column_int(stmt, 3))
            let last = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4) + Self.coreDataEpoch)
            chats.append(WhatsAppChat(jid: jid, name: name, isGroup: type == 1,
                                      messageCount: count, lastMessage: last))
        }
        return chats
    }

    // MARK: Messages

    private static let selectMessage = """
        SELECT m.Z_PK, m.ZISFROMME, m.ZMESSAGEDATE, m.ZTEXT, m.ZMESSAGETYPE, mi.ZTITLE,
               mi.ZMEDIALOCALPATH, s.ZCONTACTJID
        FROM ZWAMESSAGE m
        JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
        LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
        """
    private static let messageFilter = " AND (COALESCE(m.ZTEXT, mi.ZTITLE) IS NOT NULL OR m.ZMESSAGETYPE = 1)"

    /// Messages in one chat with `since <= date < until`, oldest first.
    func fetchMessages(chat: TicketChat, since: Date, until: Date? = nil) throws -> [ChatMessage] {
        let db = try open()
        var sql = Self.selectMessage + " WHERE s.ZCONTACTJID = ? AND m.ZMESSAGEDATE >= ?" + Self.messageFilter
        if until != nil { sql += " AND m.ZMESSAGEDATE < ?" }
        sql += " ORDER BY m.ZMESSAGEDATE, m.Z_PK"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WhatsAppError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, chat.jid, -1, Self.transient)
        sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970 - Self.coreDataEpoch)
        if let until { sqlite3_bind_double(stmt, 3, until.timeIntervalSince1970 - Self.coreDataEpoch) }
        return try rows(stmt, chat: chat)
    }

    /// The `n` messages before `date`, oldest first, for context.
    func fetchContext(chat: TicketChat, before: Date, count: Int) throws -> [ChatMessage] {
        let db = try open()
        let sql = Self.selectMessage + " WHERE s.ZCONTACTJID = ? AND m.ZMESSAGEDATE < ?" + Self.messageFilter
            + " ORDER BY m.ZMESSAGEDATE DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WhatsAppError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, chat.jid, -1, Self.transient)
        sqlite3_bind_double(stmt, 2, before.timeIntervalSince1970 - Self.coreDataEpoch)
        sqlite3_bind_int(stmt, 3, Int32(count))
        return try rows(stmt, chat: chat).reversed()
    }

    private func rows(_ stmt: OpaquePointer?, chat: TicketChat) throws -> [ChatMessage] {
        var out: [ChatMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = Int(sqlite3_column_int64(stmt, 0))
            let fromMe = sqlite3_column_int(stmt, 1) != 0
            let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2) + Self.coreDataEpoch)
            var text = Self.text(stmt, 3)
            let type = Int(sqlite3_column_int(stmt, 4))
            let title = Self.text(stmt, 5)
            let mediaPath = Self.text(stmt, 6)

            if text == nil {
                let tag = Self.mediaTag[type] ?? "[media]"
                text = (tag + " " + (title ?? "")).trimmingCharacters(in: .whitespaces)
            } else if type == 7, let title, !title.isEmpty, !(text!.contains(title)) {
                text! += " [link: \(title)]"
            }
            if type == 1 {
                let shot = ocr(pk: pk, relativePath: mediaPath)
                if !shot.isEmpty { text! += " (screenshot text: \(shot))" }
            }
            out.append(ChatMessage(pk: pk, fromMe: fromMe, date: date, text: text ?? "",
                                   chatJID: chat.jid,
                                   speaker: fromMe ? "ME" : chat.speakerLabel))
        }
        return out
    }

    // MARK: OCR

    /// Text in a screenshot, via Vision, cached per message. WhatsApp only keeps
    /// recent media on disk, so an image that is gone yields "" and stays "".
    func ocr(pk: Int, relativePath: String?, limit: Int = 700) -> String {
        let key = String(pk)
        if let cached = ocrCache[key] { return cached }
        var text = ""
        if ocrEnabled, let relativePath, !relativePath.isEmpty {
            let full = (Self.mediaRoot as NSString).appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: full) {
                text = String(Self.recognizeText(at: URL(fileURLWithPath: full)).prefix(limit))
            }
        }
        ocrCache[key] = text
        return text
    }

    static func recognizeText(at url: URL) -> String {
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
        return lines.joined(separator: " | ")
    }

    // MARK: Helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: raw)
    }
}
