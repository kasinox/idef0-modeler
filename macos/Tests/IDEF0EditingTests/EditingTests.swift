// The editing canvas's rules and edits, checked against the behaviour of
// src/ui/canvas.js. Where the web app does something non-obvious — which box
// wins an ambiguous grab, which way a half rounds, which edge a minimum size
// pins — the test says so.

import Testing
@testable import IDEF0Core
@testable import IDEF0Editing

/// A context box decomposed into three: A-0 with one box, A0 with three.
func decomposedModel() throws -> (IDEF0Model, context: String, child: String) {
    var m = IDEF0Model.create(title: "Make Widget")
    let ctx = m.rootDiagramId
    let top = try #require(m.contextDiagram?.boxes.first)
    _ = try Edits.drawArrow(&m, diagramId: ctx, from: .boundary(.top, 0.5), to: .box(top.id, .top, 0.5))
    _ = try Edits.drawArrow(&m, diagramId: ctx, from: .box(top.id, .right, 0.5), to: .boundary(.right, 0.5))
    // #require cannot wrap a mutating call, so the result is taken first.
    let decomposed = m.decomposeBox(diagramId: ctx, boxId: top.id, count: 3)
    let child = try #require(decomposed)
    // S01: a decomposition seeds no arrows any more (the child starts with
    // ports), so the two the parent's arrows used to seed — the control into
    // the first box, the output out of the last — are drawn here, as
    // connecting those ports would.
    let boxes = try #require(m.diagrams[child]).boxes
    _ = try Edits.drawArrow(&m, diagramId: child, from: .boundary(.top, 0.5), to: .box(boxes[0].id, .top, 0.5))
    _ = try Edits.drawArrow(&m, diagramId: child, from: .box(boxes[2].id, .right, 0.5), to: .boundary(.right, 0.5))
    return (m, ctx, child)
}

/// A context box with a labelled input, control and output, decomposed into
/// three and left unconnected (S01): the child diagram starts with three
/// ports — I1 "Raw Stock", C1 "Spec", O1 "Widget" — each bound to the
/// concept its parent arrow's label denotes.
func portedModel() throws -> (IDEF0Model, context: String, child: String) {
    var m = IDEF0Model.create(title: "Make Widget")
    let ctx = m.rootDiagramId
    let top = try #require(m.contextDiagram?.boxes.first)
    let input = try Edits.drawArrow(&m, diagramId: ctx, from: .boundary(.left, 0.5), to: .box(top.id, .left, 0.5))
    try Edits.labelArrow(&m, diagramId: ctx, arrowId: input, to: "Raw Stock")
    let control = try Edits.drawArrow(&m, diagramId: ctx, from: .boundary(.top, 0.5), to: .box(top.id, .top, 0.5))
    try Edits.labelArrow(&m, diagramId: ctx, arrowId: control, to: "Spec")
    let output = try Edits.drawArrow(&m, diagramId: ctx, from: .box(top.id, .right, 0.5), to: .boundary(.right, 0.5))
    try Edits.labelArrow(&m, diagramId: ctx, arrowId: output, to: "Widget")
    let decomposed = m.decomposeBox(diagramId: ctx, boxId: top.id, count: 3)
    let child = try #require(decomposed)
    return (m, ctx, child)
}

@Suite("Canvas rules")
struct CanvasRulesTests {
    @Test("Snapping rounds half-steps towards +∞, as Math.round does")
    func snap() {
        #expect(CanvasRules.snap(12.4) == 10)
        #expect(CanvasRules.snap(12.5) == 15)
        #expect(CanvasRules.snap(-12.5) == -10)
        #expect(CanvasRules.snap(-12.6) == -15)
    }

    @Test("A pointer near a box side anchors to that side")
    func anchorsToBoxSide() throws {
        let (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let b = d.boxes[0]
        let justOutsideLeft = Point(x: b.x - 10, y: b.y + b.h / 2)
        #expect(HitTest.anchor(in: d, at: justOutsideLeft) == .box(b.id, .left, 0.5))
        let onTop = Point(x: b.x + b.w * 0.25, y: b.y + 2)
        #expect(HitTest.anchor(in: d, at: onTop) == .box(b.id, .top, 0.25))
        // Beyond the box's 14-unit reach, and far from any sheet edge.
        #expect(HitTest.anchor(in: d, at: Point(x: b.x - 20, y: b.y + b.h / 2), boxesOnly: true) == nil)
    }

    @Test("Overlapping reach goes to the first box in drawing order, not the topmost")
    func anchorPrefersFirstBox() {
        var d = newDiagram(node: "A0", title: "t")
        let first = newBox(name: "First", x: 300, y: 300, w: 120, h: 80)
        let second = newBox(name: "Second", x: 430, y: 300, w: 120, h: 80)
        d.boxes = [first, second]
        // x = 425 is within 14 of both the first box's right side and the second's left.
        let hit = HitTest.anchor(in: d, at: Point(x: 425, y: 340))
        #expect(hit?.boxId == first.id)
        // …whereas selection picks the topmost box under the pointer.
        let stacked = [newBox(name: "Under", x: 300, y: 300), newBox(name: "Over", x: 310, y: 310)]
        d.boxes = stacked
        #expect(HitTest.box(in: d, at: Point(x: 320, y: 320))?.name == "Over")
    }

    @Test("Near the drawing-area edge the anchor is a boundary endpoint")
    func anchorsToBoundary() {
        let d = newDiagram(node: "A0", title: "t")
        let w = Sheet.work
        let p = Point(x: w.x + 10, y: w.y + w.h * 0.25)
        #expect(HitTest.anchor(in: d, at: p) == .boundary(.left, 0.25))
        // Below the left edge's span, the left edge no longer catches the
        // pointer — but the bottom edge, 20 units away, still does.
        #expect(HitTest.anchor(in: d, at: Point(x: w.x + 10, y: w.y2 + 20)) == .boundary(.bottom, 0.02))
        // Outside both edges' spans by more than 4 units: nothing.
        #expect(HitTest.anchor(in: d, at: Point(x: w.x - 20, y: w.y2 + 20)) == nil)
        // More than 26 units in from every edge: nothing.
        #expect(HitTest.anchor(in: d, at: Point(x: w.x + 100, y: w.y + 100)) == nil)
    }

    @Test("A click within 9 units of a route selects the arrow")
    func arrowHit() throws {
        let (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let a = try #require(d.arrows.first)
        let pts = HitTest.route(m, in: d, a)
        let mid = Point(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        #expect(HitTest.arrow(in: d, at: mid)?.id == a.id)
        #expect(HitTest.arrow(in: d, at: Point(x: mid.x, y: mid.y + 40)) == nil)
    }

    /// A single-box diagram with one mechanism arrow, from the drawing-area's
    /// bottom edge into the box's bottom face — both boundary and box ends
    /// face the same way, so the route's longest run is vertical and its
    /// label draws start-anchored beside it, as 'Plant Equipment' does on the
    /// shipped sample (F39's own reproduction case).
    private func labelTestModel() -> (IDEF0Model, Diagram, Arrow) {
        var m = IDEF0Model.create(title: "M")
        var d = newDiagram(node: "A0", title: "t")
        let b = newBox(name: "Box", x: 400, y: 200, w: 190, h: 112)
        d.boxes = [b]
        let a = newArrow(label: "Plant Equipment", from: .boundary(.bottom, 0.5), to: .box(b.id, .bottom, 0.5))
        d.arrows = [a]
        m.diagrams[d.id] = d
        return (m, d, a)
    }

    @Test("HitTest.label hits a vertical-run label's actual text, well outside arrowGrab's reach of the route (F39)")
    func labelHitVerticalRun() throws {
        let (m, d, a) = labelTestModel()
        let pts = HitTest.route(m, in: d, a)
        let mid = longestSegmentMid(pts)
        #expect(!mid.horizontal, "the route's longest run should be vertical")
        // labelPosition's default for a vertical run: start-anchored 12 units
        // out — comfortably past arrowGrab's 9-unit reach of the line itself.
        let onText = Point(x: mid.x + 20, y: mid.y)
        #expect(HitTest.arrow(in: d, at: onText) == nil, "the press should already miss the route")
        #expect(HitTest.label(m, in: d, at: onText)?.id == a.id)
    }

    @Test("HitTest.label hits a label dragged well away from its route exactly where it is drawn (F39)")
    func labelHitMovedLabel() throws {
        let (m0, d0, a0) = labelTestModel()
        var d = d0
        let i = try #require(d.arrows.firstIndex { $0.id == a0.id })
        d.arrows[i].ldx = 60
        d.arrows[i].ldy = 40
        var m = m0
        m.diagrams[d.id] = d
        let arrow = d.arrows[i]
        let pos = labelPosition(HitTest.route(m, in: d, arrow), arrow)
        // Well past the old fixed-offset base, and past arrowGrab's reach of
        // the route itself.
        #expect(HitTest.arrow(in: d, at: Point(x: pos.x, y: pos.y)) == nil)
        #expect(HitTest.label(m, in: d, at: Point(x: pos.x, y: pos.y))?.id == arrow.id)
    }

    @Test("HitTest.label misses a press past the end of the label's text (F39)")
    func labelHitMissesPastText() throws {
        let (m, d, a) = labelTestModel()
        let pts = HitTest.route(m, in: d, a)
        let pos = labelPosition(pts, a)
        let width = textWidth(a.label, fontSize: 10.5)
        let rect = labelRect(pos, width)
        #expect(HitTest.label(m, in: d, at: Point(x: rect.x + rect.w / 2, y: rect.y + rect.h / 2))?.id == a.id)
        #expect(HitTest.label(m, in: d, at: Point(x: rect.x + rect.w + 40, y: rect.y + rect.h / 2)) == nil)
    }

    @Test("HitTest.label hits a horizontal label's centre, and finds nothing on an arrow with no label")
    func labelHitHorizontalCentre() throws {
        var m = IDEF0Model.create(title: "M")
        var d = newDiagram(node: "A0", title: "t")
        let b1 = newBox(name: "One", x: 100, y: 300, w: 190, h: 112)
        let b2 = newBox(name: "Two", x: 500, y: 300, w: 190, h: 112)
        d.boxes = [b1, b2]
        let a = newArrow(label: "Work Order", from: .box(b1.id, .right, 0.5), to: .box(b2.id, .left, 0.5))
        d.arrows = [a]
        m.diagrams[d.id] = d

        let pos = labelPosition(HitTest.route(m, in: d, a), a)
        #expect(pos.anchor == .middle, "a horizontal run's label centres on the route")
        #expect(HitTest.label(m, in: d, at: Point(x: pos.x, y: pos.y))?.id == a.id)

        var unlabelled = d
        unlabelled.arrows[0].label = ""
        #expect(HitTest.label(m, in: unlabelled, at: Point(x: pos.x, y: pos.y)) == nil)
    }

    @Test("DragRules.labelDragOrigin keeps ldx/ldy meaning: unchanged once already offset, or the gap from the auto spot to legacyLabelBase otherwise (F59)")
    func labelDragOriginContinuity() throws {
        let (m, d, a) = labelTestModel()
        // Already offset: the drag starts from its own ldx/ldy, unchanged.
        var offset = a
        offset.ldx = 12; offset.ldy = -8
        #expect(DragRules.labelDragOrigin(m, d, offset) == Point(x: 12, y: -8))

        // Still auto-placed: the origin is the gap between the auto-placed
        // spot and the legacy base, so adding it back reproduces the spot
        // the label was actually drawn at — no jump when the drag begins.
        let pts = HitTest.route(m, in: d, a)
        let auto = labelPlacement(pts, a.label)
        let base = legacyLabelBase(pts)
        let origin = DragRules.labelDragOrigin(m, d, a)
        #expect(origin == Point(x: auto.x - base.x, y: auto.y - base.y))
        #expect(Point(x: base.x + origin.x, y: base.y + origin.y) == Point(x: auto.x, y: auto.y))
    }

    @Test("HitTest.port hits a port's stub and its open circle, and misses beside the stub and away from the edge (S01)")
    func portHit() throws {
        let (m, _, child) = try portedModel()
        let d = try #require(m.diagrams[child])
        let ports = m.ports(d)
        #expect(ports.map(\.code) == ["I1", "C1", "O1"])
        let input = try #require(ports.first { $0.code == "I1" })
        let s = portShape(input)
        #expect(s.edge.x == Sheet.work.x && s.inner.x == Sheet.work.x + 26, "an I port's stub runs in from the left edge")

        // Anywhere along the stub, within the 10-unit band around it.
        let onStub = Point(x: (s.edge.x + s.inner.x) / 2, y: s.edge.y + 4)
        #expect(HitTest.port(in: ports, at: onStub) == input)
        #expect(HitTest.port(in: ports, at: s.inner) == input, "the open circle takes the press too")
        // Just past the circle's grab, along the stub's line.
        #expect(HitTest.port(in: ports, at: Point(x: s.inner.x + CanvasRules.portRingGrab + 1, y: s.inner.y)) == nil)
        // Beside the stub, outside the band.
        #expect(HitTest.port(in: ports, at: Point(x: (s.edge.x + s.inner.x) / 2, y: s.edge.y + 12)) == nil)
        // Well inside the drawing area: nothing.
        #expect(HitTest.port(in: ports, at: Point(x: Sheet.work.x + 200, y: Sheet.work.y + 200)) == nil)

        // The output port sits on the right edge, and the control on the top.
        let output = try #require(ports.first { $0.code == "O1" })
        #expect(HitTest.port(in: ports, at: portShape(output).inner) == output)
        let control = try #require(ports.first { $0.code == "C1" })
        #expect(portShape(control).inner.y == Sheet.work.y + 26)
        #expect(HitTest.port(in: ports, at: Point(x: portShape(control).edge.x - 3, y: Sheet.work.y + 10)) == control)

        // No ports, nothing to hit; the context diagram has none.
        #expect(HitTest.port(in: [], at: s.inner) == nil)
        let context = try #require(m.contextDiagram)
        #expect(m.ports(context).isEmpty)
    }

    @Test("HitTest.port is the web canvas's portAt, unit for unit: the stub's own rectangle, 10 wide, and 6 from the ring's centre (S01)")
    func portHitGeometryMatchesWeb() throws {
        let (m, _, child) = try portedModel()
        let d = try #require(m.diagrams[child])
        let ports = m.ports(d)
        let input = try #require(ports.first { $0.code == "I1" })
        #expect(portShape(input) == PortShape(edge: Point(x: 40, y: 443), inner: Point(x: 66, y: 443)), "the same port tests/web/canvas-ports.test.mjs probes")
        #expect(CanvasRules.portGrab == 5 && CanvasRules.portRingGrab == 6)
        // The web test's probes, verbatim: along the stub, on the ring, at the
        // rectangle's width…
        for p in [Point(x: 40, y: 443), Point(x: 53, y: 443), Point(x: 66, y: 443), Point(x: 53, y: 448), Point(x: 53, y: 438), Point(x: 71, y: 445)] {
            #expect(HitTest.port(in: ports, at: p) == input, "\(p)")
        }
        // …and past the rectangle, past the ring, and beyond the stub's ends
        // (the rectangle does not overhang the edge or the ring).
        for p in [Point(x: 53, y: 449), Point(x: 53, y: 437), Point(x: 73, y: 443), Point(x: 40, y: 200), Point(x: 36, y: 443), Point(x: 72.5, y: 443)] {
            #expect(HitTest.port(in: ports, at: p) == nil, "\(p)")
        }
        let control = try #require(ports.first { $0.code == "C1" })
        let c = portShape(control)
        #expect(HitTest.port(in: ports, at: Point(x: c.edge.x + 4, y: c.edge.y + 13)) == control)
        #expect(HitTest.port(in: ports, at: Point(x: c.edge.x + 6, y: c.edge.y + 13)) == nil)
    }

    @Test("HitTest.arrow(_:in:at:) finds no route for a hidden bundle member and selects the representative on its drawn line; labels are hit and read as drawn; a member alone keeps its own (S01)")
    func hiddenMemberResolvesToRepresentative() throws {
        var (m, ctx, _) = try portedModel()
        let top = try #require(m.contextDiagram?.boxes.first)
        // A second input on the same faces as "Raw Stock", then the two combined.
        let parts = try Edits.drawArrow(&m, diagramId: ctx, from: .boundary(.left, 0.7), to: .box(top.id, .left, 0.7))
        try Edits.labelArrow(&m, diagramId: ctx, arrowId: parts, to: "Parts")
        let stock = try #require(m.findConcept("Raw Stock")), partsConcept = try #require(m.findConcept("Parts"))
        let bundle = try Edits.combineConcepts(&m, memberIds: [stock.id, partsConcept.id], term: "Inputs")
        let d = try #require(m.diagrams[ctx])
        let rep = try #require(d.arrows.first { $0.label == "Raw Stock" })
        let hidden = try #require(d.arrows.first { $0.id == parts })
        #expect(HitTest.drawnEntry(m, in: d, standingFor: hidden.id)?.arrow.id == rep.id)
        #expect(HitTest.drawnEntry(m, in: d, standingFor: rep.id)?.hidden == [hidden.id])
        #expect(HitTest.drawnEntry(m, in: d, standingFor: "no-such-arrow") == nil)

        // The hidden member's own route is not drawn (S02: only drawn arrows
        // are routed): a press on it, clear of the representative's line,
        // finds nothing; the route-only hit test still knows it.
        let ghostMid = longestSegmentMid(routeArrow(d, hidden))
        let ghost = Point(x: ghostMid.x, y: ghostMid.y)
        #expect(distToPolyline(HitTest.route(m, in: d, rep), ghost) > CanvasRules.arrowGrab, "the ghost is on the hidden route only")
        #expect(HitTest.arrow(in: d, at: ghost)?.id == hidden.id, "the route alone")
        #expect(HitTest.arrow(m, in: d, at: ghost) == nil, "no ink there, nothing to press")
        let probeMid = longestSegmentMid(HitTest.route(m, in: d, rep))
        let probe = Point(x: probeMid.x, y: probeMid.y)
        #expect(HitTest.arrow(m, in: d, at: probe)?.id == rep.id, "the one line drawn for the pair")
        // The representative, alone among the drawn arrows on its faces, is
        // routed as the one line it is: no lane is spread for the member that
        // draws nothing.
        var withoutHidden = d
        withoutHidden.arrows.removeAll { $0.id == hidden.id }
        #expect(HitTest.route(m, in: d, rep) == routeArrow(withoutHidden, rep))
        #expect(HitTest.drawnLabel(m, in: d, of: rep) == "Inputs")
        #expect(HitTest.drawnLabel(m, in: d, of: hidden) == "Parts", "not drawn at all, so it reads as its own")
        #expect(HitTest.drawsBundleTerm(m, in: d, rep) && !HitTest.drawsBundleTerm(m, in: d, hidden))

        // The label is hit where "Inputs" is drawn, placed and measured as that text.
        var labelled = rep
        labelled.label = bundle.term
        let icomEnds = SheetDrawing.icomRects(m, d)
        let boxes = d.boxes.map(\.rect)
        let pos = labelPosition(HitTest.labelPath(m, in: d, rep), labelled, icomEnds: icomEnds, boxes: boxes)
        #expect(HitTest.label(m, in: d, at: Point(x: pos.x, y: pos.y))?.id == rep.id)
        let ownPos = labelPosition(routeArrow(d, hidden), hidden, icomEnds: icomEnds, boxes: boxes)
        #expect(HitTest.label(m, in: d, at: Point(x: ownPos.x, y: ownPos.y))?.id != hidden.id, "a hidden member has no label to hit")

        // The member moved to another face is alone there: both draw, each
        // with its own label, and the route resolves to itself.
        var alone = m
        alone.updateDiagram(ctx) { dg in
            let i = dg.arrows.firstIndex { $0.id == hidden.id }!
            dg.arrows[i].to.side = .top
        }
        let da = try #require(alone.diagrams[ctx])
        let movedHidden = try #require(da.arrows.first { $0.id == hidden.id })
        #expect(HitTest.drawnLabel(alone, in: da, of: rep) == "Raw Stock")
        #expect(HitTest.drawnLabel(alone, in: da, of: movedHidden) == "Parts")
        #expect(!HitTest.drawsBundleTerm(alone, in: da, rep))
        // Both still leave the left edge for the same bundle, so they fork off
        // one boundary line (S02): the trunk is the representative's, the
        // branch — the part of the route that is Parts's own — is Parts.
        let branch = HitTest.labelPath(alone, in: da, movedHidden)
        let aloneRoute = HitTest.route(alone, in: da, movedHidden)
        #expect(aloneRoute[0] == HitTest.route(alone, in: da, rep)[0], "the branch leaves from the trunk")
        #expect(HitTest.arrow(alone, in: da, at: aloneRoute[0])?.id == rep.id, "the trunk is the representative")
        let branchMid = longestSegmentMid(branch)
        #expect(HitTest.arrow(alone, in: da, at: Point(x: branchMid.x, y: branchMid.y))?.id == hidden.id)
    }

    // MARK: S02 forks and joins

    /// The sample as the goldens read it, bound.
    private func boundSample() -> IDEF0Model {
        var m = buildSampleModel()
        m.bindAll()
        return m
    }

    @Test("The sample's three Work Orders fork off Plan Production (S02): one trunk, every branch routed from the representative's pos, one label; a join mirrors it at the to end")
    func forkAndJoinDrawnAsOne() throws {
        var m = boundSample()
        let a0Id = try #require(m.diagrams.first { $0.value.node == "A0" }?.key)
        var a0 = try #require(m.diagrams[a0Id])
        let wos = a0.arrows.filter { $0.label == "Work Order" }
        #expect(wos.count == 3)
        let drawn = SheetDrawing.drawnArrows(m, a0)
        let entries = wos.map { w in drawn.first { $0.arrow.id == w.id }! }
        let rep = wos[0]   // pos 0.5, the lowest on the right side
        #expect(entries.allSatisfy { $0.fork == rep.id && $0.join == nil })
        #expect(entries.allSatisfy { $0.drawn.from == rep.from && $0.drawn.to == $0.arrow.to })
        #expect(entries.allSatisfy { $0.pts[0] == entries[0].pts[0] && $0.forkTrunk == entries[0].forkTrunk })
        let trunk = try #require(entries[0].forkTrunk)
        #expect(trunk.count >= 2 && trunk[0] == entries[0].pts[0] && trunk[1].y == trunk[0].y)
        #expect(trunk[1].x == entries.map { $0.pts[1].x }.min(), "to the first branch's turn")
        #expect(entries[0].labelPath == trunk, "the representative labels the trunk")
        #expect(entries[1].labelPath == nil && entries[2].labelPath == nil, "the branches read the same, so draw none")
        #expect(wos.map { $0.from.pos } == [0.5, 0.7, 0.88], "the stored ends are untouched")
        // The trunk is a piece of every branch's route, so a press there is the representative's.
        let onTrunk = Point(x: (trunk[0].x + trunk[1].x) / 2, y: trunk[0].y)
        #expect(HitTest.arrow(m, in: a0, at: onTrunk)?.id == rep.id)
        let midRoute = entries[1].pts
        #expect(HitTest.arrow(m, in: a0, at: Point(x: midRoute[1].x, y: (midRoute[1].y + midRoute[2].y) / 2))?.id == wos[1].id, "a branch's drop is its own")
        #expect(HitTest.label(m, in: a0, at: {
            let pos = labelPosition(trunk, rep, icomEnds: SheetDrawing.icomRects(m, a0), boxes: a0.boxes.map(\.rect))
            return Point(x: pos.x, y: pos.y)
        }())?.id == rep.id)
        #expect(HitTest.endGroup(m, in: a0, arrowId: wos[1].id, end: .from).map(\.id) == wos.map(\.id))
        #expect(HitTest.endGroup(m, in: a0, arrowId: wos[1].id, end: .to).map(\.id) == [wos[1].id])

        // A join: two same-concept outputs entering Ship Product's top.
        let fab = try #require(a0.boxes.first { $0.name == "Fabricate Components" })
        let asm = try #require(a0.boxes.first { $0.name == "Assemble Product" })
        let ship = try #require(a0.boxes.first { $0.name == "Ship Product" })
        let j1 = newArrow(label: "Inspection Report", from: .box(fab.id, .right, 0.8), to: .box(ship.id, .top, 0.75))
        let j2 = newArrow(label: "Inspection Report", from: .box(asm.id, .right, 0.8), to: .box(ship.id, .top, 0.6))
        a0.arrows += [j1, j2]
        m.diagrams[a0Id] = a0
        m.bindAll()
        let joined = try #require(m.diagrams[a0Id])
        let jd = SheetDrawing.drawnArrows(m, joined)
        let e1 = try #require(jd.first { $0.arrow.id == j1.id })
        let e2 = try #require(jd.first { $0.arrow.id == j2.id })
        #expect(e1.join == j2.id, "the lowest position on the top side, though later in array order")
        #expect(e2.join == j2.id)
        #expect(e1.fork == nil)
        #expect(e1.drawn.to == j2.to)
        #expect(e1.pts.last == e2.pts.last, "one point of entry")
        let jt = try #require(e2.joinTrunk)
        #expect(e1.joinTrunk == jt && jt.last == e2.pts.last)
        #expect(e2.labelPath == jt && e1.labelPath == nil)
        #expect(e1.isJoinBranch && !e2.isJoinBranch)
        // Only the representative draws the arrowhead into the box.
        let heads = SheetDrawing.build(m, diagramId: a0Id).filter { op in
            if case .path(_, let fill, let stroke, let role) = op, fill != nil, stroke == nil,
               role == .arrow(j1.id) || role == .arrow(j2.id) { return true }
            return false
        }
        #expect(heads.count == 1)
    }

    @Test("A trunk carries the label only when its longest segment can: a horizontal one at least the text's width, a vertical one a line high; otherwise the representative's whole route, clear of the frame (S02)")
    func trunkTooShortForItsLabel() throws {
        var m = boundSample()
        let a0Id = try #require(m.diagrams.first { $0.value.node == "A0" }?.key)
        // Plan Production's Work Order trunk (94.5 units) carries 'Work Order'.
        let before = try #require(m.diagrams[a0Id])
        let wo = try #require(before.arrows.first { $0.label == "Work Order" })
        let rep = try #require(SheetDrawing.drawnArrows(m, before).first { $0.arrow.id == wo.id })
        let woTrunk = try #require(rep.forkTrunk)
        #expect(longestSegmentMid(woTrunk).length >= textWidth("Work Order", fontSize: 10.5))
        #expect(rep.labelPath == woTrunk)
        // I1 into boxes 1 and 2 (box 1 by the left edge): the trunk is the
        // 30-unit boundary stub, and a label against it would cross the frame.
        let fab = try #require(before.boxes.first { $0.name == "Fabricate Components" })
        let copy = newArrow(label: "Customer Order", from: .boundary(.left, 0.3), to: .box(fab.id, .left, 0.25), conceptId: "gl1")
        m.updateDiagram(a0Id) { $0.arrows.append(copy) }
        let a0 = try #require(m.diagrams[a0Id])
        let orig = try #require(a0.arrows.first { $0.label == "Customer Order" && $0.id != copy.id })
        let drawn = SheetDrawing.drawnArrows(m, a0)
        let eCo = try #require(drawn.first { $0.arrow.id == orig.id })
        let eCopy = try #require(drawn.first { $0.arrow.id == copy.id })
        let stub = try #require(eCo.forkTrunk)
        #expect(longestSegmentMid(stub).length < textWidth("Customer Order", fontSize: 10.5))
        #expect(eCo.labelPath == eCo.pts, "the whole route")
        #expect(eCopy.labelPath == nil, "still one label for the group")
        let width = textWidth("Customer Order", fontSize: 10.5)
        let boxes = a0.boxes.map(\.rect)
        let onTrunk = labelRect(labelPlacement(stub, "Customer Order", boxes: boxes), width)
        #expect(onTrunk.x < 24, "against the stub the text would start on the frame border")
        let placed = labelRect(labelPlacement(eCo.pts, "Customer Order", icomEnds: SheetDrawing.icomRects(m, a0), boxes: boxes), width)
        #expect(placed.x >= 24, "on the route it clears the frame")
        // The thresholds are >=, as render.js's; a vertical trunk needs a line's height.
        let w = textWidth("ab", fontSize: 10.5)
        let route = [Point(x: 0, y: 0), Point(x: 200, y: 0)]
        let exact = [Point(x: 0, y: 0), Point(x: w, y: 0)]
        #expect(SheetDrawing.trunkLabelPath(exact, route, "ab") == exact)
        #expect(SheetDrawing.trunkLabelPath([Point(x: 0, y: 0), Point(x: w - 1e-9, y: 0)], route, "ab") == route)
        let vertical = [Point(x: 0, y: 0), Point(x: 0, y: 16)]
        let down = [Point(x: 0, y: 0), Point(x: 0, y: 200)]
        #expect(SheetDrawing.trunkLabelPath(vertical, down, "a long label indeed") == vertical)
        #expect(SheetDrawing.trunkLabelPath([Point(x: 0, y: 0), Point(x: 0, y: 15.9)], down, "ab") == down)
        #expect(SheetDrawing.trunkLabelPath([Point(x: 0, y: 0)], down, "") == down, "a one-point trunk never carries a label")
        // A join into a box top: the short vertical drop carries the label beside it.
        let asm = try #require(a0.boxes.first { $0.name == "Assemble Product" })
        let ship = try #require(a0.boxes.first { $0.name == "Ship Product" })
        let j1 = newArrow(label: "Inspection Report", from: .box(fab.id, .right, 0.8), to: .box(ship.id, .top, 0.75))
        let j2 = newArrow(label: "Inspection Report", from: .box(asm.id, .right, 0.8), to: .box(ship.id, .top, 0.6))
        m.updateDiagram(a0Id) { $0.arrows += [j1, j2] }
        m.bindAll()
        let joined = try #require(m.diagrams[a0Id])
        let e2 = try #require(SheetDrawing.drawnArrows(m, joined).first { $0.arrow.id == j2.id })
        let jt = try #require(e2.joinTrunk)
        let seg = longestSegmentMid(jt)
        #expect(!seg.horizontal && seg.length < textWidth("Inspection Report", fontSize: 10.5) && seg.length >= 16)
        #expect(e2.labelPath == jt)
    }

    @Test("A branch left a single point by overlapping trunks labels its whole route, so a dragged label still has a segment to sit on (S02)")
    func overlappingTrunksLeaveTheBranchItsRoute() throws {
        var m = boundSample()
        let a0Id = try #require(m.diagrams.first { $0.value.node == "A0" }?.key)
        // A second Production Staff arrow between the same faces as the
        // sample's (boundary bottom → Assemble Product bottom), with a label
        // of its own and a lower pos: the representative of both the fork
        // and the join, so the sample's arrow is a branch whose trunks cover
        // its route.
        let ps = try #require(m.diagrams[a0Id]?.arrows.first { $0.label == "Production Staff" })
        var to = ps.to
        to.pos = 0.3
        let dup = newArrow(label: "Shift Crew", from: .boundary(.bottom, 0.14), to: to, conceptId: ps.conceptId)
        m.updateDiagram(a0Id) { d in
            d.arrows.append(dup)
            let i = d.arrows.firstIndex { $0.id == ps.id }!
            d.arrows[i].ldx = 7   // dragged
            d.arrows[i].ldy = -5
        }
        let a0 = try #require(m.diagrams[a0Id])
        let drawn = SheetDrawing.drawnArrows(m, a0)
        let ePs = try #require(drawn.first { $0.arrow.id == ps.id })
        let eDup = try #require(drawn.first { $0.arrow.id == dup.id })
        #expect(ePs.fork == dup.id && ePs.join == dup.id)
        #expect(SheetDrawing.branchPart(ePs.pts, ePs.forkTrunk, ePs.joinTrunk).count == 1, "the branch part is one point")
        #expect(ePs.labelPath == ePs.pts, "so the label path is the route")
        #expect(eDup.labelPath == eDup.pts, "the representative's trunks are its whole route, long enough for the text")
        // Both labels are placed, and the sheet builds, without a one-point path.
        let icomEnds = SheetDrawing.icomRects(m, a0), boxes = a0.boxes.map(\.rect)
        for e in [ePs, eDup] {
            var labelled = e.arrow
            labelled.label = e.label
            let pos = labelPosition(try #require(e.labelPath), labelled, icomEnds: icomEnds, boxes: boxes)
            #expect(pos.x.isFinite && pos.y.isFinite)
        }
        #expect(!SheetDrawing.build(m, diagramId: a0Id).isEmpty)
        let p = { (x: Double, y: Double) in Point(x: x, y: y) }
        #expect(SheetDrawing.branchLabelPath([p(70, 0)], [p(0, 0), p(80, 0)]) == [p(0, 0), p(80, 0)])
        #expect(SheetDrawing.branchLabelPath([p(30, 0), p(60, 0)], [p(0, 0), p(80, 0)]) == [p(30, 0), p(60, 0)])
    }

    @Test("A boundary fork writes its shared code once, at the trunk; a branch with a label of its own draws it on its branch alone; a hidden bundle member is no branch (S02)")
    func boundaryForkCodesAndBranchLabels() throws {
        var m = boundSample()
        let a0Id = try #require(m.diagrams.first { $0.value.node == "A0" }?.key)
        let fab = try #require(m.diagrams[a0Id]?.boxes.first { $0.name == "Fabricate Components" })
        let copy = newArrow(label: "Customer Order", from: .boundary(.left, 0.3), to: .box(fab.id, .left, 0.25), conceptId: "gl1")
        m.updateDiagram(a0Id) { $0.arrows.append(copy) }
        let a0 = try #require(m.diagrams[a0Id])
        let orig = try #require(a0.arrows.first { $0.label == "Customer Order" && $0.id != copy.id })
        let codes = m.icomCodes(a0)
        #expect(codes["\(copy.id):from"] == "I1", "rule 14: the fork shares the code")
        let drawn = SheetDrawing.drawnArrows(m, a0)
        let eCo = try #require(drawn.first { $0.arrow.id == orig.id })
        let eCopy = try #require(drawn.first { $0.arrow.id == copy.id })
        #expect(eCo.fork == orig.id)
        #expect(eCopy.fork == orig.id)
        #expect(eCopy.drawn.from == orig.from)
        #expect(SheetDrawing.drawnCodes(eCo, codes: codes) == [.from: "I1"])
        #expect(SheetDrawing.drawnCodes(eCopy, codes: codes) == [:], "the representative already writes I1 there")
        #expect(SheetDrawing.drawnCodes(eCopy, codes: ["\(copy.id):from": "I9"]) == [.from: "I9"], "kept where the representative has none")
        #expect(SheetDrawing.icomRects(drawn, codes: codes).count == codes.count - 1, "one I1, not two")

        // Customer Order and Raw Materials combined (on the sample as it
        // is, without the copy): on A0 Raw Materials forks off Customer
        // Order's boundary line and keeps its specific label, drawn on its
        // branch, after the trunk.
        m = boundSample()
        let members = ["Customer Order", "Raw Materials"].compactMap { m.findConcept($0)?.id }
        _ = try m.combineConcepts(members, term: "Inputs")
        let freshA0Id = try #require(m.diagrams.first { $0.value.node == "A0" }?.key)
        let bundled = try #require(m.diagrams[freshA0Id])
        let co = try #require(bundled.arrows.first { $0.label == "Customer Order" })
        let bd = SheetDrawing.drawnArrows(m, bundled)
        let rm = try #require(bundled.arrows.first { $0.label == "Raw Materials" })
        let eRm = try #require(bd.first { $0.arrow.id == rm.id })
        let eCo2 = try #require(bd.first { $0.arrow.id == co.id })
        #expect(eRm.fork == co.id)
        #expect(eRm.label == "Raw Materials" && eCo2.label == "Customer Order")
        // The boundary trunk here is only the stub before the branches turn,
        // too short for the text: the representative's label falls back to
        // its route.
        let stub = try #require(eCo2.forkTrunk)
        #expect(longestSegmentMid(stub).length < textWidth("Customer Order", fontSize: 10.5))
        #expect(eCo2.labelPath == eCo2.pts)
        let branch = try #require(eRm.labelPath)
        #expect(branch.first == eRm.forkTrunk?.last && branch.last == eRm.pts.last)
        #expect(branch == SheetDrawing.branchPart(eRm.pts, eRm.forkTrunk, nil))

        // On A-0 the pair runs between the same faces: the bundle merge takes
        // precedence, the hidden member is no branch, and the representative,
        // alone on its face, forks nothing.
        let ctx = try #require(m.contextDiagram)
        let cd = SheetDrawing.drawnArrows(m, ctx)
        #expect(cd.count == ctx.arrows.count - 1)
        #expect(cd[0].hidden.count == 1 && cd[0].fork == nil && cd[0].join == nil && cd[0].labelPath == cd[0].pts)
    }

    @Test("The representative is the earliest on the face — the lowest stored pos, then array order — parentBoxArrows's own rule (S02)")
    func representativeFollowsIcomOrder() throws {
        var m = boundSample()
        let a0Id = try #require(m.diagrams.first { $0.value.node == "A0" }?.key)
        func check(_ expectRep: Int) throws {
            let a0 = try #require(m.diagrams[a0Id])
            let wos = a0.arrows.filter { $0.label == "Work Order" }
            let plan = try #require(a0.boxes.first { $0.name == "Plan Production" })
            let entry = try #require(m.parentBoxArrows(a0, plan.id)[.right]?.first { $0.arrows.count == 3 })
            #expect(entry.arrow.id == wos[expectRep].id, "the ICOM code is numbered by it")
            let drawn = SheetDrawing.drawnArrows(m, a0)
            #expect(drawn.filter { $0.fork != nil }.allSatisfy { $0.fork == wos[expectRep].id && $0.drawn.from == wos[expectRep].from })
        }
        try check(0)
        m.updateDiagram(a0Id) { dg in
            let i = dg.arrows.lastIndex { $0.label == "Work Order" }!
            dg.arrows[i].from.pos = 0.1
        }
        try check(2)
        m.updateDiagram(a0Id) { dg in
            let i = dg.arrows.lastIndex { $0.label == "Work Order" }!
            dg.arrows[i].from.pos = 0.5
        }
        try check(0)   // a tie keeps the earlier in array order
    }

    @Test("Edits.moveEndpoint with members moves a grouped end along its face together, and leaves the group alone when the end reconnects elsewhere (S02)")
    func groupedEndpointMove() throws {
        var m = boundSample()
        let a0Id = try #require(m.diagrams.first { $0.value.node == "A0" }?.key)
        let a0 = try #require(m.diagrams[a0Id])
        let wos = a0.arrows.filter { $0.label == "Work Order" }
        let plan = try #require(a0.boxes.first { $0.name == "Plan Production" })
        let members = HitTest.endGroup(m, in: a0, arrowId: wos[1].id, end: .from)
        #expect(members.map(\.id) == wos.map(\.id) && members.map(\.endpoint) == wos.map(\.from))
        // Along the face: every member follows.
        Edits.moveEndpoint(&m, diagramId: a0Id, arrowId: wos[1].id, end: .from, to: .box(plan.id, .right, 0.2), members: members)
        var after = try #require(m.diagrams[a0Id]).arrows.filter { $0.label == "Work Order" }
        #expect(after.allSatisfy { $0.from == .box(plan.id, .right, 0.2) && $0.bend == nil })
        #expect(after.map(\.to) == wos.map(\.to))
        // Onto another side: only the dragged arrow moves; the others are put
        // back as `members` recorded them.
        Edits.moveEndpoint(&m, diagramId: a0Id, arrowId: wos[1].id, end: .from, to: .box(plan.id, .bottom, 0.5), members: members)
        after = try #require(m.diagrams[a0Id]).arrows.filter { $0.label == "Work Order" }
        #expect(after[0].from == wos[0].from && after[2].from == wos[2].from)
        #expect(after[1].from == .box(plan.id, .bottom, 0.5))
        // An arrow alone at its end is a group of one, moved as ever.
        let alone = HitTest.endGroup(m, in: try #require(m.diagrams[a0Id]), arrowId: wos[1].id, end: .from)
        #expect(alone.map(\.id) == [wos[1].id])
        #expect(HitTest.endGroup(m, in: try #require(m.diagrams[a0Id]), arrowId: "no-such-arrow", end: .from).isEmpty)
    }

    @Test("Only an arrow between parallel sides has a bend handle")
    func bendHandleAxis() throws {
        let (m, _, child) = try decomposedModel()
        var d = try #require(m.diagrams[child])
        let (b1, b3) = (d.boxes[0], d.boxes[2])
        d.arrows = [
            newArrow(label: "Parallel", from: .box(b1.id, .right, 0.5), to: .box(b3.id, .left, 0.5)),
            newArrow(label: "Crossed", from: .box(b1.id, .right, 0.5), to: .box(b3.id, .top, 0.5)),
        ]
        #expect(HitTest.bendHandle(m, in: d, d.arrows[0])?.axis == .x)
        #expect(HitTest.bendHandle(m, in: d, d.arrows[1]) == nil)
    }

    @Test("A feedback route, and a straight same-y route, have no bend handle to grab (F40)")
    func bendHandleHiddenWhenThereIsNoVisibleBend() {
        let m = IDEF0Model.create(title: "M")
        var d = newDiagram(node: "A0", title: "t")
        // Box 3, well to the right, output back to box 1 on its left: a
        // genuine feedback (down-and-under), whose shape is fixed.
        let b1 = newBox(name: "One", x: 100, y: 300, w: 150, h: 90)
        let b3 = newBox(name: "Three", x: 700, y: 300, w: 150, h: 90)
        d.boxes = [b1, b3]
        let feedback = newArrow(label: "Rework", from: .box(b3.id, .right, 0.5), to: .box(b1.id, .left, 0.5))
        #expect(HitTest.bendHandle(m, in: d, feedback) == nil)

        // Box 1 right to box 3 left, exactly the same y: the two-point route
        // has no middle run to drag either.
        let straight = newArrow(label: "Output", from: .box(b1.id, .right, 0.5), to: .box(b3.id, .left, 0.5))
        #expect(HitTest.route(m, in: d, straight).count == 2)
        #expect(HitTest.bendHandle(m, in: d, straight) == nil)
    }

    @Test("A dragged bend stays inside the drawing area")
    func bendClamps() {
        let w = Sheet.work
        #expect(DragRules.bend(axis: .x, pointer: Point(x: -5000, y: 0)) == w.x)
        #expect(DragRules.bend(axis: .x, pointer: Point(x: 5000, y: 0)) == w.x2)
        #expect(DragRules.bend(axis: .y, pointer: Point(x: 0, y: -5000)) == w.y)
        #expect(DragRules.bend(axis: .y, pointer: Point(x: 0, y: 5000)) == w.y2)
        #expect(DragRules.bend(axis: .x, pointer: Point(x: 512, y: 0)) == 510)
    }

    @Test("A dragged label offset rounds as Math.round does")
    func labelOffsetRounding() {
        let o = DragRules.labelOffset(original: Point(x: 0, y: 0), dragStart: Point(x: 10, y: 10), pointer: Point(x: 12.5, y: 7.5))
        #expect(o.x == 3 && o.y == -2)
    }
}

@Suite("Edits")
struct EditsTests {
    @Test("Renaming a box binds its concept and carries an unlocked child title along")
    func renameBindsAndSyncsTitle() throws {
        var (m, ctx, child) = try decomposedModel()
        let top = try #require(m.contextDiagram?.boxes.first)
        try Edits.renameBox(&m, diagramId: ctx, boxId: top.id, to: "  Build Widget  ")
        let renamed = try #require(m.contextDiagram?.boxes.first)
        #expect(renamed.name == "Build Widget")
        #expect(m.conceptById(renamed.conceptId)?.term == "Build Widget")
        #expect(m.conceptById(renamed.conceptId)?.kind == "activity")
        #expect(m.diagrams[child]?.title == "Build Widget")
        #expect(m.title == "Build Widget", "renaming the A-0 box renames the model")

        m.updateDiagram(child) { $0.title = "Kept"; $0.titleLocked = true }
        try Edits.renameBox(&m, diagramId: ctx, boxId: top.id, to: "Assemble Widget")
        #expect(m.diagrams[child]?.title == "Kept", "a title the modeller set is not overwritten")
    }

    @Test("Labelling an arrow into a bottom side makes a mechanism concept")
    func labelBindsKind() throws {
        var (m, _, child) = try decomposedModel()
        let b = try #require(m.diagrams[child]?.boxes[1])
        let id = try Edits.drawArrow(&m, diagramId: child, from: .boundary(.bottom, 0.4), to: .box(b.id, .bottom, 0.5))
        try Edits.labelArrow(&m, diagramId: child, arrowId: id, to: "Machinist")
        let a = try #require(m.diagrams[child]?.arrows.last)
        #expect(m.conceptById(a.conceptId)?.kind == "mechanism")
    }

    @Test("The A-0 diagram keeps its single box (F08): adding one is refused once it has one, and allowed on an empty root")
    func addBoxRules() throws {
        var (m, ctx, _) = try decomposedModel()
        #expect(throws: Edits.Refusal.contextKeepsItsBox) {
            try Edits.addBox(&m, diagramId: ctx)
        }
        m.updateDiagram(ctx) { $0.boxes = [] }
        // A malformed or imported file with zero boxes on A-0 stays repairable.
        let box = try Edits.addBox(&m, diagramId: ctx)
        #expect(m.diagrams[ctx]?.boxes.map(\.id) == [box.id])
    }

    @Test("A-0 bars a tunnel only at an unconnected end (F08): the box end may still be tunnelled")
    func ctxTunnelRules() throws {
        var (m, ctx, _) = try decomposedModel()
        let arrow = try #require(m.diagrams[ctx]?.arrows.first { $0.from.isBox || $0.to.isBox })
        let boxEnd: ArrowEnd = arrow.from.isBox ? .from : .to
        let boundaryEnd: ArrowEnd = boxEnd == .from ? .to : .from
        try Edits.setTunnel(&m, diagramId: ctx, arrowId: arrow.id, end: boxEnd, on: true)
        #expect(m.diagrams[ctx]?.arrows.first { $0.id == arrow.id }?.isTunnelled(boxEnd) == true)
        #expect(throws: Edits.Refusal.contextHasNoTunnels) {
            try Edits.setTunnel(&m, diagramId: ctx, arrowId: arrow.id, end: boundaryEnd, on: true)
        }
    }

    @Test("The A-0 box cannot be deleted; a decomposition box takes its arrows with it")
    func deleteRules() throws {
        var (m, ctx, child) = try decomposedModel()
        let top = try #require(m.contextDiagram?.boxes.first)
        #expect(throws: Edits.Refusal.contextKeepsItsBox) {
            try Edits.delete(&m, diagramId: ctx, selection: .box(top.id))
        }
        let victim = try #require(m.diagrams[child]?.boxes[0])
        let touching = m.diagrams[child]!.arrowsTouching(victim.id).count
        #expect(touching > 0)
        let before = m.diagrams[child]!.arrows.count
        try Edits.delete(&m, diagramId: child, selection: .box(victim.id))
        #expect(m.diagrams[child]!.boxes.count == 2)
        #expect(m.diagrams[child]!.arrows.count == before - touching)
        #expect(m.diagrams[child]!.boxes.map(\.number) == [1, 2], "remaining boxes renumber")
    }

    @Test("An arrow cannot be drawn from or to a box the diagram no longer has")
    func drawArrowRefusesMissingBox() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let (gone, kept) = (d.boxes[0], d.boxes[2])
        try Edits.delete(&m, diagramId: child, selection: .box(gone.id))
        let before = m.diagrams[child]!.arrows.count
        #expect(throws: Edits.Refusal.noSuchObject) {
            try Edits.drawArrow(&m, diagramId: child, from: .box(gone.id, .right, 0.5), to: .box(kept.id, .left, 0.5))
        }
        #expect(throws: Edits.Refusal.noSuchObject) {
            try Edits.drawArrow(&m, diagramId: child, from: .boundary(.left, 0.5), to: .box(gone.id, .left, 0.5))
        }
        #expect(m.diagrams[child]!.arrows.count == before, "nothing dangling was written")
        // Boundary ends need no box.
        _ = try Edits.drawArrow(&m, diagramId: child, from: .boundary(.left, 0.5), to: .box(kept.id, .left, 0.5))
        #expect(m.diagrams[child]!.arrows.count == before + 1)
    }

    @Test("Moving an arrow end discards its pinned bend")
    func endpointClearsBend() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let id = try Edits.drawArrow(&m, diagramId: child, from: .box(d.boxes[0].id, .right, 0.5), to: .box(d.boxes[2].id, .left, 0.5))
        Edits.setBend(&m, diagramId: child, arrowId: id, axis: .x, pointer: Point(x: 612, y: 0))
        #expect(m.diagrams[child]?.arrows.last?.bend == 610)
        Edits.moveEndpoint(&m, diagramId: child, arrowId: id, end: .to, to: .box(d.boxes[1].id, .left, 0.3))
        #expect(m.diagrams[child]?.arrows.last?.bend == nil)
    }

    // MARK: S01 — structured editing

    @Test("connectPort draws an I port's arrow from the edge into the box, bound to the port's concept and labelled with its term")
    func connectInputPort() throws {
        var (m, _, child) = try portedModel()
        let d = try #require(m.diagrams[child])
        let input = try #require(m.ports(d).first { $0.code == "I1" })
        let concept = try #require(m.conceptById(input.conceptId))
        #expect(concept.term == "Raw Stock")
        let box = d.boxes[1]
        let id = try Edits.connectPort(&m, diagramId: child, port: input, boxId: box.id, side: .left, pos: 0.4)
        let a = try #require(m.diagrams[child]?.arrows.first { $0.id == id })
        #expect(a.from == .boundary(.left, input.pos), "an input enters from the sheet edge where the port stood")
        #expect(a.to == .box(box.id, .left, 0.4))
        #expect(a.label == "Raw Stock")
        #expect(a.conceptId == input.conceptId)
        #expect(a.role == .input)
        // The port is satisfied: only C1 and O1 remain, and I1 is paired.
        let after = try #require(m.diagrams[child])
        #expect(m.ports(after).map(\.code) == ["C1", "O1"])
        #expect(m.icomCodes(after)["\(id):from"] == "I1")
    }

    @Test("connectPort draws an O port's arrow out of the box to the edge: the box side is the source, the port the destination")
    func connectOutputPort() throws {
        var (m, _, child) = try portedModel()
        let d = try #require(m.diagrams[child])
        let output = try #require(m.ports(d).first { $0.code == "O1" })
        let box = d.boxes[2]
        let id = try Edits.connectPort(&m, diagramId: child, port: output, boxId: box.id, side: .right, pos: 0.6)
        let a = try #require(m.diagrams[child]?.arrows.first { $0.id == id })
        #expect(a.from == .box(box.id, .right, 0.6))
        #expect(a.to == .boundary(.right, output.pos))
        #expect(a.label == "Widget" && a.conceptId == output.conceptId)
        #expect(a.role == .output)
        let after = try #require(m.diagrams[child])
        #expect(m.ports(after).map(\.code) == ["I1", "C1"])
        #expect(m.icomCodes(after)["\(id):to"] == "O1")
    }

    @Test("connectPort refuses a box the diagram no longer has, as drawArrow does")
    func connectPortRefusesMissingBox() throws {
        var (m, _, child) = try portedModel()
        let d = try #require(m.diagrams[child])
        let control = try #require(m.ports(d).first { $0.code == "C1" })
        let gone = d.boxes[0]
        try Edits.delete(&m, diagramId: child, selection: .box(gone.id))
        let before = m.diagrams[child]!.arrows.count
        #expect(throws: Edits.Refusal.noSuchObject) {
            try Edits.connectPort(&m, diagramId: child, port: control, boxId: gone.id, side: .top, pos: 0.5)
        }
        #expect(m.diagrams[child]!.arrows.count == before)
        #expect(throws: Edits.Refusal.noSuchDiagram) {
            try Edits.connectPort(&m, diagramId: "no-such-diagram", port: control, boxId: gone.id, side: .top, pos: 0.5)
        }
    }

    @Test("moveBox swaps a box with its neighbour in the order and lays the staircase out again; the ends and A-0 are refused")
    func moveBoxThroughEdits() throws {
        var (m, ctx, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let (first, second, third) = (d.boxes[0], d.boxes[1], d.boxes[2])
        #expect(!Edits.canMoveBox(m, diagramId: child, boxId: first.id, by: -1))
        #expect(Edits.canMoveBox(m, diagramId: child, boxId: first.id, by: 1))
        #expect(throws: Edits.Refusal.noNeighbourThatWay) {
            try Edits.moveBox(&m, diagramId: child, boxId: first.id, by: -1)
        }
        #expect(m.diagrams[child] == d, "a refused move changes nothing")

        try Edits.moveBox(&m, diagramId: child, boxId: first.id, by: 1)
        let moved = try #require(m.diagrams[child])
        #expect(moved.findBox(first.id)?.number == 2 && moved.findBox(second.id)?.number == 1)
        #expect(moved.findBox(third.id)?.number == 3, "the box not swapped keeps its number")
        // The staircase follows the new order: box 1's place is now the second box's.
        let rects = staircaseLayout(3)
        #expect(moved.findBox(second.id)?.rect == rects[0])
        #expect(moved.findBox(first.id)?.rect == rects[1])
        #expect(boxNode(moved, moved.findBox(first.id)!) == "A2", "node numbers follow")
        #expect(!Edits.canMoveBox(m, diagramId: child, boxId: third.id, by: 1))

        let top = try #require(m.contextDiagram?.boxes.first)
        #expect(throws: Edits.Refusal.contextIsNotArranged) {
            try Edits.moveBox(&m, diagramId: ctx, boxId: top.id, by: 1)
        }
        #expect(!Edits.canMoveBox(m, diagramId: ctx, boxId: top.id, by: 1))
        #expect(throws: Edits.Refusal.noSuchObject) {
            try Edits.moveBox(&m, diagramId: child, boxId: "no-such-box", by: 1)
        }
    }

    @Test("arrange lays a child diagram out along the staircase in number order and is refused on A-0")
    func arrangeThroughEdits() throws {
        var (m, ctx, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        // Knock the boxes off the staircase, as an older file can hold them.
        Edits.setBoxGeometry(&m, diagramId: child, boxId: d.boxes[1].id, x: 100, y: 100, w: 300, h: 40)
        try Edits.arrange(&m, diagramId: child)
        let arranged = try #require(m.diagrams[child])
        let rects = staircaseLayout(3)
        for (i, b) in arranged.sortedBoxes.enumerated() { #expect(b.rect == rects[i]) }
        #expect(arranged.arrows == d.arrows, "arrows are untouched")

        let ctxBefore = m.diagrams[ctx]
        #expect(throws: Edits.Refusal.contextIsNotArranged) {
            try Edits.arrange(&m, diagramId: ctx)
        }
        #expect(m.diagrams[ctx] == ctxBefore)
        #expect(throws: Edits.Refusal.noSuchDiagram) {
            try Edits.arrange(&m, diagramId: "no-such-diagram")
        }
    }

    @Test("combineConcepts makes a bundle of the members and uncombineConcept dissolves it; refusals come back as errors, changing nothing")
    func combineAndUncombineThroughEdits() throws {
        var (m, _, _) = try portedModel()
        let stock = try #require(m.findConcept("Raw Stock"))
        let spec = try #require(m.findConcept("Spec"))
        let widget = try #require(m.findConcept("Widget"))
        #expect(Edits.defaultBundleTerm(m, memberIds: [stock.id, spec.id]) == "Raw Stock & Spec")

        let bundle = try Edits.combineConcepts(&m, memberIds: [stock.id, spec.id], term: "  Inputs  ")
        #expect(bundle.term == "Inputs" && bundle.members == [stock.id, spec.id])
        #expect(bundle.kind == "data", "the members agree on their kind")
        #expect(m.bundleOf(stock.id)?.id == bundle.id)
        #expect(m.effectiveConceptId(spec.id) == bundle.id)
        #expect(m.conceptById(stock.id) != nil && m.conceptById(spec.id) != nil, "the members keep their own entries")

        // Refusals: a member already in a bundle, fewer than two, an unknown id, a blank term.
        let before = m
        #expect(throws: BundleError.alreadyMember(stock.id)) {
            try Edits.combineConcepts(&m, memberIds: [stock.id, widget.id], term: "Again")
        }
        #expect(throws: BundleError.tooFewMembers) {
            try Edits.combineConcepts(&m, memberIds: [widget.id, widget.id], term: "Alone")
        }
        #expect(throws: BundleError.unknownConcept("no-such-concept")) {
            try Edits.combineConcepts(&m, memberIds: [widget.id, "no-such-concept"], term: "Ghost")
        }
        #expect(throws: Edits.Refusal.blankTerm) {
            try Edits.combineConcepts(&m, memberIds: [widget.id, bundle.id], term: "   ")
        }
        #expect(m == before, "no refused combine touched the glossary")
        #expect(String(describing: BundleError.tooFewMembers) == "A bundle combines at least two concepts.", "the hint reads as a sentence")

        // Un-combining is lossless: the members are as they were.
        #expect(throws: BundleError.notABundle(widget.id)) {
            try Edits.uncombineConcept(&m, bundleId: widget.id)
        }
        try Edits.uncombineConcept(&m, bundleId: bundle.id)
        #expect(m.conceptById(bundle.id) == nil)
        #expect(m.bundleOf(stock.id) == nil && m.bundleOf(spec.id) == nil)
        #expect(m.effectiveConceptId(spec.id) == spec.id)
    }

    @Test("removeConcept goes through the core: a member leaves its bundle's list, and an unused bundle is un-combined")
    func removeConceptThroughCore() throws {
        var (m, _, _) = try portedModel()
        // Two fresh, unused concepts to bundle, so removal is not refused for use.
        Edits.addConcept(&m, term: "Gauge", kind: "mechanism", definition: "")
        Edits.addConcept(&m, term: "Jig", kind: "mechanism", definition: "")
        let gauge = try #require(m.findConcept("Gauge")), jig = try #require(m.findConcept("Jig"))
        let bundle = try Edits.combineConcepts(&m, memberIds: [gauge.id, jig.id], term: "Tooling")

        try Edits.removeConcept(&m, conceptId: gauge.id)
        #expect(m.conceptById(gauge.id) == nil)
        #expect(m.conceptById(bundle.id)?.members == [jig.id], "the member is dropped from the bundle's list")

        try Edits.removeConcept(&m, conceptId: bundle.id)
        #expect(m.conceptById(bundle.id) == nil)
        #expect(m.conceptById(jig.id) != nil, "removing a bundle un-combines it; the member stays")
        #expect(m.bundleOf(jig.id) == nil)

        #expect(throws: Edits.Refusal.noSuchConcept) {
            try Edits.removeConcept(&m, conceptId: bundle.id)
        }
        let used = try #require(m.findConcept("Spec"))
        #expect(throws: Edits.Refusal.conceptInUse) {
            try Edits.removeConcept(&m, conceptId: used.id)
        }
    }

    @Test("setBoxGeometry renumbers when x or y changes, never for a pure width/height edit (F10)")
    func setBoxGeometryRenumbers() throws {
        var (m, _, child) = try decomposedModel()
        let d = try #require(m.diagrams[child])
        let first = d.boxes[0]
        let last = d.boxes[2]
        Edits.setBoxGeometry(&m, diagramId: child, boxId: first.id, w: 5)
        #expect(m.diagrams[child]?.findBox(first.id)?.w == 5)
        #expect(m.diagrams[child]?.findBox(first.id)?.number == 1, "a pure width/height edit never renumbers")
        Edits.setBoxGeometry(&m, diagramId: child, boxId: first.id, x: last.x + 220, y: last.y + 130)
        #expect(m.diagrams[child]?.findBox(first.id)?.number == 3, "an X or Y edit renumbers in the same commit")
    }

    @Test("Escape from a child diagram selects the box it details")
    func parentTarget() throws {
        let (m, ctx, child) = try decomposedModel()
        let target = try #require(Edits.parentTarget(of: m, diagramId: child))
        #expect(target.diagramId == ctx)
        #expect(target.selection == .box(m.contextDiagram!.boxes[0].id))
        #expect(Edits.parentTarget(of: m, diagramId: ctx) == nil)
    }
}
