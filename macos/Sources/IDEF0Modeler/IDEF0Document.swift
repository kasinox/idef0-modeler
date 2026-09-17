// One open IDEF0 model: the file on disk, the model in memory, and its undo history.

import IDEF0Core
import SwiftUI
import UniformTypeIdentifiers

final class IDEF0Document: ReferenceFileDocument {
    typealias Snapshot = IDEF0Model

    /// A project file is plain JSON, so any `.json` opens; the web app's XML
    /// interchange opens too. Saving always writes the canonical JSON the web
    /// app writes, so an XML file is saved as a new `.idef0.json`.
    static var readableContentTypes: [UTType] { [.json, .xml] }
    static var writableContentTypes: [UTType] { [.json] }

    /// The committed model. A drag in progress is not in it: the canvas keeps
    /// the geometry to itself until the mouse comes up and applies it then as
    /// one edit — as the web app's light updates redraw only the canvas — so
    /// the sidebar and inspector are not re-evaluated on every mouse move.
    @Published private(set) var model: IDEF0Model
    /// The rule check's findings for the current model. Recomputed after each
    /// committed edit, not on every mouse move of a drag — as the web app does.
    @Published private(set) var issues: [ValidationIssue] = []

    /// A load-time repair `init(configuration:)` made that has not yet become
    /// a saved edit (F13): concepts bound that the file did not carry, the
    /// file's top-level `id` minted because it had none, or both. `before`
    /// is the model as read, before that repair; `actionName` names the
    /// eventual undo action. Binding (and any id-minting `ModelFile.read`
    /// did) happens immediately, so `model` and `issues` are consistent from
    /// the start — but the repair is only a load-time convenience like the
    /// web app's until `assignConceptsIfNeeded` turns it into one undoable
    /// edit, the first time a window can register it. `nil` once nothing
    /// needed repair, or once that edit has been recorded.
    private var pendingLoadRepair: (before: IDEF0Model, actionName: String)?

    init(model: IDEF0Model) {
        var m = model
        // The in-memory convenience init: not a file on disk, so there is
        // nothing to fall behind — bind directly, as before.
        m.bindAll()
        self.model = m
        revalidate()
    }

    convenience init() {
        self.init(model: IDEF0Model.create(title: "Untitled Model"))
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let text = ModelFile.decodeText(data)
        do {
            let loaded = try Self.loadedState(text: text, isXML: configuration.contentType.conforms(to: .xml))
            model = loaded.model
            pendingLoadRepair = loaded.pendingLoadRepair
            revalidate()
        } catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedFailureReasonErrorKey: String(describing: error),
            ])
        }
    }

    /// Test-only seam: reach the "just read, possibly with a pending repair"
    /// state `init(configuration:)` produces, without needing SwiftUI's
    /// `FileDocumentReadConfiguration` — a struct the framework gives no
    /// public initialiser for, so it cannot be built outside the framework's
    /// own file-opening machinery. Takes `loadedState`'s result directly.
    init(loadedState state: (model: IDEF0Model, pendingLoadRepair: (before: IDEF0Model, actionName: String)?)) {
        model = state.model
        pendingLoadRepair = state.pendingLoadRepair
        revalidate()
    }

    /// The web app's rule: XML by type, or by a leading "<" whatever the name says.
    static func read(_ text: String, isXML: Bool) throws -> IDEF0Model {
        try ModelFile.read(text, isXML: isXML)
    }

    /// Parse and bind a file's text the way `init(configuration:)` does,
    /// isolated from `ReadConfiguration`/`FileWrapper` (which SwiftUI gives
    /// no public initialiser for) so the logic can be exercised directly by
    /// a test. Detects both load-time repairs F13 tracks: concepts `bindAll`
    /// had to assign, and — JSON only, mirroring the web app's `!raw.id` in
    /// json.js — a top-level `id` the file lacked, which `ModelFile.read`
    /// already minted into `loaded.id` before this runs.
    static func loadedState(
        text: String, isXML: Bool
    ) throws -> (model: IDEF0Model, pendingLoadRepair: (before: IDEF0Model, actionName: String)?) {
        let loaded = try read(text, isXML: isXML)
        var bound = loaded
        bound.bindAll()
        let conceptsBound = bound != loaded
        let idWasMinted = !isXML && modelIdWasMissing(in: text)
        guard conceptsBound || idWasMinted else { return (bound, nil) }
        let actionName = conceptsBound && idWasMinted ? "Assign Concepts and Model Id"
            : conceptsBound ? "Assign Concepts" : "Assign Model Id"
        return (bound, (before: loaded, actionName: actionName))
    }

    /// `!raw.id` from the web app's json.js: true when the file's top-level
    /// `id` is absent, null, or empty, so `ModelFile.read` had to mint one
    /// that exists only in memory until this read is saved (F13). Malformed
    /// JSON is not this method's problem — `ModelFile.read` already threw,
    /// or will, before its result is used.
    private static func modelIdWasMissing(in text: String) -> Bool {
        guard let value = try? JSONValue.parse(text), case .object(let obj) = value else { return false }
        return !JSONValue.truthy(obj["id"])
    }

    func snapshot(contentType: UTType) throws -> IDEF0Model { model }

    func fileWrapper(snapshot: IDEF0Model, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(ModelFile.serialize(snapshot).utf8))
    }

    // MARK: Editing

    /// Turn the load-time repair `init(configuration:)` already made (bound
    /// concepts, a minted model id, or both — F13) into one undoable edit,
    /// the first time a window hands this document an undoManager — so it is
    /// saved, or autosaved, instead of only existing in memory. A window
    /// calls this once it can supply an undoManager (e.g. on appearing).
    /// Idempotent: does nothing once recorded, and never fires for a
    /// document created in-app, whose concepts `init(model:)` already bound
    /// before this class had anything to observe as unbound.
    func assignConceptsIfNeeded(undoManager: UndoManager?) {
        guard let pending = pendingLoadRepair, let undoManager else { return }
        pendingLoadRepair = nil
        registerUndo(pending.actionName, restoring: pending.before, undoManager)
    }

    /// Apply one named, undoable edit. An edit that changes nothing is not
    /// recorded — but "nothing" means byte-identical once saved, not merely
    /// `==`: the model's synthesized Equatable compares strings the way Swift
    /// does, by canonical equivalence, so an edit that only renormalizes
    /// Unicode text (NFD to NFC, say) leaves `next == model` true even though
    /// the two serialize to different UTF-8 bytes. Such an edit must still be
    /// applied and made undoable, or a deliberate re-normalizing fix silently
    /// does nothing. The serialize-and-compare fallback only runs when `==`
    /// already says equal — the rare no-op path, not the drag-geometry edits
    /// that make up most calls here — so it costs nothing on the common case.
    /// Throws whatever `change` throws, leaving the model untouched.
    func apply(_ actionName: String, undoManager: UndoManager?, _ change: (inout IDEF0Model) throws -> Void) rethrows {
        var next = model
        try change(&next)
        guard next != model || !Self.serializedBytesMatch(next, model) else { return }
        let before = model
        model = next
        revalidate()
        registerUndo(actionName, restoring: before, undoManager)
    }

    /// Whether `a` and `b` write the identical `.idef0.json` bytes — the
    /// byte-exact check `apply` falls back to once `==` has already called
    /// the two models canonically equal.
    private static func serializedBytesMatch(_ a: IDEF0Model, _ b: IDEF0Model) -> Bool {
        ModelFile.serialize(a).utf8.elementsEqual(ModelFile.serialize(b).utf8)
    }

    private func revalidate() {
        issues = validate(model)
    }

    private func registerUndo(_ actionName: String, restoring previous: IDEF0Model, _ undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { doc in
            let current = doc.model
            doc.model = previous
            doc.revalidate()
            // Registering the inverse while undoing is what makes redo work.
            doc.registerUndo(actionName, restoring: current, undoManager)
        }
        undoManager.setActionName(actionName)
    }
}
