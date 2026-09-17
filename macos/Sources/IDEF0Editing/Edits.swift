// The edits a modeller makes, as operations on a model value.
//
// Every user-visible change goes through one of these, so the canvas, the
// inspector and the menus cannot drift apart in what "rename" or "delete"
// means. Each mirrors the web app's commit for the same action; where the web
// app's canvas and panel disagreed, the difference is noted.

import IDEF0Core

public enum Edits {
    /// Why an edit did nothing.
    public enum Refusal: Error, Hashable, Sendable, CustomStringConvertible {
        case contextKeepsItsBox
        case contextHasNoTunnels
        case contextIsNotArranged
        case noNeighbourThatWay
        case conceptInUse
        case noSuchConcept
        case blankTerm
        case noSuchDiagram
        case noSuchObject

        public var description: String {
            switch self {
            case .contextKeepsItsBox: return "The A-0 context diagram must keep its single box."
            case .contextHasNoTunnels: return "The A-0 context diagram has no parent, so its arrows cannot be tunnelled."
            case .contextIsNotArranged: return "The A-0 context diagram holds one box, so there is nothing to arrange."
            case .noNeighbourThatWay: return "That box is already at that end of the order."
            case .conceptInUse: return "That concept is still used. Rename or merge it instead."
            case .noSuchConcept: return "That concept no longer exists."
            case .blankTerm: return "A bundle needs a term."
            case .noSuchDiagram: return "That diagram no longer exists."
            case .noSuchObject: return "That box or arrow no longer exists."
            }
        }
    }

    /// Rename a box and bind it to the concept its new name denotes — keeping
    /// the concept id, and letting the text drift, where `relabelBox`'s rules
    /// call for that (F11).
    ///
    /// The web app's canvas trims the name and renumbers nodes; its properties
    /// panel does neither but updates the model title when the A-0 box is
    /// renamed. Both are done here: trimmed, the unlocked child title follows
    /// (via renumberNodes), and renaming the top box renames the model —
    /// unless the name was cleared, when the model keeps its title.
    public static func renameBox(_ m: inout IDEF0Model, diagramId: String, boxId: String, to name: String) throws {
        guard let d = m.diagrams[diagramId] else { throw Refusal.noSuchDiagram }
        guard d.boxIndex(boxId) != nil else { throw Refusal.noSuchObject }
        m.relabelBox(diagramId: diagramId, boxId: boxId, to: name)
        m.renumberNodes()
        let newName = m.diagrams[diagramId]?.findBox(boxId)?.name ?? ""
        if m.isRootDiagram(diagramId), !newName.isEmpty { m.title = newName }
    }

    /// Label an arrow and bind it to the concept its label denotes — via
    /// `relabelArrow`, so an inherited boundary label kept for §3.3.2.4 or a
    /// typo fix on an undefined term does not silently rebind (F11).
    public static func labelArrow(_ m: inout IDEF0Model, diagramId: String, arrowId: String, to label: String) throws {
        guard let d = m.diagrams[diagramId] else { throw Refusal.noSuchDiagram }
        guard d.arrowIndex(arrowId) != nil else { throw Refusal.noSuchObject }
        m.relabelArrow(diagramId: diagramId, arrowId: arrowId, to: label)
    }

    /// Draw a new, unlabelled arrow; returns its id. An end on a box the
    /// diagram no longer has — deleted or undone away since the first click —
    /// is refused rather than written as a dangling arrow.
    @discardableResult
    public static func drawArrow(_ m: inout IDEF0Model, diagramId: String, from: Endpoint, to: Endpoint) throws -> String {
        guard let d = m.diagrams[diagramId] else { throw Refusal.noSuchDiagram }
        for end in [from, to] where end.kind == .box && d.findBox(end.boxId) == nil { throw Refusal.noSuchObject }
        let arrow = newArrow(label: "", from: from, to: to)
        m.updateDiagram(diagramId) { $0.arrows.append(arrow) }
        return arrow.id
    }

    /// Draw the arrow a port stands for (S01): from the port's boundary
    /// endpoint to `side`/`pos` of the box it was dropped on — any side takes
    /// the drop; whether the role fits it is the checks' business, as on the
    /// web — labelled with the port's label and bound to the port's concept,
    /// through `drawArrow`, so a box the diagram no longer has is refused the
    /// same way. An O port leaves the diagram, so for it the box side is the
    /// `from` end and the port the `to` end; an I, C or M port enters, so
    /// the port is `from`. Returns the new arrow's id.
    @discardableResult
    public static func connectPort(_ m: inout IDEF0Model, diagramId: String, port: ICOMPort, boxId: String, side: Side, pos: Double) throws -> String {
        let edge = Endpoint.boundary(port.side, port.pos)
        let at = Endpoint.box(boxId, side, pos)
        let (from, to) = port.role == .output ? (at, edge) : (edge, at)
        let id = try drawArrow(&m, diagramId: diagramId, from: from, to: to)
        m.updateDiagram(diagramId) { d in
            guard let i = d.arrowIndex(id) else { return }
            d.arrows[i].label = port.label
            d.arrows[i].conceptId = port.conceptId
        }
        return id
    }

    /// Add a box as the next activity in the order; the staircase places it
    /// (S01). Returns it after renumbering.
    ///
    /// FIPS 183 §3.4.2: the A-0 context diagram holds exactly one box. Once it
    /// has one, adding another here would give it two, which nothing else in
    /// either app expects. A file that already violates this (e.g. an import
    /// with zero boxes) stays repairable, since the guard only blocks going
    /// to two.
    @discardableResult
    public static func addBox(_ m: inout IDEF0Model, diagramId: String) throws -> Box {
        guard let d = m.diagrams[diagramId] else { throw Refusal.noSuchDiagram }
        if m.isRootDiagram(diagramId), !d.boxes.isEmpty { throw Refusal.contextKeepsItsBox }
        guard let box = m.addBox(diagramId: diagramId) else { throw Refusal.noSuchDiagram }
        return box
    }

    /// Move a box one step earlier (`by` = -1) or later (`by` = +1) in the
    /// reading order (S01): it swaps numbers with its neighbour and the
    /// staircase is laid out again. Refused on the A-0 diagram, whose one
    /// box has no order, and at either end of the order.
    public static func moveBox(_ m: inout IDEF0Model, diagramId: String, boxId: String, by: Int) throws {
        guard let d = m.diagrams[diagramId] else { throw Refusal.noSuchDiagram }
        if m.isRootDiagram(diagramId) { throw Refusal.contextIsNotArranged }
        guard d.boxIndex(boxId) != nil else { throw Refusal.noSuchObject }
        guard m.moveBox(diagramId: diagramId, boxId: boxId, by: by) else { throw Refusal.noNeighbourThatWay }
    }

    /// Whether `moveBox` would move the box: what enables "Move Earlier" and
    /// "Move Later" — not on A-0, and not past either end of the number order.
    public static func canMoveBox(_ m: IDEF0Model, diagramId: String, boxId: String, by: Int) -> Bool {
        guard let d = m.diagrams[diagramId], !m.isRootDiagram(diagramId), by == -1 || by == 1 else { return false }
        let order = d.sortedBoxes
        guard let i = order.firstIndex(where: { $0.id.utf16.elementsEqual(boxId.utf16) }) else { return false }
        return i + by >= 0 && i + by < order.count
    }

    /// Lay the diagram's boxes out along the staircase again, in number
    /// order (S01's "Arrange"). Nothing else changes: numbers, arrows and
    /// glossary are as they were. Refused on A-0, which is never laid out.
    public static func arrange(_ m: inout IDEF0Model, diagramId: String) throws {
        guard m.diagrams[diagramId] != nil else { throw Refusal.noSuchDiagram }
        if m.isRootDiagram(diagramId) { throw Refusal.contextIsNotArranged }
        m.updateDiagram(diagramId) { $0.layoutBoxes() }
    }

    /// Delete the selected box (and everything below it) or arrow.
    public static func delete(_ m: inout IDEF0Model, diagramId: String, selection: Selection) throws {
        guard let d = m.diagrams[diagramId] else { throw Refusal.noSuchDiagram }
        switch selection {
        case .box(let id):
            if m.isRootDiagram(diagramId) { throw Refusal.contextKeepsItsBox }
            guard d.boxIndex(id) != nil else { throw Refusal.noSuchObject }
            m.removeBox(diagramId: diagramId, boxId: id)
        case .arrow(let id):
            guard d.arrowIndex(id) != nil else { throw Refusal.noSuchObject }
            m.updateDiagram(diagramId) { $0.removeArrow(id) }
        }
    }

    // MARK: Drags — applied continuously while the pointer moves
    //
    // Only an arrow's ends, bend and label are dragged (S01): a box's place
    // is the staircase's, so there is no move or resize here.

    /// Re-attaching an arrow end discards any pinned bend, as the route changes shape.
    public static func moveEndpoint(_ m: inout IDEF0Model, diagramId: String, arrowId: String, end: ArrowEnd, to endpoint: Endpoint) {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId) else { return }
        m.updateDiagram(diagramId) { d in
            d.arrows[i][end] = endpoint
            d.arrows[i].bend = nil
        }
    }

    /// Move a grouped end (S02): the dragged arrow's `end` goes to `endpoint`
    /// as `moveEndpoint` moves it, and while `endpoint` is still on the face
    /// the group left from — the same kind, box and side as the dragged
    /// arrow's own stored end in `members` — every other member's end goes
    /// there too, so the stored positions stay consistent with the one drawn
    /// trunk. Reconnected to another side or box, the dragged arrow leaves
    /// the group alone: the other members are put back exactly as `members`
    /// recorded them at the press. The web canvas's endpoint drag, rule for
    /// rule; `members` comes from `HitTest.endGroup`.
    public static func moveEndpoint(
        _ m: inout IDEF0Model, diagramId: String, arrowId: String, end: ArrowEnd, to endpoint: Endpoint, members: [EndMember]
    ) {
        guard m.diagrams[diagramId] != nil else { return }
        guard let own = members.first(where: { sameId($0.id, arrowId) }) else {
            moveEndpoint(&m, diagramId: diagramId, arrowId: arrowId, end: end, to: endpoint)
            return
        }
        let sameFace = own.endpoint.kind == endpoint.kind && own.endpoint.side == endpoint.side
            && (endpoint.kind != .box || sameId(own.endpoint.boxId, endpoint.boxId))
        m.updateDiagram(diagramId) { d in
            for member in members {
                guard let i = d.arrowIndex(member.id) else { continue }
                if sameId(member.id, arrowId) || sameFace {
                    d.arrows[i][end] = endpoint
                    d.arrows[i].bend = nil
                } else {
                    d.arrows[i][end] = member.endpoint
                    d.arrows[i].bend = member.bend
                }
            }
        }
    }

    public static func setBend(_ m: inout IDEF0Model, diagramId: String, arrowId: String, axis: BendAxis, pointer: Point) {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId) else { return }
        m.updateDiagram(diagramId) { $0.arrows[i].bend = DragRules.bend(axis: axis, pointer: pointer) }
    }

    public static func moveLabel(_ m: inout IDEF0Model, diagramId: String, arrowId: String, original: Point, dragStart: Point, pointer: Point) {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId) else { return }
        let o = DragRules.labelOffset(original: original, dragStart: dragStart, pointer: pointer)
        m.updateDiagram(diagramId) { d in
            d.arrows[i].ldx = o.x
            d.arrows[i].ldy = o.y
        }
    }

    /// Escape on a diagram with nothing selected goes up to the parent,
    /// selecting the box this diagram details.
    public static func parentTarget(of m: IDEF0Model, diagramId: String) -> (diagramId: String, selection: Selection)? {
        guard let parent = m.parentOf(m.diagrams[diagramId]) else { return nil }
        return (parent.diagramId, .box(parent.box.id))
    }
}
