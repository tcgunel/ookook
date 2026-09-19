import Foundation

/// Headless entry points for the ticket pipeline, so it can be checked from a
/// terminal without clicking through the app:
///
///     Ookook tickets list-chats
///     Ookook tickets import-config <wa-tickets config.json> --project <id>
///     Ookook tickets set-key <deepseek key> [--project <id>]
///     Ookook tickets backtest --project <id> --from 2026-04-20 --to 2026-05-08 [--out report.json]
///     Ookook tickets redact-test --project <id> [--hours 24]
///
/// Uses the same UserDefaults domain and Keychain items as the GUI when run
/// from inside the app bundle (`Ookook.app/Contents/MacOS/Ookook tickets ...`).
enum TicketsCLI {
    /// Returns true when the process was a CLI invocation and has finished.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 2, args[1] == "tickets" else { return false }
        let command = args.count >= 3 ? args[2] : "help"
        let options = parse(Array(args.dropFirst(3)))
        let done = TicketsWorker.CancelFlag()
        var exitCode: Int32 = 0
        Task.detached {
            do { try await run(command, options) } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            done.set()
        }
        // Keep the main run loop alive: the work hops to the main actor for
        // UserDefaults-backed stores, which would deadlock behind a semaphore.
        while !done.isSet { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        exit(exitCode)
    }

    private struct Options {
        var flags: [String: String] = [:]
        var positional: [String] = []
        func string(_ name: String) -> String? { flags[name] }
    }

    private static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { o.flags[name] = args[i + 1]; i += 2 }
                else { o.flags[name] = "true"; i += 1 }
            } else { o.positional.append(a); i += 1 }
        }
        return o
    }

    private static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private static func run(_ command: String, _ o: Options) async throws {
        switch command {
        case "list-chats":
            let store = WhatsAppStore()
            defer { store.close() }
            print("JID".padding(toLength: 32, withPad: " ", startingAt: 0) + " type   msgs  name")
            for c in try store.listChats() {
                print(c.jid.padding(toLength: 32, withPad: " ", startingAt: 0) + " "
                      + (c.isGroup ? "group" : "1:1").padding(toLength: 6, withPad: " ", startingAt: 0)
                      + String(format: " %5d  ", c.messageCount) + c.name)
            }

        case "import-config":
            guard let path = o.positional.first, let id = o.string("project") else {
                throw CLIError("usage: import-config <config.json> --project <project id>")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError("bad json") }
            var config = await MainActor.run { TicketsConfigStore().config(for: id) }
            if let jid = json["chat_jid"] as? String, !jid.isEmpty, !config.chats.contains(where: { $0.jid == jid }) {
                let store = WhatsAppStore()
                let name = (try? store.listChats(limit: 500))?.first { $0.jid == jid }?.name ?? jid
                store.close()
                config.chats.append(TicketChat(jid: jid, name: name))
            }
            config.repos = (json["repos"] as? [[String: Any]] ?? []).map {
                TicketRepo(repo: $0["repo"] as? String ?? "", localPath: $0["local_path"] as? String ?? "",
                           hint: $0["hint"] as? String ?? "")
            }
            if let v = json["poll_seconds"] as? Int { config.pollSeconds = v }
            if let v = json["batch_gap_seconds"] as? Int { config.batchGapSeconds = v }
            if let v = json["context_messages"] as? Int { config.contextMessages = v }
            if let v = json["min_confidence"] as? Double { config.minConfidence = v }
            if let v = json["low_confidence_below"] as? Double { config.lowConfidenceBelow = v }
            if let v = json["issue_lookback_days"] as? Int { config.issueLookbackDays = v }
            if let v = json["labels"] as? [String] { config.labels = v }
            if let v = json["language_hint"] as? String { config.languageHint = v }
            if let v = json["deepseek_model"] as? String { config.model = v }
            let final = config
            await MainActor.run { TicketsConfigStore().set(final, for: id) }
            print("imported: \(config.chats.count) chat(s), \(config.repos.count) repo(s) for \(id) (pipeline left \(config.enabled ? "enabled" : "disabled"))")

        case "set-key":
            guard let key = o.positional.first else { throw CLIError("usage: set-key <key> [--project <id>]") }
            let account = o.string("project").map { TicketsKeychain.deepSeekAccount(projectID: $0) } ?? TicketsKeychain.sharedAccount
            TicketsKeychain.set(key, account: account)
            print("saved to keychain as \(account)")

        case "backtest":
            guard let id = o.string("project"), let from = o.string("from").flatMap(day), let to = o.string("to").flatMap(day) else {
                throw CLIError("usage: backtest --project <id> --from YYYY-MM-DD --to YYYY-MM-DD [--out file]")
            }
            let config = await MainActor.run { TicketsConfigStore().config(for: id) }
            guard config.isConfigured else { throw CLIError("project \(id) has no chats/repos configured") }
            guard let key = o.string("key") ?? TicketsKeychain.deepSeekKey(projectID: id) else { throw DeepSeekError.noKey }
            let deepSeek = DeepSeekClient(apiKey: key, model: config.model, baseURL: config.baseURL)
            let report = await TicketPipeline.backtest(config: config, deepSeek: deepSeek, from: from, to: to,
                                                       progress: { print($0); fflush(stdout) }, isCancelled: { false })
            print("\n\(report.issues.count) issues from \(report.messages) msgs / \(report.batches) batches")
            print(report.usage.summary)
            let byType = Dictionary(grouping: report.issues, by: \.type).mapValues(\.count)
            print(byType.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            if let out = o.string("out") {
                let issues: [[String: Any]] = report.issues.map { i in
                    ["ref": i.ref, "title": i.fullTitle, "type": i.type, "shop": i.shop ?? NSNull(),
                     "priority": i.priority, "confidence": i.confidence, "labels": i.labels,
                     "created": ISO8601DateFormatter().string(from: i.created), "body": i.body,
                     "events": i.events.map { ["text": $0.text, "labels": $0.labels] }]
                }
                let payload: [String: Any] = ["messages": report.messages, "batches": report.batches,
                                              "usage": ["calls": report.usage.calls, "prompt": report.usage.promptTokens,
                                                        "cache_hit": report.usage.cacheHitTokens, "completion": report.usage.completionTokens],
                                              "issues": issues, "log": report.log]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: out))
                print("report -> \(out)")
            }

        case "redact-test":
            guard let id = o.string("project") else { throw CLIError("usage: redact-test --project <id> [--hours N]") }
            let hours = Double(o.string("hours") ?? "24") ?? 24
            let config = await MainActor.run { TicketsConfigStore().config(for: id) }
            let store = WhatsAppStore()
            defer { store.close() }
            for chat in config.chats {
                var messages = try store.fetchMessages(chat: chat, since: Date().addingTimeInterval(-hours * 3600))
                Redactor.redactSequence(&messages)
                for m in messages { print(m.formatted) }
            }

        default:
            print("commands: list-chats, import-config, set-key, backtest, redact-test")
        }
    }

    struct CLIError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
