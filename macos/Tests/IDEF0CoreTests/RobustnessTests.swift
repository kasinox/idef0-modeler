// Inputs that are legal but extreme must fail softly or work, never trap:
// a box width of 1e20 (F69) and JSON nested hundreds of levels deep (F70).
//
// The expected `wrapText` arrays were taken from `node` running src/util.js,
// so these are parity checks as much as crash checks; only the nesting limit
// is a deliberate deviation, documented on `JSONValue.maxNestingDepth`.

import Foundation
import Testing
import os
@testable import IDEF0Core

@Suite("Robustness against extreme inputs")
struct RobustnessTests {

    // MARK: F69 — wrapText never traps on an extreme width or font size

    static let long = "Plan and control production of the whole product line"

    @Test("A box 1e20 wide wraps as the web app does instead of trapping on Int.max")
    func hugeWidth() {
        #expect(wrapText("Manufacture Product", width: 1e20, fontSize: 13) == ["Manufacture Product"])
        #expect(wrapText(Self.long, width: 1e20, fontSize: 13) == [Self.long])
        #expect(wrapText(Self.long, width: 1e308, fontSize: 13) == [Self.long])
        #expect(wrapText(Self.long, width: .infinity, fontSize: 13) == [Self.long])
        // Just below where the Int conversion used to trap, and just above.
        #expect(wrapText(Self.long, width: 9.3e18, fontSize: 13) == [Self.long])
        #expect(wrapText(Self.long, width: 9.3e19, fontSize: 13) == [Self.long])
    }

    // F62 replaced the 0.54-em-per-character guess with a real Helvetica
    // advance-width measure (src/util.js `textWidth`), so a candidate line's
    // fit no longer turns on a character-count budget. These four expected
    // arrays were re-taken from `node` running the new util.js: a width that
    // can fit not even one code unit (deeply negative, or zero, since every
    // measured width is non-negative) still makes progress one code unit at a
    // time — `breakToken`'s forced-minimum-one-unit rule — rather than
    // falling back to a fixed character count, and the trailing slot still
    // collapses to a bare "…" once `ellipsize` trims it to nothing.
    @Test("A width of -1e20 breaks one code unit at a time, never trapping")
    func hugeNegativeWidth() {
        #expect(wrapText("Manufacture Product", width: -1e20, fontSize: 13) == ["M", "a", "n", "…"])
        #expect(wrapText(Self.long, width: -1e20, fontSize: 13) == ["P", "l", "a", "…"])
        #expect(wrapText(Self.long, width: -1e308, fontSize: 13) == ["P", "l", "a", "…"])
        #expect(wrapText(Self.long, width: -.infinity, fontSize: 13) == ["P", "l", "a", "…"])
        #expect(wrapText(Self.long, width: 0, fontSize: 13) == ["P", "l", "a", "…"])
    }

    @Test("A NaN budget fits nothing, as comparisons against NaN are always false")
    func nanBudget() {
        // Every candidate's measured width is NaN once `fontSize` is NaN, and
        // `NaN <= width` is false regardless of width, so each word stands
        // alone — except a one-code-unit word, which `breakToken`'s hard-break
        // loop (itself NaN-guarded the same way) still returns whole.
        #expect(wrapText("A B C", width: .nan, fontSize: 13) == ["A", "B", "C"])
        // A zero font size measures every candidate at exactly 0, which fits
        // any non-negative width (0 <= 0): the whole text stays on one line.
        #expect(wrapText("A B C", width: 0, fontSize: 0) == ["A B C"])
        #expect(wrapText("A B C", width: 1e20, fontSize: .nan) == ["A", "B", "C"])
        #expect(wrapText(Self.long, width: 1e20, fontSize: .nan) == ["Plan", "and", "control", "production…"])
        #expect(wrapText(Self.long, width: 1e20, fontSize: 0) == [Self.long])
        // A negative font size measures every candidate at a negative width,
        // which is `<=` any non-negative box width: everything fits.
        #expect(wrapText(Self.long, width: 1e20, fontSize: -13) == [Self.long])
    }

    @Test("Ordinary widths wrap exactly as before")
    func ordinaryWidth() {
        // The real advance-width measure fits "whole product line" on one
        // line at width 120 — the old 0.54-em-per-character guess could not.
        #expect(wrapText(Self.long, width: 120, fontSize: 13) == ["Plan and control", "production of the", "whole product line"])
        #expect(wrapText("Manufacture Product", width: 120, fontSize: 13) == ["Manufacture", "Product"])
        #expect(wrapText("Manufacture Product", width: 140, fontSize: 13) == ["Manufacture Product"])
        #expect(wrapText("", width: 120, fontSize: 13) == [])
    }

    @Test("A diagram holding a box 1e20 wide builds its display list and SVG")
    func renderHugeBox() throws {
        var model = buildSampleModel()
        let rootId = model.rootDiagramId
        var root = try #require(model.diagrams[rootId])
        #expect(!root.boxes.isEmpty)
        root.boxes[0].w = 1e20
        model.diagrams[rootId] = root
        let ops = SheetDrawing.build(model, diagramId: rootId)
        #expect(!ops.isEmpty)
        let svg = try #require(SVGWriter.diagram(model, diagramId: rootId))
        #expect(svg.contains("<svg"))
        #expect(svg.contains(root.boxes[0].name))

        root.boxes[0].w = -1e20
        model.diagrams[rootId] = root
        #expect(!SheetDrawing.build(model, diagramId: rootId).isEmpty)
        #expect(SVGWriter.diagram(model, diagramId: rootId) != nil)
    }

    // MARK: F70 — the JSON parser refuses nesting it could not walk

    static let limit = JSONValue.maxNestingDepth

    static func nestedArrays(_ depth: Int) -> String {
        String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    }

    static func nestedObjects(_ depth: Int) -> String {
        String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
    }

    @Test("Arrays nested to the limit parse and write back byte for byte")
    func arraysAtLimit() throws {
        let text = Self.nestedArrays(Self.limit)
        let value = try JSONValue.parse(text)
        #expect(value.stringified(indent: 0) == text)
        let pretty = value.stringified()
        #expect(pretty.hasPrefix("[\n  [\n    [\n"))
        #expect(try JSONValue.parse(pretty) == value)
    }

    @Test("Objects nested to the limit parse and write back byte for byte")
    func objectsAtLimit() throws {
        let text = Self.nestedObjects(Self.limit)
        let value = try JSONValue.parse(text)
        #expect(value.stringified(indent: 0) == text)
        #expect(try JSONValue.parse(value.stringified()) == value)
    }

    @Test("One level past the limit fails at the bracket that went too deep")
    func oneLevelTooDeep() {
        let expected = JSONParseError(message: "JSON is nested too deeply", offset: Self.limit)
        #expect(throws: expected) { try JSONValue.parse(Self.nestedArrays(Self.limit + 1)) }
        // The 257th "{" sits after 256 copies of `{"a":`.
        let objectOffset = Self.limit * #"{"a":"#.utf8.count
        #expect(throws: JSONParseError(message: "JSON is nested too deeply", offset: objectOffset)) {
            try JSONValue.parse(Self.nestedObjects(Self.limit + 1))
        }
        // Far past the limit — the depths that used to overflow the stack.
        #expect(throws: expected) { try JSONValue.parse(Self.nestedArrays(10_000)) }
        #expect(throws: expected) { try JSONValue.parse(Self.nestedArrays(100_000)) }
        #expect(throws: (any Error).self) { try JSONValue.parse(Self.nestedObjects(10_000)) }
    }

    @Test("Mixed arrays and objects count every container")
    func mixedNesting() throws {
        let pairs = Self.limit / 2
        let open = String(repeating: #"[{"k":"#, count: pairs)
        let close = String(repeating: "}]", count: pairs)
        let atLimit = open + "null" + close
        #expect(try JSONValue.parse(atLimit).stringified(indent: 0) == atLimit)
        let tooDeep = open + "[null]" + close
        #expect(throws: JSONParseError(message: "JSON is nested too deeply", offset: open.utf8.count)) {
            try JSONValue.parse(tooDeep)
        }
    }

    @Test("Leaving a container gives its depth back to its siblings")
    func siblingsDoNotAccumulate() throws {
        // Two siblings each nesting to the limit are fine; a counter that never
        // decremented would count the second one twice as deep.
        let inner = Self.nestedArrays(Self.limit - 1)
        let text = "[\(inner),\(inner),\(inner)]"
        #expect(try JSONValue.parse(text).stringified(indent: 0) == text)
        let objects = #"{"a":\#(Self.nestedObjects(Self.limit - 1)),"b":\#(Self.nestedArrays(Self.limit - 1))}"#
        #expect(try JSONValue.parse(objects).stringified(indent: 0) == objects)
    }

    @Test("Shallow JSON still parses exactly as before")
    func shallowUnchanged() throws {
        let text = #"{"a":[1,{"b":[]}],"c":{},"d":"x","e":true,"f":null}"#
        #expect(try JSONValue.parse(text).stringified(indent: 0) == text)
        #expect(try ModelFile.serialize(ModelFile.deserialize(Fixtures.sampleText)) == Fixtures.sampleText)
    }

    @Test("A project file whose extra member nests past the limit fails to open instead of crashing")
    func deepExtraMemberFailsSoftly() throws {
        // A verbatim member the web app would keep; sample.idef0.json ends "\n}\n".
        let sample = Fixtures.sampleText
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.hasSuffix("}"))
        let body = String(trimmed.dropLast())

        let withinLimit = body + ",\n  \"deep\": " + Self.nestedArrays(Self.limit - 1) + "\n}\n"
        let model = try ModelFile.deserialize(withinLimit)
        #expect(model.extras["deep"] == (try JSONValue.parse(Self.nestedArrays(Self.limit - 1))))
        let written = ModelFile.serialize(model)
        #expect(written.contains("\"deep\": [\n    [\n"))
        #expect(try ModelFile.deserialize(written).extras == model.extras)

        let tooDeep = body + ",\n  \"deep\": " + Self.nestedArrays(Self.limit) + "\n}\n"
        #expect(throws: ModelFileError.self) { try ModelFile.deserialize(tooDeep) }
        do {
            _ = try ModelFile.deserialize(tooDeep)
            Issue.record("expected the deep file to fail")
        } catch let error as ModelFileError {
            #expect(error.description.hasPrefix("Not valid JSON: JSON is nested too deeply at position "))
        }
        #expect(throws: ModelFileError.self) {
            try ModelFile.deserialize(body + ",\n  \"deep\": " + Self.nestedArrays(10_000) + "\n}\n")
        }
    }

    @Test("A value at the limit survives every recursive walk on a default secondary-thread stack")
    func fitsSecondaryThreadStack() throws {
        // Thread stacks default to 512 KB, a fraction of the main thread's 8 MB;
        // document reads and exports run on them. Parse, pretty-write, `==`,
        // hash and release a value at the limit there.
        let text = Self.nestedArrays(Self.limit)
        let outcome = OSAllocatedUnfairLock<String?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            defer { done.signal() }
            do {
                let value = try JSONValue.parse(text)
                let pretty = value.stringified()
                let again = try JSONValue.parse(pretty)
                var hasher = Hasher()
                hasher.combine(again)
                _ = hasher.finalize()
                let equal = value == again && value.stringified(indent: 0) == text
                outcome.withLock { $0 = equal ? "ok" : "round trip differs" }
            } catch {
                outcome.withLock { $0 = "\(error)" }
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(outcome.withLock { $0 } == "ok")
    }
}
