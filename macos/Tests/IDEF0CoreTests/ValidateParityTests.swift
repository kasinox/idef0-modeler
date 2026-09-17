// The validator against goldens captured from the web app: every issue of every
// scenario — severity, code, message to the character, and what it points at —
// in the order the web app reports them, plus hand-built models for the rules
// and heuristic edge cases the scenarios never reach.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("ValidateParity")
struct ValidateParityTests {

    // MARK: Golden access

    private static let scenarios = Fixtures.json("golden-scenarios.json").objectValue!

    /// One issue as the generator recorded it: [severity, code, message, diagramId, kind, id].
    private static func row(_ i: ValidationIssue, _ map: (String?) -> String?) -> JSONValue {
        func opt(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
        return .array([
            .string(i.severity.rawValue), .string(i.code), .string(i.message),
            opt(map(i.diagramId)), opt(i.target?.rawValue), opt(map(i.targetId)),
        ])
    }

    private static func summaryJSON(_ s: IssueSummary) -> JSONValue {
        var o = JSONObject()
        o["errors"] = .number(Double(s.errors))
        o["warnings"] = .number(Double(s.warnings))
        return .object(o)
    }

    // MARK: Scenarios

    @Test("every scenario's issues and summary match the web app's", arguments: ScenarioReplayer.names)
    func scenario(_ name: String) throws {
        let m = try ScenarioReplayer.model(for: name)
        let golden = try #require(Self.scenarios[name]?.objectValue)
        let map = GoldenIdMap(model: m, golden: golden)
        let issues = validate(m)

        let expected = try #require(golden["issues"]?.arrayValue)
        #expect(issues.count == expected.count, "\(name): \(issues.count) issues, golden has \(expected.count)")
        for (k, pair) in zip(expected, issues).enumerated() {
            let d = jsonDiff(pair.0, Self.row(pair.1, { map($0) }), path: "\(name).issues[\(k)]")
            #expect(d == nil, "\(d ?? "")")
        }

        let d = jsonDiff(golden["summary"]!, Self.summaryJSON(summarize(issues)), path: "\(name).summary")
        #expect(d == nil, "\(d ?? "")")
    }

    @Test("the scenarios cover the issue codes they were written for")
    func coverage() throws {
        var codes = Set<String>()
        var total = 0
        var goldenTotal = 0
        for name in ScenarioReplayer.names {
            let issues = validate(try ScenarioReplayer.model(for: name))
            total += issues.count
            goldenTotal += try #require(Self.scenarios[name]?.objectValue?["issues"]?.arrayValue).count
            codes.formUnion(issues.map(\.code))
        }
        // The scenario list and the goldens are regenerated together; the
        // counts come from the fixtures so a new scenario needs no edit here.
        #expect(ScenarioReplayer.names.count == Self.scenarios.count)
        #expect(total > 0 && total == goldenTotal)
        for code in ["concept-undefined", "ctx-tunnel", "box-number-range", "box-number-order", "icom-relabel", "icom-orphan",
                     "concept-unbound", "icom-missing", "decomp-count", "box-control", "box-output",
                     "box-name", "box-verb", "boundary-direction", "box-call-count", "call-decomposed",
                     "call-target", "reserved-term", "concept-kind", "id-dup", "detail-dangling",
                     "detail-parent", "decomp-cycle", "diagram-unreachable"] {
            #expect(codes.contains(code), "no scenario raises \(code)")
        }
    }

    // MARK: No context

    @Test("a model whose root names no diagram reports only that")
    func noContext() {
        var m = IDEF0Model.create(title: "")
        m.purpose = ""
        m.rootDiagramId = "dg_nowhere"
        let issues = validate(m)
        #expect(issues == [ValidationIssue(
            severity: .error, code: "no-context", message: "The model has no A-0 context diagram.",
            diagramId: nil, target: nil, targetId: nil)])
        #expect(summarize(issues) == IssueSummary(errors: 1, warnings: 0))
    }

    // MARK: Edge-case model

    /// A model built to break every structural rule the scenarios leave alone:
    /// duplicate numbers and nodes, blank labels, passthrough, self and
    /// dangling arrows, unknown concept kinds. `expectedEdge` is what the web
    /// app's own deserialize + validate printed for it under Node.
    private static let edgeModel = #"""
{"schema":"idef0-modeler/1","id":"mdl_edge","title":"  ","purpose":"","viewpoint":"Someone","status":"WORKING","created":"2026-09-14","revised":"2026-09-14",
"glossary":[{"id":"gl_plan","term":"Planning","kind":"activity","definition":""},
            {"id":"gl_x","term":"Thing X","kind":"weird","definition":"  "},
            {"id":"gl_def","term":"Defined","kind":"data","definition":"ok"},
            {"id":"gl_unused","term":"Unused","kind":"data","definition":""}],
"rootDiagramId":"dg_ctx",
"diagrams":{
 "dg_ctx":{"id":"dg_ctx","node":"A-0","title":"Edge","parentBoxId":null,"boxes":[
    {"id":"bx_top","name":"Planning ","number":0,"conceptId":"gl_plan","x":100,"y":100,"w":190,"h":112,"childDiagramId":"dg_child"},
    {"id":"bx_blank","name":"   ","number":0,"conceptId":null,"x":400,"y":100,"w":190,"h":112}],
  "arrows":[
    {"id":"ar_blank","label":"  ","from":{"type":"boundary","side":"left","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5},"tunnelFrom":true},
    {"id":"ar_self","label":"Loop","conceptId":"gl_gone","from":{"type":"box","boxId":"bx_top","side":"left","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"right","pos":0.5}},
    {"id":"ar_dangle","label":"","from":{"type":"box","boxId":"bx_gone","side":"bottom","pos":0.5},"to":{"type":"boundary","side":"bottom","pos":0.5}},
    {"id":"ar_ctl","label":"Defined","conceptId":"gl_def","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"top","pos":0.5},"tunnelTo":true},
    {"id":"ar_out","label":"Big  Output","conceptId":"gl_def","from":{"type":"box","boxId":"bx_top","side":"right","pos":0.4},"to":{"type":"boundary","side":"right","pos":0.4}},
    {"id":"ar_out2","label":"Second Output","from":{"type":"box","boxId":"bx_top","side":"right","pos":0.8},"to":{"type":"boundary","side":"right","pos":0.8}}
  ]},
 "dg_child":{"id":"dg_child","node":"A0","title":"Child","parentBoxId":"bx_top","boxes":[
    {"id":"bx_c1","name":"The Thing","number":1,"conceptId":"gl_x","x":100,"y":100,"w":190,"h":112},
    {"id":"bx_c2","name":"Management","number":9,"conceptId":"gl_x","x":400,"y":300,"w":190,"h":112},
    {"id":"bx_c3","name":"Build It","number":1,"conceptId":"gl_x","x":700,"y":500,"w":190,"h":112}],
  "arrows":[
    {"id":"ar_corphan","label":"  ","from":{"type":"boundary","side":"left","pos":0.5},"to":{"type":"box","boxId":"bx_c1","side":"left","pos":0.5}},
    {"id":"ar_cout","label":"big output","from":{"type":"box","boxId":"bx_c1","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.9}},
    {"id":"ar_cout2","label":"Detailed Output","from":{"type":"box","boxId":"bx_c2","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.95}}
  ]},
 "dg_dup":{"id":"dg_dup","node":"A0","title":"Dup","parentBoxId":null,"boxes":[],"arrows":[]}
}}
"""#

    private static let expectedEdge: [[String?]] = [
            ["error", "ctx-single-box", "The A-0 context diagram holds 2 boxes; it must hold exactly one.", "dg_ctx", nil, nil],
            ["error", "box-number-dup", "Box number 0 appears twice on A-0.", "dg_ctx", "box", "bx_blank"],
            ["error", "box-name", "Box 0 on A-0 is unnamed. Box names are active verb phrases.", "dg_ctx", "box", "bx_blank"],
            ["error", "box-control", "A0 has no control. Every IDEF0 box requires at least one control arrow on its top.", "dg_ctx", "box", "bx_blank"],
            ["error", "box-output", "A0 has no output. Every IDEF0 box requires at least one output arrow from its right.", "dg_ctx", "box", "bx_blank"],
            ["error", "arrow-label", "An unlabelled unclassified arrow on A-0. Arrow labels are noun phrases.", "dg_ctx", "arrow", "ar_blank"],
            ["error", "arrow-passthrough", "“  ” runs from boundary to boundary on A-0 without touching a box.", "dg_ctx", "arrow", "ar_blank"],
            ["error", "ctx-tunnel", "“  ” is tunnelled at its unconnected end on the A-0 context diagram. A-0 has no parent, so it carries neither ICOM codes nor tunnels.", "dg_ctx", "arrow", "ar_blank"],
            ["error", "arrow-origin", "“Loop” leaves a box from its left. Arrows leave a box only from the right (output) or bottom (call).", "dg_ctx", "arrow", "ar_self"],
            ["error", "arrow-target", "“Loop” enters a box on its right. The right side carries outputs only.", "dg_ctx", "arrow", "ar_self"],
            ["error", "arrow-self", "“Loop” starts and ends on the same box.", "dg_ctx", "arrow", "ar_self"],
            ["error", "concept-unbound", "“Loop” on A-0 is not bound to a glossary concept. Re-enter its label to bind it.", "dg_ctx", "arrow", "ar_self"],
            ["error", "arrow-label", "An unlabelled call arrow on A-0. Arrow labels are noun phrases.", "dg_ctx", "arrow", "ar_dangle"],
            ["error", "arrow-dangling", "An arrow on A-0 points at a box that no longer exists.", "dg_ctx", "arrow", "ar_dangle"],
            // ar_ctl's tunnel is at its box end (to bx_top), which FIPS 183
            // §3.4.2 allows even on A-0 — only an unconnected end is barred.
            ["error", "concept-unbound", "“Second Output” on A-0 is not bound to a glossary concept. Re-enter its label to bind it.", "dg_ctx", "arrow", "ar_out2"],
            ["error", "icom-missing", "A-0: O3 “Second Output” on box A0 (right) does not appear as a boundary arrow on A0. Add it there or tunnel it.", "dg_ctx", "box", "bx_top"],
            ["error", "box-number-range", "Box number 9 on A0 is outside the 1–6 range IDEF0 allows.", "dg_child", "box", "bx_c2"],
            ["error", "box-number-dup", "Box number 1 appears twice on A0.", "dg_child", "box", "bx_c3"],
            ["error", "box-control", "A1 has no control. Every IDEF0 box requires at least one control arrow on its top.", "dg_child", "box", "bx_c1"],
            ["error", "box-control", "A9 has no control. Every IDEF0 box requires at least one control arrow on its top.", "dg_child", "box", "bx_c2"],
            ["error", "box-control", "A1 has no control. Every IDEF0 box requires at least one control arrow on its top.", "dg_child", "box", "bx_c3"],
            ["error", "box-output", "A1 has no output. Every IDEF0 box requires at least one output arrow from its right.", "dg_child", "box", "bx_c3"],
            ["error", "arrow-label", "An unlabelled input arrow on A0. Arrow labels are noun phrases.", "dg_child", "arrow", "ar_corphan"],
            ["error", "concept-unbound", "“big output” on A0 is not bound to a glossary concept. Re-enter its label to bind it.", "dg_child", "arrow", "ar_cout"],
            ["error", "concept-unbound", "“Detailed Output” on A0 is not bound to a glossary concept. Re-enter its label to bind it.", "dg_child", "arrow", "ar_cout2"],
            ["error", "node-dup", "Node number A0 is used by more than one diagram.", "dg_dup", nil, nil],
            // dg_dup hangs off nothing, so it is reported before any rule that
            // walks a diagram — and still after every error.
            ["warning", "diagram-unreachable", "A0 is not reached from the A-0 context diagram through any decomposition. Link it to the box it details or delete it.", "dg_dup", nil, nil],
            ["warning", "model-purpose", "The model states no purpose. Every IDEF0 model must declare one.", "dg_ctx", nil, nil],
            ["warning", "model-title", "The model has no title.", "dg_ctx", nil, nil],
            ["warning", "box-verb", "“Planning ” (A0) may not be an active verb phrase — IDEF0 box names are verbs, e.g. “Assemble Chassis”.", "dg_ctx", "box", "bx_top"],
            ["warning", "icom-relabel", "A0: I1 reads “(unlabelled)” where parent box A0 carries “Loop”. Fine if it details that arrow — otherwise the two have drifted apart.", "dg_child", "arrow", "ar_corphan"],
            ["warning", "icom-relabel", "A0: O2 reads “Detailed Output” where parent box A0 carries “Loop”. Fine if it details that arrow — otherwise the two have drifted apart.", "dg_child", "arrow", "ar_cout2"],
            ["warning", "box-verb", "“The\u{00A0}Thing” (A1) may not be an active verb phrase — IDEF0 box names are verbs, e.g. “Assemble Chassis”.", "dg_child", "box", "bx_c1"],
            ["warning", "box-verb", "“Management” (A9) may not be an active verb phrase — IDEF0 box names are verbs, e.g. “Assemble Chassis”.", "dg_child", "box", "bx_c2"],
            ["warning", "decomp-count", "A0 has 0 box(es). A decomposition should have 3–6; fewer than 3 adds no detail.", "dg_dup", nil, nil],
            ["warning", "concept-undefined", "“Planning” (activity) is used 1× but has no glossary definition.", "dg_ctx", "box", "bx_top"],
            ["warning", "concept-undefined", "“Thing X” (weird) is used 3× but has no glossary definition.", "dg_child", "box", "bx_c1"],
    ]

    // MARK: box-number-order (F10)

    /// The root box decomposed into `count` empty-named boxes on the default
    /// staircase — enough to exercise box ordering without the arrows or
    /// names that the other rules would otherwise also flag.
    private static func decomposedModel(count: Int = 3) -> (IDEF0Model, ctx: String, child: String) {
        var m = IDEF0Model.create(title: "Make Widget")
        let ctx = m.rootDiagramId
        let top = m.contextDiagram!.boxes[0]
        let child = m.decomposeBox(diagramId: ctx, boxId: top.id, count: count)!
        return (m, ctx, child)
    }

    /// A resize (or a typed X/Y) can move a box without renumbering, and a
    /// hand-edited or imported file can carry numbers that never matched
    /// reading order at all. Swapping two numbers, with positions untouched,
    /// reproduces the disagreement without depending on the geometry heuristic.
    @Test("box-number-order fires once per diagram when the stored numbers disagree with reading order")
    func boxNumberOrderFires() throws {
        var (m, ctx, child) = Self.decomposedModel()
        let node = try #require(m.diagrams[child]).node
        let last = try #require(m.diagrams[child]).boxes.count - 1
        m.updateDiagram(child) { d in
            let a = d.boxes[0].number, b = d.boxes[last].number
            d.boxes[0].number = b
            d.boxes[last].number = a
        }
        let issues = validate(m)
        let order = try #require(issues.first { $0.code == "box-number-order" })
        #expect(order.severity == .warning)
        #expect(order.message == "\(node): box numbers do not follow reading order (FIPS 183 §3.3.4.1); move a box or renumber to re-derive them.")
        #expect(order.diagramId == child)
        #expect(order.target == nil && order.targetId == nil)
        #expect(issues.filter { $0.code == "box-number-order" }.count == 1, "once per diagram, not once per box")
        // A-0's single box is always renumbered to 0 (box-number-range covers
        // that box), so the order check never looks at the context diagram.
        #expect(!issues.contains { $0.code == "box-number-order" && $0.diagramId == ctx })
    }

    @Test("box-number-order is skipped once box-number-dup or box-number-range already flagged the diagram")
    func boxNumberOrderSkippedWithOtherNumberIssues() throws {
        var (dupModel, _, dupChild) = Self.decomposedModel()
        let lastIndex = try #require(dupModel.diagrams[dupChild]).boxes.count - 1
        dupModel.updateDiagram(dupChild) { d in
            d.boxes[lastIndex].number = d.boxes[0].number  // duplicate, and now out of order too
        }
        let dupIssues = validate(dupModel)
        #expect(dupIssues.contains { $0.code == "box-number-dup" && $0.diagramId == dupChild })
        #expect(!dupIssues.contains { $0.code == "box-number-order" && $0.diagramId == dupChild })

        var (rangeModel, _, rangeChild) = Self.decomposedModel()
        rangeModel.updateDiagram(rangeChild) { d in
            let a = d.boxes[0].number, b = d.boxes[d.boxes.count - 1].number
            d.boxes[0].number = b
            d.boxes[d.boxes.count - 1].number = a
            d.boxes[0].number = 9  // now out of range, and still out of order
        }
        let rangeIssues = validate(rangeModel)
        #expect(rangeIssues.contains { $0.code == "box-number-range" && $0.diagramId == rangeChild })
        #expect(!rangeIssues.contains { $0.code == "box-number-order" && $0.diagramId == rangeChild })
    }

    @Test("a hand-built edge-case model matches the web app's output issue for issue")
    func edgeCases() throws {
        let m = try ModelFile.deserialize(Self.edgeModel)
        let issues = validate(m)
        #expect(issues.count == Self.expectedEdge.count)
        for (k, pair) in zip(Self.expectedEdge, issues).enumerated() {
            let (e, i) = pair
            let actual: [String?] = [i.severity.rawValue, i.code, i.message, i.diagramId, i.target?.rawValue, i.targetId]
            #expect(actual == e, "edge.issues[\(k)]")
        }
        #expect(summarize(issues) == IssueSummary(errors: 26, warnings: 11))
    }

    @Test("errors come first, each severity in discovery order")
    func ordering() throws {
        let issues = validate(try ModelFile.deserialize(Self.edgeModel))
        let firstWarning = try #require(issues.firstIndex { $0.severity == .warning })
        #expect(issues[..<firstWarning].allSatisfy { $0.severity == .error })
        #expect(issues[firstWarning...].allSatisfy { $0.severity == .warning })
        // The structural warnings and model-purpose are found before any diagram
        // is visited, yet sort after every error.
        #expect(issues[firstWarning].code == "diagram-unreachable")
        #expect(issues[firstWarning + 1].code == "model-purpose")
    }

    // MARK: Verb-phrase heuristic

    /// Whether a lone context box with this name draws the `box-verb` warning.
    private static func flagged(_ name: String) -> Bool {
        var m = IDEF0Model.create(title: "Model")
        let dg = m.rootDiagramId
        m.updateDiagram(dg) { $0.boxes[0].name = name }
        return validate(m).contains { $0.code == "box-verb" }
    }

    /// Cases read from `NOUNY = /^(the|a|an)\s/i` and
    /// `/(?:ing|tion|sion|ment|ness|ity|ance|ence)$/i`; each verdict was
    /// confirmed by running the web app's looksLikeVerbPhrase under Node.
    @Test("looksLikeVerbPhrase: article prefix", arguments: [
        ("The Shipping", true), ("the\tthing", true), ("An Order", true), ("A thing", true),
        ("THE ORDER", true), ("The\u{00A0}Order", true), ("The\u{2028}Order", true), ("an\u{3000}x", true),
        // NOUNY needs whitespace after the article, and reads the untrimmed name.
        ("Theory Building", false), ("Another order", false), ("The", false), ("A", false),
        (" The Order", false), ("The\u{200B}Order", false), ("Thé Order", false), ("a\u{0301} thing", false),
    ])
    func articles(_ name: String, _ expected: Bool) {
        #expect(Self.flagged(name) == expected, "\(name.debugDescription)")
    }

    @Test("looksLikeVerbPhrase: nominal suffix on a one-word name", arguments: [
        ("Planning", true), ("PLANNING", true), ("Planning ", true), ("\tPlanning\n", true),
        ("Quality", true), ("Maintenance", true), ("Existence", true), ("Decision", true),
        ("Station", true), ("Management", true), ("Readiness", true), ("Sing", true), ("ing", true),
        ("Pre-Processing", true),
        // Two words, no suffix, or a suffix letter only a Unicode fold would match.
        ("Plan Manufacturing", false), ("Build", false), ("Ingest", false), ("Processing-Unit", false),
        ("Assemble Chassis", false), ("Plann\u{0131}ng", false), ("Deci\u{017F}ion", false), ("Test\u{FEFF}", false),
    ])
    func suffixes(_ name: String, _ expected: Bool) {
        #expect(Self.flagged(name) == expected, "\(name.debugDescription)")
    }

    @Test("the box-verb message quotes the name as written; a blank name is box-name instead")
    func verbMessage() throws {
        var m = IDEF0Model.create(title: "Model")
        let dg = m.rootDiagramId
        m.updateDiagram(dg) { $0.boxes[0].name = "Planning " }
        let verb = try #require(validate(m).first { $0.code == "box-verb" })
        #expect(verb.message == "“Planning ” (A0) may not be an active verb phrase — IDEF0 box names are verbs, e.g. “Assemble Chassis”.")
        #expect(verb.severity == .warning && verb.diagramId == dg && verb.target == .box && verb.targetId == m.contextDiagram?.boxes[0].id)

        m.updateDiagram(dg) { $0.boxes[0].name = " \t " }
        let issues = validate(m)
        #expect(!issues.contains { $0.code == "box-verb" })
        #expect(issues.contains { $0.code == "box-name" && $0.message == "Box 0 on A-0 is unnamed. Box names are active verb phrases." })
    }
}
