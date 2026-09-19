import Foundation

/// Token accounting for one pipeline run, shown in the sidebar status line.
struct DeepSeekUsage: Codable, Equatable {
    var calls = 0
    var promptTokens = 0
    var cacheHitTokens = 0
    var completionTokens = 0

    var cacheHitPercent: Int {
        promptTokens == 0 ? 0 : Int((100.0 * Double(cacheHitTokens) / Double(promptTokens)).rounded())
    }

    var summary: String {
        guard calls > 0 else { return "no API calls" }
        return "\(calls) calls, \(promptTokens) prompt tokens (\(cacheHitPercent)% cache hit), \(completionTokens) completion"
    }

    mutating func add(_ other: DeepSeekUsage) {
        calls += other.calls
        promptTokens += other.promptTokens
        cacheHitTokens += other.cacheHitTokens
        completionTokens += other.completionTokens
    }
}

enum DeepSeekError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "No DeepSeek API key. Add one in Settings › Tickets."
        case .http(let code, let body): return "DeepSeek HTTP \(code): \(body.prefix(200))"
        case .badResponse(let why): return "DeepSeek returned something unexpected: \(why)"
        }
    }
}

/// Minimal chat-completions client. JSON mode, low temperature, three tries.
final class DeepSeekClient {
    let apiKey: String
    let model: String
    let baseURL: String
    var usage = DeepSeekUsage()

    init(apiKey: String, model: String, baseURL: String) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    /// Sends one system message and returns the parsed JSON object it answers with.
    func completeJSON(system content: String, maxTokens: Int = 3000) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: baseURL.trimmingTrailingSlash + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": content]],
            "response_format": ["type": "json_object"],
            "temperature": 0.1,
            "max_tokens": maxTokens,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = DeepSeekError.badResponse("no attempts")
        for attempt in 1 ... 3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200 ..< 300).contains(code) else {
                    throw DeepSeekError.http(code, String(data: data, encoding: .utf8) ?? "")
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let text = message["content"] as? String,
                      let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else { throw DeepSeekError.badResponse("missing choices or non-JSON content") }
                let u = json["usage"] as? [String: Any] ?? [:]
                usage.calls += 1
                usage.promptTokens += u["prompt_tokens"] as? Int ?? 0
                usage.cacheHitTokens += u["prompt_cache_hit_tokens"] as? Int ?? 0
                usage.completionTokens += u["completion_tokens"] as? Int ?? 0
                return parsed
            } catch {
                lastError = error
                // A 4xx other than rate limiting will not get better by waiting.
                if case DeepSeekError.http(let code, _) = error, code != 429, code < 500 { throw error }
                if attempt < 3 { try? await Task.sleep(nanoseconds: UInt64(5 * attempt) * 1_000_000_000) }
            }
        }
        throw lastError
    }
}

extension String {
    var trimmingTrailingSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
