// Shared test machinery: fixture loading, a JSON diff that names the first
// differing path, and the id normalisation the golden files were written with.
//
// The golden files are produced by running the web app's own modules in a
// browser (see Fixtures/README.md). They are the reference behaviour; a Swift
// result that differs from them is a porting bug unless a test says otherwise.

import Foundation
import Testing
@testable import IDEF0Core

enum Fixtures {
    static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            fatalError("Missing fixture \(name)")
        }
        return url
    }

    static func text(_ name: String) -> String {
        do { return try String(contentsOf: url(name), encoding: .utf8) } catch { fatalError("Unreadable fixture \(name): \(error)") }
    }

    static func json(_ name: String) -> JSONValue {
        do { return try JSONValue.parse(text(name)) } catch { fatalError("Fixture \(name) is not JSON: \(error)") }
    }

    /// The canonical sample model, exactly as the web app serialises it.
    static var sampleText: String { text("sample.idef0.json") }
}

/// The first difference between two JSON values as "path: detail", or nil.
/// Numbers compare within a relative tolerance — the web app's `Math.hypot` is
/// not correctly rounded, so distances may differ in the last unit in the last place.
func jsonDiff(_ expected: JSONValue, _ actual: JSONValue, path: String = "$", tolerance: Double = 1e-9) -> String? {
    switch (expected, actual) {
    case (.number(let e), .number(let a)):
        let scale = max(1, abs(e), abs(a))
        return abs(e - a) <= tolerance * scale ? nil : "\(path): expected \(jsNumberString(e)), got \(jsNumberString(a))"
    case (.object(let e), .object(let a)):
        let ek = Set(e.keys), ak = Set(a.keys)
        if let missing = ek.subtracting(ak).sorted().first { return "\(path).\(missing): missing" }
        if let extra = ak.subtracting(ek).sorted().first { return "\(path).\(extra): unexpected" }
        for m in e.members {
            if let d = jsonDiff(m.value, a[m.key]!, path: "\(path).\(m.key)", tolerance: tolerance) { return d }
        }
        return nil
    case (.array(let e), .array(let a)):
        if e.count != a.count { return "\(path): expected \(e.count) elements, got \(a.count)" }
        for (i, pair) in zip(e, a).enumerated() {
            if let d = jsonDiff(pair.0, pair.1, path: "\(path)[\(i)]", tolerance: tolerance) { return d }
        }
        return nil
    default:
        return expected == actual ? nil : "\(path): expected \(expected.stringified(indent: 0)), got \(actual.stringified(indent: 0))"
    }
}

/// The first line where two texts differ, for readable failures on long files.
func textDiff(_ expected: String, _ actual: String) -> String? {
    if expected == actual { return nil }
    let e = expected.components(separatedBy: "\n"), a = actual.components(separatedBy: "\n")
    for i in 0..<max(e.count, a.count) {
        let el = i < e.count ? e[i] : "<end>", al = i < a.count ? a[i] : "<end>"
        if el != al { return "line \(i + 1):\n  expected: \(el)\n  actual:   \(al)" }
    }
    return "texts differ only in trailing content"
}

/// Ids the goldens keep verbatim; any other generated id becomes `new1`,
/// `new2`… in order of first appearance, exactly as the generator did.
enum IdNormaliser {
    static let fixtureIds: Set<String> = [
        "ar_fxorphan", "ar_fxfb1", "ar_fxfb2", "ar_fxfb3", "ar_fxbent",
        "bx_fx5", "bx_fx6", "bx_fx7", "bx_fxunnamed", "gl_doesnotexist",
        "ar_fxcall", "ar_fxcall1", "ar_fxcall2", "ar_fxtun", "ar_fxfork", "ar_fxqs", "ar_fxqsin",
        "ar_fxdup", "bx_fxdup", "dg_fxmissing",
        "ar_fxport1", "ar_fxport2", "ar_fxjoin1", "ar_fxjoin2",
    ]

    static let pattern = try! NSRegularExpression(pattern: #"\b(?:dg|bx|ar|gl|mdl)_[a-z0-9]+\b"#)

    static var fixedIds: Set<String> {
        let text = Fixtures.sampleText
        let ns = text as NSString
        var ids = fixtureIds
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            ids.insert(ns.substring(with: m.range))
        }
        return ids
    }

    static func normalise(_ text: String, fixed: Set<String> = fixedIds) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var assigned: [String: String] = [:]
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let id = ns.substring(with: m.range)
            if fixed.contains(id) {
                out += id
            } else {
                if assigned[id] == nil { assigned[id] = "new\(assigned.count + 1)" }
                out += assigned[id]!
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
