// Referential integrity and the walks that follow the decomposition, on a
// model no editor can produce: duplicate ids, a detail link to no diagram, a
// diagram no box names, a box detailed by its own diagram, by an ancestor and
// by A-0.
//
// Every expected value here is what the web app's own modules printed for this
// file under Node (src/model/validate.js, model.js and src/io/report.js). The
// point of the model is that each walk ends: before the path guards, web
// diagramTree and renumberNodes threw RangeError and the Swift report and PDF
// kit took the process down with them.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("StructureParity")
struct StructureParityTests {

    /// A-0 → A0; A0's box 2 names A0 itself and box 3 names A-0; A1's only box
    /// names A0 again. A9 hangs off nothing and its box names no diagram at
    /// all. `ar_ctl` is used by two arrows and `g1` by two glossary entries.
    private static let cyclicModel = #"""
{"schema":"idef0-modeler/1","id":"mdl_cyc","title":"Cyclic","author":"","project":"","purpose":"P","viewpoint":"V","status":"WORKING","created":"2026-09-14","revised":"2026-09-14",
"glossary":[{"id":"g1","term":"Run Plant","kind":"activity","definition":"d"},
            {"id":"g1","term":"Order","kind":"data","definition":"d"}],
"rootDiagramId":"dg_ctx",
"diagrams":{
 "dg_ctx":{"id":"dg_ctx","node":"A-0","title":"Cyclic","parentBoxId":null,"boxes":[
    {"id":"bx_top","name":"Run Plant","number":0,"conceptId":"g1","x":400,"y":300,"w":300,"h":170,"childDiagramId":"dg_a0"}],
  "arrows":[
    {"id":"ar_ctl","label":"Order","conceptId":"g1","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"top","pos":0.5}},
    {"id":"ar_out","label":"Order","conceptId":"g1","from":{"type":"box","boxId":"bx_top","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}]},
 "dg_a0":{"id":"dg_a0","node":"A0","title":"Run Plant","parentBoxId":"bx_top","boxes":[
    {"id":"bx_1","name":"Take Order","number":1,"conceptId":"g1","x":100,"y":172,"w":190,"h":112,"childDiagramId":"dg_a1"},
    {"id":"bx_2","name":"Make Goods","number":2,"conceptId":"g1","x":400,"y":330,"w":190,"h":112,"childDiagramId":"dg_a0"},
    {"id":"bx_3","name":"Ship Goods","number":3,"conceptId":"g1","x":700,"y":488,"w":190,"h":112,"childDiagramId":"dg_ctx"}],
  "arrows":[
    {"id":"ar_ctl","label":"Order","conceptId":"g1","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_1","side":"top","pos":0.5}},
    {"id":"ar_a0ctl2","label":"Order","conceptId":"g1","from":{"type":"boundary","side":"top","pos":0.8},"to":{"type":"box","boxId":"bx_2","side":"top","pos":0.5}},
    {"id":"ar_a0ctl3","label":"Order","conceptId":"g1","from":{"type":"boundary","side":"top","pos":0.9},"to":{"type":"box","boxId":"bx_3","side":"top","pos":0.5}},
    {"id":"ar_a0out","label":"Order","conceptId":"g1","from":{"type":"box","boxId":"bx_3","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}},
    {"id":"ar_a0o2","label":"Order","conceptId":"g1","from":{"type":"box","boxId":"bx_1","side":"right","pos":0.5},"to":{"type":"box","boxId":"bx_2","side":"left","pos":0.5}},
    {"id":"ar_a0o3","label":"Order","conceptId":"g1","from":{"type":"box","boxId":"bx_2","side":"right","pos":0.5},"to":{"type":"box","boxId":"bx_3","side":"left","pos":0.5}}]},
 "dg_a1":{"id":"dg_a1","node":"A1","title":"Take Order","parentBoxId":"bx_1","boxes":[
    {"id":"bx_11","name":"Check Order","number":1,"conceptId":"g1","x":100,"y":172,"w":190,"h":112,"childDiagramId":"dg_a0"}],
  "arrows":[
    {"id":"ar_a1ctl","label":"Order","conceptId":"g1","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_11","side":"top","pos":0.5}},
    {"id":"ar_a1out","label":"Order","conceptId":"g1","from":{"type":"box","boxId":"bx_11","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}]},
 "dg_orphan":{"id":"dg_orphan","node":"A9","title":"Orphan","parentBoxId":"bx_gone","boxes":[
    {"id":"bx_9","name":"Store Stock","number":1,"conceptId":"g1","x":100,"y":172,"w":190,"h":112,"childDiagramId":"dg_missing"}],
  "arrows":[]}
}}
"""#

    private static func model() throws -> IDEF0Model { try ModelFile.deserialize(cyclicModel) }

    /// An arrow bound to the activity concept, reported on each diagram.
    private static func kindRow(_ node: String, _ diagramId: String, _ arrowId: String) -> [String?] {
        ["warning", "concept-kind",
         "“Order” on \(node) is bound to activity “Run Plant”. An arrow denotes an object; give it a distinct term or change the concept’s kind.",
         diagramId, "arrow", arrowId]
    }

    private static let expected: [[String?]] = [
        ["error", "id-dup", "Arrow id ar_ctl on A0 is already used by another arrow. Ids must be unique across the model.", "dg_a0", "arrow", "ar_ctl"],
        ["error", "id-dup", "Concept id g1 (“Order”) is already used by another glossary entry. Ids must be unique across the model.", "dg_ctx", nil, nil],
        ["error", "detail-parent", "A0: box A2 names A0 as its detail diagram, which another box already names. A diagram details exactly one box.", "dg_a0", "box", "bx_2"],
        ["error", "detail-parent", "A0: box A3 names A-0 as its detail diagram, but A-0 does not name that box as its parent.", "dg_a0", "box", "bx_3"],
        ["error", "detail-parent", "A1: box A11 names A0 as its detail diagram, which another box already names. A diagram details exactly one box.", "dg_a1", "box", "bx_11"],
        ["error", "detail-dangling", "A9: box A91 names a detail diagram the model does not hold. Clear the link or restore the diagram.", "dg_orphan", "box", "bx_9"],
        // The walk reaches A1 before it returns to A0's own boxes.
        ["error", "decomp-cycle", "A1: box A11 is detailed by A0, which is one of its own ancestors. Unlink the decomposition.", "dg_a1", "box", "bx_11"],
        ["error", "decomp-cycle", "A0: box A2 is detailed by A0, which is one of its own ancestors. Unlink the decomposition.", "dg_a0", "box", "bx_2"],
        ["error", "decomp-cycle", "A0: box A3 is detailed by A-0, which is one of its own ancestors. Unlink the decomposition.", "dg_a0", "box", "bx_3"],
        ["error", "box-control", "A91 has no control. Every IDEF0 box requires at least one control arrow on its top.", "dg_orphan", "box", "bx_9"],
        ["error", "box-output", "A91 has no output. Every IDEF0 box requires at least one output arrow from its right.", "dg_orphan", "box", "bx_9"],
        ["warning", "diagram-unreachable", "A9 is not reached from the A-0 context diagram through any decomposition. Link it to the box it details or delete it.", "dg_orphan", nil, nil],
        kindRow("A-0", "dg_ctx", "ar_ctl"),
        kindRow("A-0", "dg_ctx", "ar_out"),
        kindRow("A0", "dg_a0", "ar_ctl"),
        kindRow("A0", "dg_a0", "ar_a0ctl2"),
        kindRow("A0", "dg_a0", "ar_a0ctl3"),
        kindRow("A0", "dg_a0", "ar_a0out"),
        kindRow("A0", "dg_a0", "ar_a0o2"),
        kindRow("A0", "dg_a0", "ar_a0o3"),
        ["warning", "decomp-count", "A1 has 1 box(es). A decomposition should have 3–6; fewer than 3 adds no detail.", "dg_a1", nil, nil],
        kindRow("A1", "dg_a1", "ar_a1ctl"),
        kindRow("A1", "dg_a1", "ar_a1out"),
        ["warning", "decomp-count", "A9 has 1 box(es). A decomposition should have 3–6; fewer than 3 adds no detail.", "dg_orphan", nil, nil],
    ]

    @Test("the structural issues are the web app's, issue for issue and in order")
    func issues() throws {
        let issues = validate(try Self.model())
        #expect(issues.count == Self.expected.count)
        for (k, pair) in zip(Self.expected, issues).enumerated() {
            let (e, i) = pair
            let actual: [String?] = [i.severity.rawValue, i.code, i.message, i.diagramId, i.target?.rawValue, i.targetId]
            #expect(actual == e, "cyclic.issues[\(k)]")
        }
        #expect(summarize(issues) == IssueSummary(errors: 11, warnings: 13))
    }

    @Test("diagramTree stops at a diagram already on the path")
    func tree() throws {
        let tree = try Self.model().diagramTree().map { [$0.diagram.id, $0.diagram.node, "\($0.depth)"] }
        #expect(tree == [["dg_ctx", "A-0", "0"], ["dg_a0", "A0", "1"], ["dg_a1", "A1", "2"]])
    }

    /// The walk behind the app's node tree tab, which opens on a freshly opened
    /// document: every box is listed, and only the descent into a diagram
    /// already on the path is skipped. Same shape as the report's node index.
    @Test("activityTree lists every box once and stops at a diagram on the path")
    func activities() throws {
        let rows = try Self.model().activityTree().map { [boxNode($0.diagram, $0.box), $0.box.name, "\($0.depth)"] }
        #expect(rows == [["A0", "Run Plant", "0"], ["A1", "Take Order", "1"], ["A11", "Check Order", "2"],
                         ["A2", "Make Goods", "1"], ["A3", "Ship Goods", "1"]])
    }

    @Test("renumberNodes leaves an ancestor named from below alone")
    func renumber() throws {
        var m = try Self.model()
        m.renumberNodes()
        let nodes = m.diagrams.values.map { [$0.id, $0.node, $0.title] }
        #expect(nodes == [["dg_ctx", "A-0", "Cyclic"], ["dg_a0", "A0", "Run Plant"],
                          ["dg_a1", "A1", "Take Order"], ["dg_orphan", "A9", "Orphan"]])
    }

    @Test("the report lists every box once and ends")
    func report() throws {
        let lines = Report.markdown(try Self.model(), generatedOn: "DATE").components(separatedBy: "\n")
        let index = try #require(lines.firstIndex(of: "## Node index"))
        let diagrams = try #require(lines.firstIndex(of: "## Diagrams"))
        #expect(Array(lines[(index + 2)..<(diagrams - 1)]) == [
            "- **A0** Run Plant",
            "  - **A1** Take Order",
            "    - **A11** Check Order",
            "  - **A2** Make Goods",
            "  - **A3** Ship Goods",
        ])
        #expect(lines.filter { $0.hasPrefix("### ") } == ["### A-0 — Cyclic", "### A0 — Run Plant", "### A1 — Take Order", "### Label elaboration"])
        // A9 is not on the tree, so the report never lists its box — only the
        // rule check mentions it.
        #expect(!lines.contains { $0.hasPrefix("| 1 | A91") })
    }

    @Test("deleting a subtree through a cycle deletes each diagram once")
    func deleteSubtree() throws {
        var m = try Self.model()
        m.deleteSubtree("dg_a1")
        #expect(Array(m.diagrams.keys) == ["dg_ctx", "dg_orphan"])
        // The box A-0 details is unhooked; the dangling link elsewhere is left as it was.
        #expect(m.diagrams["dg_ctx"]?.boxes.first?.childDiagramId == nil)
        #expect(m.diagrams["dg_orphan"]?.boxes.first?.childDiagramId == "dg_missing")
    }

    @Test("removing a box whose diagram is its own detail ends")
    func removeBox() throws {
        var m = try Self.model()
        m.removeBox(diagramId: "dg_a0", boxId: "bx_2")
        #expect(Array(m.diagrams.keys) == ["dg_ctx", "dg_orphan"])
    }
}
