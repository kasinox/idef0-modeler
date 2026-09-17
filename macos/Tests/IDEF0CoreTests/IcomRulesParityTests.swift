// The call-arrow, boundary-direction, tunnel-at-box and reserved-word rules on
// a hand-built model that reaches the cases the scenarios do not: a call arrow
// drawn to the right or top edge, a tunnelled call, a caller whose child id
// dangles, a reserved word that is one only after normalisation, and a
// passthrough that runs the wrong way at both ends. Every expected value is
// what the web app's own deserialize + icomCodes + validate printed for this
// model under Node.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("IcomRulesParity")
struct IcomRulesParityTests {

    /// A-0 → A0 → A1. On A0, box 1's controls are Plan (C1), Budget tunnelled
    /// at the box (C2) and Rules (C3); box 2 carries two call arrows, one to the
    /// right edge and one tunnelled; box 3's call goes to the top edge and its
    /// childDiagramId names no diagram; "Back" runs right edge to left edge.
    /// On A1 a box is named "Input", another "Process Control", and an arrow
    /// "\tCONTROL " (a tab and a trailing space).
    private static let rulesModel = #"""
{"schema":"idef0-modeler/1","id":"mdl_rules","title":"Rules","purpose":"Pin the call, direction, tunnel and reserved-word rules.","viewpoint":"The checker.","status":"WORKING","created":"2026-09-15","revised":"2026-09-15",
"glossary":[],
"rootDiagramId":"dg_ctx",
"diagrams":{
 "dg_ctx":{"id":"dg_ctx","node":"A-0","title":"Rules","parentBoxId":null,"boxes":[
    {"id":"bx_top","name":"Run Shop","number":0,"x":400,"y":300,"w":300,"h":170,"childDiagramId":"dg_a0"}],
  "arrows":[
    {"id":"ar_in","label":"Order","from":{"type":"boundary","side":"left","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"left","pos":0.5}},
    {"id":"ar_ctl","label":"Plan","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"top","pos":0.5}},
    {"id":"ar_out","label":"Goods","from":{"type":"box","boxId":"bx_top","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}},
    {"id":"ar_mech","label":"Staff","from":{"type":"boundary","side":"bottom","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"bottom","pos":0.5}}
  ]},
 "dg_a0":{"id":"dg_a0","node":"A0","title":"Rules","parentBoxId":"bx_top","boxes":[
    {"id":"bx_1","name":"Take Order","number":1,"x":100,"y":172,"w":190,"h":112,"childDiagramId":"dg_a1"},
    {"id":"bx_2","name":"Make Goods","number":2,"x":400,"y":330,"w":190,"h":112},
    {"id":"bx_3","name":"Ship Goods","number":3,"x":700,"y":488,"w":190,"h":112,"childDiagramId":"dg_nowhere"}],
  "arrows":[
    {"id":"ar_a0in","label":"Order","from":{"type":"boundary","side":"left","pos":0.3},"to":{"type":"box","boxId":"bx_1","side":"left","pos":0.5}},
    {"id":"ar_a0ctl","label":"Plan","from":{"type":"boundary","side":"top","pos":0.2},"to":{"type":"box","boxId":"bx_1","side":"top","pos":0.3}},
    {"id":"ar_budget","label":"Budget","from":{"type":"box","boxId":"bx_3","side":"right","pos":0.2},"to":{"type":"box","boxId":"bx_1","side":"top","pos":0.5},"tunnelTo":true},
    {"id":"ar_rules","label":"Rules","from":{"type":"box","boxId":"bx_3","side":"right","pos":0.4},"to":{"type":"box","boxId":"bx_1","side":"top","pos":0.8}},
    {"id":"ar_rec","label":"Order Record","from":{"type":"box","boxId":"bx_1","side":"right","pos":0.5},"to":{"type":"box","boxId":"bx_2","side":"left","pos":0.5}},
    {"id":"ar_a0mech","label":"Staff","from":{"type":"boundary","side":"bottom","pos":0.3},"to":{"type":"box","boxId":"bx_2","side":"bottom","pos":0.5}},
    {"id":"ar_parts","label":"Parts","from":{"type":"box","boxId":"bx_2","side":"right","pos":0.5},"to":{"type":"box","boxId":"bx_3","side":"left","pos":0.5}},
    {"id":"ar_a0out","label":"Goods","from":{"type":"box","boxId":"bx_3","side":"right","pos":0.6},"to":{"type":"boundary","side":"right","pos":0.5}},
    {"id":"ar_callright","label":"X/A1","from":{"type":"box","boxId":"bx_2","side":"bottom","pos":0.3},"to":{"type":"boundary","side":"right","pos":0.9}},
    {"id":"ar_calltun","label":"Z/A3","from":{"type":"box","boxId":"bx_2","side":"bottom","pos":0.7},"to":{"type":"boundary","side":"bottom","pos":0.8},"tunnelTo":true},
    {"id":"ar_calltop","label":"Y/A2","from":{"type":"box","boxId":"bx_3","side":"bottom","pos":0.5},"to":{"type":"boundary","side":"top","pos":0.9}},
    {"id":"ar_back","label":"Back","from":{"type":"boundary","side":"right","pos":0.2},"to":{"type":"boundary","side":"left","pos":0.8}}
  ]},
 "dg_a1":{"id":"dg_a1","node":"A1","title":"Take Order","parentBoxId":"bx_1","boxes":[
    {"id":"bx_11","name":"Check Order","number":1,"x":100,"y":172,"w":190,"h":112},
    {"id":"bx_12","name":"Input","number":2,"x":400,"y":330,"w":190,"h":112},
    {"id":"bx_13","name":"Process Control","number":3,"x":700,"y":488,"w":190,"h":112}],
  "arrows":[
    {"id":"ar_a1in","label":"Order","from":{"type":"boundary","side":"left","pos":0.5},"to":{"type":"box","boxId":"bx_11","side":"left","pos":0.5}},
    {"id":"ar_a1ctl","label":"Plan","from":{"type":"boundary","side":"top","pos":0.3},"to":{"type":"box","boxId":"bx_11","side":"top","pos":0.5}},
    {"id":"ar_a1rules","label":"Rules","from":{"type":"boundary","side":"top","pos":0.7},"to":{"type":"box","boxId":"bx_12","side":"top","pos":0.5}},
    {"id":"ar_a1res","label":"\tCONTROL ","from":{"type":"box","boxId":"bx_11","side":"right","pos":0.5},"to":{"type":"box","boxId":"bx_12","side":"left","pos":0.5}},
    {"id":"ar_a1chk","label":"Checked Order","from":{"type":"box","boxId":"bx_12","side":"right","pos":0.5},"to":{"type":"box","boxId":"bx_13","side":"top","pos":0.5}},
    {"id":"ar_a1out","label":"Order Record","from":{"type":"box","boxId":"bx_13","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}
  ]}
}}
"""#

    // MARK: ICOM coding

    @Test("a control tunnelled at the box keeps its ordinal; call and wrong-way ends take no code")
    func codes() throws {
        let m = try ModelFile.deserialize(Self.rulesModel)
        let a0 = try #require(m.diagrams["dg_a0"])
        let a1 = try #require(m.diagrams["dg_a1"])

        // The call arrows to the right and top edges, the tunnelled call and
        // "Back" are all uncoded: none is a boundary end that can carry a code.
        #expect(m.icomCodes(a0) == ["ar_a0in:from": "I1", "ar_a0ctl:from": "C1", "ar_a0out:to": "O1", "ar_a0mech:from": "M1"])
        // Figure 18: C1 and C3, with C2 (Budget) tunnelled at the parent box.
        #expect(m.icomCodes(a1) == ["ar_a1in:from": "I1", "ar_a1ctl:from": "C1", "ar_a1rules:from": "C3", "ar_a1out:to": "O1"])
        for dg in [a0, a1] {
            let p = m.icomPairing(dg)
            #expect(p.orphans.isEmpty && p.missing.isEmpty, "\(dg.node): \(p.orphans.count) orphans, \(p.missing.count) missing")
        }
        let top = try #require(m.parentBoxArrows(a0, "bx_1")[.top])
        #expect(top.map { "\($0.arrow.id) \($0.code) \($0.tunnelled)" } == ["ar_a0ctl C1 false", "ar_budget C2 true", "ar_rules C3 false"])

        // The context diagram has no parent, so every collected end is an
        // orphan — and only ends that can carry a code are collected.
        let ctx = try #require(m.contextDiagram)
        let pairing = m.icomPairing(ctx)
        #expect(pairing.parent == nil && pairing.pairs.isEmpty && pairing.missing.isEmpty)
        #expect(pairing.orphans.map { "\($0.side.rawValue) \($0.child.arrow.id) \($0.child.end.rawValue)" }
                == ["left ar_in from", "top ar_ctl from", "right ar_out to", "bottom ar_mech from"])
    }

    @Test("ParentArrow defaults to not tunnelled")
    func parentArrowDefault() {
        let a = newArrow(label: "x", from: .boundary(.left), to: .box("bx", .left))
        #expect(ParentArrow(arrow: a, pos: 0.5, code: "I1").tunnelled == false)
    }

    // MARK: Validation

    /// The rule issues the web app reports, in order — every one that is not
    /// concept-unbound (nothing here is bound; those rows are ValidateParity's).
    private static let expected: [[String?]] = [
        // bx_3's childDiagramId names no diagram: a dangling detail link, found
        // before any rule that follows it.
        ["error", "detail-dangling", "A0: box A3 names a detail diagram the model does not hold. Clear the link or restore the diagram.", "dg_a0", "box", "bx_3"],
        ["error", "box-control", "A2 has no control. Every IDEF0 box requires at least one control arrow on its top.", "dg_a0", "box", "bx_2"],
        // The tunnelled call still counts: tunnelling does not exempt it from rule 11.
        ["error", "box-call-count", "A2 has 2 call arrows. A box may have at most one (FIPS 183 §3.3.3).", "dg_a0", "box", "bx_2"],
        // bx_3's childDiagramId names no diagram, so it is not decomposed: no call-decomposed.
        ["error", "box-control", "A3 has no control. Every IDEF0 box requires at least one control arrow on its top.", "dg_a0", "box", "bx_3"],
        // A call to the top edge runs the wrong way; the one to the right edge does not.
        ["error", "boundary-direction", "“Y/A2” runs the wrong way at the top edge of A0. Boundary arrows enter a diagram on the left, top or bottom and leave it on the right.", "dg_a0", "arrow", "ar_calltop"],
        ["error", "arrow-passthrough", "“Back” runs from boundary to boundary on A0 without touching a box.", "dg_a0", "arrow", "ar_back"],
        ["error", "boundary-direction", "“Back” runs the wrong way at the right edge of A0. Boundary arrows enter a diagram on the left, top or bottom and leave it on the right.", "dg_a0", "arrow", "ar_back"],
        ["error", "boundary-direction", "“Back” runs the wrong way at the left edge of A0. Boundary arrows enter a diagram on the left, top or bottom and leave it on the right.", "dg_a0", "arrow", "ar_back"],
        // "Input" is reserved and draws no box-verb as well; "Process Control" is a phrase.
        ["error", "reserved-term", "“Input” (A12) is a reserved IDEF0 word. Name the function it performs (FIPS 183 §3.3.3).", "dg_a1", "box", "bx_12"],
        // Reserved after trimming, whitespace collapsing and lower-casing; quoted as written.
        ["error", "reserved-term", "“\tCONTROL ” on A1 is a reserved IDEF0 word. Label the arrow with the object it carries (FIPS 183 §3.2.2.3).", "dg_a1", "arrow", "ar_a1res"],
    ]

    @Test("the rule issues match the web app's, rule for rule and in order")
    func issues() throws {
        let m = try ModelFile.deserialize(Self.rulesModel)
        let issues = validate(m)
        #expect(summarize(issues) == IssueSummary(errors: 39, warnings: 0))
        let rules = issues.filter { $0.code != "concept-unbound" }
        #expect(rules.count == Self.expected.count)
        for (k, pair) in zip(Self.expected, rules).enumerated() {
            let (e, i) = pair
            let actual: [String?] = [i.severity.rawValue, i.code, i.message, i.diagramId, i.target?.rawValue, i.targetId]
            #expect(actual == e, "rules.issues[\(k)]")
        }
    }

    /// Whether a lone context box with this name draws `reserved-term`.
    private static func reserved(_ name: String) -> Bool {
        var m = IDEF0Model.create(title: "Model")
        let dg = m.rootDiagramId
        m.updateDiagram(dg) { $0.boxes[0].name = name }
        return validate(m).contains { $0.code == "reserved-term" }
    }

    /// Whole-name matches after the web app's `norm`: trim, collapse
    /// whitespace, toLowerCase. "Call" is reserved for labels only (§3.2.2.3
    /// rule 5), so as a box name it passes. A long s or a dotted capital I
    /// lower-case to something other than ASCII in JavaScript, so those
    /// spellings are not the reserved word; each verdict was confirmed by
    /// running the web app's validate under Node.
    @Test("reserved box names match the whole normalised name", arguments: [
        ("Process", true), ("process", true), ("PROCESS", true), ("  Function\t", true), ("Activity", true),
        ("Input", true), ("Output", true), ("Control", true), ("Mechanism", true), ("Mechanism\u{00A0}", true),
        ("Process Control", false), ("Inputs", false), ("Call", false), ("Pre-process", false), ("", false),
        ("Proce\u{017F}s", false), ("\u{0130}nput", false), ("Proce\u{0073}s", true),
    ])
    func reservedBoxNames(_ name: String, _ expected: Bool) {
        #expect(Self.reserved(name) == expected, "\(name.debugDescription)")
    }
}
