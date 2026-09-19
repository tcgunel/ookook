import Foundation

/// Everything that leaves the machine (DeepSeek) or lands in GitHub goes
/// through here. The chat routinely carries panel passwords, FTP/API
/// credentials, one-time SMS codes and login details in URL parameters, from
/// both sides, so this is deliberately eager: a masked ordinary word costs
/// nothing, a leaked password does.
enum Redactor {
    private static let credWords = #"(?:şifre\w*|sifre\w*|parola\w*|password|passwd|pass|pwd|pw|kullanıcı adı|kullanici adi|k\.adı|k\.adi|username|user|login|token|api ?key|apikey|secret|anahtar\w*|client ?secret|kid değeri|k değeri|müşteri no|customer ?no|hesap no)"#

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants; a typo here is a programming error worth a crash at launch.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let email = re(#"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#)
    private static let phone = re(#"(?:\+90|0)?\s?5\d{2}[\s-]?\d{3}[\s-]?\d{2}[\s-]?\d{2}\b"#)
    private static let urlParam = re(#"([?&](?:p|pass|password|pw|token|key|apikey|api_key|secret|auth)=)[^&\s]+"#, .caseInsensitive)
    private static let keyValue = re(#"((?<![<\w])"# + credWords + #"\b\s*[:=]?\s*)(\S+)"#, .caseInsensitive)
    private static let jsonKeyValue = re(#"("(?:password|pass|secret|token|apikey|api_key|key)"\s*:\s*")[^"]*(")"#, .caseInsensitive)
    private static let token = re(#"\b(?=\w*\d)(?=\w*[A-Za-z])[A-Za-z0-9_]{20,}\b"#)
    private static let base64 = re(#"(?<![\w/.\-])(?=[\w\-]*\d)(?=[\w\-]*[a-z])(?=[\w\-]*[A-Z])[A-Za-z0-9_\-]{40,}={0,2}(?![\w/.\-])"#)
    private static let hex32 = re(#"\b[0-9a-f]{32,}\b|\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, .caseInsensitive)
    private static let otp = re(#"^\s*\d{4,8}\s*$"#)
    private static let passwordish = re(#"^(?=\S{4,40}$)(?:(?=.*[A-Za-z])(?=.*\d)|(?=.*[!@#$%^&*_+{}\[\]|\\~`<>=]))\S+$"#)
    private static let trailingPunct = re(#"[.,:;!?)\]]+$"#)
    private static let credContext = re(#"\b(?:"# + credWords + #"|giriş\w*|login|admin|ftp|bilgileri şöyle|bilgiler bunlar|bilgileri atayım)\b"#, .caseInsensitive)
    private static let longDigits = re(#"^\d{6,}$"#)

    private static func full(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: full(s)) != nil
    }

    /// Masks secrets inside one piece of text.
    static func redact(_ text: String) -> String {
        if text.isEmpty { return text }
        var t = jsonKeyValue.stringByReplacingMatches(in: text, range: full(text), withTemplate: "$1<secret>$2")
        t = urlParam.stringByReplacingMatches(in: t, range: full(t), withTemplate: "$1<secret>")
        t = replaceKeyValue(in: t)
        t = email.stringByReplacingMatches(in: t, range: full(t), withTemplate: "<email>")
        t = phone.stringByReplacingMatches(in: t, range: full(t), withTemplate: "<phone>")
        t = hex32.stringByReplacingMatches(in: t, range: full(t), withTemplate: "<id>")
        t = token.stringByReplacingMatches(in: t, range: full(t), withTemplate: "<token>")
        t = base64.stringByReplacingMatches(in: t, range: full(t), withTemplate: "<token>")
        return t
    }

    /// "şifre: abc" -> "şifre: <secret>", but leave "şifre <secret>" and
    /// "şifre: 'x'" style values alone (already masked, or quoted structure).
    private static func replaceKeyValue(in s: String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in keyValue.matches(in: s, range: full(s)) {
            let value = ns.substring(with: m.range(at: 2))
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if let first = value.first, "<\"':=".contains(first) {
                out += ns.substring(with: m.range)
            } else {
                out += ns.substring(with: m.range(at: 1)) + "<secret>"
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Redacts a run of messages in order. Bare one-line secrets that follow a
    /// credential-context message (an email, "şifre", "giriş bilgileri", ...)
    /// are masked whole, as are bare 4-8 digit codes.
    static func redactSequence(_ messages: inout [ChatMessage]) {
        var ctx = 0
        for i in messages.indices {
            let raw = messages[i].text
            if matches(credContext, raw) || matches(email, raw) { ctx = 4 }
            var t = redact(raw)
            let body = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if matches(otp, body) {
                t = "<code>"
            } else if ctx > 0 {
                t = t.split(separator: " ", omittingEmptySubsequences: false)
                    .map { maskInCredentialContext(String($0)) }
                    .joined(separator: " ")
            }
            messages[i].text = t
            if ctx > 0 { ctx -= 1 }
        }
    }

    private static func maskInCredentialContext(_ word: String) -> String {
        let core = trailingPunct.stringByReplacingMatches(in: word, range: full(word), withTemplate: "")
        if word.hasPrefix("http") || word.hasPrefix("[") || word.hasPrefix("(") || word.contains("<") || core.isEmpty {
            return word
        }
        return (matches(passwordish, core) || matches(longDigits, core)) ? "<secret>" : word
    }
}
