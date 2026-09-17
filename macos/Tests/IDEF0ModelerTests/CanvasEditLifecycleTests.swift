// The canvas's housekeeping around an edit: the floating field's life when
// the window moves on without it, requests from menus arriving during a
// SwiftUI update, keys whose release may go elsewhere, and a half-drawn arrow
// whose source has been deleted.

import AppKit
import Testing
@testable import IDEF0Core
@testable import IDEF0Editing
@testable import IDEF0Modeler

@MainActor
@Suite("Canvas edit lifecycle", .serialized)
struct CanvasEditLifecycleTests {
    @Test("Navigating during an inline edit commits it to the diagram it began on and takes the field down")
    func navigationCommitsInlineEdit() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let a0 = h.state.diagramId
        let b = h.diagram.boxes[1]
        h.click(Point(x: b.x + b.w / 2, y: b.y + b.h / 2), clicks: 2)
        #expect(h.state.editing == .boxName(b.id))
        h.canvas.textField?.stringValue = "Typed Before Leaving"

        // A toolbar button, a menu item or a tree row opens another diagram.
        h.state.open(h.document.model.rootDiagramId)
        #expect(h.state.diagramId == h.document.model.rootDiagramId)
        #expect(h.canvas.textField == nil)
        #expect(h.canvas.subviews.isEmpty, "the field does not linger over the new diagram")
        #expect(h.state.editing == nil)
        #expect(h.document.model.diagrams[a0]?.findBox(b.id)?.name == "Typed Before Leaving")
        #expect(h.undoManager.undoActionName == "Rename Box")

        // The next edit opens one field, not a second beside a leftover.
        let top = h.diagram.boxes[0]
        h.click(Point(x: top.x + top.w / 2, y: top.y + top.h / 2), clicks: 2)
        #expect(h.canvas.subviews.count == 1)
        h.type("Run Plant")
        #expect(h.diagram.boxes[0].name == "Run Plant")
        #expect(h.canvas.subviews.isEmpty)
    }

    @Test("The state's commit hook is the canvas's, so Decompose can commit a name before it titles the child")
    func commitHookCommits() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[2]
        h.click(Point(x: b.x + b.w / 2, y: b.y + b.h / 2), clicks: 2)
        h.canvas.textField?.stringValue = "Inspect Widget"
        h.state.commitPendingEdit?()
        #expect(h.diagram.findBox(b.id)?.name == "Inspect Widget")
        #expect(h.canvas.textField == nil && h.state.editing == nil)
        // With nothing in progress the hook is harmless.
        h.state.commitPendingEdit?()
        #expect(h.undoManager.undoActionName == "Rename Box")
    }

    @Test("Opening the diagram already shown, with the same selection, leaves an edit alone")
    func reopeningKeepsEdit() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let b = h.diagram.boxes[1]
        // The first click of a double-click selects; the second opens the field.
        h.click(Point(x: b.x + b.w / 2, y: b.y + b.h / 2))
        h.click(Point(x: b.x + b.w / 2, y: b.y + b.h / 2), clicks: 2)
        #expect(h.state.selection == .box(b.id) && h.state.editing == .boxName(b.id))
        // The tree row for this box, say, opens what is already open.
        h.state.open(h.state.diagramId, selecting: .box(b.id))
        #expect(h.canvas.textField != nil && h.state.editing == .boxName(b.id))
        #expect(!h.undoManager.canUndo)
    }

    @Test("A menu request runs after the update pass that delivered it, once, and a new canvas does not replay it")
    func requestsAreDeferredAndNotReplayed() async {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let before = h.diagram.boxes.count
        h.state.request(.addBox)
        h.canvas.handle(h.state.canvasRequest)
        #expect(h.diagram.boxes.count == before, "nothing is edited inside the pass")
        for _ in 0..<5 { await Task.yield() }
        #expect(h.diagram.boxes.count == before + 1)
        #expect(h.canvas.textField != nil, "the new box's name is open for editing")

        // SwiftUI may deliver the same request in several update passes.
        h.canvas.handle(h.state.canvasRequest)
        for _ in 0..<5 { await Task.yield() }
        #expect(h.diagram.boxes.count == before + 1)

        // A canvas created on a state that has a request outstanding starts past it.
        let fresh = SheetCanvasView(frame: h.canvas.frame)
        fresh.document = h.document
        fresh.state = h.state
        fresh.handle(h.state.canvasRequest)
        for _ in 0..<5 { await Task.yield() }
        #expect(h.diagram.boxes.count == before + 1)

        // …but carries out the next one.
        h.state.request(.deleteSelection)
        fresh.handle(h.state.canvasRequest)
        for _ in 0..<5 { await Task.yield() }
        #expect(h.diagram.boxes.count == before)
    }

    @Test("Space-to-pan ends when the canvas loses focus or its window stops being key")
    func spacePanIsReleased() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        h.window.makeFirstResponder(h.canvas)
        h.key(" ", keyCode: 49)
        #expect(h.canvas.spaceDown)
        // A sidebar row or an inspector field takes focus while Space is held;
        // the key-up goes there, never here.
        h.window.makeFirstResponder(nil)
        #expect(!h.canvas.spaceDown)
        let b = h.diagram.boxes[1]
        h.click(Point(x: b.x + b.w / 2, y: b.y + 10))
        #expect(h.state.selection == .box(b.id), "the click selects; it does not pan")

        h.key(" ", keyCode: 49)
        #expect(h.canvas.spaceDown)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: h.window)
        #expect(!h.canvas.spaceDown)

        // The key-up itself still ends it, and auto-repeat does not re-arm anything.
        h.key(" ", keyCode: 49)
        h.key(" ", keyCode: 49, up: true)
        #expect(!h.canvas.spaceDown)
    }

    @Test("⌘↑, ⌘↓ and ⌘Home navigate from the canvas; the bare arrow keys do not")
    func commandChordsNavigate() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let root = h.document.model.rootDiagramId
        let a0 = h.state.diagramId
        let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
        h.key("\u{F700}", keyCode: 126, modifiers: arrows.union(.command))
        #expect(h.state.diagramId == root)
        #expect(h.state.selection == .box(h.document.model.contextDiagram!.boxes[0].id))
        h.key("\u{F701}", keyCode: 125, modifiers: arrows.union(.command))
        #expect(h.state.diagramId == a0, "⌘↓ opens the selected box's child")
        h.key("\u{F729}", keyCode: 115, modifiers: [.function, .command])
        #expect(h.state.diagramId == root)
        h.state.open(a0)
        h.key("\u{F700}", keyCode: 126, modifiers: arrows)
        #expect(h.state.diagramId == a0, "without ⌘ the arrow keys are not navigation")
    }

    @Test("Edit ▸ Delete reaches the canvas as delete:, enabled only with a selection")
    func deleteAction() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let item = NSMenuItem(title: "Delete", action: #selector(SheetCanvasView.delete(_:)), keyEquivalent: "")
        #expect(!h.canvas.validateUserInterfaceItem(item))
        let b = h.diagram.boxes[1]
        h.click(Point(x: b.x + b.w / 2, y: b.y + 10))
        #expect(h.canvas.validateUserInterfaceItem(item))
        let before = h.diagram.boxes.count
        h.canvas.delete(nil)
        #expect(h.diagram.boxes.count == before - 1)
        #expect(h.state.selection == nil)
        #expect(h.undoManager.undoActionName == "Delete Box")
    }

    @Test("Deleting the source of a half-drawn arrow cannot end in an arrow from nowhere")
    func deletedSourceIsRefused() {
        let h = CanvasHarness(model: decomposedSample(), diagramNode: "A0")
        let (b1, b3Id) = (h.diagram.boxes[0], h.diagram.boxes[2].id)
        h.click(Point(x: b1.x + 20, y: b1.y + 20))
        h.key("a")
        h.click(Point(x: b1.x + b1.w, y: b1.y + b1.h * 0.2))
        #expect(h.state.pendingFrom?.boxId == b1.id)
        h.key("\u{7F}", keyCode: 51)
        #expect(h.diagram.findBox(b1.id) == nil)
        // S01: deleting a box lays the survivors out again, so b3 is read
        // back where it now sits.
        let b3 = h.diagram.findBox(b3Id)!

        // The window reconciles the state after every model change; that
        // alone drops the pending source…
        let reconciled = EditorState(diagramId: h.state.diagramId)
        reconciled.pendingFrom = h.state.pendingFrom
        reconciled.reconcile(with: h.document.model)
        #expect(reconciled.pendingFrom == nil)

        // …and should a click come first, the edit itself refuses the missing box.
        let arrows = h.diagram.arrows.count
        h.click(Point(x: b3.x, y: b3.y + b3.h * 0.8))
        #expect(h.diagram.arrows.count == arrows)
        #expect(h.state.hint == Edits.Refusal.noSuchObject.description)
        #expect(h.state.pendingFrom == nil)
        let d = h.diagram
        #expect(!d.arrows.contains { a in [a.from, a.to].contains { $0.kind == .box && d.findBox($0.boxId) == nil } },
                "no arrow refers to a box the diagram does not have")
    }
}
