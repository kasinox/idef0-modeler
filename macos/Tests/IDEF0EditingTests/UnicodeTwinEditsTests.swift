// F75: edits that look up a concept or a diagram by id must use the same
// code-unit identity the web app's `===`/`Map`/`Set` use, not Swift's
// canonical-equivalence `==`. Two ids that are only Unicode-normalization
// twins of each other (an accented letter, precomposed vs. combining) must
// never be treated as naming the same concept or the same (root) diagram —
// InspectorEdits' concept edits and Edits' root-diagram checks now go through
// IDEF0Model's `conceptIndex`/`isConceptUsed`/`isRootDiagram` for exactly
// this reason.

import Testing
@testable import IDEF0Core
@testable import IDEF0Editing

@Suite("Unicode twin identity in edits (F75)")
struct UnicodeTwinEditsTests {
    // MARK: Concept edits

    /// A-0 with one box bound to an NFC-spelled concept id, plus a glossary
    /// entry whose id is that same id's NFD twin — canonically "the same"
    /// string to Swift, but a different concept nothing on the model uses.
    private static func modelWithTwinConcepts() -> (model: IDEF0Model, nfc: String, nfd: String) {
        let nfc = "gl_caf\u{E9}", nfd = "gl_cafe\u{301}"
        var diagrams = OrderedMap<Diagram>()
        var ctx = Diagram(id: "dg_ctx", node: "A-0", title: "T")
        ctx.boxes = [Box(id: "bx1", name: "A", number: 0, conceptId: nfc, x: 0, y: 0, w: 1, h: 1)]
        diagrams[ctx.id] = ctx
        let model = IDEF0Model(
            id: "mdl", title: "T", created: "2026-01-01", revised: "2026-01-01",
            glossary: [Concept(id: nfc, term: "A", kind: "activity"), Concept(id: nfd, term: "B", kind: "other")],
            diagrams: diagrams, rootDiagramId: "dg_ctx"
        )
        return (model, nfc, nfd)
    }

    @Test("setConceptKind touches only the exact-id concept, not its NFC/NFD twin")
    func setConceptKindDoesNotTouchTwin() {
        var (model, nfc, nfd) = Self.modelWithTwinConcepts()
        Edits.setConceptKind(&model, conceptId: nfc, kind: "data")
        #expect(model.conceptById(nfc)?.kind == "data")
        #expect(model.conceptById(nfd)?.kind == "other", "the twin id must be untouched")
    }

    @Test("defineConcept touches only the exact-id concept, not its NFC/NFD twin")
    func defineConceptDoesNotTouchTwin() {
        var (model, nfc, nfd) = Self.modelWithTwinConcepts()
        Edits.defineConcept(&model, conceptId: nfc, definition: "The NFC one")
        #expect(model.conceptById(nfc)?.definition == "The NFC one")
        #expect(model.conceptById(nfd)?.definition.isEmpty == true, "the twin id must be untouched")
    }

    @Test("removeConcept's usage check and deletion are both exact, not merged across twins")
    func removeConceptDoesNotMergeUsageOrDeleteTwin() throws {
        var (model, nfc, nfd) = Self.modelWithTwinConcepts()
        // The NFC concept is used by bx1; its NFD twin is not — a merged
        // usage count would wrongly refuse removing the unused one, or wrongly
        // allow removing the used one.
        #expect(throws: Edits.Refusal.conceptInUse) {
            try Edits.removeConcept(&model, conceptId: nfc)
        }
        #expect(model.glossary.count == 2, "the refused removal must not have touched the glossary")

        try Edits.removeConcept(&model, conceptId: nfd)
        #expect(model.conceptById(nfd) == nil, "the unused twin is removed")
        #expect(model.conceptById(nfc) != nil, "the used concept survives its twin's removal, untouched")
    }

    @Test("removeConcept removes every glossary entry that matches the id exactly, as the web app's filter does")
    func removeConceptRemovesAllExactDuplicates() throws {
        // A hand-edited or foreign file can hold two glossary entries that
        // share one id exactly (not merely a twin); the fix must still remove
        // every one of them, not just the first found.
        let id = "gl_dup"
        var model = IDEF0Model(
            id: "mdl", title: "T", created: "2026-01-01", revised: "2026-01-01",
            glossary: [Concept(id: id, term: "A", kind: "other"), Concept(id: id, term: "B", kind: "other")],
            diagrams: OrderedMap(), rootDiagramId: "dg_missing"
        )
        try Edits.removeConcept(&model, conceptId: id)
        #expect(model.glossary.isEmpty)
    }

    // MARK: isRootDiagram-guarded rules

    @Test("setTunnel refuses tunnelling only on the exact root diagram, not a diagram whose id is merely its Unicode-normalization twin")
    func setTunnelRootCheckIsExact() throws {
        let root = "dg_caf\u{E9}", twin = "dg_cafe\u{301}"
        func diagram(id: String, node: String) -> Diagram {
            var d = Diagram(id: id, node: node, title: "T")
            d.arrows = [Arrow(id: "ar1", label: "L", from: .boundary(.left, 0.5), to: .boundary(.right, 0.5))]
            return d
        }
        var diagrams = OrderedMap<Diagram>()
        diagrams[root] = diagram(id: root, node: "A-0")
        diagrams[twin] = diagram(id: twin, node: "A0")
        var model = IDEF0Model(id: "mdl", title: "T", created: "2026-01-01", revised: "2026-01-01",
                                diagrams: diagrams, rootDiagramId: root)

        #expect(throws: Edits.Refusal.contextHasNoTunnels) {
            try Edits.setTunnel(&model, diagramId: root, arrowId: "ar1", end: .from, on: true)
        }
        // The twin id names a genuinely different diagram, which is not the root.
        try Edits.setTunnel(&model, diagramId: twin, arrowId: "ar1", end: .from, on: true)
        #expect(model.diagrams[twin]?.arrows.first?.tunnelFrom == true)
    }

    @Test("delete refuses to remove the last box only on the exact root diagram")
    func deleteContextCheckIsExact() throws {
        let root = "dg_caf\u{E9}", twin = "dg_cafe\u{301}"
        func diagram(id: String, node: String) -> Diagram {
            var d = Diagram(id: id, node: node, title: "T")
            d.boxes = [newBox(name: "B", number: 1, x: 0, y: 0)]
            return d
        }
        let rootDg = diagram(id: root, node: "A-0")
        let twinDg = diagram(id: twin, node: "A0")
        var diagrams = OrderedMap<Diagram>()
        diagrams[root] = rootDg
        diagrams[twin] = twinDg
        var model = IDEF0Model(id: "mdl", title: "T", created: "2026-01-01", revised: "2026-01-01",
                                diagrams: diagrams, rootDiagramId: root)

        #expect(throws: Edits.Refusal.contextKeepsItsBox) {
            try Edits.delete(&model, diagramId: root, selection: .box(rootDg.boxes[0].id))
        }
        // The twin id names a different diagram — deleting its only box is allowed.
        try Edits.delete(&model, diagramId: twin, selection: .box(twinDg.boxes[0].id))
        #expect(model.diagrams[twin]?.boxes.isEmpty == true)
    }

    @Test("renameBox retitles the model only when its diagram is exactly the root, not a twin of the root's id")
    func renameBoxRootCheckIsExact() throws {
        let root = "dg_caf\u{E9}", twin = "dg_cafe\u{301}"
        var rootDg = Diagram(id: root, node: "A-0", title: "T")
        rootDg.boxes = [newBox(name: "Old", number: 0, x: 0, y: 0)]
        var twinDg = Diagram(id: twin, node: "A0", title: "T")
        twinDg.boxes = [newBox(name: "Old", number: 1, x: 0, y: 0)]
        var diagrams = OrderedMap<Diagram>()
        diagrams[root] = rootDg
        diagrams[twin] = twinDg
        var model = IDEF0Model(id: "mdl", title: "Original", created: "2026-01-01", revised: "2026-01-01",
                                diagrams: diagrams, rootDiagramId: root)

        try Edits.renameBox(&model, diagramId: twin, boxId: twinDg.boxes[0].id, to: "Renamed On Twin")
        #expect(model.title == "Original", "renaming a box on a diagram that only looks like the root must not retitle the model")

        try Edits.renameBox(&model, diagramId: root, boxId: rootDg.boxes[0].id, to: "Renamed On Root")
        #expect(model.title == "Renamed On Root")
    }
}
