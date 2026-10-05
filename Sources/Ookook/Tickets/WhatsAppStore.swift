import Foundation
import CSQLCipher

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

/// Read-only access to the official WhatsApp desktop app's Core Data store.
///
/// Text lives in ZTEXT for text (0) and link (7) messages; image and video
/// captions in ZWAMEDIAITEM.ZTITLE. Z_PK is NOT chronological (history sync
/// assigns ids out of order), so every cursor is on ZMESSAGEDATE.
final class WhatsAppStore: ChatStore {
    static let coreDataEpoch: TimeInterval = 978_307_200
    static let defaultDatabase = NSString(string:
        "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite").expandingTildeInPath
    static let mediaRoot = NSString(string:
        "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message").expandingTildeInPath

    private static let mediaTag: [Int: String] = [1: "[image]", 2: "[video]", 3: "[voice]", 8: "[document]", 14: "[sticker]"]

    let label = "WhatsApp app"
    let path: String
    private var db: OpaquePointer?

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

    func listChats(limit: Int = 80) throws -> [ChatSummary] {
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
        var chats: [ChatSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let jid = Self.text(stmt, 0) ?? ""
            let name = Self.text(stmt, 1) ?? jid
            let type = Int(sqlite3_column_int(stmt, 2))
            let count = Int(sqlite3_column_int(stmt, 3))
            let last = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4) + Self.coreDataEpoch)
            chats.append(ChatSummary(jid: jid, name: name, isGroup: type == 1,
                                     messageCount: count, lastMessage: last))
        }
        return chats
    }

    func hasChat(_ jid: String) throws -> Bool {
        let db = try open()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM ZWACHATSESSION WHERE ZCONTACTJID = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            throw WhatsAppError.query(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, jid, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: Messages

    private static let selectMessage = """
        SELECT m.Z_PK, m.ZISFROMME, m.ZMESSAGEDATE, m.ZTEXT, m.ZMESSAGETYPE, mi.ZTITLE,
               mi.ZMEDIALOCALPATH, s.ZCONTACTJID
        FROM ZWAMESSAGE m
        JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
        LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
        """
    private static let messageFilter = " AND (COALESCE(m.ZTEXT, mi.ZTITLE) IS NOT NULL OR m.ZMESSAGETYPE IN (1, 2, 3))"

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
            let relative = Self.text(stmt, 6)

            if text == nil {
                let tag = Self.mediaTag[type] ?? "[media]"
                text = (tag + " " + (title ?? "")).trimmingCharacters(in: .whitespaces)
            } else if type == 7, let title, !title.isEmpty, !(text!.contains(title)) {
                text! += " [link: \(title)]"
            }
            // Absolute up front: the pipeline no longer knows which client a
            // message came from, and both stores hand it resolvable paths.
            let mediaPath = relative.map { (Self.mediaRoot as NSString).appendingPathComponent($0) }
            out.append(ChatMessage(id: String(pk), fromMe: fromMe, date: date, text: text ?? "",
                                   chatJID: chat.jid, mediaType: type, mediaPath: mediaPath,
                                   speaker: fromMe ? "ME" : chat.speakerLabel))
        }
        return out
    }

    // MARK: Helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: raw)
    }
}
