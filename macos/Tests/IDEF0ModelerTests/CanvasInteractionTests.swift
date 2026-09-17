// The real editing canvas, driven by synthesized mouse and keyboard events in
// an offscreen window. These test the part the editing kernel's own tests
// cannot: that AppKit events are mapped onto the right rules — coordinates
// converted, handles found, drags recorded as one undo step, text committed.

import AppKit
import Testing
@testable import IDEF0Core
@testable import IDEF0Editing
@testable import IDEF0Modeler

@MainActor
final class CanvasHarness {
    let window: NSWindow
    let canvas: SheetCanvasView
    let document: IDEF0Document
    let state: EditorState

    init(model: IDEF0Model, diagramNode: String? = nil) {
        _ = NSApplication.shared
        let doc = IDEF0Document(model: model)
        let diagramId = diagramNode.flatMap { n in doc.model.diagrams.first { $0.value.node == n }?.key } ?? doc.model.rootDiagramId
        document = doc
        state = EditorState(diagramId: diagramId)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 1000), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = SheetCanvasView(frame: window.contentLayoutRect)
        canvas.document = document
        canvas.state = state
        window.contentView = canvas
        canvas.fitToWindow()
    }

    var diagram: Diagram { document.model.diagrams[state.diagramId]! }
    var undoManager: UndoManager { window.undoManager! }

    private func event(_ type: NSEvent.EventType, at p: Point, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let inWindow = canvas.convert(canvas.viewPoint(p), to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: modifiers, timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: clicks, pressure: 1)!
    }

    func click(_ p: Point, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        canvas.mouseDown(with: event(.leftMouseDown, at: p, clicks: clicks, modifiers: modifiers))
        canvas.mouseUp(with: event(.leftMouseUp, at: p, clicks: clicks, modifiers: modifiers))
    }

    /// Press at `from`, move through intermediate points to `to`, release.
    func drag(from: Point, to: Point, steps: Int = 6) {
        press(from)
        moveHeld(from: from, to: to, steps: steps)
        release(to)
    }

    /// The parts of a drag, for a test that looks in between them.
    func press(_ p: Point) { canvas.mouseDown(with: event(.leftMouseDown, at: p)) }

    func moveHeld(from: Point, to: Point, steps: Int = 6) {
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            canvas.mouseDragged(with: event(.leftMouseDragged, at: Point(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
        }
    }

    func release(_ p: Point) { canvas.mouseUp(with: event(.leftMouseUp, at: p)) }

    func key(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [], up: Bool = false) {
        let e = NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        if up { canvas.keyUp(with: e) } else { canvas.keyDown(with: e) }
    }

    /// Type into the floating field and press Return.
    func type(_ text: String) {
        guard let field = canvas.textField else { return }
        field.stringValue = text
        canvas.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field,
                                                    userInfo: ["NSTextMovement": NSTextMovement.return.rawValue]))
    }
}

func decomposedSample() -> IDEF0Model {
    var m = buildSampleModel()
    m.bindAll()
    return m
}

@MainActor
@Suite("Canvas interaction", .serialized)
struct CanvasInteractionTests {
    @Test("Clicking a box selects it; clicking empty sheet clears the selection")
    func clickSelects() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[1]
        h.click(Point(x: b.x + b.w / 2, y: b.y + 10))
        #expect(h.state.selection == .box(b.id))
        h.click(Point(x: Sheet.work.x + 30, y: Sheet.work.y2 - 30))
        #expect(h.state.selection == nil)
    }

    @Test("Dragging a box does not move it (S01): the press selects, the drag makes no draft and records no edit")
    func dragDoesNotMoveBox() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[1]
        let start = Point(x: b.x + 20, y: b.y + 20)
        h.press(start)
        #expect(h.state.selection == .box(b.id))
        h.moveHeld(from: start, to: Point(x: start.x + 43, y: start.y + 17))
        #expect(h.canvas.draftModel == nil, "no drag draft: there is nothing a box drag edits")
        h.release(Point(x: start.x + 43, y: start.y + 17))
        #expect(h.diagram.findBox(b.id)!.rect == b.rect)
        #expect(!h.undoManager.canUndo)
        #expect(h.state.selection == .box(b.id))
    }

    @Test("A click that does not move records no edit")
    func clickIsNotAnEdit() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[0]
        h.click(Point(x: b.x + 30, y: b.y + 30))
        #expect(!h.undoManager.canUndo)
    }

    @Test("The arrow tool draws from a box side to another, then asks for a label that binds a concept")
    func drawArrowAndLabel() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let (b1, b3) = (h.diagram.boxes[0], h.diagram.boxes[2])
        let before = h.diagram.arrows.count
        h.key("a")
        #expect(h.state.tool == .arrow)
        h.click(Point(x: b1.x + b1.w, y: b1.y + b1.h * 0.2))
        #expect(h.state.pendingFrom?.boxId == b1.id)
        h.click(Point(x: b3.x, y: b3.y + b3.h * 0.8))
        #expect(h.diagram.arrows.count == before + 1)
        let created = h.diagram.arrows.last!
        #expect(created.from.side == .right && created.to.side == .left)
        #expect(h.state.selection == .arrow(created.id))
        #expect(h.canvas.textField != nil, "label editing opens straight away")
        h.type("Inspection Report")
        let labelled = h.diagram.arrows.last!
        #expect(labelled.label == "Inspection Report")
        #expect(h.document.model.conceptById(labelled.conceptId)?.term == "Inspection Report")
    }

    @Test("Double-clicking a box renames it through the floating field")
    func doubleClickRenames() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[3]
        h.click(Point(x: b.x + b.w / 2, y: b.y + b.h / 2), clicks: 2)
        #expect(h.state.editing == .boxName(b.id))
        h.type("  Dispatch Product ")
        #expect(h.diagram.findBox(b.id)?.name == "Dispatch Product")
        #expect(h.undoManager.undoActionName == "Rename Box")
    }

    @Test("Cancelling the floating field changes nothing")
    func cancelEdit() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[0]
        h.click(Point(x: b.x + b.w / 2, y: b.y + b.h / 2), clicks: 2)
        let field = h.canvas.textField!
        field.stringValue = "Scrapped"
        h.canvas.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field,
                                                      userInfo: ["NSTextMovement": NSTextMovement.cancel.rawValue]))
        #expect(h.diagram.findBox(b.id)?.name == b.name)
        #expect(!h.undoManager.canUndo)
    }

    @Test("Deleting the A-0 box is refused with a hint")
    func contextBoxDeleteRefused() {
        let h = CanvasHarness(model: decomposedSample())
        let top = h.diagram.boxes[0]
        h.click(Point(x: top.x + 20, y: top.y + 20))
        h.key("\u{7F}", keyCode: 51)
        #expect(h.diagram.boxes.count == 1)
        #expect(h.state.hint.contains("single box"))
    }

    @Test("Escape clears the selection, then goes up to the parent selecting the detailed box")
    func escapeGoesUp() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[0]
        h.click(Point(x: b.x + 20, y: b.y + 20))
        h.key("\u{1B}", keyCode: 53)
        #expect(h.state.selection == nil)
        h.key("\u{1B}", keyCode: 53)
        #expect(h.state.diagramId == h.document.model.rootDiagramId)
        #expect(h.state.selection == .box(h.document.model.contextDiagram!.boxes[0].id))
    }

    @Test("A selected box has no resize handles (S01): a drag from its corner changes nothing")
    func noResizeByCorner() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[0]
        h.click(Point(x: b.x + 20, y: b.y + 20))
        #expect(h.canvas.cursorKind(at: Point(x: b.x + b.w, y: b.y + b.h)) == .arrow, "no handle, no resize cursor")
        h.drag(from: Point(x: b.x + b.w, y: b.y + b.h), to: Point(x: b.x + b.w + 40, y: b.y + b.h + 30))
        #expect(h.diagram.findBox(b.id)!.rect == b.rect)
        #expect(!h.undoManager.canUndo)
    }

    /// The sample with "Fabricate Components" decomposed into three: its
    /// child starts with no arrows and five ports — Raw Materials (I1),
    /// Quality Standards (C1), Work Order (C2), Plant Equipment (M1) and
    /// Components (O1).
    private func portedHarness() -> (CanvasHarness, [ICOMPort]) {
        var m = decomposedSample()
        let a0 = m.diagrams.values.first { $0.node == "A0" }!
        let fab = a0.boxes.first { $0.name == "Fabricate Components" }!
        let child = try! Edits.decompose(&m, diagramId: a0.id, boxId: fab.id, count: 3)
        let node = m.diagrams[child]!.node
        let h = CanvasHarness(model: m, diagramNode: node)
        return (h, h.document.model.ports(h.diagram))
    }

    @Test("Dragging a port onto a box side draws its arrow, bound to the port's concept, as one 'Connect Port' undo step (S01)")
    func portDragConnects() throws {
        let (h, ports) = portedHarness()
        #expect(h.diagram.arrows.isEmpty && ports.count == 5)
        let raw = try #require(ports.first { $0.label == "Raw Materials" })
        #expect(raw.role == .input && raw.side == .left)
        let box = h.diagram.boxes[0]
        let inner = portShape(raw).inner
        #expect(h.canvas.cursorKind(at: inner) == .crosshair, "a port shows the crosshair an arrow is drawn with")

        h.drag(from: inner, to: Point(x: box.x - 4, y: box.y + box.h * 0.5))
        let created = try #require(h.diagram.arrows.last)
        #expect(h.diagram.arrows.count == 1)
        #expect(created.from == .boundary(.left, raw.pos))
        #expect(created.to.boxId == box.id && created.to.side == .left)
        #expect(created.label == "Raw Materials")
        #expect(created.conceptId == raw.conceptId)
        #expect(h.document.model.conceptById(created.conceptId)?.term == "Raw Materials")
        #expect(h.state.selection == .arrow(created.id), "the new arrow is selected; the port never is")
        #expect(h.state.hint == "Connected I1 “Raw Materials” to box 1.", "the web canvas's hint, word for word")
        #expect(h.canvas.textField == nil, "no label editor follows a connect: the arrow carries the parent's label")
        #expect(h.undoManager.undoActionName == "Connect Port")
        #expect(h.document.model.ports(h.diagram).count == 4, "the port is satisfied")

        h.undoManager.undo()
        #expect(h.diagram.arrows.isEmpty)
        #expect(!h.undoManager.canUndo, "one step")
        #expect(h.document.model.ports(h.diagram).count == 5)
    }

    @Test("Dragging an output port onto a box draws the arrow out of the box: the box side is the source (S01)")
    func outputPortDragConnects() throws {
        let (h, ports) = portedHarness()
        let out = try #require(ports.first { $0.label == "Components" })
        #expect(out.role == .output && out.side == .right)
        let box = h.diagram.boxes[2]
        h.drag(from: portShape(out).inner, to: Point(x: box.x + box.w + 4, y: box.y + box.h * 0.5))
        let created = try #require(h.diagram.arrows.last)
        #expect(created.from.boxId == box.id && created.from.side == .right)
        #expect(created.to == .boundary(.right, out.pos))
        #expect(created.label == "Components" && created.conceptId == out.conceptId)
    }

    @Test("A port released anywhere but a box side connects nothing, says so, and selects nothing (S01)")
    func portDragCancels() throws {
        let (h, ports) = portedHarness()
        let spec = try #require(ports.first { $0.label == "Quality Standards" })
        h.state.selection = .box(h.diagram.boxes[1].id)
        // Released on empty sheet, well away from every box.
        h.drag(from: portShape(spec).inner, to: Point(x: Sheet.work.x + 60, y: Sheet.work.y2 - 40))
        #expect(h.diagram.arrows.isEmpty)
        #expect(!h.undoManager.canUndo)
        #expect(h.state.hint == "Drop the port on a box side to connect it.", "the web canvas's cancel hint, word for word")
        #expect(h.state.selection == .box(h.diagram.boxes[1].id), "a port press changes no selection")
        #expect(h.canvas.draftModel == nil)

        // A plain click on a port is not a connection either.
        h.click(portShape(spec).inner)
        #expect(h.diagram.arrows.isEmpty && !h.undoManager.canUndo)

        // Under the arrow tool a port still starts a connection, not a boundary arrow.
        h.key("a")
        h.drag(from: portShape(spec).inner, to: Point(x: Sheet.work.x + 60, y: Sheet.work.y2 - 40))
        #expect(h.diagram.arrows.isEmpty && h.state.pendingFrom == nil)
        let box = h.diagram.boxes[0]
        h.drag(from: portShape(spec).inner, to: Point(x: box.x + box.w * 0.5, y: box.y - 4))
        #expect(h.diagram.arrows.count == 1)
        #expect(h.diagram.arrows[0].to.side == .top && h.diagram.arrows[0].label == "Quality Standards")
    }

    @Test("A port drag whose diagram changed underneath it connects nothing (S01)")
    func portDragDroppedOnChange() throws {
        let (h, ports) = portedHarness()
        let raw = try #require(ports.first { $0.label == "Raw Materials" })
        let box = h.diagram.boxes[0]
        let inner = portShape(raw).inner, target = Point(x: box.x - 4, y: box.y + box.h * 0.5)
        h.press(inner)
        h.moveHeld(from: inner, to: target)
        // An edit lands while the button is down — a rename from the inspector, say.
        h.document.apply("Rename Box", undoManager: h.undoManager) { m in
            m.updateDiagram(h.state.diagramId) { d in d.boxes[0].name = "Cut Stock" }
        }
        h.release(target)
        #expect(h.diagram.arrows.isEmpty)
        #expect(h.undoManager.undoActionName == "Rename Box", "only the rename was recorded")
        #expect(h.state.hint.contains("changed during the drag"))
    }

    @Test("Move Earlier / Move Later and Arrange reach the canvas as requests, each one undo step (S01)")
    func moveAndArrangeRequests() async {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let boxes = h.diagram.sortedBoxes
        let (first, second) = (boxes[0], boxes[1])
        h.state.selection = .box(second.id)
        h.state.request(.moveSelection(by: -1))
        h.canvas.handle(h.state.canvasRequest)
        for _ in 0..<5 { await Task.yield() }
        #expect(h.diagram.findBox(second.id)?.number == 1 && h.diagram.findBox(first.id)?.number == 2)
        #expect(h.diagram.findBox(second.id)?.rect == staircaseLayout(4)[0])
        #expect(h.undoManager.undoActionName == "Move Activity")
        #expect(h.state.selection == .box(second.id), "the box keeps its selection, not its place")

        // Already first: refused with a hint, nothing recorded.
        h.undoManager.removeAllActions()
        h.state.request(.moveSelection(by: -1))
        h.canvas.handle(h.state.canvasRequest)
        for _ in 0..<5 { await Task.yield() }
        #expect(!h.undoManager.canUndo)
        #expect(h.state.hint == Edits.Refusal.noNeighbourThatWay.description)

        // Arrange puts a displaced box back on the staircase.
        h.document.apply("Displace", undoManager: h.undoManager) { m in
            Edits.setBoxGeometry(&m, diagramId: h.state.diagramId, boxId: first.id, w: 300, h: 40)
        }
        h.state.request(.arrange)
        h.canvas.handle(h.state.canvasRequest)
        for _ in 0..<5 { await Task.yield() }
        #expect(h.diagram.findBox(first.id)?.rect == staircaseLayout(4)[1])
        #expect(h.undoManager.undoActionName == "Arrange")

        // Never on A-0.
        h.state.open(h.document.model.rootDiagramId)
        h.undoManager.removeAllActions()
        h.state.request(.arrange)
        h.canvas.handle(h.state.canvasRequest)
        for _ in 0..<5 { await Task.yield() }
        #expect(!h.undoManager.canUndo)
        #expect(h.state.hint == Edits.Refusal.contextIsNotArranged.description)
    }

    @Test("A hidden bundle member has no route to press; a press on the representative's drawn line selects it, and the field on it edits the bundle's term as one 'Rename Concept' step, a lone branch its own label (S01)")
    func hiddenMemberPressAndBundleRename() throws {
        var m = decomposedSample()
        let members = ["Customer Order", "Raw Materials"].compactMap { m.findConcept($0)?.id }
        _ = try m.combineConcepts(members, term: "Inputs")
        let h = CanvasHarness(model: m)   // A-0: the pair is one drawn line
        let d = h.diagram
        let co = try #require(d.arrows.first { $0.label == "Customer Order" })
        let rm = try #require(d.arrows.first { $0.label == "Raw Materials" })
        // The hidden member's own route is not drawn (S02): nothing to press.
        let ghostMid = longestSegmentMid(routeArrow(d, rm))
        let ghost = Point(x: ghostMid.x, y: ghostMid.y)
        #expect(distToPolyline(HitTest.route(m, in: d, co), ghost) > CanvasRules.arrowGrab, "the ghost is on the hidden route only")
        #expect(h.canvas.cursorKind(at: ghost) == .arrow, "no ink there, nothing to press")
        let probeMid = longestSegmentMid(HitTest.route(m, in: d, co))
        let probe = Point(x: probeMid.x, y: probeMid.y)
        #expect(h.canvas.cursorKind(at: probe) == .pointingHand)
        h.click(probe)
        #expect(h.state.selection == .arrow(co.id), "the representative, the one arrow drawn there")
        #expect(!h.undoManager.canUndo)

        // Double-click the representative: the field opens on the bundle's
        // term, and Return renames the bundle, not the arrow.
        h.click(probe, clicks: 2)
        #expect(h.state.editing == .arrowLabel(co.id))
        #expect(h.canvas.textField?.stringValue == "Inputs", "the drawn text, not the arrow's own label")
        h.type("  Order Inputs ")
        #expect(h.undoManager.undoActionName == "Rename Concept")
        #expect(h.document.model.findConcept("Inputs") == nil)
        #expect(h.document.model.findConcept("Order Inputs")?.members == members, "the bundle, renamed")
        #expect(h.diagram.arrows.first { $0.id == co.id }?.label == "Customer Order", "the members' own labels are untouched")
        #expect(h.diagram.arrows.first { $0.id == rm.id }?.label == "Raw Materials")

        // A blank term is refused, as it is everywhere a bundle is named.
        h.click(probe, clicks: 2)
        h.type("   ")
        #expect(h.state.hint == Edits.Refusal.blankTerm.description)
        #expect(h.document.model.findConcept("Order Inputs") != nil)
        #expect(h.undoManager.undoActionName == "Rename Concept", "nothing else was recorded")

        // On A0 each branch is alone on its faces (forked off one boundary
        // line, S02): the field edits the arrow's own label.
        let a0Id = try #require(h.document.model.diagrams.first { $0.value.node == "A0" }?.key)
        h.state.open(a0Id)
        let a0 = h.diagram
        let coA0 = try #require(a0.arrows.first { $0.label == "Customer Order" })
        let a0Mid = longestSegmentMid(HitTest.route(h.document.model, in: a0, coA0))
        h.click(Point(x: a0Mid.x, y: a0Mid.y), clicks: 2)
        #expect(h.state.editing == .arrowLabel(coA0.id))
        #expect(h.canvas.textField?.stringValue == "Customer Order")
        h.type("Customer Orders")
        #expect(h.undoManager.undoActionName == "Label Arrow")
        #expect(h.diagram.arrows.first { $0.id == coA0.id }?.label == "Customer Orders")
        #expect(h.document.model.findConcept("Order Inputs")?.members == members, "the bundle is not what changed")
    }

    @Test("Dragging a fork's end handle along its face moves every branch's pos together as one 'Move Arrow End' step; onto another side it takes only that arrow (S02)")
    func groupedEndpointDrag() throws {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let d = h.diagram
        let wos = d.arrows.filter { $0.label == "Work Order" }
        let plan = try #require(d.boxes.first { $0.name == "Plan Production" })
        h.state.selection = .arrow(wos[1].id)
        // The handle sits at the trunk — the representative's pos — not the branch's own.
        let start = try #require(HitTest.route(h.document.model, in: d, wos[1]).first)
        #expect(abs(start.y - anchorOf(d, wos[0].from).y) < 1e-9)
        #expect(h.canvas.cursorKind(at: start) == .crosshair)
        h.drag(from: start, to: Point(x: plan.x + plan.w + 3, y: plan.y + plan.h * 0.2))
        var after = h.diagram.arrows.filter { $0.label == "Work Order" }
        #expect(after.allSatisfy { $0.from.boxId == plan.id && $0.from.side == .right && abs($0.from.pos - 0.2) < 0.02 })
        #expect(after.map(\.to) == wos.map(\.to))
        #expect(h.undoManager.undoActionName == "Move Arrow End")
        h.undoManager.undo()
        #expect(h.diagram.arrows.filter { $0.label == "Work Order" }.map { $0.from.pos } == [0.5, 0.7, 0.88])

        // Along the face first, then onto the bottom: the two left behind are as stored.
        h.state.selection = .arrow(wos[2].id)
        let grab = try #require(HitTest.route(h.document.model, in: h.diagram, wos[2]).first)
        h.press(grab)
        h.moveHeld(from: grab, to: Point(x: plan.x + plan.w + 3, y: plan.y + plan.h * 0.3))
        #expect(h.canvas.draftModel?.diagrams[d.id]?.arrows.filter { $0.label == "Work Order" }.allSatisfy { abs($0.from.pos - 0.3) < 0.02 } == true)
        let bottom = Point(x: plan.x + plan.w * 0.5, y: plan.y + plan.h + 3)
        h.moveHeld(from: Point(x: plan.x + plan.w + 3, y: plan.y + plan.h * 0.3), to: bottom)
        h.release(bottom)
        after = h.diagram.arrows.filter { $0.label == "Work Order" }
        #expect(after[0].from == wos[0].from && after[1].from == wos[1].from)
        #expect(after[2].from.side == .bottom && after[2].from.boxId == plan.id)
        #expect(h.undoManager.undoActionName == "Move Arrow End")
    }

    @Test("Pressing B adds a box and opens its name for editing")
    func addBoxKey() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let before = h.diagram.boxes.count
        h.key("b")
        #expect(h.diagram.boxes.count == before + 1)
        #expect(h.canvas.textField != nil)
        h.type("Inspect Product")
        #expect(h.diagram.boxes.contains { $0.name == "Inspect Product" })
    }
}
