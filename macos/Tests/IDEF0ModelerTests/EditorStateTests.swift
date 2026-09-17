// The window's editing state on its own: what a tool change, a navigation and
// a model change do to the hint, the pending arrow and the selection.

import Testing
@testable import IDEF0Core
@testable import IDEF0Editing
@testable import IDEF0Modeler

@MainActor
@Suite("Editor state")
struct EditorStateTests {
    private func a0(_ m: IDEF0Model) -> Diagram { m.diagrams.values.first { $0.node == "A0" }! }

    @Test("A hint is transient: the tool's prompt replaces it, navigation clears it, a selection change keeps it")
    func hintsAreTransient() {
        let m = decomposedSample()
        let s = EditorState(diagramId: m.rootDiagramId)
        s.hint = "Arrow added. Give it a noun-phrase label."
        s.tool = .arrow
        #expect(s.hint == EditorState.arrowPrompt, "the arrow tool asks for a source, from the picker and menu as from the A key")
        s.hint = Edits.Refusal.noSuchObject.description
        s.tool = .select
        #expect(s.hint == "")
        s.hint = "Could not export."
        s.open(a0(m).id)
        #expect(s.hint == "")
        // Drawing an arrow sets the selection and its hint together; the hint must stay.
        s.hint = "Arrow added. Give it a noun-phrase label."
        s.selection = .box(a0(m).boxes[0].id)
        #expect(s.hint == "Arrow added. Give it a noun-phrase label.")
    }

    @Test("Switching tools drops a half-drawn arrow")
    func toolChangeDropsPending() {
        let m = decomposedSample()
        let s = EditorState(diagramId: a0(m).id)
        s.tool = .arrow
        s.pendingFrom = .boundary(.left, 0.5)
        s.tool = .select
        #expect(s.pendingFrom == nil)
    }

    @Test("Reconciling after a model change drops a pending source whose box, or diagram, is gone")
    func reconcileDropsPending() throws {
        var m = decomposedSample()
        let d = a0(m)
        let s = EditorState(diagramId: d.id)
        let b = d.boxes[1]
        s.pendingFrom = .box(b.id, .right, 0.5)
        s.reconcile(with: m)
        #expect(s.pendingFrom == .box(b.id, .right, 0.5), "the box exists, so the pending arrow is kept")
        m.removeBox(diagramId: d.id, boxId: b.id)
        s.reconcile(with: m)
        #expect(s.pendingFrom == nil)

        // A boundary source needs no box…
        s.pendingFrom = .boundary(.left, 0.3)
        s.reconcile(with: m)
        #expect(s.pendingFrom == .boundary(.left, 0.3))
        // …but goes with the diagram it was clicked on.
        Edits.deleteDecomposition(&m, childDiagramId: d.id)
        s.reconcile(with: m)
        #expect(s.diagramId == m.rootDiagramId)
        #expect(s.pendingFrom == nil)
    }

    @Test("goToParent and openChild move as the toolbar, menu and canvas do")
    func navigationHelpers() {
        let m = decomposedSample()
        let d = a0(m)
        let s = EditorState(diagramId: d.id)
        s.openChild(in: m)
        #expect(s.diagramId == d.id, "nothing selected: nowhere to go down")
        s.goToParent(in: m)
        #expect(s.diagramId == m.rootDiagramId)
        #expect(s.selection == .box(m.contextDiagram!.boxes[0].id), "the parent opens on the box this diagram details")
        s.goToParent(in: m)
        #expect(s.diagramId == m.rootDiagramId, "A-0 has no parent")
        s.openChild(in: m)
        #expect(s.diagramId == d.id && s.selection == nil)
    }

    @Test("Opening another diagram commits the inline edit first, on the diagram it began on")
    func openCommitsFirst() {
        let m = decomposedSample()
        let s = EditorState(diagramId: m.rootDiagramId)
        var seen: [String] = []
        s.commitPendingEdit = { seen.append(s.diagramId) }
        s.open(a0(m).id)
        #expect(seen == [m.rootDiagramId])
        s.open(a0(m).id)
        #expect(seen.count == 1, "opening what is already open changes nothing, so commits nothing")
    }
}
