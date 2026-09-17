// F71: IDEF0Document.apply must not mistake a normalization-only edit for a
// no-op. The model's synthesized Equatable compares strings the way Swift
// does — by canonical equivalence — so an edit that only changes an NFD
// spelling to its NFC twin (or back) leaves `next == model` true even though
// the two serialize to different UTF-8 bytes. `apply` falls back to a
// byte-exact serialize comparison once `==` already says equal, so such an
// edit is still applied, still recorded as undoable, and still changes what
// gets saved.
//
// `IDEF0Document(model:)` is the in-memory convenience init (no file, no
// pending load repair), the same seam `DocumentLoadRepairTests.swift` uses
// for `init(loadedState:)`.

import Foundation
import Testing
@testable import IDEF0Core
@testable import IDEF0Modeler

@Suite("IDEF0Document.apply and normalization-only edits (F71)")
struct NormalizationEditTests {
    @Test("renaming a concept from NFD to NFC through apply records an edit and changes the saved bytes")
    func renameConceptNormalizationIsAppliedAndUndoable() throws {
        var model = IDEF0Model.create(title: "Shop")
        let ctx = model.rootDiagramId
        let nfd = "Cafe\u{301} Menu"
        model.updateDiagram(ctx) { $0.boxes[0].name = nfd }
        model.bindAll()
        let conceptId = try #require(model.contextDiagram?.boxes.first?.conceptId)
        #expect(model.conceptById(conceptId)?.term.utf8.elementsEqual(nfd.utf8) == true, "bound exactly as typed, not renormalized")

        let doc = IDEF0Document(model: model)
        let beforeBytes = ModelFile.serialize(doc.model)
        let undoManager = UndoManager()

        let nfc = "Caf\u{E9} Menu"
        doc.apply("Rename Concept", undoManager: undoManager) { m in
            _ = m.renameConcept(conceptId, to: nfc)
        }

        #expect(doc.model == model, "the edit is canonically a no-op under Swift's ==")
        let afterBytes = ModelFile.serialize(doc.model)
        #expect(!beforeBytes.utf8.elementsEqual(afterBytes.utf8), "but it must still change what gets saved")
        #expect(undoManager.canUndo, "and it must still be recorded as one undoable edit")
        #expect(undoManager.undoActionName == "Rename Concept")

        undoManager.undo()
        #expect(ModelFile.serialize(doc.model).utf8.elementsEqual(beforeBytes.utf8), "undo restores the original bytes")
        #expect(undoManager.canRedo)

        undoManager.redo()
        #expect(ModelFile.serialize(doc.model).utf8.elementsEqual(afterBytes.utf8), "redo reapplies the renormalized bytes")
    }

    @Test("apply still skips an edit that changes nothing at all")
    func applySkipsARealNoOp() {
        let doc = IDEF0Document(model: IDEF0Model.create(title: "Shop"))
        let before = doc.model
        let undoManager = UndoManager()
        doc.apply("Do Nothing", undoManager: undoManager) { _ in }
        #expect(!undoManager.canUndo, "a genuine no-op must not be recorded")
        #expect(doc.model == before)
    }

    @Test("apply still applies and records an edit that is not merely a normalization change")
    func applyStillAppliesAnOrdinaryEdit() {
        let model = IDEF0Model.create(title: "Shop")
        let doc = IDEF0Document(model: model)
        let undoManager = UndoManager()
        doc.apply("Retitle", undoManager: undoManager) { $0.title = "New Shop" }
        #expect(doc.model.title == "New Shop")
        #expect(undoManager.canUndo)
    }
}
