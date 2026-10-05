import Foundation
import Security
import CryptoKit
import CSQLCipher

enum ZapFastError: LocalizedError {
    case notInstalled
    case keyMissing
    case keyDenied(String)
    case cannotOpen(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "ZapFast has no local archive on this Mac. Open ZapFast and let it link, then try again."
        case .keyMissing:
            return "ZapFast's archive key is not in the keychain. Open ZapFast once so it can create the key."
        case .keyDenied(let why):
            return "macOS blocked reading ZapFast's archive key (\(why)). Approve the Keychain prompt for Ookook and choose Always Allow."
        case .cannotOpen(let why):
            return "Cannot open ZapFast's archive (\(why))."
        case .query(let why):
            return "ZapFast query failed: \(why)"
        }
    }
}

/// Where one ZapFast install keeps its data, from the app's own layout rules
/// (`me.paolino.zapfast`, older names included) plus the active account.
struct ZapFastInstall {
    let stateRoot: URL
    let accountID: String
    let accountStateDir: URL
    let accountCacheDir: URL

    var archiveURL: URL { accountStateDir.appendingPathComponent("archive.db") }
    var mediaDir: URL { accountCacheDir.appendingPathComponent("media") }

    /// The keychain account name ZapFast uses: a digest of the archive's
    /// canonical parent directory, so profiles never share a key.
    var keyIdentity: String { "archive-" + ZapFastKeychain.sha256Hex(accountStateDir) }

    static func discover() -> ZapFastInstall? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first

        for name in ["me.paolino.zapfast", "me.paolino.fastsapp", "me.paolino.fastwhatsapp"] {
            let state = support.appendingPathComponent(name, isDirectory: true)
            let cache = caches?.appendingPathComponent(name, isDirectory: true) ?? state
            guard fm.fileExists(atPath: state.path) else { continue }

            let accountIDs: [String] = {
                if let data = try? Data(contentsOf: state.appendingPathComponent("accounts.json")),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let active = json["active"] as? String, !active.isEmpty { return [active] }
                    if let order = json["order"] as? [String] { return order }
                }
                return ((try? fm.contentsOfDirectory(atPath: state.appendingPathComponent("accounts").path)) ?? []).sorted()
            }()

            for id in accountIDs {
                let accountState = state.appendingPathComponent("accounts/\(id)", isDirectory: true)
                if fm.fileExists(atPath: accountState.appendingPathComponent("archive.db").path) {
                    return ZapFastInstall(stateRoot: state, accountID: id, accountStateDir: accountState,
                                          accountCacheDir: cache.appendingPathComponent("accounts/\(id)", isDirectory: true))
                }
            }
            // Single-account layout from before accounts/<id>/ existed.
            if fm.fileExists(atPath: state.appendingPathComponent("archive.db").path) {
                return ZapFastInstall(stateRoot: state, accountID: "", accountStateDir: state, accountCacheDir: cache)
            }
        }
        return nil
    }
}

/// Reads ZapFast's archive key from the login keychain, where ZapFast (a
/// Developer-ID-signed app) stored it. The first read prompts: the user
/// clicks Always Allow once per code-signing identity. Successes are cached
/// for the process; failures cool down so a denied prompt is not hammered.
enum ZapFastKeychain {
    static let service = "rocks.zapfast.ZapFast"
    private static let lock = NSLock()
    private static var keys: [String: Data] = [:]
    private static var failures: [String: (at: Date, error: ZapFastError)] = [:]
    private static let failureCooldown: TimeInterval = 120

    static func sha256Hex(_ url: URL) -> String {
        let canonical = URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func archiveKey(_ identity: String) -> Result<Data, ZapFastError> {
        lock.lock()
        defer { lock.unlock() }
        if let key = keys[identity] { return .success(key) }
        if let failure = failures[identity], Date().timeIntervalSince(failure.at) < failureCooldown {
            return .failure(failure.error)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                let error = ZapFastError.cannotOpen("the keychain key for \(identity) is not 32 bytes")
                failures[identity] = (Date(), error)
                return .failure(error)
            }
            keys[identity] = data
            failures[identity] = nil
            return .success(data)
        case errSecItemNotFound:
            let error = ZapFastError.keyMissing
            failures[identity] = (Date(), error)
            return .failure(error)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            let error = ZapFastError.keyDenied(Self.describe(status))
            failures[identity] = (Date(), error)
            return .failure(error)
        default:
            let error = ZapFastError.keyDenied("\(Self.describe(status)), OSStatus \(status)")
            failures[identity] = (Date(), error)
            return .failure(error)
        }
    }

    /// Drops cached failures so a Settings "check again" can re-prompt.
    static func resetFailures() {
        lock.lock()
        defer { lock.unlock() }
        failures.removeAll()
    }

    private static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecUserCanceled: return "request cancelled"
        case errSecAuthFailed: return "authentication failed"
        case errSecInteractionNotAllowed: return "not allowed without user interaction"
        default: return SecCopyErrorMessageString(status, nil) as String? ?? "keychain error \(status)"
        }
    }
}

/// Read-only access to ZapFast's SQLCipher message archive.
///
/// ZapFast stores chats and messages in SQLite under `accounts/<id>/`, with
/// message content as JSON (`{"kind": "text"|"image"|...}`). The archive is
/// encrypted; the key lives in the login keychain. A plaintext archive (from
/// a build before encryption, or mid-migration) opens without a key.
final class ZapFastStore: ChatStore {
    let label = "ZapFast"
    let path: String
    private let install: ZapFastInstall
    private let key: Data?
    private var db: OpaquePointer?

    private init(install: ZapFastInstall, key: Data?) {
        self.install = install
        self.key = key
        self.path = install.archiveURL.path
    }

    deinit { close() }

    /// The install, its key, and an open probe in one step. Errors here are
    /// what the "auto" resolver and the Settings badge report.
    static func make() -> Result<ZapFastStore, ZapFastError> {
        guard let install = ZapFastInstall.discover() else { return .failure(.notInstalled) }
        let key: Data?
        if Self.isPlaintext(install.archiveURL) {
            key = nil
        } else {
            switch ZapFastKeychain.archiveKey(install.keyIdentity) {
            case .success(let data): key = data
            case .failure(let error): return .failure(error)
            }
        }
        let store = ZapFastStore(install: install, key: key)
        do {
            _ = try store.open()
            return .success(store)
        } catch let error as ZapFastError {
            return .failure(error)
        } catch {
            return .failure(.cannotOpen(error.localizedDescription))
        }
    }

    /// For the Settings badge: opens and closes, reporting where it read from.
    static func canRead() -> Result<String, ZapFastError> {
        make().map { store in
            let account = store.install.accountID.isEmpty ? "" : " (account \(store.install.accountID))"
            store.close()
            return "ZapFast\(account)"
        }
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: Opening

    private static func isPlaintext(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    private func open() throws -> OpaquePointer {
        if let db { return db }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw ZapFastError.cannotOpen("archive missing at \(path)") }
        do {
            db = try connect(path: path)
        } catch {
            // A crash can leave a WAL that needs recovery, which a read-only
            // connection may not do in place. Work on a copy instead; the
            // original stays untouched.
            guard let copy = Self.copyForRead(path) else { throw error }
            db = try connect(path: copy)
        }
        return db!
    }

    private func connect(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            let why = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw ZapFastError.cannotOpen(why)
        }
        do {
            if let key {
                let hex = key.map { String(format: "%02x", $0) }.joined()
                let rc = sqlite3_exec(handle, "PRAGMA key = \"x'\(hex)'\";", nil, nil, nil)
                if rc != SQLITE_OK {
                    throw ZapFastError.cannotOpen("the key was rejected (\(String(cString: sqlite3_errmsg(handle))))")
                }
            }
            // PRAGMA key alone does not verify; read a page before trusting it.
            var probe: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM chats", -1, &probe, nil) == SQLITE_OK else {
                throw ZapFastError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
            }
            let rc = sqlite3_step(probe)
            sqlite3_finalize(probe)
            guard rc == SQLITE_ROW else {
                throw ZapFastError.cannotOpen("unlock failed (\(String(cString: sqlite3_errmsg(handle))))")
            }
            sqlite3_exec(handle, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
            return handle
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    private static func copyForRead(_ sourcePath: String) -> String? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let digest = SHA256.hash(data: Data(sourcePath.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let dir = caches.appendingPathComponent("Ookook/ZapFastRead", isDirectory: true)
            .appendingPathComponent(String(digest), isDirectory: true)
        let target = dir.appendingPathComponent("archive.db")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(atPath: sourcePath, toPath: target.path)
            for suffix in ["-wal", "-shm"] {
                let from = sourcePath + suffix
                let to = target.path + suffix
                try? fm.removeItem(atPath: to)
                if fm.fileExists(atPath: from) { try? fm.copyItem(atPath: from, toPath: to) }
            }
            return target.path
        } catch {
            return nil
        }
    }

    // MARK: Chats

    func listChats(limit: Int = 80) throws -> [ChatSummary] {
        let db = try open()
        let sql = """
            SELECT c.id, c.name, c.kind,
                   (SELECT COUNT(*) FROM messages m WHERE m.chat = c.id),
                   c.last_activity
            FROM chats c
            ORDER BY c.last_activity DESC LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZapFastError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var chats: [ChatSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let jid = Self.text(stmt, 0) ?? ""
            let name = Self.text(stmt, 1) ?? jid
            let kind = Self.text(stmt, 2) ?? "direct"
            let count = Int(sqlite3_column_int64(stmt, 3))
            let ts = sqlite3_column_int64(stmt, 4)
            let last = ts > 0 ? Date(timeIntervalSince1970: Double(ts)) : nil
            chats.append(ChatSummary(jid: jid, name: name, isGroup: kind == "group",
                                     messageCount: count, lastMessage: last))
        }
        return chats
    }

    func hasChat(_ jid: String) throws -> Bool {
        try resolvedChatID(jid) != nil
    }

    /// The chat id ZapFast actually stores for a configured JID. WhatsApp
    /// addresses a contact by phone number or by LID depending on how the
    /// chat was learned; ZapFast keeps the bridge in its `lids` table. A
    /// project configured against the official app can therefore watch a
    /// `…@lid` chat that ZapFast archives under `…@s.whatsapp.net`, and the
    /// other way round, without the user re-adding the chat.
    func resolvedChatID(_ jid: String) throws -> String? {
        let db = try open()
        if Self.chatExists(db, jid) { return jid }
        guard let at = jid.firstIndex(of: "@") else { return nil }
        let user = String(jid[..<at])
        let domain = String(jid[jid.index(after: at)...])
        let lookFor: String
        let lookIn: String
        let otherDomain: String
        switch domain {
        case "lid": lookFor = "pn"; lookIn = "lid"; otherDomain = "s.whatsapp.net"
        case "s.whatsapp.net": lookFor = "lid"; lookIn = "pn"; otherDomain = "lid"
        default: return nil
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT \(lookFor) FROM lids WHERE \(lookIn) = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            throw ZapFastError.query(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, user, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { return nil }
        let mapped = "\(String(cString: raw))@\(otherDomain)"
        return Self.chatExists(db, mapped) ? mapped : nil
    }

    private static func chatExists(_ db: OpaquePointer, _ jid: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM chats WHERE id = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, jid, -1, transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: Messages

    func fetchMessages(chat: TicketChat, since: Date, until: Date? = nil) throws -> [ChatMessage] {
        let db = try open()
        let chatID = try resolvedChatID(chat.jid) ?? chat.jid
        var sql = "SELECT id, from_me, timestamp, content FROM messages WHERE chat = ? AND timestamp >= ?"
        if until != nil { sql += " AND timestamp < ?" }
        sql += " ORDER BY timestamp, rowid"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZapFastError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, chatID, -1, Self.transient)
        sqlite3_bind_int64(stmt, 2, Int64(since.timeIntervalSince1970.rounded(.down)))
        if let until { sqlite3_bind_int64(stmt, 3, Int64(until.timeIntervalSince1970.rounded(.down))) }
        return rows(stmt, chat: chat)
    }

    func fetchContext(chat: TicketChat, before: Date, count: Int) throws -> [ChatMessage] {
        let db = try open()
        let chatID = try resolvedChatID(chat.jid) ?? chat.jid
        let sql = "SELECT id, from_me, timestamp, content FROM messages WHERE chat = ? AND timestamp < ?"
            + " ORDER BY timestamp DESC, rowid DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZapFastError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, chatID, -1, Self.transient)
        sqlite3_bind_int64(stmt, 2, Int64(before.timeIntervalSince1970.rounded(.down)))
        sqlite3_bind_int(stmt, 3, Int32(count))
        return rows(stmt, chat: chat).reversed()
    }

    private func rows(_ stmt: OpaquePointer?, chat: TicketChat) -> [ChatMessage] {
        var out: [ChatMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Self.text(stmt, 0) ?? ""
            let fromMe = sqlite3_column_int(stmt, 1) != 0
            let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)))
            let content = Self.text(stmt, 3) ?? ""
            let parsed = Self.parse(content: content)
            out.append(ChatMessage(id: id, fromMe: fromMe, date: date, text: parsed.text,
                                   chatJID: chat.jid, mediaType: parsed.mediaType, mediaPath: parsed.mediaPath,
                                   speaker: fromMe ? "ME" : chat.speakerLabel))
        }
        return out
    }

    /// Turns one stored JSON content value into the line the model sees. The
    /// kinds are ZapFast's own (`src/model.rs`, serde's lowercase tag).
    static func parse(content: String) -> (text: String, mediaType: Int, mediaPath: String?) {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else {
            return ("[unsupported]", 0, nil)
        }
        func string(_ key: String) -> String? {
            guard let value = obj[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        var mediaPath: String?
        if let media = obj["media"] as? [String: Any], let path = media["path"] as? String, !path.isEmpty {
            mediaPath = path
        }

        switch kind {
        case "text", "interactive":
            var text = string("text") ?? ""
            if let preview = obj["preview"] as? [String: Any],
               let title = preview["title"] as? String, !title.isEmpty, !text.contains(title) {
                text += " [link: \(title)]"
            }
            return (text, 0, nil)
        case "image":
            return (Self.joined("[image]", string("caption")), 1, mediaPath)
        case "video":
            return (Self.joined("[video]", string("caption")), 2, mediaPath)
        case "audio":
            let voice = obj["voice_note"] as? Bool ?? false
            return (voice ? "[voice]" : "[audio]", 3, mediaPath)
        case "document":
            let labeled = Self.joined("[document]", string("file_name"))
            return (Self.joined(labeled, string("caption")), 8, mediaPath)
        case "sticker":
            return ("[sticker]", 14, mediaPath)
        case "sticker_pack":
            return (Self.joined("[sticker pack]", string("name")), 0, nil)
        case "location":
            let where_ = [string("name"), string("address")].compactMap { $0 }.joined(separator: ", ")
            return (Self.joined("[location]", where_.isEmpty ? nil : where_), 0, nil)
        case "livelocation":
            let ended = obj["ended"] as? Bool ?? false
            return (ended ? "[live location ended]" : "[live location]", 0, nil)
        case "contact":
            return (Self.joined("[contact]", string("display_name")), 0, nil)
        case "poll":
            return (Self.joined("[poll]", string("question")), 0, nil)
        case "revoked":
            return ("This message was deleted", 0, nil)
        case "unsupported":
            return (Self.joined("[unsupported]", string("what")), 0, nil)
        case "phoneonly":
            return ("[phone-only message]", 0, nil)
        default:
            return ("[unsupported]", 0, nil)
        }
    }

    private static func joined(_ head: String, _ tail: String?) -> String {
        guard let tail, !tail.trimmingCharacters(in: .whitespaces).isEmpty else { return head }
        return head + " " + tail
    }

    // MARK: Helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: raw)
    }
}
