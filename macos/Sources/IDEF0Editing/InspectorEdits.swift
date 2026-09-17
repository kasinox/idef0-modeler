// Edits made from the inspector and the model panel — ports of the commits in
// src/ui/panels.js.

import IDEF0Core

extension Edits {
    // MARK: Arrows

    /// Moving an end to another side reshapes the route, so a pinned bend goes.
    public static func setEndpointSide(_ m: inout IDEF0Model, diagramId: String, arrowId: String, end: ArrowEnd, side: Side) {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId) else { return }
        m.updateDiagram(diagramId) { d in
            d.arrows[i][end].side = side
            d.arrows[i].bend = nil
        }
    }

    /// Position along the side, as a percentage; kept off the corners (§3.2.1.3).
    public static func setEndpointPosition(_ m: inout IDEF0Model, diagramId: String, arrowId: String, end: ArrowEnd, percent: Double) {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId), percent.isFinite else { return }
        m.updateDiagram(diagramId) { $0.arrows[i][end].pos = Swift.min(0.98, Swift.max(0.02, percent / 100)) }
    }

    /// FIPS 183 §3.4.2: the A-0 diagram carries no tunnels — it has no parent to hide from.
    public static func setTunnel(_ m: inout IDEF0Model, diagramId: String, arrowId: String, end: ArrowEnd, on: Bool) throws {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId) else { throw Refusal.noSuchObject }
        // FIPS 183 §3.4.2 bars a tunnel only at an unconnected (boundary) end:
        // A-0 has no parent to resolve it against. A tunnel at the box end is
        // ordinary notation (§3.3.2.9) that happens to be moot on A-0.
        if on, m.isRootDiagram(diagramId), m.diagrams[diagramId]?.arrows[i][end].kind == .boundary {
            throw Refusal.contextHasNoTunnels
        }
        m.updateDiagram(diagramId) { d in
            if end == .from { d.arrows[i].tunnelFrom = on } else { d.arrows[i].tunnelTo = on }
        }
    }

    public static func resetRouting(_ m: inout IDEF0Model, diagramId: String, arrowId: String) {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId) else { return }
        m.updateDiagram(diagramId) { d in
            d.arrows[i].bend = nil
            d.arrows[i].ldx = 0
            d.arrows[i].ldy = 0
        }
    }

    /// Swap source and destination; each end keeps its own tunnel mark.
    public static func reverseArrow(_ m: inout IDEF0Model, diagramId: String, arrowId: String) {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId) else { return }
        m.updateDiagram(diagramId) { d in
            let a = d.arrows[i]
            d.arrows[i].from = a.to
            d.arrows[i].to = a.from
            d.arrows[i].tunnelFrom = a.tunnelTo
            d.arrows[i].tunnelTo = a.tunnelFrom
            d.arrows[i].bend = nil
        }
    }

    public static func setArrowNote(_ m: inout IDEF0Model, diagramId: String, arrowId: String, note: String) {
        guard let i = m.diagrams[diagramId]?.arrowIndex(arrowId) else { return }
        m.updateDiagram(diagramId) { $0.arrows[i].note = note }
    }

    // MARK: Boxes

    /// Write a box's geometry as given, with no snap or clamp. No longer
    /// reachable from the app (S01: a box's place is the staircase's, and the
    /// inspector has no X/Y/W/H fields) — kept for tests and scripting. A
    /// typed X or Y can change reading order, so it renumbers before
    /// returning, as one step (F10); a pure width/height edit leaves the box
    /// where it is and never renumbers.
    public static func setBoxGeometry(_ m: inout IDEF0Model, diagramId: String, boxId: String,
                                      x: Double? = nil, y: Double? = nil, w: Double? = nil, h: Double? = nil) {
        guard let i = m.diagrams[diagramId]?.boxIndex(boxId) else { return }
        var movedPosition = false
        m.updateDiagram(diagramId) { d in
            if let x, x.isFinite { d.boxes[i].x = x; movedPosition = true }
            if let y, y.isFinite { d.boxes[i].y = y; movedPosition = true }
            if let w, w.isFinite { d.boxes[i].w = w }
            if let h, h.isFinite { d.boxes[i].h = h }
        }
        if movedPosition {
            m.updateDiagram(diagramId) { $0.renumberBoxes() }
            m.renumberNodes()
        }
    }

    public static func setBoxNote(_ m: inout IDEF0Model, diagramId: String, boxId: String, note: String) {
        guard let i = m.diagrams[diagramId]?.boxIndex(boxId) else { return }
        m.updateDiagram(diagramId) { $0.boxes[i].note = note }
    }

    /// Decompose a box into 3–6 child activities (§3.3.3 rule 4); returns the child diagram.
    @discardableResult
    public static func decompose(_ m: inout IDEF0Model, diagramId: String, boxId: String, count: Int) throws -> String {
        guard m.diagrams[diagramId]?.findBox(boxId) != nil else { throw Refusal.noSuchObject }
        let n = Swift.min(Sheet.decompMax, Swift.max(Sheet.decompMin, count))
        guard let child = m.decomposeBox(diagramId: diagramId, boxId: boxId, count: n) else { throw Refusal.noSuchObject }
        return child
    }

    public static func deleteDecomposition(_ m: inout IDEF0Model, childDiagramId: String) {
        m.deleteSubtree(childDiagramId)
    }

    // MARK: Diagrams

    /// Typing a title claims it; clearing it hands the diagram back to the name
    /// of the box it details.
    public static func setDiagramTitle(_ m: inout IDEF0Model, diagramId: String, title: String) {
        m.updateDiagram(diagramId) { d in
            d.title = title
            d.titleLocked = !jsTrim(title).isEmpty
        }
    }

    public static func setCNumber(_ m: inout IDEF0Model, diagramId: String, cNumber: String) {
        m.updateDiagram(diagramId) { $0.cNumber = cNumber }
    }

    // MARK: The model

    /// The model title also titles the A-0 diagram, and names its box if the
    /// box has no name yet. The web app sets that name without binding it to a
    /// concept; here it is bound, as every other naming path binds.
    public static func setModelTitle(_ m: inout IDEF0Model, title: String) {
        m.title = title
        let ctx = m.rootDiagramId
        m.updateDiagram(ctx) { $0.title = title }
        if let box = m.diagrams[ctx]?.boxes.first, box.name.isEmpty, !title.isEmpty {
            m.updateDiagram(ctx) { $0.boxes[0].name = title }
            m.bindBox(diagramId: ctx, boxId: box.id)
        }
    }

    // MARK: Concepts

    public static func setConceptKind(_ m: inout IDEF0Model, conceptId: String, kind: String) {
        guard let i = m.conceptIndex(conceptId) else { return }
        m.glossary[i].kind = kind
    }

    public static func defineConcept(_ m: inout IDEF0Model, conceptId: String, definition: String) {
        guard let i = m.conceptIndex(conceptId) else { return }
        m.glossary[i].definition = definition
    }

    /// Add a concept, or define an existing one of the same term. An existing
    /// term's definition is set only when the typed definition is non-blank
    /// (F15): the field being left blank must not wipe out a definition that
    /// concept already carries, and the typed kind is ignored for an existing
    /// term, as `resolveConcept` already documents.
    public static func addConcept(_ m: inout IDEF0Model, term: String, kind: String, definition: String) {
        guard let c = m.resolveConcept(term, kind: kind) else { return }
        let d = jsTrim(definition)
        if !d.isEmpty { defineConcept(&m, conceptId: c.id, definition: d) }
    }

    /// Only a concept nothing refers to can be removed; a used one is renamed
    /// or merged instead. The removal itself is the core's `removeConcept`
    /// (S01), the one place both apps delete a glossary entry: a bundle is
    /// un-combined (its members survive), a member is dropped from its
    /// bundle's list, and every entry matching the id exactly — by code
    /// units, as the web app's `filter((x) => x.id !== id)` — goes.
    public static func removeConcept(_ m: inout IDEF0Model, conceptId: String) throws {
        if m.isConceptUsed(conceptId) { throw Refusal.conceptInUse }
        guard m.removeConcept(conceptId) != nil else { throw Refusal.noSuchConcept }
    }

    // MARK: Bundles (S01, FIPS 183 §3.2.2.3)

    /// Combine two or more concepts into a new bundle named `term` — the
    /// core's `combineConcepts`, whose refusals (`BundleError`: fewer than
    /// two, an unknown id, one already in a bundle, a bundle inside itself)
    /// pass through for the caller to show. A blank term is refused here:
    /// the bundle's term is the label its general arrow carries, and an
    /// arrow with no label is what the checks report. Returns the bundle.
    @discardableResult
    public static func combineConcepts(_ m: inout IDEF0Model, memberIds: [String], term: String) throws -> Concept {
        if jsTrim(term).isEmpty { throw Refusal.blankTerm }
        return try m.combineConcepts(memberIds, term: term)
    }

    /// Dissolve a bundle — the core's `uncombineConcept`: its members stand
    /// on their own again (and join any outer bundle), and the entry goes —
    /// unless a box or arrow is bound to the bundle itself (one drawn from
    /// its port), when it stays as a plain concept rather than leaving that
    /// arrow dangling. Nothing bound to a member changes, so the diagrams
    /// read as they did before, and nothing needs confirming. Refused
    /// (`BundleError.notABundle`) for anything that is not a bundle.
    @discardableResult
    public static func uncombineConcept(_ m: inout IDEF0Model, bundleId: String) throws -> Concept {
        try m.uncombineConcept(bundleId)
    }

    /// The default term "Combine Selected" offers (S01): the members' terms
    /// joined by " & ", in the order given.
    public static func defaultBundleTerm(_ m: IDEF0Model, memberIds: [String]) -> String {
        memberIds.compactMap { m.conceptById($0)?.term }.joined(separator: " & ")
    }
}
