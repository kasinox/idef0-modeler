// Small shared helpers, each matching its counterpart in the web app's
// src/util.js — including the places where JavaScript's semantics differ from
// Swift's defaults (rounding, sorting stability, string length).

import Foundation

// MARK: - Identifiers and dates

/// A fresh identifier shaped like the web app's `uid()`:
/// `prefix_<milliseconds base36><64 random bits as 16 hex digits>`.
///
/// The random tail is fixed-width, so two ids can never spell the same string
/// from different parts, and it is wide enough that ids minted in separate
/// processes (the app, parallel CLI runs) in the same millisecond do not
/// collide — an id is what the ontology toolkit joins on. The bits come from
/// `SystemRandomNumberGenerator`, as the web's come from `crypto.getRandomValues`.
/// Ids are opaque: nothing parses the timestamp back.
public func uid(_ prefix: String = "id") -> String {
    let ms = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    let random = String(UInt64.random(in: .min ... .max), radix: 16)
    let tail = String(repeating: "0", count: 16 - random.count) + random
    return "\(prefix)_\(String(ms, radix: 36))\(tail)"
}

/// `new Date().toISOString().slice(0, 10)` — today's date in UTC.
public func todayISO(_ date: Date = Date()) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
}

// MARK: - Numbers

/// `Math.round` — ties go towards +∞, so `jsRound(-2.5) == -2`, unlike
/// Swift's `rounded()`, which sends ties away from zero.
public func jsRound(_ x: Double) -> Double {
    guard x.isFinite else { return x }
    let floor = x.rounded(.down)
    return x - floor >= 0.5 ? floor + 1 : floor
}

/// The one-decimal rounding the web app applies to every coordinate it writes.
public func roundTenth(_ v: Double) -> Double { jsRound(v * 10) / 10 }

public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { v < lo ? lo : (v > hi ? hi : v) }

// MARK: - Strings

/// The characters JavaScript's `String.prototype.trim` and `\s` treat as whitespace.
private let jsWhitespace: Set<UInt32> = [
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
]

public func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool { jsWhitespace.contains(scalar.value) }

/// `String.prototype.trim`.
public func jsTrim(_ s: String) -> String {
    let scalars = Array(s.unicodeScalars)
    var lo = 0
    var hi = scalars.count
    while lo < hi, isJSWhitespace(scalars[lo]) { lo += 1 }
    while hi > lo, isJSWhitespace(scalars[hi - 1]) { hi -= 1 }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars[lo..<hi])
    return String(out)
}

/// `.replace(/\s+/g, ' ')`.
public func jsCollapseWhitespace(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    var inRun = false
    for scalar in s.unicodeScalars {
        if isJSWhitespace(scalar) {
            if !inRun { out.append(" ") }
            inRun = true
        } else {
            out.append(scalar)
            inRun = false
        }
    }
    return String(out)
}

/// `.split(/\s+/)` followed by `.filter(Boolean)`.
public func jsWords(_ s: String) -> [String] {
    jsCollapseWhitespace(jsTrim(s)).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
}

/// `String.prototype.toLowerCase`: full Unicode mappings plus the one
/// context-sensitive rule, Greek final sigma, which a per-scalar mapping misses
/// ("ΟΔΟΣ" → "οδος", not "οδοσ").
public func jsLowercase(_ s: String) -> String {
    let scalars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    for (i, scalar) in scalars.enumerated() {
        if scalar.value == 0x03A3, isFinalSigma(scalars, i) {
            out.append("\u{03C2}")
        } else {
            out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
        }
    }
    return String(out)
}

/// Unicode's Final_Sigma condition: a cased letter before (skipping
/// case-ignorables) and none after.
private func isFinalSigma(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
    var j = i - 1
    while j >= 0, s[j].properties.isCaseIgnorable { j -= 1 }
    guard j >= 0, s[j].properties.isCased else { return false }
    var k = i + 1
    while k < s.count, s[k].properties.isCaseIgnorable { k += 1 }
    return !(k < s.count && s[k].properties.isCased)
}

/// Length as JavaScript counts it, in UTF-16 code units.
public func jsLength(_ s: String) -> Int { s.utf16.count }

/// `a === b` for strings: the same code units. Swift's `==` compares by
/// canonical equivalence, so "Café" typed and "Cafe\u{301}" pasted are one
/// string to Swift but two to JavaScript — two concepts in the web app's
/// glossary, and so in the file both front-ends write.
func jsStrictEquals(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.utf8.elementsEqual(b.utf8)
}

/// A string as a JavaScript `Map`, `Set` or object key: equal only to the
/// same code units (see `jsStrictEquals`).
struct JSStringKey: Hashable, Sendable {
    let string: String
    init(_ string: String) { self.string = string }
    static func == (a: JSStringKey, b: JSStringKey) -> Bool { jsStrictEquals(a.string, b.string) }
    func hash(into hasher: inout Hasher) {
        for byte in string.utf8 { hasher.combine(byte) }
        hasher.combine(0xFF as UInt8)   // never a UTF-8 byte: ends the key
    }
}

/// `String.prototype.localeCompare` under an English locale, as the browser's
/// ICU collator orders strings.
///
/// Foundation's localized comparison is close but not identical. ICU ignores
/// the completely ignorable code points (controls, soft hyphen, zero-width
/// joiners, BOM) that Foundation weighs; and where Foundation calls two
/// strings equal that are not canonically equivalent — full-width letters,
/// ligatures, a no-break space — ICU still orders them at the tertiary level,
/// which a stable sort makes visible in the glossary. It does not order
/// digits of different scripts ("3" and "٣"), nor canonically equivalent
/// spellings ("é" and "e\u{301}"): those stay equal and keep their order.
public func jsLocaleCompare(_ a: String, _ b: String) -> Int {
    let a = withoutCollationIgnorables(a), b = withoutCollationIgnorables(b)
    let locale = Locale(identifier: "en_US")
    var order = a.compare(b, options: [], range: nil, locale: locale)
    if order == .orderedSame {
        // Swift's `==` is canonical equivalence, which is what is wanted here.
        let fa = withASCIIDigits(a), fb = withASCIIDigits(b)
        if fa != fb { order = fa.compare(fb, options: [.forcedOrdering], range: nil, locale: locale) }
    }
    switch order {
    case .orderedAscending: return -1
    case .orderedDescending: return 1
    case .orderedSame: return 0
    }
}

/// Drops what the Unicode Collation Algorithm treats as completely ignorable:
/// default-ignorable code points and the C0/C1 controls other than the
/// whitespace controls TAB…CR.
private func withoutCollationIgnorables(_ s: String) -> String {
    let ignorable: (Unicode.Scalar) -> Bool = { u in
        u.properties.isDefaultIgnorableCodePoint
            || (u.value < 0x20 && !(0x09...0x0D).contains(u.value))
            || (0x7F...0x9F).contains(u.value)
    }
    guard s.unicodeScalars.contains(where: ignorable) else { return s }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: s.unicodeScalars.filter { !ignorable($0) })
    return String(out)
}

/// Decimal digits of any script as ASCII digits. A digit with a compatibility
/// decomposition (full-width "３") is a tertiary variant to ICU and stays.
private func withASCIIDigits(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        if !u.isASCII, u.properties.numericType == .decimal, let v = u.properties.numericValue,
           String(u).decomposedStringWithCompatibilityMapping.unicodeScalars.elementsEqual([u]),
           let digit = Unicode.Scalar(48 + UInt32(v)) {
            out.append(digit)
        } else {
            out.append(u)
        }
    }
    return String(out)
}

/// `escapeXml` from src/util.js. The regex replaces code units, so this walks
/// scalars: as a Swift `Character`, "<" followed by a combining mark is not "<".
public func escapeXml(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        switch scalar {
        case "<": out.append(contentsOf: "&lt;".unicodeScalars)
        case ">": out.append(contentsOf: "&gt;".unicodeScalars)
        case "&": out.append(contentsOf: "&amp;".unicodeScalars)
        case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
        case "'": out.append(contentsOf: "&apos;".unicodeScalars)
        default: out.append(scalar)
        }
    }
    return String(out)
}

/// `slugify` from src/util.js.
public func slugify(_ s: String) -> String {
    let source = s.isEmpty ? "model" : jsLowercase(s)
    var out = ""
    var pendingDash = false
    for scalar in source.unicodeScalars {
        let v = scalar.value
        if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
            if pendingDash && !out.isEmpty { out.append("-") }
            // A leading run of punctuation produces no dash: it would be trimmed.
            pendingDash = false
            out.unicodeScalars.append(scalar)
        } else {
            pendingDash = true
        }
    }
    // A dash is only ever written ahead of a letter or digit, so `out` already
    // matches `.replace(/^-|-$/g, '')`. JavaScript slices after trimming, so a
    // slug cut at 60 characters may end in a dash — and keeps it.
    let sliced = String(out.prefix(60))
    return sliced.isEmpty ? "model" : sliced
}

// MARK: - Text metrics

/// Helvetica AFM advance widths (em fractions — 1/1000 units — for the
/// printable ASCII range), keyed by code point, which equals the UTF-16 code
/// unit for these characters. An unlisted Latin code unit (below 0x2E80)
/// defaults to 0.556 em, the width of most Helvetica lowercase letters; a
/// code unit at or above 0x2E80 (CJK and other wide scripts, and any
/// surrogate half) defaults to a full 1.0 em, since Helvetica has no metrics
/// for them and a full-width guess keeps wrapping conservative rather than
/// overflowing. Matches src/util.js's `HELVETICA_ADVANCE` exactly.
private let helveticaAdvance: [UInt16: Double] = [
    32: 0.278, 33: 0.278, 34: 0.355, 35: 0.556, 36: 0.556, 37: 0.889, 38: 0.667, 39: 0.191,
    40: 0.333, 41: 0.333, 42: 0.389, 43: 0.584, 44: 0.278, 45: 0.333, 46: 0.278, 47: 0.278,
    48: 0.556, 49: 0.556, 50: 0.556, 51: 0.556, 52: 0.556, 53: 0.556, 54: 0.556, 55: 0.556,
    56: 0.556, 57: 0.556, 58: 0.278, 59: 0.278, 60: 0.584, 61: 0.584, 62: 0.584, 63: 0.556,
    64: 1.015, 65: 0.667, 66: 0.667, 67: 0.722, 68: 0.722, 69: 0.667, 70: 0.611, 71: 0.778,
    72: 0.722, 73: 0.278, 74: 0.500, 75: 0.667, 76: 0.556, 77: 0.833, 78: 0.722, 79: 0.778,
    80: 0.667, 81: 0.778, 82: 0.722, 83: 0.667, 84: 0.611, 85: 0.722, 86: 0.667, 87: 0.944,
    88: 0.667, 89: 0.667, 90: 0.611, 91: 0.278, 92: 0.278, 93: 0.278, 94: 0.469, 95: 0.556,
    96: 0.333, 97: 0.556, 98: 0.556, 99: 0.500, 100: 0.556, 101: 0.556, 102: 0.278, 103: 0.556,
    104: 0.556, 105: 0.222, 106: 0.222, 107: 0.500, 108: 0.222, 109: 0.833, 110: 0.556,
    111: 0.556, 112: 0.556, 113: 0.556, 114: 0.333, 115: 0.500, 116: 0.278, 117: 0.556,
    118: 0.500, 119: 0.722, 120: 0.500, 121: 0.500, 122: 0.500, 123: 0.334, 124: 0.260,
    125: 0.334, 126: 0.584,
]
private let latinDefaultAdvance = 0.556
private let wideDefaultAdvance = 1.0
private let wideThreshold: UInt16 = 0x2e80

private func charAdvance(_ codeUnit: UInt16) -> Double {
    if let known = helveticaAdvance[codeUnit] { return known }
    return codeUnit >= wideThreshold ? wideDefaultAdvance : latinDefaultAdvance
}

/// Width of `text` set in Helvetica at `fontSize`, summed per UTF-16 code unit.
public func textWidth(_ text: String, fontSize: Double) -> Double {
    var w = 0.0
    for unit in text.utf16 { w += charAdvance(unit) }
    return w * fontSize
}

/// Break `word` at the last '-', '_' or '/' whose prefix still fits
/// `maxWidth`; failing that, hard-break at the widest whole prefix that fits.
/// Always returns a non-empty head, so wrapping keeps making progress even
/// when no prefix fits within `maxWidth`. Slices by UTF-16 code unit, as the
/// web app's `String.slice` does.
private func breakToken(_ word: String, fontSize: Double, maxWidth: Double) -> (head: String, rest: String) {
    let units = Array(word.utf16)
    let hyphen: UInt16 = 0x2D, underscore: UInt16 = 0x5F, slash: UInt16 = 0x2F
    var splitAt = 0
    for i in 0..<units.count {
        let c = units[i]
        guard c == hyphen || c == underscore || c == slash else { continue }
        let prefix = String(decoding: units[0...i], as: UTF16.self)
        if textWidth(prefix, fontSize: fontSize) > maxWidth { break }
        splitAt = i + 1
    }
    if splitAt > 0 {
        return (String(decoding: units[0..<splitAt], as: UTF16.self), String(decoding: units[splitAt...], as: UTF16.self))
    }
    var n = 1
    if units.count >= 2 {
        for k in 2...units.count {
            let prefix = String(decoding: units[0..<k], as: UTF16.self)
            if textWidth(prefix, fontSize: fontSize) > maxWidth { break }
            n = k
        }
    }
    return (String(decoding: units[0..<n], as: UTF16.self), String(decoding: units[n...], as: UTF16.self))
}

/// Trim `s` from the end, if it must, so `s…` fits `maxWidth` at `fontSize`.
private func ellipsize(_ s: String, fontSize: Double, maxWidth: Double) -> String {
    if textWidth("\(s)…", fontSize: fontSize) <= maxWidth { return "\(s)…" }
    var units = Array(s.utf16)
    while !units.isEmpty, textWidth("\(String(decoding: units, as: UTF16.self))…", fontSize: fontSize) > maxWidth {
        units.removeLast()
    }
    return "\(String(decoding: units, as: UTF16.self))…"
}

/// `wrapText` from src/util.js: break `text` into at most `maxLines` lines
/// that fit `width` sheet units at `fontSize`, measured with the Helvetica
/// advance table. Lines fill greedily; a word wider than a line is broken
/// (preferring '-', '_' or '/', otherwise a hard character break), and if
/// words remain once `maxLines` lines are full, the LAST line — never an
/// earlier one — is trimmed and given a trailing "…". `lastLineWidth`, when
/// given, narrows only that final line slot: FIPS boxes keep it clear of the
/// box number sharing that row (see `boxNameLines`). Swift cannot default one
/// parameter to another's value, hence the `nil` sentinel for "same as `width`".
public func wrapText(_ text: String, width: Double, fontSize: Double, maxLines: Int = 4, lastLineWidth: Double? = nil) -> [String] {
    let lastWidth = lastLineWidth ?? width
    var queue = jsWords(text)
    if queue.isEmpty { return [] }
    var lines: [String] = []
    while !queue.isEmpty {
        let isLastSlot = lines.count == maxLines - 1
        let slotWidth = isLastSlot ? lastWidth : width
        var cur = ""
        while !queue.isEmpty {
            let word = queue[0]
            let cand = cur.isEmpty ? word : "\(cur) \(word)"
            if textWidth(cand, fontSize: fontSize) <= slotWidth {
                cur = cand
                queue.removeFirst()
                continue
            }
            if !cur.isEmpty { break }
            let (head, rest) = breakToken(word, fontSize: fontSize, maxWidth: slotWidth)
            cur = head
            if rest.isEmpty { queue.removeFirst() } else { queue[0] = rest }
            break
        }
        lines.append(cur)
        if lines.count == maxLines { break }
    }
    if !queue.isEmpty, !lines.isEmpty {
        let last = lines.count - 1
        lines[last] = ellipsize(lines[last], fontSize: fontSize, maxWidth: lastWidth)
    }
    return lines
}

/// `fitText` from src/util.js: truncate `text` to a single line no wider than
/// `width` at `fontSize`.
public func fitText(_ text: String, width: Double, fontSize: Double) -> String {
    if text.isEmpty { return "" }
    if textWidth(text, fontSize: fontSize) <= width { return text }
    if width <= 0 { return "" }
    var units = Array(text.utf16)
    while !units.isEmpty, textWidth("\(String(decoding: units, as: UTF16.self))…", fontSize: fontSize) > width {
        units.removeLast()
    }
    return units.isEmpty ? "…" : "\(String(decoding: units, as: UTF16.self))…"
}

/// `boxNameLines` from src/util.js — box-name layout shared by the renderer
/// and the validator (FIPS 183 §3.2.1.3): wrap `name` for a box `w` × `h`
/// sheet units at `fontSize`, capping lines to what the box height allows and
/// keeping the last line clear of the box number drawn at its bottom-right
/// corner.
public func boxNameLines(_ name: String, w: Double, h: Double, number: Int, fontSize: Double) -> [String] {
    let availWidth = w - 22
    // `Math.max(1, Math.min(4, Math.floor((h - 18) / 16)))`: JS propagates a
    // NaN `h` straight through (Math.min/max return NaN if either argument
    // is NaN), which then disables wrapText's maxLines cap and its ellipsis
    // step entirely (`lines.length === maxLines` and `=== maxLines - 1` are
    // never true against NaN). Swift's `Swift.min`/`Swift.max` instead use
    // `<`, which is false for NaN either way round, so they silently resolve
    // to the other, non-NaN operand (here, 4) — a real divergence caught by
    // `boxNameLinesPropagatesNaNHeight` below. `raw` is NaN exactly when `h`
    // is NaN (any finite or infinite `h` yields a non-NaN `raw`), so gate on
    // it and hand wrapText a maxLines so large its own comparisons can never
    // hit it — reproducing "the cap never fires" without giving wrapText's
    // `Int` parameter an actual NaN, which Int cannot represent.
    let raw = ((h - 18) / 16).rounded(.down)
    let maxLines = raw.isNaN ? Int.max : Int(Swift.max(1, Swift.min(4, raw)))
    let numberWidth = textWidth(String(number), fontSize: 10)
    let lastLineWidth = Swift.max(0, availWidth - numberWidth - 4)
    return wrapText(name, width: availWidth, fontSize: fontSize, maxLines: maxLines, lastLineWidth: lastLineWidth)
}

// MARK: - Sorting

extension Sequence {
    /// A guaranteed-stable sort. JavaScript's `Array.prototype.sort` is stable,
    /// and the web app's orderings (arrows along a side, terms in a glossary)
    /// depend on it; Swift's `sorted` makes no such promise.
    public func stableSorted(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Element] {
        try enumerated().sorted { a, b in
            if try areInIncreasingOrder(a.element, b.element) { return true }
            if try areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Stable sort with a JavaScript-style comparator: negative means `a` first.
    public func stableSorted(comparing compare: (Element, Element) throws -> Double) rethrows -> [Element] {
        try stableSorted { try compare($0, $1) < 0 }
    }
}
