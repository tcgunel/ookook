import Foundation

/// An issue as the sidebar and the model see it.
struct TicketIssue: Identifiable, Hashable, Codable {
    let repo: String
    let number: Int
    var title: String
    var labels: [String]
    var body: String
    var url: String
    var isClosed: Bool
    var updatedAt: Date?
    var comments: Int

    var id: String { ref }
    var ref: String { "\(repo)#\(number)" }
    var type: String? { labels.first { $0.hasPrefix("type:") }.map { String($0.dropFirst(5)) } }
    var shop: String? {
        guard let range = body.range(of: #"\*\*Shop:\*\*\s*(.+)"#, options: .regularExpression) else { return nil }
        let line = body[range].replacingOccurrences(of: "**Shop:**", with: "").trimmingCharacters(in: .whitespaces)
        return line.isEmpty || line == "unknown" ? nil : line
    }
    var isHighPriority: Bool { labels.contains("priority:high") }
    var column: String {
        if isClosed { return "done" }
        for c in ["in-progress", "todo", "triage"] where labels.contains(c) { return c }
        return "other"
    }
    /// Title without the shop prefix, for compact rows.
    var shortTitle: String {
        if let shop, title.hasPrefix(shop + ": ") { return String(title.dropFirst(shop.count + 2)) }
        return title
    }
}

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noToken: return "No GitHub token. Log in with `gh auth login` or paste a token in Settings › Tickets."
        case .http(let code, let body): return "GitHub HTTP \(code): \(body.prefix(200))"
        case .badResponse: return "GitHub returned something unexpected."
        }
    }
}

/// GitHub REST, just the handful of calls the board needs.
///
/// Uses the REST API directly rather than shelling out to `gh` so it works
/// when Ookook is launched from Finder with no PATH; the token still comes
/// from `gh` when the user has not pasted one.
final class GitHubClient {
    static let labelColors: [String: String] = [
        "triage": "fbca04", "todo": "0e8a16", "in-progress": "1d76db", "ai-generated": "c5def5",
        "low-confidence": "e4e669", "shop-unknown": "f9d0c4", "priority:high": "b60205",
        "resolved-in-chat": "5319e7", "requested-again": "d93f0b",
        "type:bug": "d73a4a", "type:feature": "a2eeef", "type:xml": "bfd4f2",
        "type:integration": "c2e0c6", "type:ops": "fef2c0", "type:question": "d4c5f9",
    ]

    private(set) var token: String

    /// Resolves a credential afresh when the API rejects the current one.
    ///
    /// A `gh` login that was rotated, or a token that lost access to a repo,
    /// reads as 401, 403 or - for a private repository - 404. Without this the
    /// rejection sticks for as long as the token lives, which for the sidebar's
    /// board means silently empty columns.
    var refreshToken: (() -> String?)?

    init(token: String) { self.token = token }

    /// A client that can re-resolve its own credential for `projectID`.
    static func resolving(projectID: String) -> GitHubClient? {
        guard let token = resolveToken(projectID: projectID) else { return nil }
        let client = GitHubClient(token: token)
        client.refreshToken = {
            invalidateGhToken()
            return resolveToken(projectID: projectID)
        }
        return client
    }

    // MARK: Token discovery

    /// Keychain (project, then shared), then whatever `gh` is logged in as.
    static func resolveToken(projectID: String) -> String? {
        if let t = TicketsKeychain.get(TicketsKeychain.gitHubAccount(projectID: projectID)) { return t }
        if let t = TicketsKeychain.get(TicketsKeychain.sharedGitHubAccount) { return t }
        return ghAuthToken()
    }

    private static var cachedGhToken: (value: String, at: Date)?

    /// Drops the token remembered from `gh`, so the next resolve asks the CLI
    /// again rather than reusing a credential the API has just rejected.
    static func invalidateGhToken() {
        cachedGhToken = nil
    }

    static func ghAuthToken() -> String? {
        if let cached = cachedGhToken, Date().timeIntervalSince(cached.at) < 3600 { return cached.value }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell so Homebrew's gh is found even when launched from Finder.
        process.arguments = ["-lc", "gh auth token 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else { return nil }
        cachedGhToken = (out, Date())
        return out
    }

    // MARK: Requests

    private func request(_ method: String, _ path: String, query: [String: String] = [:],
                         body: Any? = nil) async throws -> (Data, Int) {
        var components = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }

    private func json(_ method: String, _ path: String, query: [String: String] = [:],
                      body: Any? = nil) async throws -> Any {
        let (data, code) = try await request(method, path, query: query, body: body)
        if (200 ..< 300).contains(code) { return try parse(data) }

        if let refreshToken, let fresh = refreshToken(), fresh != token {
            token = fresh
            let (retryData, retryCode) = try await request(method, path, query: query, body: body)
            guard (200 ..< 300).contains(retryCode) else {
                throw GitHubError.http(retryCode, String(data: retryData, encoding: .utf8) ?? "")
            }
            return try parse(retryData)
        }
        throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "")
    }

    private func parse(_ data: Data) throws -> Any {
        if data.isEmpty { return [:] as [String: Any] }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Labels

    /// Creates the board's labels in a repo; existing ones are left alone.
    func ensureLabels(repo: String) async {
        let existing = (try? await json("GET", "/repos/\(repo)/labels", query: ["per_page": "100"])) as? [[String: Any]] ?? []
        let have = Set(existing.compactMap { $0["name"] as? String })
        for (name, color) in Self.labelColors where !have.contains(name) {
            _ = try? await json("POST", "/repos/\(repo)/labels", body: ["name": name, "color": color])
        }
    }

    // MARK: Issues

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parse(_ item: [String: Any], repo: String) -> TicketIssue? {
        guard item["pull_request"] == nil, let number = item["number"] as? Int else { return nil }
        let labels = (item["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return TicketIssue(repo: repo, number: number,
                           title: item["title"] as? String ?? "",
                           labels: labels,
                           body: item["body"] as? String ?? "",
                           url: item["html_url"] as? String ?? "",
                           isClosed: (item["state"] as? String) == "closed",
                           updatedAt: (item["updated_at"] as? String).flatMap { Self.iso.date(from: $0) },
                           comments: item["comments"] as? Int ?? 0)
    }

    /// Open issues plus ones closed within `lookbackDays`, all AI-generated.
    func boardIssues(repo: String, lookbackDays: Int) async throws -> [TicketIssue] {
        var out: [TicketIssue] = []
        let open = try await json("GET", "/repos/\(repo)/issues",
                                  query: ["labels": "ai-generated", "state": "open", "per_page": "100"])
        out += (open as? [[String: Any]] ?? []).compactMap { parse($0, repo: repo) }
        let since = Self.iso.string(from: Date().addingTimeInterval(-Double(lookbackDays) * 86400))
        let closed = try await json("GET", "/repos/\(repo)/issues",
                                    query: ["labels": "ai-generated", "state": "closed", "since": since, "per_page": "100"])
        out += (closed as? [[String: Any]] ?? []).compactMap { parse($0, repo: repo) }
        return out
    }

    func issue(repo: String, number: Int) async throws -> TicketIssue {
        let item = try await json("GET", "/repos/\(repo)/issues/\(number)")
        guard let dict = item as? [String: Any], let issue = parse(dict, repo: repo) else { throw GitHubError.badResponse }
        return issue
    }

    /// Comment bodies with author and date, oldest first.
    func comments(repo: String, number: Int) async throws -> [String] {
        let list = try await json("GET", "/repos/\(repo)/issues/\(number)/comments", query: ["per_page": "50"])
        return (list as? [[String: Any]] ?? []).map { c in
            let who = (c["user"] as? [String: Any])?["login"] as? String ?? "?"
            let when = (c["created_at"] as? String ?? "").prefix(10)
            return "\(who) (\(when)):\n\(c["body"] as? String ?? "")"
        }
    }

    func createIssue(repo: String, title: String, body: String, labels: [String]) async throws -> TicketIssue {
        let created = try await json("POST", "/repos/\(repo)/issues",
                                     body: ["title": title, "body": body, "labels": labels])
        guard let item = created as? [String: Any], let issue = parse(item, repo: repo) else { throw GitHubError.badResponse }
        return issue
    }

    func comment(repo: String, number: Int, body: String) async throws {
        _ = try await json("POST", "/repos/\(repo)/issues/\(number)/comments", body: ["body": body])
    }

    func addLabels(repo: String, number: Int, _ labels: [String]) async throws {
        guard !labels.isEmpty else { return }
        _ = try await json("POST", "/repos/\(repo)/issues/\(number)/labels", body: ["labels": labels])
    }

    func removeLabel(repo: String, number: Int, _ label: String) async throws {
        let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
        let (data, code) = try await request("DELETE", "/repos/\(repo)/issues/\(number)/labels/\(encoded)")
        // 404 here means the label was not on the issue, which is the state we wanted.
        guard (200 ..< 300).contains(code) || code == 404 else {
            throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func setState(repo: String, number: Int, closed: Bool) async throws {
        _ = try await json("PATCH", "/repos/\(repo)/issues/\(number)", body: ["state": closed ? "closed" : "open"])
    }

    /// Moves an issue between board columns by swapping the column labels.
    func move(repo: String, number: Int, to column: String) async throws {
        for other in ["triage", "todo", "in-progress"] where other != column {
            try await removeLabel(repo: repo, number: number, other)
        }
        try await addLabels(repo: repo, number: number, [column])
    }

    // MARK: Attachments

    /// Branch chat media is committed to, kept out of the default branch so a
    /// ticket's screenshots never land in the project's own history.
    static let attachmentBranch = "ookook-attachments"

    /// Repos whose attachment branch is known to exist, so the ref is looked
    /// up once per client rather than once per file.
    private var attachmentBranchReady: Set<String> = []

    /// Creates the attachment branch if the repo does not have it yet.
    ///
    /// The probes use `request` rather than `json` on purpose: a 404 is the
    /// expected answer for a branch that is not there yet, and `json` would
    /// treat it as a rejected credential, rotate the token and retry.
    private func ensureAttachmentBranch(repo: String) async throws {
        guard !attachmentBranchReady.contains(repo) else { return }
        let existing = try? await request("GET", "/repos/\(repo)/git/ref/heads/\(Self.attachmentBranch)")
        if let existing, (200 ..< 300).contains(existing.1) {
            attachmentBranchReady.insert(repo)
            return
        }
        let info = try await json("GET", "/repos/\(repo)")
        guard let info = info as? [String: Any],
              let head = info["default_branch"] as? String else { throw GitHubError.badResponse }
        let ref = try await json("GET", "/repos/\(repo)/git/ref/heads/\(head)")
        let object = (ref as? [String: Any])?["object"] as? [String: Any]
        guard let sha = object?["sha"] as? String else { throw GitHubError.badResponse }
        _ = try await json("POST", "/repos/\(repo)/git/refs",
                           body: ["ref": "refs/heads/\(Self.attachmentBranch)", "sha": sha])
        attachmentBranchReady.insert(repo)
    }

    /// Commits one file to the attachment branch and returns the URL to embed.
    ///
    /// The `github.com/owner/repo/raw/...` form is deliberate and load-bearing.
    /// The obvious `raw.githubusercontent.com` URL renders as a broken image in
    /// a private repository - that host does not receive the reader's GitHub
    /// cookie, so it 404s for everyone who can see the issue. The same-origin
    /// form is authenticated by the session already in the browser and
    /// displays. Verified against a private repo, not assumed.
    func attach(repo: String, path: String, data: Data, message: String) async throws -> String {
        try await ensureAttachmentBranch(repo: repo)
        // Re-uploading the same path (a cursor reset, or a retry after a failed
        // batch) needs the blob's current sha, or the API answers 422. A 404
        // here is the normal first-upload case, hence `request` and not `json`.
        var body: [String: Any] = [
            "message": message,
            "content": data.base64EncodedString(),
            "branch": Self.attachmentBranch,
        ]
        if let existing = try? await request("GET", "/repos/\(repo)/contents/\(path)",
                                             query: ["ref": Self.attachmentBranch]),
           let object = try? parse(existing.0) as? [String: Any],
           let sha = object["sha"] as? String {
            body["sha"] = sha
        }
        _ = try await json("PUT", "/repos/\(repo)/contents/\(path)", body: body)
        return "https://github.com/\(repo)/raw/\(Self.attachmentBranch)/\(path)"
    }
}
