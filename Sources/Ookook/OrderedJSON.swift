import Foundation

/// A JSON tree that remembers the order its keys were written in.
///
/// `JSONSerialization` cannot be used to edit the user's real Claude Code
/// config: it hands back an unordered `NSDictionary`, so re-serialising a file
/// shuffles every key. `.sortedKeys` makes that deterministic but still rewrites
/// the whole document into alphabetical order, which turns a one-key edit into a
/// diff touching every line of a 10 KB hand-maintained `settings.json`.
///
/// So we keep our own tree: keys stay in file order, numbers keep their original
/// literal text (no `200` becoming `200.0`), and only the values we actually
/// touch change. What is *not* preserved is whitespace and comment trivia -
/// re-indentation to two spaces is uniform, which matches what Claude Code
/// itself writes, and JSON has no comments to lose.
indirect enum JSONValue: Equatable {
    case null
    case bool(Bool)
    /// Kept as the source literal so round-tripping never renormalises a number.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// An insertion-ordered JSON object.
struct JSONObject: Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}

    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Edit a nested object in place, creating it if the file never had one.
    /// Removes the key again when the closure leaves the child empty, so we do
    /// not litter the file with `"permissions": {}`.
    mutating func withObject(_ key: String, _ body: (inout JSONObject) -> Void) {
        var child: JSONObject
        if case .object(let existing)? = self[key] { child = existing } else { child = JSONObject() }
        body(&child)
        self[key] = child.keys.isEmpty ? nil : .object(child)
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    /// Every element that is a string, skipping anything else. Permission lists
    /// are strings today, but degrading quietly beats trapping on a future shape.
    var stringArray: [String] { arrayValue?.compactMap(\.stringValue) ?? [] }

    /// Flattens a string-to-string map such as `env`; non-string values are dropped
    /// rather than coerced, because writing them back changed would be worse.
    var stringMap: [(String, String)] {
        guard let object = objectValue else { return [] }
        return object.keys.compactMap { key in object[key]?.stringValue.map { (key, $0) } }
    }
}

// MARK: - Parsing

extension JSONValue {
    enum ParseError: Error { case malformed(offset: Int) }

    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw ParseError.malformed(offset: parser.index) }
        return value
    }

    static func parse(contentsOf url: URL) throws -> JSONValue {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        var isAtEnd: Bool { index >= scalars.count }
        private var current: Unicode.Scalar? { isAtEnd ? nil : scalars[index] }

        mutating func skipWhitespace() {
            while let c = current, c == " " || c == "\n" || c == "\r" || c == "\t" { index += 1 }
        }

        private mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard current == scalar else { throw ParseError.malformed(offset: index) }
            index += 1
        }

        private mutating func match(_ literal: String) -> Bool {
            let chars = Array(literal.unicodeScalars)
            guard index + chars.count <= scalars.count else { return false }
            for (offset, c) in chars.enumerated() where scalars[index + offset] != c { return false }
            index += chars.count
            return true
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard let c = current else { throw ParseError.malformed(offset: index) }
            switch c {
            case "{": return .object(try parseObject())
            case "[": return .array(try parseArray())
            case "\"": return .string(try parseString())
            case "t": guard match("true") else { throw ParseError.malformed(offset: index) }; return .bool(true)
            case "f": guard match("false") else { throw ParseError.malformed(offset: index) }; return .bool(false)
            case "n": guard match("null") else { throw ParseError.malformed(offset: index) }; return .null
            default: return .number(try parseNumber())
            }
        }

        private mutating func parseObject() throws -> JSONObject {
            try expect("{")
            var object = JSONObject()
            skipWhitespace()
            if current == "}" { index += 1; return object }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                object[key] = try parseValue()
                skipWhitespace()
                if current == "," { index += 1; continue }
                try expect("}")
                return object
            }
        }

        private mutating func parseArray() throws -> [JSONValue] {
            try expect("[")
            var items: [JSONValue] = []
            skipWhitespace()
            if current == "]" { index += 1; return items }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                if current == "," { index += 1; continue }
                try expect("]")
                return items
            }
        }

        private mutating func parseString() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while true {
                guard let c = current else { throw ParseError.malformed(offset: index) }
                index += 1
                if c == "\"" { return String(out) }
                guard c == "\\" else { out.append(c); continue }
                guard let escape = current else { throw ParseError.malformed(offset: index) }
                index += 1
                switch escape {
                case "\"", "\\", "/": out.append(escape)
                case "b": out.append(Unicode.Scalar(8))
                case "f": out.append(Unicode.Scalar(12))
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    let unit = try parseHexQuad()
                    // A high surrogate is only meaningful paired with its low half;
                    // decode the pair rather than emitting a replacement character.
                    if unit >= 0xD800, unit <= 0xDBFF, index + 1 < scalars.count,
                       scalars[index] == "\\", scalars[index + 1] == "u" {
                        let mark = index
                        index += 2
                        let low = try parseHexQuad()
                        if low >= 0xDC00, low <= 0xDFFF {
                            let combined = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00)
                            out.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
                            continue
                        }
                        index = mark
                    }
                    out.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                default: throw ParseError.malformed(offset: index)
                }
            }
        }

        private mutating func parseHexQuad() throws -> UInt16 {
            guard index + 4 <= scalars.count else { throw ParseError.malformed(offset: index) }
            let digits = String(String.UnicodeScalarView(scalars[index ..< index + 4]))
            guard let value = UInt16(digits, radix: 16) else { throw ParseError.malformed(offset: index) }
            index += 4
            return value
        }

        private mutating func parseNumber() throws -> String {
            let start = index
            while let c = current, "0123456789+-.eE".unicodeScalars.contains(c) { index += 1 }
            guard index > start else { throw ParseError.malformed(offset: index) }
            return String(String.UnicodeScalarView(scalars[start ..< index]))
        }
    }
}

// MARK: - Serialising

extension JSONValue {
    /// Two-space indent with a trailing newline - the shape Claude Code's own
    /// writer produces, so an Ookook edit does not show up as a whole-file diff.
    func serialized() -> String {
        var out = ""
        write(into: &out, depth: 0)
        out.append("\n")
        return out
    }

    private func write(into out: inout String, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let inner = String(repeating: "  ", count: depth + 1)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let literal): out += literal
        case .string(let s): out += Self.quote(s)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (offset, item) in items.enumerated() {
                out += inner
                item.write(into: &out, depth: depth + 1)
                out += offset == items.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        case .object(let object):
            guard !object.keys.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (offset, key) in object.keys.enumerated() {
                out += inner + Self.quote(key) + ": "
                (object[key] ?? .null).write(into: &out, depth: depth + 1)
                out += offset == object.keys.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
