// The whole Swift core against the web app, one scenario at a time.
//
// scripts/goldens.html's `computeAll(m)` records everything the model layer
// derives from a model — the decomposition tree, per-diagram numbering, ICOM
// codes and pairing, every arrow's anchors, route, path data and label spot,
// the concept registry's queries, the validator's issues, and the saved file —
// in one JSON record. `computeAll` below builds the identical record from the
// Swift core: same member names in the same order, same array order.
//
// The record is compared as the generator wrote it: stringified, with
// generated ids renumbered new1, new2… in order of first appearance, then
// parsed back. Because that numbering runs across the whole text, a member
// written out of order would misnumber every id after it — so this suite holds
// the port to the web app's member order as well as to its values.
//
// The regression tests at the end cover porting bugs found by replaying
// random models and edits through the web app's modules under Node; their
// expected values come from those modules.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("ScenarioParity")
struct ScenarioParityTests {

    private static let goldens = Fixtures.json("golden-scenarios.json").objectValue!

    // MARK: Every scenario

    @Test("computeAll matches the web app's record exactly", arguments: ScenarioReplayer.names)
    func scenario(_ name: String) throws {
        let m = try ScenarioReplayer.model(for: name)
        let golden = try #require(Self.goldens[name]?.objectValue)

        let text = IdNormaliser.normalise(Self.computeAll(m).stringified(indent: 0), fixed: IdNormaliser.fixedIds)
        let actual = try #require(try JSONValue.parse(text).objectValue)

        // Member names and order, recursively — the normalisation already
        // depends on it, but this names the first misplaced member directly.
        let order = keyOrderDiff(.object(golden), .object(actual), path: name)
        #expect(order == nil, "\(order ?? "")")

        // Values, section by section so a failure names where it is.
        for key in golden.keys where key != "file" {
            guard let expectedSection = golden[key], let actualSection = actual[key] else {
                Issue.record("\(name).\(key): missing from the Swift record")
                continue
            }
            let d = jsonDiff(expectedSection, actualSection, path: "\(name).\(key)")
            #expect(d == nil, "\(d ?? "")")
        }

        // The saved file, byte for byte. `textDiff` names the line; the UTF-8
        // comparison also catches what Swift's canonical `==` would call equal.
        let goldenFile = try #require(golden["file"]?.stringValue)
        let file = try #require(actual["file"]?.stringValue)
        let fileDiff = textDiff(goldenFile, file)
        #expect(fileDiff == nil, "\(name).file \(fileDiff ?? "")")
        #expect(goldenFile.utf8.elementsEqual(file.utf8), "\(name).file differs in its bytes")

        // And the whole record as JSON.stringify wrote it: every number to the
        // last digit, every string to the code unit.
        #expect(JSONValue.object(golden).stringified(indent: 0).utf8.elementsEqual(text.utf8),
                "\(name): record text differs from the golden's")
    }

    @Test("the scenario list and the goldens agree, and every section has content")
    func coverage() throws {
        let names = ScenarioReplayer.names
        #expect(!names.isEmpty && names.count == Set(names).count)
        #expect(Set(names) == Set(Self.goldens.keys))
        var arrows = 0, pairs = 0, orphans = 0, missing = 0, drift = 0, unused = 0, issues = 0, validated = 0
        for name in names {
            let g = Self.goldens[name]!.objectValue!
            for d in g["diagrams"]!.arrayValue! {
                let o = d.objectValue!
                arrows += o["arrows"]!.arrayValue!.count
                let p = o["pairing"]!.objectValue!
                pairs += p["pairs"]!.arrayValue!.count
                orphans += p["orphans"]!.arrayValue!.count
                missing += p["missing"]!.arrayValue!.count
            }
            let concepts = g["concepts"]!.objectValue!
            drift += concepts["drift"]!.arrayValue!.count
            unused += concepts["unused"]!.arrayValue!.count
            issues += g["issues"]!.arrayValue!.count
            validated += validate(try ScenarioReplayer.model(for: name)).count
        }
        #expect(arrows > 0 && pairs > 0 && orphans > 0 && missing > 0 && drift > 0 && unused > 0)
        // The issue total is the fixtures' own, so a new scenario needs no edit here.
        #expect(issues > 0 && issues == validated)
    }

    // MARK: Regressions — strings compared as JavaScript compares them

    /// Two spellings of "Café Menu": precomposed on the parent, decomposed on
    /// the child. The "K" of the control arrow is U+212A KELVIN SIGN on the child.
    private static let unicodeModel = #"""
    {"id":"mdl_u","title":"Brew","purpose":"p","viewpoint":"v","created":"2026-01-01","revised":"2026-01-01",
     "rootDiagramId":"dg_ctx","glossary":[],"diagrams":{
      "dg_ctx":{"node":"A-0","title":"Brew","boxes":[{"id":"bx_top","name":"Brew Coffee","number":0,"x":400,"y":300,"w":300,"h":170,"childDiagramId":"dg_a0"}],
       "arrows":[
        {"id":"ar_in","label":"Café Menu","from":{"type":"boundary","side":"left","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"left","pos":0.5}},
        {"id":"ar_ctl","label":"Kit Recipe","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"top","pos":0.5}},
        {"id":"ar_out","label":"Coffee","from":{"type":"box","boxId":"bx_top","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}]},
      "dg_a0":{"node":"A0","title":"Brew","parentBoxId":"bx_top","boxes":[
        {"id":"bx_1","name":"Grind Beans","number":1,"x":100,"y":172,"w":190,"h":112},
        {"id":"bx_2","name":"Heat Water","number":2,"x":400,"y":330,"w":190,"h":112},
        {"id":"bx_3","name":"Pour Cup","number":3,"x":700,"y":488,"w":190,"h":112}],
       "arrows":[
        {"id":"ar_cin","label":"Café Menu","from":{"type":"boundary","side":"left","pos":0.5},"to":{"type":"box","boxId":"bx_1","side":"left","pos":0.5}},
        {"id":"ar_cctl","label":"Kit Recipe","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_1","side":"top","pos":0.5}},
        {"id":"ar_cout","label":"Coffee","from":{"type":"box","boxId":"bx_3","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}]}}}
    """#

    private static func scalars(_ strings: [String]) -> [[Unicode.Scalar]] {
        strings.map { Array($0.unicodeScalars) }
    }

    @Test("terms that differ only in Unicode normalisation are two concepts, as in the web app")
    func canonicallyEquivalentTermsStayApart() throws {
        var m = try ModelFile.deserialize(Self.unicodeModel)
        m.bindAll()

        // Swift's `==` calls "Café" and "Cafe\u{301}" equal; JavaScript's ===
        // does not, so the web app binds them to separate concepts. Lower-casing
        // does fold the Kelvin sign into "k", so those two share one.
        #expect(Self.scalars(m.glossary.map(\.term)) == Self.scalars([
            "Brew Coffee", "Caf\u{E9} Menu", "Cafe\u{301} Menu", "Coffee",
            "Grind Beans", "Heat Water", "Kit Recipe", "Pour Cup",
        ]))
        let parentIn = try #require(m.diagrams["dg_ctx"]?.arrows[0].conceptId)
        let childIn = try #require(m.diagrams["dg_a0"]?.arrows[0].conceptId)
        #expect(!jsStrictEquals(parentIn, childIn))
        let nfd = try #require(m.findConcept("Cafe\u{301} Menu"))
        #expect(jsStrictEquals(nfd.id, childIn))

        // Pairing falls through to position, and the check reports the relabel.
        let pairing = m.icomPairing(try #require(m.diagrams["dg_a0"]))
        #expect(pairing.pairs.map { "\($0.side.rawValue) \($0.child.arrow.id) \($0.parent.arrow.id) \($0.code)" }
                == ["left ar_cin ar_in I1", "top ar_cctl ar_ctl C1", "right ar_cout ar_out O1"])
        #expect(pairing.orphans.isEmpty && pairing.missing.isEmpty)
        #expect(m.driftedOccurrences().isEmpty)

        let issues = validate(m)
        let rows = issues.map { i in
            [i.severity.rawValue, i.code, i.message, i.diagramId ?? "-", i.target?.rawValue ?? "-", i.targetId ?? "-"].joined(separator: " | ")
        }
        #expect(Self.scalars(rows) == Self.scalars([
            "error | box-output | A1 has no output. Every IDEF0 box requires at least one output arrow from its right. | dg_a0 | box | bx_1",
            "error | box-control | A2 has no control. Every IDEF0 box requires at least one control arrow on its top. | dg_a0 | box | bx_2",
            "error | box-output | A2 has no output. Every IDEF0 box requires at least one output arrow from its right. | dg_a0 | box | bx_2",
            "error | box-control | A3 has no control. Every IDEF0 box requires at least one control arrow on its top. | dg_a0 | box | bx_3",
            "warning | icom-concept-mismatch | A0: I1 \u{201C}Cafe\u{301} Menu\u{201D} is bound to a different concept than parent box A0 carries as \u{201C}Caf\u{E9} Menu\u{201D}. The two ends of an ICOM pair should denote the same object (\u{00A7}3.3.2.4). | dg_a0 | arrow | ar_cin",
            "warning | icom-relabel | A0: I1 reads \u{201C}Cafe\u{301} Menu\u{201D} where parent box A0 carries \u{201C}Caf\u{E9} Menu\u{201D}. Fine if it details that arrow \u{2014} otherwise the two have drifted apart. | dg_a0 | arrow | ar_cin",
            "warning | concept-undefined | \u{201C}Brew Coffee\u{201D} (activity) is used 1\u{D7} but has no glossary definition. | dg_ctx | box | bx_top",
            "warning | concept-undefined | \u{201C}Caf\u{E9} Menu\u{201D} (data) is used 1\u{D7} but has no glossary definition. | dg_ctx | arrow | ar_in",
            "warning | concept-undefined | \u{201C}Cafe\u{301} Menu\u{201D} (data) is used 1\u{D7} but has no glossary definition. | dg_a0 | arrow | ar_cin",
            "warning | concept-undefined | \u{201C}Coffee\u{201D} (data) is used 2\u{D7} but has no glossary definition. | dg_ctx | arrow | ar_out",
            "warning | concept-undefined | \u{201C}Grind Beans\u{201D} (activity) is used 1\u{D7} but has no glossary definition. | dg_a0 | box | bx_1",
            "warning | concept-undefined | \u{201C}Heat Water\u{201D} (activity) is used 1\u{D7} but has no glossary definition. | dg_a0 | box | bx_2",
            "warning | concept-undefined | \u{201C}Kit Recipe\u{201D} (data) is used 2\u{D7} but has no glossary definition. | dg_ctx | arrow | ar_ctl",
            "warning | concept-undefined | \u{201C}Pour Cup\u{201D} (activity) is used 1\u{D7} but has no glossary definition. | dg_a0 | box | bx_3",
        ]))
    }

    @Test("ids and keys that differ only in Unicode normalisation stay distinct")
    func canonicallyEquivalentKeysStayApart() throws {
        let nfc = "dg_caf\u{E9}", nfd = "dg_cafe\u{301}"
        var map = OrderedMap<Int>()
        map[nfc] = 1
        map[nfd] = 2
        #expect(map.count == 2 && map[nfc] == 1 && map[nfd] == 2)
        map[nfd] = nil
        #expect(Self.scalars(map.keys) == Self.scalars([nfc]))

        // JSON.parse keeps both members; a box whose id matches neither
        // spelling exactly is not found.
        let object = try #require(try JSONValue.parse(#"{"café":1,"café":2}"#).objectValue)
        #expect(object.count == 2)
        let dg = Diagram(id: "dg", node: "A0", title: "", boxes: [Box(id: "bx_caf\u{E9}", name: "", number: 1, x: 0, y: 0, w: 1, h: 1)])
        #expect(dg.findBox("bx_cafe\u{301}") == nil)
        #expect(!Endpoint.box("bx_cafe\u{301}", .left).isOnBox("bx_caf\u{E9}"))
    }

    // MARK: Regressions — localeCompare as ICU orders

    @Test("the glossary sorts as the browser's collator does where Foundation's calls terms equal")
    func localeCompareTertiaryOrder() {
        // Full-width letters, ligatures, no-break spaces: equal to Foundation,
        // ordered by ICU. Soft hyphens and zero-width spaces: ignored by ICU,
        // weighed by Foundation. Digits of another script: equal to both, so a
        // stable sort keeps the input order.
        let terms = ["file", "\u{FB01}le", "A Wide", "\u{FF21} Wide", "x\u{A0}y", "x y", "3 Items", "\u{663} Items",
                     "Soft\u{AD}ware", "Software", "Zero\u{200B}Width", "ZeroWidth"]
        let sorted = terms.stableSorted { jsLocaleCompare($0, $1) < 0 }
        #expect(Self.scalars(sorted) == Self.scalars([
            "3 Items", "\u{663} Items", "A Wide", "\u{FF21} Wide", "file", "\u{FB01}le",
            "Soft\u{AD}ware", "Software", "x y", "x\u{A0}y", "Zero\u{200B}Width", "ZeroWidth",
        ]))
        let reversed = terms.reversed().stableSorted { jsLocaleCompare($0, $1) < 0 }
        #expect(Self.scalars(reversed) == Self.scalars([
            "\u{663} Items", "3 Items", "A Wide", "\u{FF21} Wide", "file", "\u{FB01}le",
            "Software", "Soft\u{AD}ware", "x y", "x\u{A0}y", "ZeroWidth", "Zero\u{200B}Width",
        ]))

        // Through the registry, which re-sorts on every new concept. "x y" is
        // the same term as "x\u{A0}y" (whitespace collapses), so it is not added.
        var m = IDEF0Model.create(title: "Sort")
        for t in terms { m.resolveConcept(t) }
        #expect(Self.scalars(m.glossary.map(\.term)) == Self.scalars([
            "3 Items", "\u{663} Items", "A Wide", "\u{FF21} Wide", "file", "\u{FB01}le",
            "Soft\u{AD}ware", "Software", "x\u{A0}y", "Zero\u{200B}Width", "ZeroWidth",
        ]))
    }

    // MARK: Regressions — XML escaping

    @Test("escapeXml escapes a markup character that carries a combining mark")
    func escapeXmlCombiningMarks() {
        // "<" + U+0338 is one Swift Character (it composes to "≮"), so matching
        // Characters against "<" missed it and wrote a raw "<" into the XML.
        let cases: [(String, String)] = [
            ("<\u{338}", "&lt;\u{338}"),
            ("a>\u{338}b", "a&gt;\u{338}b"),
            ("&\u{301}", "&amp;\u{301}"),
            ("\"\u{301}'\u{301}", "&quot;\u{301}&apos;\u{301}"),
        ]
        for (input, expected) in cases {
            #expect(escapeXml(input).unicodeScalars.elementsEqual(expected.unicodeScalars), "escapeXml(\(input.debugDescription))")
        }
    }

    // MARK: Record comparison

    /// The first object whose member names or member order differ, or nil.
    private func keyOrderDiff(_ expected: JSONValue, _ actual: JSONValue, path: String) -> String? {
        switch (expected, actual) {
        case (.object(let e), .object(let a)):
            if !e.keys.elementsEqual(a.keys, by: { jsStrictEquals($0, $1) }) {
                return "\(path): members \(e.keys), got \(a.keys)"
            }
            for m in e.members {
                if let d = keyOrderDiff(m.value, a[m.key]!, path: "\(path).\(m.key)") { return d }
            }
            return nil
        case (.array(let e), .array(let a)):
            for (i, pair) in zip(e, a).enumerated() {
                if let d = keyOrderDiff(pair.0, pair.1, path: "\(path)[\(i)]") { return d }
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - computeAll, as scripts/goldens.html builds it

extension ScenarioParityTests {
    /// The golden record for one model, member for member. Object literals
    /// follow the web app's: `anchorOf` is `{ ...pt, nx, ny, boundary, ok }`,
    /// `pointAt` `{ x, y, dx, dy }`, `longestSegmentMid` `{ x, y, horizontal, length }`.
    static func computeAll(_ m: IDEF0Model) -> JSONValue {
        var diagrams: [JSONValue] = []
        for dg in m.diagrams.values {
            let codes = m.icomCodes(dg)
            let p = m.icomPairing(dg)
            let obstacles = dg.boxes.map(\.rect)
            diagrams.append(obj([
                ("id", .string(dg.id)),
                ("node", .string(dg.node)),
                ("title", .string(dg.title)),
                ("titleLocked", .bool(dg.titleLocked)),
                ("parentBoxId", opt(dg.parentBoxId)),
                ("boxes", .array(dg.boxes.map { b in
                    obj([
                        ("id", .string(b.id)), ("name", .string(b.name)), ("number", .number(Double(b.number))),
                        ("node", .string(boxNode(dg, b))),
                        ("x", .number(b.x)), ("y", .number(b.y)), ("w", .number(b.w)), ("h", .number(b.h)),
                        ("conceptId", opt(b.conceptId)), ("childDiagramId", opt(b.childDiagramId)),
                    ])
                })),
                ("sortedBoxes", .array(dg.sortedBoxes.map { .string($0.id) })),
                ("readingOrder", .array(boxReadingOrder(dg.boxes).map { .string($0.id) })),
                ("icom", .array(dg.arrows.flatMap { a in
                    ArrowEnd.allCases.map { end in
                        .array([.string(a.id), .string(end.rawValue), opt(codes["\(a.id):\(end.rawValue)"])])
                    }
                })),
                ("pairing", obj([
                    ("pairs", .array(p.pairs.map {
                        .array([.string($0.side.rawValue), .string($0.child.arrow.id), .string($0.child.end.rawValue),
                                .string($0.parent.arrow.id), .string($0.code)])
                    })),
                    ("orphans", .array(p.orphans.map {
                        .array([.string($0.side.rawValue), .string($0.child.arrow.id), .string($0.child.end.rawValue)])
                    })),
                    ("missing", .array(p.missing.map {
                        .array([.string($0.side.rawValue), .string($0.parent.arrow.id), .string($0.parent.code)])
                    })),
                ])),
                ("ports", .array(m.ports(dg).map(portJSON))),
                ("arrows", .array(dg.arrows.map { a in
                    let from = anchorOf(dg, a.from), to = anchorOf(dg, a.to)
                    let pts = routePoints(from, to, bend: a.bend, obstacles: obstacles)
                    let mid = longestSegmentMid(pts)
                    let at = pointAt(pts, 0.5)
                    return obj([
                        ("id", .string(a.id)), ("label", .string(a.label)), ("role", .string(a.role.rawValue)),
                        ("conceptId", opt(a.conceptId)),
                        ("from", anchorJSON(from)), ("to", anchorJSON(to)),
                        ("pts", .array(pts.map { obj([("x", .number($0.x)), ("y", .number($0.y))]) })),
                        ("path", .string(pointsToPath(pts))),
                        ("mid", obj([("x", .number(mid.x)), ("y", .number(mid.y)),
                                     ("horizontal", .bool(mid.horizontal)), ("length", .number(mid.length))])),
                        ("at", obj([("x", .number(at.x)), ("y", .number(at.y)), ("dx", .number(at.dx)), ("dy", .number(at.dy))])),
                        ("dist", .number(distToPolyline(pts, Point(x: 500, y: 400)))),
                    ])
                })),
            ]))
        }

        // `C.conceptUsage(m).get(g.id) || 0` — the Map's keys are code units.
        let usage = m.exactConceptUsage()
        let issues = validate(m)
        let summary = summarize(issues)
        return obj([
            ("tree", .array(m.diagramTree().map {
                .array([.string($0.diagram.id), .string($0.diagram.node), .number(Double($0.depth))])
            })),
            ("diagrams", .array(diagrams)),
            ("concepts", obj([
                ("glossary", .array(m.glossary.map {
                    .array([.string($0.id), .string($0.term), .string($0.kind), .string($0.definition)])
                })),
                ("usage", .array(m.glossary.map {
                    .array([.string($0.id), .number(Double(usage[JSStringKey($0.id)] ?? 0))])
                })),
                ("occurrences", .array(m.glossary.map { g in
                    .array([.string(g.id), .array(m.occurrencesOf(g.id).map { o in
                        obj([("diagramId", .string(o.diagramId)), ("node", .string(o.node)), ("kind", .string(o.kind.rawValue)),
                             ("id", .string(o.id)), ("text", .string(o.text))])
                    })])
                })),
                ("unused", .array(m.unusedConcepts().map { .string($0.id) })),
                ("drift", .array(m.driftedOccurrences().map { o in
                    obj([("diagramId", .string(o.diagramId)), ("node", .string(o.node)), ("kind", .string(o.kind.rawValue)), ("id", .string(o.id)),
                         ("text", .string(o.text)), ("conceptId", .string(o.conceptId)), ("term", .string(o.term))])
                })),
                // S01: `[id, bundleOf(id)?.id ?? null, effectiveConceptId(id), members]`.
                ("bundles", .array(m.glossary.map { g in
                    .array([.string(g.id), opt(m.bundleOf(g.id)?.id), opt(m.effectiveConceptId(g.id)),
                            .array(g.members.map(JSONValue.string))])
                })),
            ])),
            ("issues", .array(issues.map { i in
                .array([.string(i.severity.rawValue), .string(i.code), .string(i.message),
                        opt(i.diagramId), opt(i.target?.rawValue), opt(i.targetId)])
            })),
            ("summary", obj([("errors", .number(Double(summary.errors))), ("warnings", .number(Double(summary.warnings)))])),
            ("file", .string(ModelFile.serialize(m))),
        ])
    }

    private static func anchorJSON(_ a: Anchor) -> JSONValue {
        obj([("x", .number(a.x)), ("y", .number(a.y)), ("nx", .number(a.nx)), ("ny", .number(a.ny)),
             ("boundary", .bool(a.boundary)), ("ok", .bool(a.ok))])
    }

    /// A port as the generator spreads it — `{ ...port, shape: portShape(port) }`.
    static func portJSON(_ p: ICOMPort) -> JSONValue {
        let s = portShape(p)
        return obj([
            ("side", .string(p.side.rawValue)), ("pos", .number(p.pos)), ("code", .string(p.code)), ("label", .string(p.label)),
            ("conceptId", opt(p.conceptId)), ("parentArrowId", .string(p.parentArrowId)), ("role", .string(p.role.rawValue)),
            ("shape", obj([
                ("edge", obj([("x", .number(s.edge.x)), ("y", .number(s.edge.y))])),
                ("inner", obj([("x", .number(s.inner.x)), ("y", .number(s.inner.y))])),
            ])),
        ])
    }

    private static func obj(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(members.map { JSONMember($0.0, $0.1) }))
    }

    private static func opt(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
}
