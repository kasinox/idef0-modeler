// Structural operations on the model — the bottom half of src/model/model.js:
// box and node numbering, ICOM coding, decomposition and structural edits.
//
// The web app mutates shared object references; here every edit goes through
// ids, re-reading the model after each step so that a change made by one step
// (a recursive delete clearing a box's childDiagramId, say) is seen by the
// next exactly as a live JavaScript reference would see it.

import Foundation

// MARK: - Numbering

/// FIPS 183 §3.3.4.1: boxes on the staircase run are numbered in order from
/// the upper left; "if off-diagonal boxes are also used, the numbering
/// sequence starts with the on-diagonal boxes and then continues, from the
/// lower right, in counter-clockwise order."
public func boxReadingOrder(_ boxes: [Box]) -> [Box] {
    readingOrderIndices(boxes).map { boxes[$0] }
}

/// The reading order as indices into `boxes`, so renumbering can write back to
/// each box even when a malformed file gives two boxes the same id.
private func readingOrderIndices(_ boxes: [Box]) -> [Int] {
    let all = Array(boxes.indices)
    if boxes.count < 2 { return all }
    let onDiagonal = staircaseChain(boxes)
    // Keyed by id, as the web app's Set is: a box sharing an on-diagonal box's
    // id is left out of the order altogether.
    let onIds = Set(onDiagonal.map { JSStringKey(boxes[$0].id) })
    let off = all.filter { !onIds.contains(JSStringKey(boxes[$0].id)) }
    if off.isEmpty { return onDiagonal }

    let count = Double(boxes.count)
    let cx = boxes.reduce(0.0) { $0 + $1.x + $1.w / 2 } / count
    let cy = boxes.reduce(0.0) { $0 + $1.y + $1.h / 2 } / count
    // Angles measured with y pointing up, so counter-clockwise is increasing.
    // The sweep starts at the lower right, which is -45° in that frame.
    let start = -Double.pi / 4
    func sweep(_ i: Int) -> Double {
        let b = boxes[i]
        let ang = atan2(-(b.y + b.h / 2 - cy), b.x + b.w / 2 - cx)
        return (ang - start + Double.pi * 4).truncatingRemainder(dividingBy: Double.pi * 2)
    }
    return onDiagonal + off.stableSorted(comparing: { sweep($0) - sweep($1) })
}

/// The longest run of boxes advancing in both x and y — the staircase.
private func staircaseChain(_ boxes: [Box]) -> [Int] {
    // `(a.x - b.x) || (a.y - b.y)`: a zero (or NaN) x difference falls through to y.
    let pts = Array(boxes.indices).stableSorted(comparing: { a, b in
        let dx = boxes[a].x - boxes[b].x
        return dx != 0 && !dx.isNaN ? dx : boxes[a].y - boxes[b].y
    })
    var len = pts.map { _ in 1 }
    var prev = pts.map { _ in -1 }
    for i in pts.indices.dropFirst() {
        for j in 0..<i where boxes[pts[j]].y <= boxes[pts[i]].y && len[j] + 1 > len[i] {
            len[i] = len[j] + 1
            prev[i] = j
        }
    }
    var best = 0
    for i in pts.indices.dropFirst() where len[i] > len[best] { best = i }
    var chain: [Int] = []
    var i = best
    while i >= 0 {
        chain.insert(pts[i], at: 0)
        i = prev[i]
    }
    return chain
}

extension Diagram {
    /// `renumberBoxes(diagram)`: numbers boxes in the order FIPS 183 §3.3.4.1
    /// lays down. The single box of an A-0 context diagram is always box 0.
    public mutating func renumberBoxes() {
        if node == "A-0" {
            for i in boxes.indices { boxes[i].number = 0 }
            return
        }
        for (n, i) in readingOrderIndices(boxes).enumerated() { boxes[i].number = n + 1 }
    }
}

extension IDEF0Model {
    /// `renumberNodes(m)`: re-derives every diagram's node number from the tree.
    /// Call after any move — a detail diagram's node is its parent box's node.
    public mutating func renumberNodes() {
        guard diagrams[rootDiagramId] != nil else { return }
        updateDiagram(rootDiagramId) { $0.node = "A-0" }
        var path = Set<JSStringKey>()
        renumberNodesWalk(rootDiagramId, &path)
    }

    private mutating func renumberNodesWalk(_ diagramId: String, _ path: inout Set<JSStringKey>) {
        path.insert(JSStringKey(diagramId))
        defer { path.remove(JSStringKey(diagramId)) }
        var i = 0
        // The diagram is re-read on every box, as the web app's live reference is.
        while let dg = diagrams[diagramId], i < dg.boxes.count {
            let b = dg.boxes[i]
            i += 1
            guard childDiagram(of: b) != nil, let childId = b.childDiagramId else { continue }
            // A box detailed by one of its own ancestors — a cycle only a
            // hand-edited or imported file can hold — is skipped: renumbering
            // that ancestor from below would rename it (A-0 itself, for a box
            // naming the root), and following the link would never end.
            if path.contains(JSStringKey(childId)) { continue }
            let node = boxNode(dg, b)
            updateDiagram(childId) { child in
                child.node = node
                // A child diagram is titled after the box it details, but only
                // until somebody titles it themselves.
                if !child.titleLocked { child.title = b.name.isEmpty ? child.title : b.name }
            }
            renumberNodesWalk(childId, &path)
        }
    }
}

/// `staircaseLayout(n)`: `n` boxes along the staircase diagonal IDEF0
/// conventionally uses.
///
/// The box size is derived from how many have to fit, so that the step along
/// the diagonal always exceeds the box itself: at the six boxes FIPS 183
/// allows, fixed box dimensions would overlap their neighbours.
public func staircaseLayout(_ n: Int) -> [SheetRect] {
    let gapX = 20.0, gapY = 14.0
    let extentX = Sheet.work.w - 120          // 60 units of margin either side
    let extentY = Sheet.work.h - 130          // 40 above, 90 below
    let count = Double(n)
    let bw = max(Sheet.boxMin.w, min(Sheet.boxDefault.w, ((extentX - (count - 1) * gapX) / count).rounded(.down)))
    let bh = max(Sheet.boxMin.h, min(Sheet.boxDefault.h, ((extentY - (count - 1) * gapY) / count).rounded(.down)))
    let spanX = extentX - bw
    let spanY = extentY - bh
    var out: [SheetRect] = []
    var i = 0
    while i < n {
        let t = n == 1 ? 0.5 : Double(i) / Double(n - 1)
        out.append(SheetRect(
            x: jsRound(Sheet.work.x + 60 + spanX * t),
            y: jsRound(Sheet.work.y + 40 + spanY * t),
            w: bw, h: bh
        ))
        i += 1
    }
    return out
}

// MARK: - ICOM coding

/// One boundary end of an arrow on a child diagram.
public struct BoundaryEnd: Hashable, Sendable {
    public var arrow: Arrow
    public var end: ArrowEnd
    public var pos: Double
    public init(arrow: Arrow, end: ArrowEnd, pos: Double) {
        self.arrow = arrow; self.end = end; self.pos = pos
    }
}

/// `isIcomEnd(a, which, side)`: whether a boundary end of an arrow can carry
/// an ICOM code.
///
/// FIPS 183 §3.3.2.7–8: a boundary arrow enters the diagram on the left, top
/// or bottom (its `from` end) and leaves it on the right (its `to` end); an end
/// running the other way corresponds to nothing on the parent box. A call
/// arrow's end never counts: it leaves a box bottom to name a called box, not
/// an arrow on the parent (§3.3.2.10), just as `parentBoxArrows` gives it no
/// code. The role test is the web app's `arrowRole`: `from` on a box bottom
/// and `to` not on a box.
private func isIcomEnd(_ a: Arrow, _ end: ArrowEnd, _ side: Side) -> Bool {
    if a.role == .call { return false }
    return side == .right ? end == .to : end == .from
}

extension Diagram {
    /// `boundaryArrowsBySide(diagram)`: boundary ends grouped by side and
    /// ordered for ICOM coding.
    ///
    /// Only ends that can carry a code are collected (see `isIcomEnd`).
    /// Tunnelled ends are left out too unless asked for. FIPS 183 §3.3.2.9: an
    /// arrow tunnelled at its unconnected end "does not have an ICOM code",
    /// because it has no counterpart on the parent — and leaving it in would
    /// consume an ordinal and shift the codes of the arrows beside it.
    public func boundaryArrowsBySide(includeTunnelled: Bool = false) -> [Side: [BoundaryEnd]] {
        var groups: [Side: [BoundaryEnd]] = [.left: [], .top: [], .right: [], .bottom: []]
        for a in arrows {
            for end in ArrowEnd.allCases {
                let e = a[end]
                if e.kind != .boundary { continue }
                if !isIcomEnd(a, end, e.side) { continue }
                if !includeTunnelled && a.isTunnelled(end) { continue }
                groups[e.side, default: []].append(BoundaryEnd(arrow: a, end: end, pos: e.pos))
            }
        }
        for side in Side.allCases { groups[side] = (groups[side] ?? []).stableSorted { $0.pos < $1.pos } }
        return groups
    }
}

/// An arrow on a parent box with the ICOM code its position gives it.
/// `tunnelled` is set when the arrow is tunnelled where it meets the box: it
/// keeps its code but is not shown on the child (§3.3.2.9, Figure 18).
///
/// Arrows on one side that denote the same concept are one fork or join and
/// share an entry: `arrow` is the lowest of them, `arrows` every member, and
/// the entry is `tunnelled` only if every member is.
public struct ParentArrow: Hashable, Sendable {
    public var arrow: Arrow
    public var arrows: [Arrow]
    public var pos: Double
    public var code: String
    public var tunnelled: Bool
    public init(arrow: Arrow, pos: Double, code: String, tunnelled: Bool = false, arrows: [Arrow]? = nil) {
        self.arrow = arrow; self.pos = pos; self.code = code; self.tunnelled = tunnelled
        self.arrows = arrows ?? [arrow]
    }
}

extension IDEF0Model {
    /// `parentBoxArrows(m, parentDg, box)`: the arrows on a box of `parentDg`,
    /// per side, each carrying its ICOM code.
    ///
    /// FIPS 183 §3.3.2.8: the letter is the role the arrow plays *on the parent
    /// box*, and the number "the relative position at which the arrow is shown
    /// connecting to the parent box". The code belongs to the parent, never to
    /// the child sheet. An arrow tunnelled where it meets the box keeps its
    /// code — §3.3.2.9: "because this arrow does correspond to one on its
    /// parent diagram, it is given an ICOM code" — it is merely not shown on
    /// the child, so Figure 18 has C1 and C3 with C2 tunnelled; such an entry is
    /// flagged `tunnelled` so the pairing can leave it alone without
    /// renumbering its neighbours. A call arrow leaving the bottom is not
    /// ICOM-coded at all (§3.3.2.10).
    ///
    /// Arrows on one side that denote the same concept are one arrow forked or
    /// joined at the box (§3.3.3 rule 14): they connect at one ICOM position,
    /// so they share one entry and one code, numbered by the lowest of them.
    /// "The same concept" is the *effective* concept (`effectiveConceptId`):
    /// two arrows whose specific concepts are members of one bundle are that
    /// bundle forked at the box (§3.2.2.3), so they too share one position and
    /// one code. An arrow bound to no concept is always an entry of its own.
    public func parentBoxArrows(_ parentDg: Diagram, _ boxId: String) -> [Side: [ParentArrow]] {
        var sides: [Side: [(arrow: Arrow, pos: Double, tunnelled: Bool)]] = [.left: [], .top: [], .right: [], .bottom: []]
        for a in parentDg.arrows {
            if a.to.isOnBox(boxId) {
                sides[a.to.side, default: []].append((a, a.to.pos, a.tunnelTo))
            }
            if a.from.isOnBox(boxId) && a.from.side != .bottom {
                sides[a.from.side, default: []].append((a, a.from.pos, a.tunnelFrom))
            }
        }
        var out: [Side: [ParentArrow]] = [:]
        for side in Side.allCases {
            let sorted = (sides[side] ?? []).stableSorted { $0.pos < $1.pos }
            var entries: [ParentArrow] = []
            var byConcept: [JSStringKey: Int] = [:]
            for e in sorted {
                let id = effectiveKey(e.arrow.conceptId)
                if let id, let k = byConcept[id] {
                    entries[k].arrows.append(e.arrow)
                    entries[k].tunnelled = entries[k].tunnelled && e.tunnelled
                    continue
                }
                if let id { byConcept[id] = entries.count }
                entries.append(ParentArrow(arrow: e.arrow, pos: e.pos, code: "", tunnelled: e.tunnelled))
            }
            for i in entries.indices { entries[i].code = "\(side.icomLetter)\(i + 1)" }
            out[side] = entries
        }
        return out
    }

    /// `id ? effectiveConceptId(m, id) : null`, as a map key: the concept an
    /// arrow's ICOM position stands for, nil for an unbound arrow.
    private func effectiveKey(_ id: String?) -> JSStringKey? {
        guard let id, !id.isEmpty else { return nil }
        return JSStringKey(effectiveConceptId(id) ?? id)
    }
}

/// A child boundary end matched to the parent arrow it continues.
public struct ICOMPair: Hashable, Sendable {
    public var side: Side
    public var child: BoundaryEnd
    public var parent: ParentArrow
    public var code: String
    public init(side: Side, child: BoundaryEnd, parent: ParentArrow, code: String) {
        self.side = side; self.child = child; self.parent = parent; self.code = code
    }
}

/// A child boundary end with no counterpart on the parent box.
public struct ICOMOrphan: Hashable, Sendable {
    public var side: Side
    public var child: BoundaryEnd
    public init(side: Side, child: BoundaryEnd) { self.side = side; self.child = child }
}

/// A parent box arrow with no counterpart on the child diagram.
public struct ICOMMissing: Hashable, Sendable {
    public var side: Side
    public var parent: ParentArrow
    public init(side: Side, parent: ParentArrow) { self.side = side; self.parent = parent }
}

/// `icomPairing(m, child)`'s result. `parent` is nil for a diagram that
/// details no box — the context diagram.
public struct ICOMPairing: Hashable, Sendable {
    public var pairs: [ICOMPair]
    public var orphans: [ICOMOrphan]
    public var missing: [ICOMMissing]
    public var parent: BoxLocation?
    public init(pairs: [ICOMPair] = [], orphans: [ICOMOrphan] = [], missing: [ICOMMissing] = [], parent: BoxLocation? = nil) {
        self.pairs = pairs; self.orphans = orphans; self.missing = missing; self.parent = parent
    }
}

/// `normLabel(v)`: trimmed, whitespace collapsed, lower-cased.
private func icomNormLabel(_ s: String) -> String {
    jsLowercase(jsCollapseWhitespace(jsTrim(s)))
}

extension IDEF0Model {
    /// `icomPairing(m, child)`: pairs a child diagram's boundary ends with the
    /// arrows on its parent box. Correspondence is found side for side, by
    /// concept first, then by label, then by remaining position — so an arrow
    /// keeps its code when it is reordered, and when a child elaborates its
    /// label (§3.3.2.4).
    ///
    /// Several child ends denoting the concept of one parent entry are a fork
    /// or a join drawn as separate arrows (§3.3.3 rule 14); they all take that
    /// entry's code. That is settled straight after the concept pass, so a
    /// duplicate can never take another arrow's code by label or position.
    ///
    /// Roles may differ between parent and child for inputs, controls and
    /// mechanisms (§3.3.2.8, Figure 15: a parent control entering the child
    /// from the left). So a child end on the left, top or bottom left unmatched
    /// on its own side pairs, by concept alone, with a parent arrow of the same
    /// concept on another of those sides, and keeps the parent's code ("C1" on
    /// the left edge). Outputs never change role. This rescue runs last, so it
    /// only ever turns an orphan into a pair; issue order is unchanged for a
    /// model that needs none. A pair's `side` is the child end's side, a
    /// missing entry's the parent's.
    ///
    /// One pairing serves both the codes that get drawn and the consistency
    /// check, so the two can never disagree.
    ///
    /// A parent arrow tunnelled at the box is not shown on the child
    /// (§3.3.2.9), so it is neither paired nor reported missing; it keeps its
    /// code all the same.
    ///
    /// Concepts are compared by their effective id (`effectiveConceptId`): a
    /// child end bound to one member of a bundle pairs with a parent entry
    /// bound to another member of it, the way the parent's own position
    /// already stands for the whole bundle (see `parentBoxArrows`).
    public func icomPairing(_ child: Diagram) -> ICOMPairing {
        var out = ICOMPairing()
        let childEnds = child.boundaryArrowsBySide()
        guard let parent = parentOf(child) else {
            for side in Side.allCases {
                for c in childEnds[side] ?? [] { out.orphans.append(ICOMOrphan(side: side, child: c)) }
            }
            return out
        }
        out.parent = parent
        let parentSides = diagrams[parent.diagramId].map { parentBoxArrows($0, parent.box.id) } ?? [:]

        /// One side's pairing state: a child index maps to the parent side and
        /// index it pairs with.
        struct SideState {
            var P: [ParentArrow]
            var C: [BoundaryEnd]
            var usedP = Set<Int>()
            var matched: [Int: (side: Side, index: Int)] = [:]
        }
        func sameConcept(_ c: BoundaryEnd, _ pe: ParentArrow) -> Bool {
            guard let id = c.arrow.conceptId, !id.isEmpty else { return false }
            return jsStrictEquals(effectiveConceptId(id), effectiveConceptId(pe.arrow.conceptId))
        }

        var state: [Side: SideState] = [:]
        for side in Side.allCases {
            var st = SideState(P: (parentSides[side] ?? []).filter { !$0.tunnelled }, C: childEnds[side] ?? [])

            func pass(_ test: (BoundaryEnd, ParentArrow) -> Bool) {
                for (ci, c) in st.C.enumerated() where st.matched[ci] == nil {
                    if let pi = st.P.indices.first(where: { !st.usedP.contains($0) && test(c, st.P[$0]) }) {
                        st.usedP.insert(pi)
                        st.matched[ci] = (side, pi)
                    }
                }
            }
            pass(sameConcept)
            // Forks and joins: further ends of a concept already paired share its code.
            for (ci, c) in st.C.enumerated() where st.matched[ci] == nil {
                if let pi = st.P.indices.first(where: { st.usedP.contains($0) && sameConcept(c, st.P[$0]) }) {
                    st.matched[ci] = (side, pi)
                }
            }
            pass { c, pe in
                let label = icomNormLabel(c.arrow.label)
                return !label.isEmpty && jsStrictEquals(label, icomNormLabel(pe.arrow.label))
            }

            let leftC = st.C.indices.filter { st.matched[$0] == nil }
            let leftP = st.P.indices.filter { !st.usedP.contains($0) }
            for (n, ci) in leftC.enumerated() where n < leftP.count {
                st.usedP.insert(leftP[n])
                st.matched[ci] = (side, leftP[n])
            }
            state[side] = st
        }

        // Role changes (§3.3.2.8): an unmatched input, control or mechanism end
        // takes an unmatched parent arrow of its concept on another of those
        // sides, and failing that one already paired there (a fork that
        // changes role).
        let roleSides: [Side] = [.left, .top, .bottom]
        for used in [false, true] {
            for side in roleSides {
                let C = state[side]!.C
                for (ci, c) in C.enumerated() where state[side]!.matched[ci] == nil {
                    guard let id = c.arrow.conceptId, !id.isEmpty else { continue }
                    for ps in roleSides where ps != side {
                        let P = state[ps]!.P
                        if let pi = P.indices.first(where: {
                            state[ps]!.usedP.contains($0) == used
                                && jsStrictEquals(effectiveConceptId(id), effectiveConceptId(P[$0].arrow.conceptId))
                        }) {
                            state[ps]!.usedP.insert(pi)
                            state[side]!.matched[ci] = (ps, pi)
                            break
                        }
                    }
                }
            }
        }

        for side in Side.allCases {
            let st = state[side]!
            for (ci, c) in st.C.enumerated() {
                if let m = st.matched[ci] {
                    let pe = state[m.side]!.P[m.index]
                    out.pairs.append(ICOMPair(side: side, child: c, parent: pe, code: pe.code))
                } else {
                    out.orphans.append(ICOMOrphan(side: side, child: c))
                }
            }
            for (k, pe) in st.P.enumerated() where !st.usedP.contains(k) {
                out.missing.append(ICOMMissing(side: side, parent: pe))
            }
        }
        return out
    }

    /// `icomCodes(m, diagram)`: `"arrowId:from"` / `"arrowId:to"` -> ICOM code.
    /// Empty for a context diagram, which has no parent to be coded against
    /// (§3.4.2).
    ///
    /// Keyed by a plain Swift `String`, so two arrow ids that differ only in
    /// Unicode normalisation share one entry here, unlike `icomPairing` itself
    /// and `exactIcomCodes` below. Kept this way for source compatibility with
    /// existing callers (the inspector, the parity tests); a caller that needs
    /// the codes to stay apart for such a twin uses `exactIcomCodes` instead.
    public func icomCodes(_ diagram: Diagram) -> [String: String] {
        var out: [String: String] = [:]
        for p in icomPairing(diagram).pairs {
            out["\(p.child.arrow.id):\(p.child.end.rawValue)"] = p.code
        }
        return out
    }

    /// `icomCodes(m, diagram)` keyed as the web app's object is — by code
    /// units — so two arrow ids that differ only in Unicode normalisation keep
    /// their own codes. Internal: used where exact identity matters (the XML
    /// and IDL export, the report) rather than through the public,
    /// canonically-merged `icomCodes(_:)` above.
    func exactIcomCodes(_ diagram: Diagram) -> [JSStringKey: String] {
        var out: [JSStringKey: String] = [:]
        for p in icomPairing(diagram).pairs {
            out[JSStringKey("\(p.child.arrow.id):\(p.child.end.rawValue)")] = p.code
        }
        return out
    }

    /// `ports(m, diagram)`: the parent box's ICOM concepts not yet (or no
    /// longer) connected to any activity on `diagram` — one per
    /// `icomPairing(diagram).missing` entry, in that order. `side` is the child
    /// edge the concept enters or leaves by (left = I, top = C, bottom = M,
    /// right = O), `pos` the parent arrow's position at the box, and
    /// `conceptId`/`label` those of the entry's representative arrow (the
    /// lowest of a fork, join or bundle). A port is drawn at the sheet edge
    /// (`portShape`) and is where an arrow for that concept starts; it is
    /// derived, never stored, and the context diagram, which has no parent,
    /// has none. Each is still the `icom-missing` error, because FIPS 183
    /// requires the match before the model is done — a port is merely the way
    /// to fix it.
    public func ports(_ diagram: Diagram) -> [ICOMPort] {
        let p = icomPairing(diagram)
        guard p.parent != nil else { return [] }
        return p.missing.map { ms in
            // A bundled ICOM entry is one port for the whole bundle: it carries
            // the bundle's term and id, so connecting it draws the general
            // arrow (FIPS 183 §3.2.2.3) and pairs by effective concept. A
            // member can still be drawn on its own afterwards, from the glossary.
            let cid = ms.parent.arrow.conceptId
            let eff = effectiveConceptId(cid)
            let bundle: Concept? = {
                guard let eff, !jsStrictEquals(eff, cid) else { return nil }
                return conceptById(eff)
            }()
            return ICOMPort(side: ms.side, pos: ms.parent.pos, code: ms.parent.code, label: bundle?.term ?? ms.parent.arrow.label,
                            conceptId: bundle?.id ?? cid, parentArrowId: ms.parent.arrow.id, role: ms.side.role)
        }
    }
}

/// A parent-box ICOM concept awaiting an arrow on the child diagram — the web
/// app's `{ side, pos, code, label, conceptId, parentArrowId, role }`.
public struct ICOMPort: Hashable, Sendable {
    public var side: Side
    public var pos: Double
    public var code: String
    public var label: String
    public var conceptId: String?
    public var parentArrowId: String
    public var role: Role
    public init(side: Side, pos: Double, code: String, label: String, conceptId: String?, parentArrowId: String, role: Role) {
        self.side = side; self.pos = pos; self.code = code; self.label = label
        self.conceptId = conceptId; self.parentArrowId = parentArrowId; self.role = role
    }
}

// MARK: - Layout

extension Diagram {
    /// The box indices in number order, stable — `sortedBoxes` as positions
    /// to write back through.
    var sortedIndices: [Int] { boxes.indices.stableSorted { boxes[$0].number < boxes[$1].number } }

    /// `layoutBoxes(diagram)`: lays the boxes out along the staircase, in
    /// box-number order — the i-th box by number takes the i-th
    /// `staircaseLayout(n)` rectangle (x, y, w, h). Pure geometry: numbers
    /// are left as they are, so a diagram whose numbers a hand-edited file
    /// left with gaps still reads in its own order. The A-0 context diagram is
    /// never laid out: its single box stays where it is. Called by every
    /// structural edit and by the "Arrange" action, never on load.
    public mutating func layoutBoxes() {
        if node == "A-0" { return }
        let order = sortedIndices
        if order.isEmpty { return }
        let rects = staircaseLayout(order.count)
        for (i, k) in order.enumerated() {
            boxes[k].x = rects[i].x
            boxes[k].y = rects[i].y
            boxes[k].w = rects[i].w
            boxes[k].h = rects[i].h
        }
    }

    /// `settleBoxes(diagram)`: the tail of every structural edit below A-0 —
    /// numbers compacted to 1..n in the surviving number order (stable, so two
    /// boxes sharing a number keep their array order), then the staircase.
    /// A-0 only renumbers, to 0.
    mutating func settleBoxes() {
        if node == "A-0" { renumberBoxes(); return }
        for (n, k) in sortedIndices.enumerated() { boxes[k].number = n + 1 }
        layoutBoxes()
    }
}

// MARK: - Decomposition

extension IDEF0Model {
    /// `decomposeBox(m, parentDiagram, box, count)`: creates the detail diagram
    /// for a box, seeded with `count` unnamed staircase boxes and no arrows.
    /// The parent box's ICOM arrows are not copied down: the child starts with
    /// a port for each of them (see `ports`), drawn at the sheet edge until the
    /// modeller connects it to an activity, and each is reported as
    /// `icom-missing` until then. A call arrow (leaving the bottom) has no
    /// counterpart at all: FIPS 183 §3.3.2.10 says a caller box is detailed by
    /// another box entirely, not by a child diagram of its own. Returns the
    /// child diagram's id — the existing one if the box is already decomposed.
    @discardableResult
    public mutating func decomposeBox(diagramId: String, boxId: String, count: Int = 3) -> String? {
        guard let parent = diagrams[diagramId], let boxIndex = parent.boxIndex(boxId) else { return nil }
        let box = parent.boxes[boxIndex]
        if let existing = box.childDiagramId, !existing.isEmpty {
            return diagrams[existing] == nil ? nil : existing
        }

        let node = boxNode(parent, box)
        var child = newDiagram(node: node, title: box.name.isEmpty ? node : box.name, parentBoxId: box.id)
        for (i, rect) in staircaseLayout(count).enumerated() {
            child.boxes.append(newBox(name: "", number: i + 1, x: rect.x, y: rect.y, w: rect.w, h: rect.h))
        }
        return attach(child, toBoxAt: boxIndex, in: diagramId)
    }

    private mutating func attach(_ child: Diagram, toBoxAt boxIndex: Int, in diagramId: String) -> String {
        diagrams[child.id] = child
        updateDiagram(diagramId) { $0.boxes[boxIndex].childDiagramId = child.id }
        renumberNodes()
        return child.id
    }

    /// `deleteSubtree(m, diagramId)`: deletes a diagram and everything below it,
    /// and unhooks it from the box it details. The context diagram stays.
    public mutating func deleteSubtree(_ diagramId: String) {
        var path = Set<JSStringKey>()
        deleteSubtreeWalk(diagramId, &path)
    }

    private mutating func deleteSubtreeWalk(_ diagramId: String, _ path: inout Set<JSStringKey>) {
        // A diagram already being deleted further up is a decomposition
        // cycle; it is not entered again.
        guard diagrams[diagramId] != nil, !jsStrictEquals(diagramId, rootDiagramId), !path.contains(JSStringKey(diagramId)) else { return }
        path.insert(JSStringKey(diagramId))
        defer { path.remove(JSStringKey(diagramId)) }
        var i = 0
        // Re-read each box: a deletion below may already have cleared its link.
        while let dg = diagrams[diagramId], i < dg.boxes.count {
            if let c = dg.boxes[i].childDiagramId, !c.isEmpty { deleteSubtreeWalk(c, &path) }
            i += 1
        }
        if let parent = parentOf(diagrams[diagramId]), let idx = diagrams[parent.diagramId]?.boxIndex(parent.box.id) {
            updateDiagram(parent.diagramId) { $0.boxes[idx].childDiagramId = nil }
        }
        diagrams.removeValue(forKey: diagramId)
    }
}

// MARK: - Editing

extension IDEF0Model {
    /// `addBox(m, diagram)`: appends an unnamed box as number n+1, then lays
    /// the diagram out (`layoutBoxes`) and renumbers nodes. Where a box goes is
    /// never the caller's to say: the staircase decides. On A-0 — reachable
    /// only to repair a file whose context diagram has lost its box — the box
    /// takes the first grid cell and number 0, and nothing is laid out.
    /// Returns the new box as numbered.
    @discardableResult
    public mutating func addBox(diagramId: String) -> Box? {
        guard let diagram = diagrams[diagramId] else { return nil }
        let n = diagram.boxes.count
        let box = newBox(
            name: "",
            number: n + 1,
            x: Sheet.work.x + 60 + Double(n % 3) * 210,
            y: Sheet.work.y + 40 + Double(n / 3) * 150
        )
        updateDiagram(diagramId) { d in
            d.boxes.append(box)
            d.settleBoxes()
        }
        renumberNodes()
        return diagrams[diagramId]?.boxes.last
    }

    /// `removeBox(m, diagram, boxId)`: removes a box with its detail subtree and
    /// every arrow touching it, compacts the survivors' numbers to 1..n in
    /// their number order, lays them out and renumbers nodes.
    public mutating func removeBox(diagramId: String, boxId: String) {
        guard let box = diagrams[diagramId]?.findBox(boxId) else { return }
        if let c = box.childDiagramId, !c.isEmpty { deleteSubtree(c) }
        updateDiagram(diagramId) { d in
            d.boxes = d.boxes.filter { !jsStrictEquals($0.id, boxId) }
            d.arrows = d.arrows.filter { !$0.from.isOnBox(boxId) && !$0.to.isOnBox(boxId) }
            d.settleBoxes()
        }
        renumberNodes()
    }

    /// `moveBox(m, diagram, boxId, by)`: moves a box one step earlier (`by` =
    /// -1) or later (`by` = +1) in the reading order — it swaps numbers with
    /// its neighbour in number order, numbers are compacted to 1..n, the
    /// diagram is laid out again and node numbers follow. Returns false,
    /// changing nothing, when there is no such diagram or box, no neighbour
    /// that way (the first box cannot move earlier), `by` is not ±1, or the
    /// diagram is A-0.
    @discardableResult
    public mutating func moveBox(diagramId: String, boxId: String, by: Int) -> Bool {
        guard let diagram = diagrams[diagramId], diagram.node != "A-0", by == -1 || by == 1 else { return false }
        let order = diagram.sortedIndices
        guard let i = order.firstIndex(where: { jsStrictEquals(diagram.boxes[$0].id, boxId) }) else { return false }
        let j = i + by
        guard j >= 0, j < order.count else { return false }
        updateDiagram(diagramId) { d in
            let t = d.boxes[order[i]].number
            d.boxes[order[i]].number = d.boxes[order[j]].number
            d.boxes[order[j]].number = t
            d.settleBoxes()
        }
        renumberNodes()
        return true
    }
}

extension Diagram {
    /// `removeArrow(diagram, arrowId)`.
    public mutating func removeArrow(_ arrowId: String) {
        arrows = arrows.filter { !jsStrictEquals($0.id, arrowId) }
    }

    /// `freePos(diagram, endpointMatch)`: a position along a side that keeps
    /// clear of the endpoints `matches` accepts, trying halves, then thirds,
    /// and so on up to tenths; 0.5 when every candidate is taken.
    public func freePos(where matches: (Endpoint) -> Bool) -> Double {
        var used: [Double] = []
        for a in arrows {
            for e in [a.from, a.to] where matches(e) { used.append(e.pos) }
        }
        for n in 1...9 {
            for i in 1...n {
                let p = Double(i) / Double(n + 1)
                if !used.contains(where: { abs($0 - p) < 0.06 }) { return p }
            }
        }
        return 0.5
    }
}
