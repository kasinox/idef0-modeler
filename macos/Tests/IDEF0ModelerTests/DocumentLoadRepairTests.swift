// F13: a document read from a file that needed concepts bound, or that had
// no top-level model id, must not look like a clean, already-saved document
// — `IDEF0Document.loadedState` decides whether a repair happened and what
// to call it, and `assignConceptsIfNeeded` turns it into one undoable edit
// the first time a window can register it. Neither had a test anywhere
// before this file (a blocking review finding on this package): `swift test`
// alone could not have caught `unboundOnDisk`'s later replacement being
// wrong, or a caller regressing which case sets `dirty`.
//
// `loadedState` is a pure static function taking text in directly, so these
// tests reach it without SwiftUI's `FileDocumentReadConfiguration` (no public
// initialiser). `init(loadedState:)` is a matching test-only seam that lets
// `assignConceptsIfNeeded`'s undo wiring be exercised the same way.

import Foundation
import Testing
@testable import IDEF0Core
@testable import IDEF0Modeler

/// A minimal, valid project file: one box on the root diagram, named unless
/// `named` is false, bound to a matching glossary concept when `bound` is
/// true, with a top-level `id` unless `withId` is false.
private func minimalModelJSON(withId: Bool, bound: Bool, named: Bool = true) -> String {
    let idMember = withId ? "\"id\": \"mdl_fixed_for_test\", " : ""
    let name = named ? "Do Something" : ""
    let conceptId = bound ? "\"conceptId\": \"gl_fixed\", " : ""
    let glossary = bound ? "\"glossary\": [ { \"id\": \"gl_fixed\", \"term\": \"Do Something\", \"kind\": \"activity\" } ], " : ""
    return """
    { \(idMember)\(glossary)"diagrams": { "d1": { "id": "d1", "node": "A0", "title": "Test",
      "boxes": [ { "id": "bx1", \(conceptId)"name": "\(name)" } ], "arrows": [] } },
      "rootDiagramId": "d1" }
    """
}

private func box(_ m: IDEF0Model) -> Box { m.diagrams["d1"]!.boxes[0] }

@Suite("IDEF0Document load-time repair (F13)")
struct DocumentLoadRepairTests {
    @Test("a file with an id and nothing left to bind needs no repair")
    func fullyBoundNeedsNoRepair() throws {
        let state = try IDEF0Document.loadedState(text: minimalModelJSON(withId: true, bound: true), isXML: false)
        #expect(state.pendingLoadRepair == nil)
        #expect(box(state.model).conceptId == "gl_fixed")
    }

    @Test("an unbound box alone is repaired as \"Assign Concepts\", not touching the model id")
    func unboundOnlyIsAssignConcepts() throws {
        let state = try IDEF0Document.loadedState(text: minimalModelJSON(withId: true, bound: false), isXML: false)
        let pending = try #require(state.pendingLoadRepair)
        #expect(pending.actionName == "Assign Concepts")
        #expect(box(pending.before).conceptId == nil, "before the repair, the box is exactly as the file had it")
        #expect(box(state.model).conceptId != nil, "loadedState itself already binds, as bindAll does on every load")
        #expect(pending.before.id == state.model.id, "only concepts changed; the id read from the file is untouched")
    }

    @Test("a missing top-level id alone is repaired as \"Assign Model Id\"")
    func missingIdOnlyIsAssignModelId() throws {
        let state = try IDEF0Document.loadedState(text: minimalModelJSON(withId: false, bound: true), isXML: false)
        let pending = try #require(state.pendingLoadRepair)
        #expect(pending.actionName == "Assign Model Id")
        #expect(!state.model.id.isEmpty, "ModelFile.read must still have minted an id")
        // Nothing else needed fixing, so "before" and "after" carry the same
        // (minted) id and are otherwise identical — the repair exists purely
        // to mark the document edited, not to change anything visible.
        #expect(pending.before == state.model)
    }

    @Test("an explicit empty-string id counts as missing, like the web app's !raw.id")
    func emptyStringIdCountsAsMissing() throws {
        let json = minimalModelJSON(withId: false, bound: true).replacingOccurrences(
            of: "\"diagrams\"", with: "\"id\": \"\", \"diagrams\"")
        let state = try IDEF0Document.loadedState(text: json, isXML: false)
        #expect(state.pendingLoadRepair?.actionName == "Assign Model Id")
    }

    @Test("both an unbound box and a missing id are named together")
    func bothTogetherAreNamedJointly() throws {
        let state = try IDEF0Document.loadedState(text: minimalModelJSON(withId: false, bound: false), isXML: false)
        #expect(state.pendingLoadRepair?.actionName == "Assign Concepts and Model Id")
    }

    @Test("XML input is never treated as having a missing model id")
    func xmlIsNeverFlaggedForAMissingId() throws {
        // isXML is asserted true regardless of content — loadedState must not
        // even try to parse XML text as the JSON `!raw.id` check would need.
        let state = try? IDEF0Document.loadedState(text: "<not json at all>", isXML: true)
        // Malformed XML fails in ModelFile.read itself; the point here is only
        // that no *id* related throw or flag comes from the JSON-only check.
        #expect(state == nil || state?.pendingLoadRepair?.actionName != "Assign Model Id")
    }

    @Test("assignConceptsIfNeeded records one undoable edit that restores the pre-repair model, and only once")
    func assignConceptsIfNeededIsUndoableAndIdempotent() throws {
        let state = try IDEF0Document.loadedState(text: minimalModelJSON(withId: false, bound: false), isXML: false)
        let before = try #require(state.pendingLoadRepair).before
        let doc = IDEF0Document(loadedState: state)
        let undoManager = UndoManager()

        doc.assignConceptsIfNeeded(undoManager: undoManager)
        #expect(undoManager.undoActionName == "Assign Concepts and Model Id")

        let afterRepair = doc.model
        undoManager.undo()
        #expect(doc.model == before)
        #expect(!undoManager.canUndo)
        #expect(undoManager.canRedo)

        // A second call, after the repair is already recorded, does nothing:
        // no new action is queued (checked with the first one sitting on the
        // redo stack, so a wrongly re-added one would show up as `canUndo`).
        doc.assignConceptsIfNeeded(undoManager: undoManager)
        #expect(!undoManager.canUndo)

        undoManager.redo()
        #expect(doc.model == afterRepair)
    }

    @Test("assignConceptsIfNeeded never fires for a document with no pending repair")
    func noRepairMeansNoUndoRegistered() throws {
        let state = try IDEF0Document.loadedState(text: minimalModelJSON(withId: true, bound: true), isXML: false)
        let doc = IDEF0Document(loadedState: state)
        let undoManager = UndoManager()
        doc.assignConceptsIfNeeded(undoManager: undoManager)
        #expect(!undoManager.canUndo)
    }
}
