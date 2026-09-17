// The editor's behaviour where it follows the web app: navigation keeps the
// view, a drag stays on the canvas until it ends, handles show their cursors,
// forward Delete deletes, boundary rows sort by code, export names slugify
// the node, and a cyclic decomposition cannot hang the node tree.

import AppKit
import Combine
import Testing
@testable import IDEF0Core
@testable import IDEF0Editing
@testable import IDEF0Modeler

@MainActor
@Suite("Editor parity", .serialized)
struct EditorParityTests {
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    // MARK: Navigation and the view (F50, F43)

    @Test("Selecting on the diagram already shown keeps the zoom, panning an off-screen selection into view")
    func selectionKeepsZoomAndReveals() async {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let boxes = h.diagram.sortedBoxes
        let (near, far) = (boxes[0], boxes[boxes.count - 1])
        h.canvas.zoom(by: 3, around: h.canvas.viewPoint(Point(x: near.x, y: near.y)))
        await settle()
        let zoomed = h.canvas.scale
        func onScreen(_ b: Box) -> Bool {
            let r = h.canvas.bounds
            return r.contains(h.canvas.viewPoint(Point(x: b.x, y: b.y))) && r.contains(h.canvas.viewPoint(Point(x: b.x + b.w, y: b.y + b.h)))
        }
        #expect(!onScreen(far), "the test needs the last box scrolled off")

        // A check, a concept chip or a tree row selects the far box.
        h.state.open(h.state.diagramId, selecting: .box(far.id))
        #expect(h.state.canvasRequest?.request == .reveal)
        h.canvas.handle(h.state.canvasRequest)
        await settle()
        #expect(h.canvas.scale == zoomed, "the zoom is the modeller's, not reset")
        #expect(onScreen(far))

        // A selection already in view does not move the sheet.
        let shown = h.diagram.findBox(far.id)!
        let before = h.canvas.viewPoint(Point(x: shown.x, y: shown.y))
        h.state.selection = nil
        h.state.open(h.state.diagramId, selecting: .box(far.id))
        h.canvas.handle(h.state.canvasRequest)
        await settle()
        #expect(h.canvas.viewPoint(Point(x: shown.x, y: shown.y)) == before)
        #expect(h.canvas.scale == zoomed)

        // Another diagram is still framed whole.
        h.state.open(h.document.model.rootDiagramId)
        #expect(h.state.canvasRequest?.request == .fit)
        h.canvas.handle(h.state.canvasRequest)
        await settle()
        #expect(h.canvas.scale < zoomed)
    }

    @Test("Re-opening where the window already is clears a stale hint, and asks the canvas for nothing")
    func reopenClearsHint() {
        let m = decomposedSample()
        let s = EditorState(diagramId: m.rootDiagramId)
        let box = m.contextDiagram!.boxes[0]
        s.open(m.rootDiagramId, selecting: .box(box.id))
        let serial = s.canvasRequest?.serial
        s.hint = Edits.Refusal.noSuchObject.description
        s.open(m.rootDiagramId, selecting: .box(box.id))
        #expect(s.hint == "")
        #expect(s.canvasRequest?.serial == serial)
    }

    // MARK: Drags (F51)
    //
    // S01: boxes are no longer dragged, so the drag-draft mechanism is
    // exercised through the one kind of drag that remains — an arrow's —
    // here its bend handle. "Components" (Fabricate → Assemble, right side
    // to left side, on different staircase rows) has a bend to grab.

    private func bendable(_ h: CanvasHarness) throws -> (Arrow, Point) {
        let d = h.diagram
        let a = try #require(d.arrows.first { $0.label == "Components" })
        let handle = try #require(HitTest.bendHandle(h.document.model, in: d, a))
        #expect(handle.axis == .x)
        h.state.selection = .arrow(a.id)
        return (a, handle.point)
    }

    @Test("A drag edits only the canvas's draft; the document changes once, when the mouse comes up")
    func dragIsLightUntilItEnds() throws {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let (a, handle) = try bendable(h)
        let before = h.document.model
        var published = 0
        let watch = h.document.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }

        let start = handle, end = Point(x: start.x + 43, y: start.y)
        h.press(start)
        h.moveHeld(from: start, to: end)
        #expect(published == 0, "no observer of the document re-evaluates while the mouse moves")
        #expect(h.document.model == before)
        let draft = h.canvas.draftModel?.diagrams[h.state.diagramId]?.arrows.first { $0.id == a.id }
        #expect(draft?.bend == CanvasRules.snap(end.x), "the canvas draws the drag as it goes")
        #expect(!h.undoManager.canUndo)

        h.release(end)
        #expect(published > 0)
        #expect(h.canvas.draftModel == nil)
        #expect(h.diagram.arrows.first { $0.id == a.id }?.bend == CanvasRules.snap(end.x))
        #expect(h.undoManager.undoActionName == "Bend Arrow")
        h.undoManager.undo()
        #expect(h.document.model == before, "one undo takes the whole drag back")
        #expect(!h.undoManager.canUndo)
    }

    @Test("An undo that arrives during a drag is not written over when the mouse comes up")
    func undoDuringDragWins() throws {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let (_, handle) = try bendable(h)
        let original = h.document.model
        h.document.apply("Rename Box", undoManager: h.undoManager) { m in
            m.updateDiagram(h.state.diagramId) { d in d.boxes[2].name = "Renamed" }
        }
        let start = handle, end = Point(x: start.x + 60, y: start.y)
        h.press(start)
        h.moveHeld(from: start, to: end)
        h.undoManager.undo()
        h.release(end)
        #expect(h.document.model == original, "neither the rename nor a bend computed from it came back")
        #expect(h.undoManager.canRedo, "no edit was recorded over the undo")
        #expect(h.canvas.draftModel == nil)
    }

    @Test("A drag that ends where it began records nothing, and a pan never makes a draft")
    func noOpDragAndPan() throws {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let (a, handle) = try bendable(h)
        // A first drag pins the bend on the snap grid, which is itself a change.
        h.drag(from: handle, to: Point(x: handle.x + 30, y: handle.y))
        h.undoManager.removeAllActions()
        let pinned = try #require(h.diagram.arrows.first { $0.id == a.id })
        #expect(pinned.bend != nil)
        let grab = try #require(HitTest.bendHandle(h.document.model, in: h.diagram, pinned)).point
        h.drag(from: grab, to: grab)
        #expect(!h.undoManager.canUndo)
        #expect(h.diagram.arrows.first { $0.id == a.id } == pinned)
        let empty = Point(x: Sheet.work.x + 30, y: Sheet.work.y2 - 30)
        h.press(empty)
        h.moveHeld(from: empty, to: Point(x: empty.x + 50, y: empty.y))
        #expect(h.canvas.draftModel == nil)
        h.release(Point(x: empty.x + 50, y: empty.y))
        #expect(!h.undoManager.canUndo)
    }

    // MARK: Cursors and keys (F52, F56)

    @Test("Handles, arrows and anchors show the cursors the web app's stylesheet gives them")
    func cursorsOverHandles() throws {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let d = h.diagram
        let b = d.boxes[1]
        #expect(h.canvas.cursorKind(at: Point(x: b.x + b.w, y: b.y + b.h)) == .arrow, "no handles before a selection")
        h.click(Point(x: b.x + b.w / 2, y: b.y + 10))
        // S01: a selected box has no handles either — it is neither resized nor moved.
        #expect(h.canvas.cursorKind(at: Point(x: b.x + b.w, y: b.y + b.h)) == .arrow)
        #expect(h.canvas.cursorKind(at: Point(x: b.x, y: b.y)) == .arrow)
        #expect(h.canvas.cursorKind(at: Point(x: b.x + b.w / 2, y: b.y + b.h / 2)) == .arrow)
        #expect(h.canvas.cursorKind(at: Point(x: Sheet.work.x + 30, y: Sheet.work.y2 - 30)) == .arrow)

        // An arrow, away from every box: the pointer the web app's .arr-hit has.
        let candidates = d.arrows.compactMap { a -> (Arrow, Point)? in
            let mid = longestSegmentMid(HitTest.route(h.document.model, in: d, a))
            let p = Point(x: mid.x, y: mid.y)
            guard HitTest.box(in: d, at: p) == nil, HitTest.arrow(in: d, at: p)?.id == a.id else { return nil }
            return (a, p)
        }
        let (arrow, mid) = try #require(candidates.first)
        #expect(h.canvas.cursorKind(at: mid) == .pointingHand)

        // A selected arrow's ends and bend handle.
        h.state.selection = .arrow(arrow.id)
        let route = HitTest.route(h.document.model, in: d, arrow)
        #expect(h.canvas.cursorKind(at: route.first!) == .crosshair)
        #expect(h.canvas.cursorKind(at: route.last!) == .crosshair)
        if let bend = d.arrows.lazy.compactMap({ a in HitTest.bendHandle(h.document.model, in: d, a).map { (a, $0) } }).first {
            h.state.selection = .arrow(bend.0.id)
            #expect(h.canvas.cursorKind(at: bend.1.point) == .bend(bend.1.axis))
        }

        // The arrow tool: a crosshair where a click would anchor.
        h.state.tool = .arrow
        #expect(h.canvas.cursorKind(at: Point(x: b.x, y: b.y + b.h / 2)) == .crosshair)
        h.state.tool = .select

        // Space-to-pan's hand wins over all of them.
        h.window.makeFirstResponder(h.canvas)
        h.key(" ", keyCode: 49)
        #expect(h.canvas.cursorKind(at: route.first!) == .openHand)
        h.key(" ", keyCode: 49, up: true)

        // Every kind has a cursor on this system.
        let kinds: [SheetCanvasView.CursorKind] = [.arrow, .pointingHand, .crosshair, .openHand, .closedHand, .bend(.x), .bend(.y)]
        for k in kinds { _ = k.cursor }
    }

    @Test("Forward Delete (fn-Delete) deletes the selection, as Delete does")
    func forwardDeleteDeletes() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[1]
        h.click(Point(x: b.x + b.w / 2, y: b.y + 10))
        let before = h.diagram.boxes.count
        h.key("\u{F728}", keyCode: 117, modifiers: [.function])
        #expect(h.diagram.boxes.count == before - 1)
        #expect(h.state.selection == nil)
        #expect(h.undoManager.undoActionName == "Delete Box")
    }

    // MARK: Inspector, exports, node tree (F56, F55, F68)

    @Test("Boundary rows sort by code with JavaScript collation, stably")
    func boundaryRowsSortLikeTheWeb() throws {
        var m = decomposedSample()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        // An extra boundary input the parent does not have: it gets no code.
        _ = try Edits.drawArrow(&m, diagramId: a0.id, from: .boundary(.left, 0.9), to: .box(a0.boxes[3].id, .left, 0.4))
        let d = try #require(m.diagrams[a0.id])
        let rows = DiagramInspector.boundaryRows(d, codes: m.icomCodes(d))
        // '—'.localeCompare('C1') < 0 in JavaScript, where Swift's `<` would put it last.
        #expect(rows.map(\.code) == ["—", "C1", "C2", "I1", "I2", "M1", "M2", "O1", "O2"])

        // On A-0 every end is uncoded, so the tie keeps arrow order.
        let ctx = try #require(m.contextDiagram)
        let ctxRows = DiagramInspector.boundaryRows(ctx, codes: m.icomCodes(ctx))
        #expect(ctxRows.map(\.arrow.id) == ctx.arrows.map(\.id))
        #expect(ctxRows.allSatisfy { $0.code == "—" })
    }

    @Test("Diagram export names slugify the node, as the web app's do")
    func exportNamesSlugifyNode() throws {
        let m = decomposedSample()
        let ctx = try #require(m.contextDiagram)
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        // Values from the web app's slugify: 'A-0' → 'a-0', 'A0' → 'a0'.
        #expect(Exporter.diagramFileName(m, ctx, ext: "svg") == "manufacture-product-a-0.svg")
        #expect(Exporter.diagramFileName(m, a0, ext: "png") == "manufacture-product-a0.png")
        var child = a0
        child.node = "A12"
        #expect(Exporter.diagramFileName(m, child, ext: "pdf") == "manufacture-product-a12.pdf")
    }

    @Test("A decomposition that loops back to its own diagram, or an ancestor, ends the node tree instead of recursing")
    func nodeTreeSurvivesCycles() throws {
        let m = decomposedSample()
        let rootId = m.rootDiagramId
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let wellFormed = NodeTreeView.rows(m)
        #expect(wellFormed.count == 1 + a0.boxes.count)

        // A0's first box names A0 itself as its detail.
        var selfLoop = m
        selfLoop.updateDiagram(a0.id) { $0.boxes[0].childDiagramId = a0.id }
        let selfRows = NodeTreeView.rows(selfLoop)
        #expect(selfRows.count == wellFormed.count, "every box is still listed once")
        #expect(selfRows.first { $0.boxId == a0.boxes[0].id }?.childId == a0.id)

        // …or the A-0 context diagram above it.
        var ancestorLoop = m
        ancestorLoop.updateDiagram(a0.id) { $0.boxes[1].childDiagramId = rootId }
        #expect(NodeTreeView.rows(ancestorLoop).count == wellFormed.count)

        // A diagram two boxes detail is not a cycle: it is listed under each, as before.
        var shared = m
        let child = try Edits.decompose(&shared, diagramId: a0.id, boxId: a0.boxes[0].id, count: 3)
        shared.updateDiagram(a0.id) { $0.boxes[1].childDiagramId = child }
        #expect(NodeTreeView.rows(shared).count == wellFormed.count + 2 * 3)
    }
}
