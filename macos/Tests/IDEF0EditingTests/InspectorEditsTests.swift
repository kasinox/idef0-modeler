// The inspector's own edits (IDEF0Editing/InspectorEdits.swift) — ports of the
// commit closures in src/ui/panels.js. F85: none of these had a test before
// this file; `decomposedModel()` (EditingTests.swift) supplies a two-diagram
// model (A-0's single box decomposed into three) for cases that need a
// non-root diagram or an existing child.

import Testing
@testable import IDEF0Core
@testable import IDEF0Editing

@Suite("InspectorEdits")
struct InspectorEditsTests {
    // MARK: Arrows

    @Test("setEndpointPosition clamps to [0.02, 0.98] and ignores non-finite input (panels.js:413)")
    func endpointPositionClamps() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let id = try Edits.drawArrow(&m, diagramId: child, from: .box(d.boxes[0].id, .right, 0.5), to: .box(d.boxes[2].id, .left, 0.5))

        Edits.setEndpointPosition(&m, diagramId: child, arrowId: id, end: .to, percent: 150)
        #expect(m.diagrams[child]?.arrows.last?.to.pos == 0.98, "150% clamps to the 0.98 ceiling")

        Edits.setEndpointPosition(&m, diagramId: child, arrowId: id, end: .to, percent: -30)
        #expect(m.diagrams[child]?.arrows.last?.to.pos == 0.02, "a negative percent clamps to the 0.02 floor")

        Edits.setEndpointPosition(&m, diagramId: child, arrowId: id, end: .to, percent: 40)
        #expect(m.diagrams[child]?.arrows.last?.to.pos == 0.4)

        // An emptied number field reads as NaN (numInput's own comment); the
        // position is left exactly as it was, not written as 0 or dropped.
        Edits.setEndpointPosition(&m, diagramId: child, arrowId: id, end: .to, percent: .nan)
        #expect(m.diagrams[child]?.arrows.last?.to.pos == 0.4, "NaN is ignored, not written")
    }

    @Test("setEndpointSide changes the side and clears a pinned bend")
    func endpointSideClearsBend() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let id = try Edits.drawArrow(&m, diagramId: child, from: .box(d.boxes[0].id, .right, 0.5), to: .box(d.boxes[2].id, .left, 0.5))
        Edits.setBend(&m, diagramId: child, arrowId: id, axis: .x, pointer: Point(x: 612, y: 0))
        #expect(m.diagrams[child]?.arrows.last?.bend != nil)

        Edits.setEndpointSide(&m, diagramId: child, arrowId: id, end: .to, side: .top)
        let a = try #require(m.diagrams[child]?.arrows.last)
        #expect(a.to.side == .top)
        #expect(a.bend == nil, "moving an end to another side reshapes the route")
    }

    @Test("setTunnel refuses on the A-0 diagram, which has no parent to hide an arrow from (FIPS 183 §3.4.2)")
    func tunnelRefusedOnRoot() throws {
        var m = IDEF0Model.create(title: "Make Widget")
        let ctx = m.rootDiagramId
        let top = try #require(m.contextDiagram?.boxes.first)
        let id = try Edits.drawArrow(&m, diagramId: ctx, from: .boundary(.top, 0.5), to: .box(top.id, .top, 0.5))
        #expect(throws: Edits.Refusal.contextHasNoTunnels) {
            try Edits.setTunnel(&m, diagramId: ctx, arrowId: id, end: .from, on: true)
        }
        #expect(m.diagrams[ctx]?.arrows.last?.tunnelFrom == false, "the refused edit changed nothing")
    }

    @Test("setTunnel sets the tunnel flag for the end named, off the A-0 diagram")
    func tunnelSetsNamedEnd() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let id = try Edits.drawArrow(&m, diagramId: child, from: .box(d.boxes[0].id, .right, 0.5), to: .box(d.boxes[2].id, .left, 0.5))
        try Edits.setTunnel(&m, diagramId: child, arrowId: id, end: .from, on: true)
        var a = try #require(m.diagrams[child]?.arrows.last)
        #expect(a.tunnelFrom == true && a.tunnelTo == false)
        try Edits.setTunnel(&m, diagramId: child, arrowId: id, end: .from, on: false)
        a = try #require(m.diagrams[child]?.arrows.last)
        #expect(a.tunnelFrom == false)
    }

    @Test("resetRouting clears the bend and label offset together (panels.js: 'Reset bend & label offset')")
    func resetRoutingClearsBendAndLabel() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let id = try Edits.drawArrow(&m, diagramId: child, from: .box(d.boxes[0].id, .right, 0.5), to: .box(d.boxes[2].id, .left, 0.5))
        Edits.setBend(&m, diagramId: child, arrowId: id, axis: .x, pointer: Point(x: 612, y: 0))
        Edits.moveLabel(&m, diagramId: child, arrowId: id, original: Point(x: 0, y: 0), dragStart: Point(x: 0, y: 0), pointer: Point(x: 30, y: 20))
        var a = try #require(m.diagrams[child]?.arrows.last)
        #expect(a.bend != nil && (a.ldx != 0 || a.ldy != 0))

        Edits.resetRouting(&m, diagramId: child, arrowId: id)
        a = try #require(m.diagrams[child]?.arrows.last)
        #expect(a.bend == nil && a.ldx == 0 && a.ldy == 0)
    }

    @Test("reverseArrow swaps the endpoints and each end's own tunnel mark, and clears the bend")
    func reverseArrowSwapsEndsAndTunnels() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let (from, to) = (Endpoint.box(d.boxes[0].id, .right, 0.3), Endpoint.box(d.boxes[2].id, .left, 0.7))
        let id = try Edits.drawArrow(&m, diagramId: child, from: from, to: to)
        try Edits.setTunnel(&m, diagramId: child, arrowId: id, end: .from, on: true)
        Edits.setBend(&m, diagramId: child, arrowId: id, axis: .x, pointer: Point(x: 612, y: 0))

        Edits.reverseArrow(&m, diagramId: child, arrowId: id)
        let a = try #require(m.diagrams[child]?.arrows.last)
        #expect(a.from == to && a.to == from, "source and destination swap")
        #expect(a.tunnelFrom == false && a.tunnelTo == true, "the tunnel mark travels with the end that had it")
        #expect(a.bend == nil, "a swapped route drops its pinned bend")
    }

    @Test("setArrowNote writes the arrow's note field")
    func arrowNote() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let id = try Edits.drawArrow(&m, diagramId: child, from: .box(d.boxes[0].id, .right, 0.5), to: .box(d.boxes[2].id, .left, 0.5))
        Edits.setArrowNote(&m, diagramId: child, arrowId: id, note: "checked twice")
        #expect(m.diagrams[child]?.arrows.last?.note == "checked twice")
        Edits.setArrowNote(&m, diagramId: child, arrowId: "no-such-arrow", note: "ignored")
        #expect(m.diagrams[child]?.arrows.last?.note == "checked twice", "an unknown id changes nothing")
    }

    // MARK: Boxes

    @Test("setBoxGeometry writes only the finite fields given, as entered — no clamp or snap")
    func boxGeometryWritesFiniteFieldsOnly() throws {
        var (m, _, child) = try decomposedModel()
        let box = try #require(m.diagrams[child]?.boxes.first)
        Edits.setBoxGeometry(&m, diagramId: child, boxId: box.id, x: 401.5, w: .nan)
        let b = try #require(m.diagrams[child]?.findBox(box.id))
        #expect(b.x == 401.5, "a finite field is written exactly as typed")
        #expect(b.w == box.w, "a non-finite field is left alone")
        #expect(b.y == box.y && b.h == box.h, "fields not named are untouched")
    }

    @Test("setBoxNote writes the box's note field")
    func boxNote() throws {
        var (m, _, child) = try decomposedModel()
        let box = try #require(m.diagrams[child]?.boxes.first)
        Edits.setBoxNote(&m, diagramId: child, boxId: box.id, note: "SOP-9")
        #expect(m.diagrams[child]?.findBox(box.id)?.note == "SOP-9")
    }

    @Test("decompose clamps the count to [3, 6] and refuses a box the diagram no longer has (§3.3.3 rule 4)")
    func decomposeClampsCountAndRefusesMissingBox() throws {
        var m = IDEF0Model.create(title: "Make Widget")
        let ctx = m.rootDiagramId
        let top = try #require(m.contextDiagram?.boxes.first)
        let childId = try Edits.decompose(&m, diagramId: ctx, boxId: top.id, count: 50)
        #expect(m.diagrams[childId]?.boxes.count == Sheet.decompMax)

        #expect(throws: Edits.Refusal.noSuchObject) {
            try Edits.decompose(&m, diagramId: ctx, boxId: "no-such-box", count: 3)
        }
    }

    @Test("decompose is idempotent: a box already decomposed returns its existing child rather than replacing it")
    func decomposeReturnsExistingChild() throws {
        var (m, ctx, child) = try decomposedModel()
        let top = try #require(m.contextDiagram?.boxes.first)
        let again = try Edits.decompose(&m, diagramId: ctx, boxId: top.id, count: 5)
        #expect(again == child)
        #expect(m.diagrams[child]?.boxes.count == 3, "the count argument is ignored once a child exists")
    }

    @Test("deleteDecomposition removes the whole subtree and unhooks the parent box's childDiagramId")
    func deleteDecompositionRemovesSubtree() throws {
        var (m, _, child) = try decomposedModel()
        let top = try #require(m.contextDiagram?.boxes.first)
        // Decompose one grandchild too, so the deletion has to recurse.
        let grandchildBox = try #require(m.diagrams[child]?.boxes.first)
        let grandchild = try Edits.decompose(&m, diagramId: child, boxId: grandchildBox.id, count: 3)

        Edits.deleteDecomposition(&m, childDiagramId: child)
        #expect(m.diagrams[child] == nil, "the child diagram is gone")
        #expect(m.diagrams[grandchild] == nil, "and everything below it")
        #expect(m.contextDiagram?.boxes.first(where: { $0.id == top.id })?.childDiagramId == nil,
                "the parent box no longer points at a diagram that does not exist")
    }

    // MARK: Diagrams

    @Test("setDiagramTitle locks the title on non-blank text and unlocks it on blank")
    func diagramTitleLocksOnNonBlank() throws {
        var (m, _, child) = try decomposedModel()
        Edits.setDiagramTitle(&m, diagramId: child, title: "Assemble Sub-parts")
        #expect(m.diagrams[child]?.title == "Assemble Sub-parts")
        #expect(m.diagrams[child]?.titleLocked == true)

        Edits.setDiagramTitle(&m, diagramId: child, title: "   ")
        #expect(m.diagrams[child]?.title == "   ", "the field keeps exactly what was typed")
        #expect(m.diagrams[child]?.titleLocked == false, "blank (after trimming) hands the title back to the box name")
    }

    @Test("setCNumber writes the diagram's C-number field verbatim")
    func cNumber() throws {
        var (m, _, child) = try decomposedModel()
        Edits.setCNumber(&m, diagramId: child, cNumber: "C-17")
        #expect(m.diagrams[child]?.cNumber == "C-17")
    }

    // MARK: The model

    @Test("setModelTitle titles the model and the A-0 diagram, and names + binds an unnamed A-0 box")
    func modelTitleNamesAndBindsUnnamedBox() throws {
        // create(title:) names the A-0 box after the title (Lookups.swift:31),
        // so an empty title is the way to start from an unnamed box.
        var m = IDEF0Model.create(title: "")
        let ctx = m.rootDiagramId
        #expect(m.contextDiagram?.boxes.first?.name == "")

        Edits.setModelTitle(&m, title: "Manufacture Product")
        #expect(m.title == "Manufacture Product")
        #expect(m.diagrams[ctx]?.title == "Manufacture Product")
        let box = try #require(m.contextDiagram?.boxes.first)
        #expect(box.name == "Manufacture Product", "the empty A-0 box takes the model title")
        #expect(m.conceptById(box.conceptId)?.term == "Manufacture Product", "and is bound to the concept it now denotes")
    }

    @Test("setModelTitle leaves an already-named A-0 box alone")
    func modelTitleLeavesNamedBoxAlone() throws {
        var (m, ctx, _) = try decomposedModel()
        let before = try #require(m.diagrams[ctx]?.boxes.first)
        Edits.setModelTitle(&m, title: "New Model Title")
        #expect(m.title == "New Model Title")
        #expect(m.diagrams[ctx]?.boxes.first?.name == before.name, "a box that already has a name keeps it")
        #expect(m.diagrams[ctx]?.boxes.first?.conceptId == before.conceptId)
    }

    // MARK: Concepts

    @Test("setConceptKind and defineConcept write those two fields only")
    func conceptKindAndDefinition() throws {
        var m = IDEF0Model.create(title: "M")
        let resolved = m.resolveConcept("Widget", kind: "data")
        let c = try #require(resolved)
        Edits.setConceptKind(&m, conceptId: c.id, kind: "mechanism")
        Edits.defineConcept(&m, conceptId: c.id, definition: "A thing that is made.")
        let updated = try #require(m.conceptById(c.id))
        #expect(updated.kind == "mechanism")
        #expect(updated.definition == "A thing that is made.")
        #expect(updated.term == "Widget", "the term is untouched by either edit")
    }

    @Test("addConcept creates a new term with the typed kind, but only redefines an existing one (F15)")
    func addConceptCreatesOrRedefinesOnly() throws {
        var m = IDEF0Model.create(title: "M")
        Edits.addConcept(&m, term: "Raw Material", kind: "data", definition: "Unprocessed stock.")
        let created = try #require(m.findConcept("Raw Material"))
        #expect(created.kind == "data")
        #expect(created.definition == "Unprocessed stock.")

        // An existing term: the typed kind is ignored, and a blank definition
        // must not wipe out the one it already has.
        Edits.addConcept(&m, term: "Raw Material", kind: "mechanism", definition: "   ")
        let untouched = try #require(m.findConcept("Raw Material"))
        #expect(untouched.kind == "data", "resolveConcept ignores kind for an existing term")
        #expect(untouched.definition == "Unprocessed stock.", "a blank typed definition does not clear the existing one")

        // A non-blank definition on the existing term does overwrite it.
        Edits.addConcept(&m, term: "raw material", kind: "data", definition: "Restated.")
        #expect(m.findConcept("Raw Material")?.definition == "Restated.")
    }

    @Test("removeConcept refuses a concept still in use and removes one that is not")
    func removeConceptRefusesWhileUsed() throws {
        var (m, ctx, _) = try decomposedModel()
        let box = try #require(m.contextDiagram?.boxes.first)
        // Naming the box binds it to a concept (Edits.renameBox); decomposing
        // alone does not.
        try Edits.renameBox(&m, diagramId: ctx, boxId: box.id, to: "Build Widget")
        let usedId = try #require(m.contextDiagram?.boxes.first?.conceptId)

        #expect(throws: Edits.Refusal.conceptInUse) {
            try Edits.removeConcept(&m, conceptId: usedId)
        }
        #expect(m.conceptById(usedId) != nil, "the refused removal changed nothing")

        // Rename the box away, unbinding the concept (F11), so it becomes unused.
        try Edits.renameBox(&m, diagramId: ctx, boxId: box.id, to: "")
        try Edits.removeConcept(&m, conceptId: usedId)
        #expect(m.conceptById(usedId) == nil)
    }

    // MARK: Edits (Edits.swift) — moveLabel, the one drag rule with no test yet

    @Test("moveLabel stores the drag as ldx/ldy, rounded as Math.round rounds")
    func moveLabelStoresRoundedOffset() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let id = try Edits.drawArrow(&m, diagramId: child, from: .box(d.boxes[0].id, .right, 0.5), to: .box(d.boxes[2].id, .left, 0.5))
        Edits.moveLabel(&m, diagramId: child, arrowId: id, original: Point(x: 0, y: 0), dragStart: Point(x: 10, y: 10), pointer: Point(x: 22.5, y: 17.5))
        let a = try #require(m.diagrams[child]?.arrows.last)
        #expect(a.ldx == 13 && a.ldy == 8)
    }
}
