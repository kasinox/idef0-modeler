// What one editor window is doing: which diagram is open, what is selected,
// which tool is armed. None of it is saved, and none of it is undoable.

import IDEF0Core
import IDEF0Editing
import Observation

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow
    var id: String { rawValue }
}

/// A text field floating over the canvas, editing a box name or an arrow label.
enum TextEditTarget: Equatable {
    case boxName(String)
    case arrowLabel(String)
}

/// A request from a menu or toolbar that the canvas carries out — it alone
/// knows its size, and it owns the floating text field an edit may open.
enum CanvasRequest: Equatable {
    case fit
    /// Pan — never zoom — until the selection is wholly in view; nothing if it already is.
    case reveal
    case zoom(by: Double)
    case actualSize
    case addBox
    case deleteSelection
    case renameSelection
    /// Lay the current diagram's boxes out along the staircase again (S01).
    case arrange
    /// Move the selected box one step earlier (-1) or later (+1) in the
    /// reading order (S01); the staircase follows.
    case moveSelection(by: Int)
    case escape
}

@Observable
final class EditorState {
    var diagramId: String
    var selection: Selection?
    /// Switching tools drops a half-drawn arrow and replaces whatever the
    /// status bar said with the new tool's prompt, so a message from before
    /// the switch — a refusal, "arrow added" — cannot outlive it. Navigation
    /// clears the hint the same way; a selection change does not, because an
    /// edit may set both together.
    var tool: Tool = .select {
        didSet {
            pendingFrom = nil
            hint = tool == .arrow ? Self.arrowPrompt : ""
        }
    }
    /// The first click of an arrow being drawn.
    var pendingFrom: Endpoint?
    var editing: TextEditTarget?
    /// A one-line prompt for the status bar.
    var hint = ""
    /// The canvas's current zoom, for the status bar; the canvas owns the transform.
    var zoom = 1.0
    var canvasRequest: (request: CanvasRequest, serial: Int)?
    var sidebarTab: SidebarTab = .tree
    var inspectorTab: InspectorTab = .properties
    var showsInspector = true

    /// Installed by the canvas: commits the inline edit in progress, if any,
    /// removing its field. Navigation calls it before changing diagrams, so
    /// what was typed goes to the box it was typed on rather than being lost
    /// with a field nothing can dismiss.
    @ObservationIgnored var commitPendingEdit: (() -> Void)?

    static let arrowPrompt = "Click a source: a box side, or the sheet edge for a boundary arrow."

    enum SidebarTab: String, CaseIterable, Identifiable {
        case tree = "Node Tree", model = "Model", concepts = "Concepts"
        var id: String { rawValue }
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case properties = "Properties", checks = "Checks"
        var id: String { rawValue }
    }

    init(diagramId: String) {
        self.diagramId = diagramId
    }

    func request(_ r: CanvasRequest) {
        canvasRequest = (r, (canvasRequest?.serial ?? 0) + 1)
    }

    /// Open a diagram, clearing whatever belonged to the one being left.
    ///
    /// The view is refitted only when the diagram changes. A selection made
    /// from the node tree, a concept chip or a check on the diagram already
    /// shown keeps the zoom and pan — as the web app's `goToDiagram` does —
    /// and asks the canvas to pan the selection into view should it be off-screen.
    func open(_ diagramId: String, selecting selection: Selection? = nil) {
        // Navigation is what clears a hint, even to where the window already
        // is: the row re-clicked, the check revealed again.
        hint = ""
        guard diagramId != self.diagramId || selection != self.selection else { return }
        let changesDiagram = diagramId != self.diagramId
        // Before the diagram changes, so the edit lands where it began; the
        // canvas clears `editing` as it takes its field down.
        commitPendingEdit?()
        self.diagramId = diagramId
        self.selection = selection
        pendingFrom = nil
        if changesDiagram {
            request(.fit)
        } else if selection != nil {
            request(.reveal)
        }
    }

    /// Up to the parent diagram, selecting the box this one details.
    func goToParent(in model: IDEF0Model) {
        guard let target = Edits.parentTarget(of: model, diagramId: diagramId) else { return }
        open(target.diagramId, selecting: target.selection)
    }

    /// Down into the selected box's child diagram, if it has one.
    func openChild(in model: IDEF0Model) {
        guard case .box(let id) = selection,
              let child = model.diagrams[diagramId]?.findBox(id)?.childDiagramId,
              model.diagrams[child] != nil
        else { return }
        open(child)
    }

    /// Keep the window pointed at something that still exists after an undo,
    /// a delete or a revert.
    func reconcile(with model: IDEF0Model) {
        if model.diagrams[diagramId] == nil {
            diagramId = model.rootDiagramId
            selection = nil
            pendingFrom = nil
        }
        guard let d = model.diagrams[diagramId] else { return }
        // A half-drawn arrow whose source box is gone is dropped, so the next
        // click cannot write an arrow from a box that no longer exists.
        if let from = pendingFrom, from.kind == .box, d.findBox(from.boxId) == nil { pendingFrom = nil }
        guard let sel = selection else { return }
        switch sel {
        case .box(let id): if d.findBox(id) == nil { selection = nil }
        case .arrow(let id): if d.arrowIndex(id) == nil { selection = nil }
        }
    }
}
