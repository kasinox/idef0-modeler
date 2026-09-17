// An order-preserving JSON value, a parser, and a serializer that reproduces
// JavaScript's `JSON.stringify(value, null, 2)` byte for byte.
//
// The web app's project file is whatever `JSON.stringify` writes. Foundation's
// `JSONEncoder` differs in key order, in `"key" : value` spacing and in number
// formatting (`100.0` against `100`), so a model opened and saved on the Mac
// would diff against every line the browser wrote. Going through this type
// instead makes identical models produce identical files in both front-ends.

import Foundation

public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// One member of a JSON object.
public struct JSONMember: Hashable, Sendable {
    public var key: String
    public var value: JSONValue
    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// A JSON object that remembers the order its members were written in.
public struct JSONObject: Hashable, Sendable, Sequence {
    public private(set) var members: [JSONMember] = []

    public init() {}
    public init(_ members: [JSONMember]) {
        for m in members { self[m.key] = m.value }
    }

    public var isEmpty: Bool { members.isEmpty }
    public var count: Int { members.count }
    public var keys: [String] { members.map(\.key) }

    public func contains(_ key: String) -> Bool { members.contains { jsStrictEquals($0.key, key) } }

    /// Setting an existing key replaces its value in place, as assignment to a
    /// JavaScript property does; setting nil removes the member.
    public subscript(key: String) -> JSONValue? {
        get { members.first { jsStrictEquals($0.key, key) }?.value }
        set {
            if let i = members.firstIndex(where: { jsStrictEquals($0.key, key) }) {
                if let v = newValue { members[i].value = v } else { members.remove(at: i) }
            } else if let v = newValue {
                members.append(JSONMember(key, v))
            }
        }
    }

    public mutating func append(_ key: String, _ value: JSONValue) { self[key] = value }

    /// Members in the order JavaScript enumerates an object's own keys: keys
    /// that are array indices first, ascending, then every other key in
    /// insertion order. `JSON.stringify` and `Object.entries` both follow it.
    public var jsOrderedMembers: [JSONMember] {
        let indexed = members.filter { isArrayIndex($0.key) }
        guard !indexed.isEmpty else { return members }
        let sortedIndexed = indexed.sorted { UInt64($0.key)! < UInt64($1.key)! }
        return sortedIndexed + members.filter { !isArrayIndex($0.key) }
    }

    public func makeIterator() -> IndexingIterator<[JSONMember]> { members.makeIterator() }
}

/// A canonical numeric string below 2^32 − 1, which JavaScript treats as an array index.
private func isArrayIndex(_ key: String) -> Bool {
    guard !key.isEmpty, key.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return false }
    if key.count > 1 && key.hasPrefix("0") { return false }
    guard let n = UInt64(key) else { return false }
    return n < 4_294_967_295
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Equatable, Sendable {
    public let message: String
    public let offset: Int
    public var description: String { "\(message) at position \(offset)" }
}

extension JSONValue {
    /// The deepest nesting of arrays and objects `parse` accepts; one level
    /// deeper fails with "JSON is nested too deeply".
    ///
    /// A deliberate deviation from the web app, whose `JSON.parse` has no
    /// limit and whose `JSON.stringify(model, null, 2)` only overflows the
    /// call stack thousands of levels down (about 5,600 in Node 26), so a file
    /// nested deeper than this but not that deep opens and saves on the web
    /// and is refused here. Parsing, writing, `==`,
    /// hashing and even freeing a `JSONValue` all recurse once per level, and
    /// a secondary thread's stack is small (512 KB by default), so an unbounded
    /// file crashes the process instead of failing the open. No edit adds
    /// nesting, so capping it at parse time bounds every later walk. Real
    /// project files nest about six levels; only a verbatim extra member kept
    /// from another tool could approach this.
    public static let maxNestingDepth = 256

    /// Parse JSON text. Duplicate keys keep their first position and their last
    /// value, which is what `JSON.parse` does.
    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(Array(text.utf8))
        p.skipWhitespace()
        let v = try p.parseValue()
        p.skipWhitespace()
        guard p.i == p.b.count else { throw p.fail("Unexpected token") }
        return v
    }
}

private struct Parser {
    let b: [UInt8]
    var i = 0
    /// Arrays and objects currently open, see `JSONValue.maxNestingDepth`.
    var depth = 0
    init(_ bytes: [UInt8]) { b = bytes }

    func fail(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: i) }

    /// Called at the opening bracket of an array or object, which `i` still
    /// points at, so the error names the bracket that went too deep.
    mutating func enterContainer() throws {
        guard depth < JSONValue.maxNestingDepth else { throw fail("JSON is nested too deeply") }
        depth += 1
    }

    mutating func skipWhitespace() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        guard i < b.count else { throw fail("Unexpected end of JSON input") }
        switch b[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { throw fail("Unexpected token") }
        i += w.count
    }

    mutating func parseObject() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        i += 1
        var obj = JSONObject()
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
        while true {
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("Expected property name") }
            let key = try parseString()
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("Expected ':' after property name") }
            i += 1
            skipWhitespace()
            obj[key] = try parseValue()
            skipWhitespace()
            guard i < b.count else { throw fail("Unexpected end of JSON input") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
            throw fail("Expected ',' or '}' after property value")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        i += 1
        var out: [JSONValue] = []
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
        while true {
            skipWhitespace()
            out.append(try parseValue())
            skipWhitespace()
            guard i < b.count else { throw fail("Unexpected end of JSON input") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            throw fail("Expected ',' or ']' after array element")
        }
    }

    mutating func parseString() throws -> String {
        i += 1
        var units: [UInt16] = []
        var run: [UInt8] = []
        func flushRun() {
            if !run.isEmpty { units.append(contentsOf: String(decoding: run, as: UTF8.self).utf16); run.removeAll() }
        }
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                flushRun()
                return String(decoding: units, as: UTF16.self)
            }
            if c < 0x20 { throw fail("Bad control character in string literal") }
            if c == UInt8(ascii: "\\") {
                flushRun()
                i += 1
                guard i < b.count else { break }
                switch b[i] {
                case UInt8(ascii: "\""): units.append(0x22)
                case UInt8(ascii: "\\"): units.append(0x5C)
                case UInt8(ascii: "/"): units.append(0x2F)
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"):
                    guard i + 4 < b.count, let v = UInt16(String(decoding: b[(i + 1)...(i + 4)], as: UTF8.self), radix: 16)
                    else { throw fail("Bad Unicode escape") }
                    units.append(v)
                    i += 4
                default: throw fail("Bad escaped character")
                }
                i += 1
                continue
            }
            run.append(c)
            i += 1
        }
        throw fail("Unterminated string in JSON")
    }

    mutating func parseNumber() throws -> Double {
        let start = i
        if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count, isDigit(b[i]) else { throw fail("Unexpected token") }
        if b[i] == UInt8(ascii: "0") { i += 1 } else { while i < b.count, isDigit(b[i]) { i += 1 } }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            guard i < b.count, isDigit(b[i]) else { throw fail("Unterminated fractional number") }
            while i < b.count, isDigit(b[i]) { i += 1 }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count, isDigit(b[i]) else { throw fail("Exponent part is missing a number") }
            while i < b.count, isDigit(b[i]) { i += 1 }
        }
        guard let d = Double(String(decoding: b[start..<i], as: UTF8.self)) else { throw fail("Invalid number") }
        return d
    }

    func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
}

// MARK: - Serialising exactly as JSON.stringify(value, null, indent)

extension JSONValue {
    public func stringified(indent: Int = 2) -> String {
        var out = ""
        write(into: &out, indent: String(repeating: " ", count: indent), current: "")
        return out
    }

    /// With an empty indent this is `JSON.stringify(value)`: no line breaks and
    /// no space after the colon. With a non-empty one, each member goes on its
    /// own line and a colon is followed by a single space.
    private func write(into out: inout String, indent: String, current: String) {
        let compact = indent.isEmpty
        switch self {
        case .null: out += "null"
        case .bool(let v): out += v ? "true" : "false"
        case .number(let v): out += v.isFinite ? jsNumberString(v) : "null"
        case .string(let s): out += jsonQuote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            let inner = current + indent
            out += compact ? "[" : "[\n"
            for (n, v) in items.enumerated() {
                out += inner
                v.write(into: &out, indent: indent, current: inner)
                if n < items.count - 1 { out += "," }
                if !compact { out += "\n" }
            }
            out += current + "]"
        case .object(let obj):
            let members = obj.jsOrderedMembers
            if members.isEmpty { out += "{}"; return }
            let inner = current + indent
            out += compact ? "{" : "{\n"
            for (n, m) in members.enumerated() {
                out += inner + jsonQuote(m.key) + (compact ? ":" : ": ")
                m.value.write(into: &out, indent: indent, current: inner)
                if n < members.count - 1 { out += "," }
                if !compact { out += "\n" }
            }
            out += current + "}"
        }
    }
}

/// `JSON.stringify`'s QuoteJSONString: only `"`, `\` and control characters
/// are escaped; `/` and non-ASCII text are written through untouched.
public func jsonQuote(_ s: String) -> String {
    // Swift strings cannot hold a lone surrogate, which is the only other thing
    // JSON.stringify escapes, so walking scalars covers every case.
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0..<0x20: out += "\\u" + String(format: "%04x", scalar.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

// MARK: - JavaScript value conversions

/// JavaScript's Number::toString(10) for a double: shortest round-trip digits,
/// laid out with the exact thresholds JavaScript uses for plain and
/// exponential notation.
public func jsNumberString(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v == 0 { return "0" }
    if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }

    // Swift's description is also shortest round-trip; only its layout differs.
    let text = "\(v.magnitude)"
    var mantissa = Substring(text)
    var exponent = 0
    if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = text[..<e]
        exponent = Int(text[text.index(after: e)...]) ?? 0
    }
    var intPart = mantissa
    var fracPart: Substring = ""
    if let dot = mantissa.firstIndex(of: ".") {
        intPart = mantissa[..<dot]
        fracPart = mantissa[mantissa.index(after: dot)...]
    }
    var digits = Array(intPart + fracPart)
    var point = intPart.count + exponent
    while digits.count > 1, digits.first == "0" { digits.removeFirst(); point -= 1 }
    while digits.count > 1, digits.last == "0" { digits.removeLast() }

    let k = digits.count
    let n = point
    let d = String(digits)
    let body: String
    if k <= n && n <= 21 {
        body = d + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        body = String(digits[0..<n]) + "." + String(digits[n...])
    } else if -6 < n && n <= 0 {
        body = "0." + String(repeating: "0", count: -n) + d
    } else {
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        body = (k == 1 ? d : String(digits[0]) + "." + String(digits[1...])) + "e" + sign + String(e.magnitude)
    }
    return v < 0 ? "-" + body : body
}

extension JSONValue {
    /// `!!value` — JavaScript truthiness. `nil` stands for `undefined`.
    public static func truthy(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let d): return !(d == 0 || d.isNaN)
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// `Number(value)` — JavaScript's ToNumber. `nil` stands for `undefined`.
    public static func toNumber(_ v: JSONValue?) -> Double {
        guard let v else { return .nan }
        switch v {
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let d): return d
        case .string(let s): return jsStringToNumber(s)
        case .array(let items):
            if items.isEmpty { return 0 }
            if items.count == 1 { return jsStringToNumber(toJSString(items[0])) }
            return .nan
        case .object: return .nan
        }
    }

    /// `String(value)` — JavaScript's ToString.
    public static func toJSString(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return jsNumberString(d)
        case .string(let s): return s
        case .array(let items):
            return items.map { item -> String in
                if case .null = item { return "" }
                return toJSString(item)
            }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
}

private func jsStringToNumber(_ raw: String) -> Double {
    let s = jsTrim(raw)
    if s.isEmpty { return 0 }
    switch s {
    case "Infinity", "+Infinity": return .infinity
    case "-Infinity": return -.infinity
    default: break
    }
    let lower = s.lowercased()
    for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
        guard let n = UInt64(lower.dropFirst(2), radix: radix) else { return .nan }
        return Double(n)
    }
    // JavaScript's StrDecimalLiteral: no hex floats, no "nan"/"inf" spellings.
    let allowed = Set("0123456789+-.eE")
    guard s.allSatisfy({ allowed.contains($0) }), let d = Double(s) else { return .nan }
    return d
}
