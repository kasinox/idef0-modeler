// One IDEF0 diagram as a display list — a port of src/ui/render.js.
//
// The web app draws the screen and every export (SVG, PNG, PDF) through one
// renderer, so what you see is what you ship. This keeps that property on the
// Mac: the editing canvas, the PNG/PDF writer and the SVG writer all consume
// the same `[DrawOp]`, produced here from the model with no platform code.
//
// Coordinates are sheet units with the origin at the top left and y down.

public struct RGBA: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// From a 24-bit hex value, as the web app's stylesheet writes colours.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    public var hexString: String {
        let c = { (v: Double) in String(format: "%02x", Int((v * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b)
    }

    public static let white = RGBA(hex: 0xFFFFFF)
    public static let ink = RGBA(hex: 0x111418)
    public static let frameLabel = RGBA(hex: 0x444C56)
    public static let muted = RGBA(hex: 0x5B6470)
    public static let placeholder = RGBA(hex: 0x8A929C)
    public static let icom = RGBA(hex: 0x1F5FA9)
    /// Selection colour on the editing canvas; exports never use it.
    public static let accent = RGBA(hex: 0x2563EB)
}

public enum FontFace: String, Hashable, Sendable { case sans, mono }
public enum FontWeight: String, Hashable, Sendable { case regular, semibold, bold }
public enum TextAnchor: String, Hashable, Sendable { case start, middle, end }
public enum TextBaseline: String, Hashable, Sendable { case alphabetic, middle }

public struct TextStyle: Hashable, Sendable {
    public var size: Double
    public var face: FontFace = .sans
    public var weight: FontWeight = .regular
    public var italic = false
    public var color: RGBA = .ink
    public var anchor: TextAnchor = .start
    public var baseline: TextBaseline = .alphabetic
    /// Extra tracking, in ems.
    public var letterSpacing: Double = 0
    /// Width of a white stroke painted behind the glyphs, so a label stays
    /// legible where it crosses a line (`paint-order: stroke`).
    public var halo: Double? = nil

    public init(size: Double, face: FontFace = .sans, weight: FontWeight = .regular, italic: Bool = false,
                color: RGBA = .ink, anchor: TextAnchor = .start, baseline: TextBaseline = .alphabetic,
                letterSpacing: Double = 0, halo: Double? = nil) {
        self.size = size; self.face = face; self.weight = weight; self.italic = italic; self.color = color
        self.anchor = anchor; self.baseline = baseline; self.letterSpacing = letterSpacing; self.halo = halo
    }
}

public struct StrokeStyle: Hashable, Sendable {
    public var color: RGBA
    public var width: Double
    public var dash: [Double] = []
    public var roundJoins = false
    public init(color: RGBA, width: Double, dash: [Double] = [], roundJoins: Bool = false) {
        self.color = color; self.width = width; self.dash = dash; self.roundJoins = roundJoins
    }
}

/// What a drawn element belongs to, so a canvas can highlight or hit-test by
/// model identity without re-deriving it from geometry.
public enum DrawRole: Hashable, Sendable {
    case sheet
    case box(String)
    case arrow(String)
    case arrowLabel(String)
    case icom(String)
    /// A port (S01) — a parent concept not yet connected on this diagram —
    /// by the id of the parent arrow it stands for (`ICOMPort.parentArrowId`),
    /// the web app's `data-port`.
    case port(String)
}

public enum DrawOp: Hashable, Sendable {
    case rect(SheetRect, fill: RGBA?, stroke: StrokeStyle?, role: DrawRole)
    case line(from: Point, to: Point, stroke: StrokeStyle, role: DrawRole)
    case path([PathCommand], fill: RGBA?, stroke: StrokeStyle?, role: DrawRole)
    case text(String, at: Point, style: TextStyle, role: DrawRole)
    /// A circle by its centre and radius — the web app's `<circle>`; a port's
    /// open ring is the one use.
    case circle(center: Point, radius: Double, fill: RGBA?, stroke: StrokeStyle?, role: DrawRole)
}

/// One arrow as `SheetDrawing.drawnArrows` decides it is drawn: with `label`
/// as its text, standing for the `hidden` arrows (by id) that draw nothing;
/// `drawn` the arrow as it is routed (S02: its grouped ends moved onto the
/// group's representative) and `pts` that route; `fork`/`join` the id of the
/// representative of the fork (`from` face) or join (`to` face) group it
/// belongs to — its own id when it is the representative — or nil;
/// `forkTrunk`/`joinTrunk` the run every member of that group shares; and
/// `labelPath` the part of the route its label is placed against, or nil
/// when it draws no label. The web app's `drawnArrows` entry, field for field.
public struct DrawnArrow: Hashable, Sendable {
    public var arrow: Arrow
    public var label: String
    public var hidden: [String]
    public var drawn: Arrow
    public var pts: [Point]
    public var fork: String?
    public var join: String?
    public var forkTrunk: [Point]?
    public var joinTrunk: [Point]?
    public var labelPath: [Point]?

    public init(arrow: Arrow, label: String, hidden: [String] = []) {
        self.arrow = arrow; self.label = label; self.hidden = hidden
        drawn = arrow; pts = []
    }

    /// Whether this is a fork member other than its representative — its
    /// `from` end is the trunk's, drawn once by the representative.
    public var isForkBranch: Bool { fork.map { !jsStrictEquals($0, arrow.id) } ?? false }
    /// The same at the `to` end: a join member other than its representative.
    public var isJoinBranch: Bool { join.map { !jsStrictEquals($0, arrow.id) } ?? false }
}

public struct DrawingOptions: Hashable, Sendable {
    /// The box or arrow to draw in the accent colour. Always nil for export.
    public var selectedBoxId: String?
    public var selectedArrowId: String?
    public init(selectedBoxId: String? = nil, selectedArrowId: String? = nil) {
        self.selectedBoxId = selectedBoxId
        self.selectedArrowId = selectedArrowId
    }
    public static let export = DrawingOptions()
}

public enum SheetDrawing {
    static let frameStroke = StrokeStyle(color: .ink, width: 1.4)
    static let thinStroke = StrokeStyle(color: .ink, width: 0.8)
    static let frameLabel = TextStyle(size: 8, color: .frameLabel, letterSpacing: 0.04)
    static let frameValue = TextStyle(size: 10.5)
    static let frameValueBig = TextStyle(size: 13, weight: .semibold)
    static let arrowHeadLength = 11.0
    static let arrowHeadHalfWidth = 4.6

    /// `renderDiagram(model, diagram)`: the sheet form, then every arrow's
    /// strokes, then every box, then every arrow's label and ICOM codes (F60)
    /// — so a label that overlaps a box paints on top of its fill instead of
    /// being erased by it — and last the ports. Only the arrows `drawnArrows`
    /// lists are drawn: a bundle's representative stands for its hidden
    /// members (S01).
    public static func build(_ model: IDEF0Model, diagramId: String, options: DrawingOptions = .export) -> [DrawOp] {
        guard let diagram = model.diagrams[diagramId] else { return [] }
        var ops = frame(model, diagram)
        let codes = model.icomCodes(diagram)
        let drawn = drawnArrows(model, diagram)
        let obstacles = diagram.boxes.map(\.rect)
        // Computed once for the whole diagram (F59): every arrow's
        // `labelPlacement` call scores against the same ICOM-code rectangles
        // this pass is about to draw, rather than each recomputing its own
        // partial view of them.
        let icomEnds = icomRects(drawn, codes: codes)
        var strokeOps: [DrawOp] = []
        var annotationOps: [DrawOp] = []
        for entry in drawn {
            let (strokes, annotations) = self.arrow(
                entry, codes: codes, obstacles: obstacles, icomEnds: icomEnds,
                selected: jsStrictEquals(entry.arrow.id, options.selectedArrowId))
            strokeOps += strokes
            annotationOps += annotations
        }
        ops += strokeOps
        for box in diagram.boxes {
            ops += self.box(diagram, box, selected: jsStrictEquals(box.id, options.selectedBoxId))
        }
        ops += annotationOps
        // Ports (S01) go in the annotations pass too, after every arrow's: a
        // parent concept still unconnected here sits at the sheet edge, on
        // top of whatever a box or an arrow put there. Their labels keep
        // clear of every ICOM code an arrow draws and of every port's own.
        let portList = model.ports(diagram)
        let portEnds = icomEnds + portList.map(portCodeRect)
        for p in portList { ops += port(p, icomEnds: portEnds, obstacles: obstacles) }
        return ops
    }

    // MARK: Bundles, forks and joins

    /// An endpoint's face: its kind, its box (a box end only) and its side.
    /// A boundary endpoint has no box, whatever stray `boxId` a hand-edited
    /// file left on it.
    struct Face: Hashable {
        var kind: EndpointKind, box: JSStringKey?, side: Side
        init(_ e: Endpoint) {
            kind = e.kind
            box = e.kind == .box ? e.boxId.map(JSStringKey.init) : nil
            side = e.side
        }
    }

    /// `drawnArrows(m, dg)` — which of a diagram's arrows are drawn, and how,
    /// in array order: one `DrawnArrow` per drawn arrow.
    ///
    /// FIPS 183 §3.2.2.3 bundling (S01): arrows whose concepts are members of
    /// one bundle (`effectiveConceptId` differs from the arrow's own
    /// `conceptId`) and that run between the same faces — the same endpoint
    /// kinds, boxes and sides, at any position — are one general arrow. The
    /// first of them in array order is its representative: it draws normally
    /// except that its label reads the bundle's term — the general label,
    /// where the specifics are actually merged into one line; the rest draw
    /// nothing at all (their ICOM code is already the representative's, since
    /// `parentBoxArrows` shares one position by effective concept). A member
    /// alone on its faces hides nothing and keeps its own specific label
    /// (§3.2.2.3: the general label on the bundle, the specific ones on its
    /// branches), as does an arrow whose concept is in no bundle.
    ///
    /// FIPS 183 §3.3.2.2, Figure 6 (S02): drawn arrows that leave the same
    /// face and denote the same effective concept are one arrow forked at
    /// that face; the same at the `to` face is a join. `icomCodes` already
    /// gives such a group one code (§3.3.3 rule 14, `parentBoxArrows`); here
    /// it is drawn as one: every member is routed as if its grouped end sat at
    /// the representative's stored `pos`, so the members' routes coincide over
    /// a leading (fork) or trailing (join) run — the trunk — and part where
    /// their targets differ. Nothing in the file changes: each member keeps
    /// its own `pos`. The representative is the arrow the group's ICOM code is
    /// numbered by — the earliest on that face (lowest stored `pos`, then
    /// array order), exactly `parentBoxArrows`'s order. A hidden bundle member
    /// is not drawn and is not a branch; the members' own hidden ends never
    /// enter the routing, so a representative is routed as the one line it is.
    /// The fork group draws one label, the representative's, on the trunk —
    /// or on the representative's whole route when the trunk is too short to
    /// carry the text (`trunkLabelPath`); a branch whose own label reads the
    /// same draws none, and one whose label differs (a bundle member keeping
    /// its specific label) draws it against its branch alone
    /// (`branchLabelPath`). Joins mirror this. Public, and one shared rule, so
    /// the canvas hit-tests exactly what was drawn; render.js's `drawnArrows`
    /// is the same function, in the same order, its keys compared by code
    /// units as a JavaScript `Map` does.
    public static func drawnArrows(_ model: IDEF0Model, _ diagram: Diagram) -> [DrawnArrow] {
        struct Faces: Hashable { var bundle: JSStringKey, from: Face, to: Face }

        var out: [DrawnArrow] = []
        var groups: [Faces: Int] = [:]
        for a in diagram.arrows {
            guard let cid = a.conceptId, !cid.isEmpty,
                  let eff = model.effectiveConceptId(cid), !jsStrictEquals(eff, cid)
            else {
                out.append(DrawnArrow(arrow: a, label: a.label))
                continue
            }
            let faces = Faces(bundle: JSStringKey(eff), from: Face(a.from), to: Face(a.to))
            if let i = groups[faces] {
                // A second member on the same faces: the representative now
                // stands for a merged line, and reads the bundle's general term.
                out[i].hidden.append(a.id)
                if let bundle = model.conceptById(eff) { out[i].label = bundle.term }
                continue
            }
            groups[faces] = out.count
            out.append(DrawnArrow(arrow: a, label: a.label))
        }

        // Forks and joins (S02): the drawn arrows grouped by face and
        // effective concept, each group's representative the earliest on
        // that face.
        let forks = endGroups(model, out, .from)
        let joins = endGroups(model, out, .to)
        for i in out.indices {
            if let g = forks[i], g.members.count > 1 {
                out[i].fork = out[g.rep].arrow.id
                out[i].drawn.from = out[g.rep].arrow.from
            }
            if let g = joins[i], g.members.count > 1 {
                out[i].join = out[g.rep].arrow.id
                out[i].drawn.to = out[g.rep].arrow.to
            }
        }

        // Routed as the diagram they draw: only drawn arrows, at their drawn ends.
        var drawnDiagram = diagram
        drawnDiagram.arrows = out.map(\.drawn)
        for i in out.indices { out[i].pts = routeArrow(drawnDiagram, out[i].drawn) }

        // The trunk of a group is the run every member's route shares: a
        // common prefix (fork) or suffix (join) of the representative's route.
        for g in Set(forks.values) where g.members.count > 1 {
            var trunk = out[g.rep].pts
            for i in g.members { trunk = commonPrefix(trunk, out[i].pts) }
            for i in g.members { out[i].forkTrunk = trunk }
        }
        for g in Set(joins.values) where g.members.count > 1 {
            var trunk = Array(out[g.rep].pts.reversed())
            for i in g.members { trunk = commonPrefix(trunk, Array(out[i].pts.reversed())) }
            trunk.reverse()
            for i in g.members { out[i].joinTrunk = trunk }
        }
        for i in out.indices {
            let forkRep = forks[i].flatMap { $0.members.count > 1 ? $0.rep : nil }
            let joinRep = joins[i].flatMap { $0.members.count > 1 ? $0.rep : nil }
            if forkRep == i {
                out[i].labelPath = trunkLabelPath(out[i].forkTrunk ?? [], out[i].pts, out[i].label)
            } else if joinRep == i {
                out[i].labelPath = trunkLabelPath(out[i].joinTrunk ?? [], out[i].pts, out[i].label)
            } else {
                let shown = forkRep.map { jsStrictEquals(out[$0].label, out[i].label) } ?? false
                    || joinRep.map { jsStrictEquals(out[$0].label, out[i].label) } ?? false
                out[i].labelPath = shown ? nil
                    : branchLabelPath(branchPart(out[i].pts, out[i].forkTrunk, out[i].joinTrunk), out[i].pts)
            }
        }
        return out
    }

    /// The label's Helvetica size and line height, as `arrow` measures it and
    /// `labelRect` boxes it (Geometry.swift's `labelFontSize`, 2 × `labelHalfH`).
    static let labelFontSize = 10.5
    static let labelHeight = 16.0

    /// `trunkLabelPath(trunk, pts, label)` — what a representative's label is
    /// placed against: the trunk, when its longest segment — the one
    /// `labelPlacement` tries first — is long enough to carry the text, or
    /// else the representative's whole route `pts`. A horizontal segment
    /// carries the label above or below its midpoint, so it must be at least
    /// `textWidth(label)` long for the text to sit against the trunk rather
    /// than hang off its ends; a vertical one carries the label beside its
    /// midpoint, so a line's height is enough. The common boundary fork — an
    /// input shared by boxes 1 and 2, box 1 by the left edge — has a trunk of
    /// only the stub before the branches turn, and a label placed against that
    /// stub runs into the frame (FIPS 183 §3.2.2.3 rule 2e) where the whole
    /// route offers `labelPlacement` a clear segment. Still one label per
    /// group. render.js's `trunkLabelPath`.
    public static func trunkLabelPath(_ trunk: [Point], _ pts: [Point], _ label: String) -> [Point] {
        if trunk.count < 2 { return pts }
        let seg = longestSegmentMid(trunk)
        let need = seg.horizontal ? textWidth(label, fontSize: labelFontSize) : labelHeight
        return seg.length >= need ? trunk : pts
    }

    /// `branchLabelPath(part, pts)` — what a branch's own label is placed
    /// against: its `branchPart`, or its whole route `pts` when the trunks it
    /// lies between overlap and leave the branch a single point — a label path
    /// always has a segment to sit against (`legacyLabelBase` reads one once
    /// the label has been dragged; the web app's throws on fewer than two
    /// points). render.js's `branchLabelPath`.
    public static func branchLabelPath(_ part: [Point], _ pts: [Point]) -> [Point] {
        part.count >= 2 ? part : pts
    }

    /// A fork or join group over `drawnArrows`'s entries, by index: the
    /// members in array order and the representative — the earliest on the
    /// face, the lowest stored `pos` then array order, which is the member
    /// `parentBoxArrows` numbers the group's ICOM code by.
    struct EndGroup: Hashable {
        var rep: Int
        var members: [Int]
    }

    /// `endGroups(m, entries, which)` (S02) — the groups among the drawn
    /// entries at their `which` end: entry index → its group. An arrow bound
    /// to no concept is in no group. Only drawn entries take part: a hidden
    /// bundle member with a lower `pos` than every drawn member still orders
    /// `parentBoxArrows`' ICOM numbering on that side, but draws nothing and
    /// so never places the trunk.
    static func endGroups(_ model: IDEF0Model, _ entries: [DrawnArrow], _ which: ArrowEnd) -> [Int: EndGroup] {
        struct Key: Hashable { var concept: JSStringKey, face: Face }
        var groups: [Key: EndGroup] = [:]
        var keyOf: [Int: Key] = [:]
        for (i, e) in entries.enumerated() {
            let a = e.arrow
            guard let cid = a.conceptId, !cid.isEmpty, let eff = model.effectiveConceptId(cid) else { continue }
            let key = Key(concept: JSStringKey(eff), face: Face(a[which]))
            var g = groups[key] ?? EndGroup(rep: i, members: [])
            g.members.append(i)
            if a[which].pos < entries[g.rep].arrow[which].pos { g.rep = i }
            groups[key] = g
            keyOf[i] = key
        }
        var out: [Int: EndGroup] = [:]
        for (i, key) in keyOf { out[i] = groups[key] }
        return out
    }

    static let near = 1e-6
    static func nearPoint(_ p: Point, _ q: Point) -> Bool { abs(p.x - q.x) < near && abs(p.y - q.y) < near }

    /// `commonPrefix(a, b)` — the run two polylines share from their common
    /// first point: they walk together while their next segments head the
    /// same way, ending at the first vertex where one turns, or where the
    /// shorter of two collinear segments ends (the longer one carries on past
    /// it). Routes are simplified, so a vertex on a straight run is a turn or
    /// a reversal, and the shared run is exactly the trunk.
    public static func commonPrefix(_ a: [Point], _ b: [Point]) -> [Point] {
        guard let a0 = a.first, let b0 = b.first, nearPoint(a0, b0) else { return a.first.map { [$0] } ?? [] }
        var out = [a0]
        var i = 1, j = 1
        while i < a.count && j < b.count {
            let cur = out[out.count - 1]
            let ax = a[i].x - cur.x, ay = a[i].y - cur.y
            let bx = b[j].x - cur.x, by = b[j].y - cur.y
            let la = jsHypot(ax, ay), lb = jsHypot(bx, by)
            if la < near || lb < near { break }
            if ax * bx + ay * by <= 0 || abs(ax * by - ay * bx) > near { break }
            if abs(la - lb) < near {
                out.append(a[i]); i += 1; j += 1
            } else if la < lb {
                out.append(a[i]); break
            } else {
                out.append(b[j]); break
            }
        }
        return out
    }

    /// `branchPart(pts, forkTrunk, joinTrunk)` — the part of a branch's route
    /// that is its own: after the fork trunk it leaves and before the join
    /// trunk it enters (either may be nil). Every trunk vertex but its last is
    /// a vertex of the route (`commonPrefix` only carries a vertex both
    /// share); the last lies on the next segment, so the branch starts at that
    /// point and continues with the route's vertices from there, mirrored at
    /// a join. Trunks that overlap leave a single point (`branchLabelPath`
    /// then labels the whole route).
    public static func branchPart(_ pts: [Point], _ forkTrunk: [Point]?, _ joinTrunk: [Point]?) -> [Point] {
        let count = pts.count
        var start = pts[0], kf = 0
        if let t = forkTrunk, t.count >= 2 { start = t[t.count - 1]; kf = t.count - 1 }
        var end = pts[count - 1], kj = count - 1
        if let t = joinTrunk, t.count >= 2 { end = t[0]; kj = count - t.count }
        var out = [start]
        func push(_ p: Point) { if !nearPoint(out[out.count - 1], p) { out.append(p) } }
        if kf > kj + 1 { return out }
        if kf == kj + 1 {
            // Both on one segment: the branch is the stretch between them, if any.
            let seg = pts[kf], prev = pts[kj]
            if (end.x - start.x) * (seg.x - prev.x) + (end.y - start.y) * (seg.y - prev.y) > 0 { push(end) }
            return out
        }
        for k in kf...kj { push(pts[k]) }
        push(end)
        return out
    }

    // MARK: The sheet form

    static func frame(_ model: IDEF0Model, _ diagram: Diagram) -> [DrawOp] {
        let F = Sheet.frame
        let headBottom = F.y + Sheet.headerHeight
        let footTop = F.y + F.h - Sheet.footerHeight
        var ops: [DrawOp] = []
        let lineOp = { (x1: Double, y1: Double, x2: Double, y2: Double, s: StrokeStyle) in
            ops.append(.line(from: Point(x: x1, y: y1), to: Point(x: x2, y: y2), stroke: s, role: .sheet))
        }
        let label = { (x: Double, y: Double, t: String) in
            ops.append(.text(t, at: Point(x: x, y: y), style: frameLabel, role: .sheet))
        }
        // FIPS 183 C.4.1.1/C.4.5.1: each header/footer field has a fixed cell
        // width on the printed form, so a value too long to fit is shrunk to
        // an ellipsis rather than overprinting its neighbour.
        let value = { (x: Double, y: Double, t: String, cellWidth: Double, fontSize: Double, big: Bool) in
            ops.append(.text(fitText(t, width: cellWidth, fontSize: fontSize), at: Point(x: x, y: y),
                             style: big ? frameValueBig : frameValue, role: .sheet))
        }

        ops.append(.rect(SheetRect(x: 0, y: 0, w: Sheet.size.w, h: Sheet.size.h), fill: .white, stroke: nil, role: .sheet))
        ops.append(.rect(F, fill: nil, stroke: frameStroke, role: .sheet))
        lineOp(F.x, headBottom, F.x + F.w, headBottom, frameStroke)
        lineOp(F.x, footTop, F.x + F.w, footTop, frameStroke)
        for x in [204.0, 564, 724, 844] { lineOp(x, F.y, x, headBottom, thinStroke) }

        label(F.x + 6, F.y + 13, "USED AT:")
        label(210, F.y + 13, "AUTHOR:")
        value(252, F.y + 14, model.author, 174, 10.5, false)
        label(430, F.y + 13, "DATE:")
        value(458, F.y + 14, model.revised, 102, 10.5, false)
        label(210, F.y + 30, "PROJECT:")
        value(256, F.y + 31, model.project, 170, 10.5, false)
        label(430, F.y + 30, "REV:")
        // The C-number belongs in NUMBER (C.4.5.1), not here; REV stays blank
        // rather than inventing a stored revision field.
        label(210, F.y + 50, "NOTES:")
        for i in 1...10 {
            let dx = Double(i - 1) * 15
            ops.append(.text(String(i), at: Point(x: 246 + dx, y: F.y + 50), style: frameLabel, role: .sheet))
            ops.append(.rect(SheetRect(x: 243 + dx, y: F.y + 54, w: 11, h: 11), fill: nil, stroke: thinStroke, role: .sheet))
        }

        // The current status's box is filled, as in the web app (which writes
        // the fill as an inline style so its stylesheet cannot cancel it).
        let status = model.status.isEmpty ? ModelStatus.working.rawValue : model.status
        for (i, s) in ModelStatus.allCases.enumerated() {
            let y = F.y + 16 + Double(i) * 19
            ops.append(.rect(SheetRect(x: 572, y: y - 8, w: 10, h: 10),
                             fill: status == s.rawValue ? .ink : .white, stroke: thinStroke, role: .sheet))
            label(588, y, s.rawValue)
        }

        label(730, F.y + 13, "READER")
        label(800, F.y + 13, "DATE")
        lineOp(794, F.y, 794, headBottom, thinStroke)
        label(850, F.y + 13, "CONTEXT:")
        ops += contextThumb(model, diagram, SheetRect(x: 850, y: F.y + 20, w: 220, h: Sheet.headerHeight - 26))

        lineOp(174, footTop, 174, F.y + F.h, thinStroke)
        lineOp(876, footTop, 876, F.y + F.h, thinStroke)
        label(F.x + 6, footTop + 12, "NODE:")
        value(F.x + 6, footTop + 34, diagram.node, 140, 13, true)
        label(180, footTop + 12, "TITLE:")
        value(180, footTop + 34, diagram.title.isEmpty ? model.title : diagram.title, 690, 13, true)
        label(882, footTop + 12, "NUMBER:")
        // FIPS 183 C.4.5.1: the large area of the Number field carries the
        // C-number, not a repeat of NODE/TITLE.
        value(882, footTop + 34, diagram.cNumber, 188, 10.5, false)

        // FIPS 183 §3.3.1.1: the A-0 context diagram presents brief
        // statements of the model's viewpoint and purpose. Drawn in the
        // sheet layer, before arrows and boxes, so a box or arrow the
        // modeller places low on the canvas paints over the statement rather
        // than the other way round.
        if model.isContext(diagram) {
            var statementLines: [String] = []
            if !jsTrim(model.purpose).isEmpty {
                statementLines += wrapText("PURPOSE: \(model.purpose)", width: Sheet.work.w - 16, fontSize: 10.5, maxLines: 2)
            }
            if !jsTrim(model.viewpoint).isEmpty {
                statementLines += wrapText("VIEWPOINT: \(model.viewpoint)", width: Sheet.work.w - 16, fontSize: 10.5, maxLines: 2)
            }
            let n = statementLines.count
            for (i, text) in statementLines.enumerated() {
                ops.append(.text(text, at: Point(x: Sheet.work.x + 8, y: Sheet.work.y2 - 4 - Double(n - 1 - i) * 13),
                                 style: frameValue, role: .sheet))
            }
        }
        return ops
    }

    /// The "where am I" sketch in the CONTEXT cell (FIPS 183 C.4.1.5). On the
    /// A-0 sheet the field just reads "TOP", centred. On any other sheet the
    /// node label stays at the cell's lower-left and a small, to-scale sketch
    /// of the parent diagram's box layout sits to its right, the parent box
    /// highlighted and its siblings outlined.
    static func contextThumb(_ model: IDEF0Model, _ diagram: Diagram, _ cell: SheetRect) -> [DrawOp] {
        if model.isContext(diagram) {
            return [.text("TOP", at: Point(x: cell.x + cell.w / 2, y: cell.y + cell.h / 2 + 4),
                          style: TextStyle(size: frameLabel.size, color: frameLabel.color, anchor: .middle,
                                           letterSpacing: frameLabel.letterSpacing),
                          role: .sheet)]
        }
        guard let parent = model.parentOf(diagram), let parentDiagram = model.diagrams[parent.diagramId] else { return [] }
        var ops: [DrawOp] = [
            .text(parentDiagram.node, at: Point(x: cell.x, y: cell.y + cell.h - 2), style: frameLabel, role: .sheet),
        ]
        // A strip on the left is reserved for the node label above; the
        // sketch maps WORK, at the parent's own scale, into the rest.
        let sx = cell.x + 40, sy = cell.y + 2, sw = cell.w - 44, sh = cell.h - 6
        let s = Swift.min(sw / Sheet.work.w, sh / Sheet.work.h)
        for b in parentDiagram.sortedBoxes {
            let x = clamp(sx + (b.x - Sheet.work.x) * s, sx, sx + sw - 2)
            let y = clamp(sy + (b.y - Sheet.work.y) * s, sy, sy + sh - 2)
            let w = Swift.max(2, b.w * s)
            let h = Swift.max(2, b.h * s)
            ops.append(.rect(SheetRect(x: x, y: y, w: w, h: h),
                             fill: jsStrictEquals(b.id, parent.box.id) ? .ink : .white,
                             stroke: StrokeStyle(color: .ink, width: 0.8), role: .sheet))
        }
        return ops
    }

    // MARK: Boxes

    static func box(_ diagram: Diagram, _ box: Box, selected: Bool) -> [DrawOp] {
        let named = !jsTrim(box.name).isEmpty
        // FIPS 183 §3.2.1.3: "Boxes shall be drawn with solid lines" — an
        // unnamed box too, in both apps; the placeholder text alone says it is
        // unnamed.
        var ops: [DrawOp] = [
            .rect(box.rect, fill: .white,
                  stroke: StrokeStyle(color: selected ? .accent : .ink, width: selected ? 2.6 : 1.6),
                  role: .box(box.id)),
        ]
        let name = box.name.isEmpty ? "(unnamed)" : box.name
        // FIPS 183 §3.2.1.3: try the box name at its usual size, then shrink
        // it a step at a time until it fits without truncation (or floors
        // out at 10).
        var fontSize = 13.0
        var lines: [String] = []
        for fs: Double in [13, 12, 11, 10] {
            lines = boxNameLines(name, w: box.w, h: box.h, number: box.number, fontSize: fs)
            fontSize = fs
            if !(lines.last?.hasSuffix("…") ?? false) { break }
        }
        let lineHeight = 16.0
        // The block centres in the box height minus a bottom band reserved
        // for the box number, so a full set of lines never runs under it.
        let y0 = box.y + (box.h - 12) / 2 - Double(lines.count - 1) * lineHeight / 2
        for (i, line) in lines.enumerated() {
            ops.append(.text(line, at: Point(x: box.x + box.w / 2, y: y0 + Double(i) * lineHeight),
                             style: TextStyle(size: fontSize, italic: !named, color: named ? .ink : .placeholder,
                                              anchor: .middle, baseline: .middle),
                             role: .box(box.id)))
        }
        ops.append(.text(String(box.number), at: Point(x: box.x + box.w - 7, y: box.y + box.h - 7),
                         style: TextStyle(size: 10, anchor: .end), role: .box(box.id)))
        // `if (box.childDiagramId)` in render.js: an empty string is no child
        // (as Report, Lookups and the XML writer read it), a dangling id still is.
        if let childDiagramId = box.childDiagramId, !childDiagramId.isEmpty {
            ops.append(.text(boxNode(diagram, box), at: Point(x: box.x + box.w + 4, y: box.y + box.h + 11),
                             style: TextStyle(size: 9, color: .muted), role: .box(box.id)))
        }
        return ops
    }

    // MARK: Arrows

    /// `(strokes, annotations)`: the arrow's path, arrowhead and tunnel
    /// marks, kept apart from its label and ICOM codes. FIPS 183 §3.2.2.3
    /// rule 3 requires every arrow to carry a visible label, but a box drawn
    /// on top of the old single op run could paint over it (F60); `build`
    /// appends every arrow's strokes, then every box, then every arrow's
    /// annotations, so a label that lands over a box stays on top of its fill.
    /// `entry` is the arrow as `drawnArrows` decided it is drawn: its route,
    /// the text its label shows — the arrow's own, or the bundle's term when
    /// it is a representative; an empty one draws no label, as an empty
    /// `arrow.label` would — and, for a fork or join (S02), which of its ends
    /// are the trunk's and where its label goes.
    static func arrow(
        _ entry: DrawnArrow, codes: [String: String], obstacles: [SheetRect],
        icomEnds: [SheetRect], selected: Bool
    ) -> (strokes: [DrawOp], annotations: [DrawOp]) {
        let arrow = entry.arrow
        let pts = entry.pts
        let label = entry.label
        guard let last = pts.last else { return ([], []) }
        let colour: RGBA = selected ? .accent : .ink
        var strokes: [DrawOp] = [
            .path(roundedPathCommands(pts), fill: nil,
                  stroke: StrokeStyle(color: colour, width: selected ? 2.4 : 1.4, roundJoins: true),
                  role: .arrow(arrow.id)),
        ]

        // Arrowhead at the destination, pointing the way the line travels. A
        // join (S02) has one: its representative's — every branch ends on
        // the same trailing segment, so a second head would only overprint
        // the first.
        let prev = pts.count >= 2 ? pts[pts.count - 2] : last
        let len = hypotOrOne(last.x - prev.x, last.y - prev.y)
        let dx = (last.x - prev.x) / len, dy = (last.y - prev.y) / len
        if !entry.isJoinBranch {
            strokes.append(.path(arrowHead(last, dx, dy), fill: colour, stroke: nil, role: .arrow(arrow.id)))
        }

        // Tunnel marks likewise belong to the trunk: a branch's grouped end
        // is the representative's end, and the representative marks it — so
        // the trunk is marked exactly when the representative's own end is
        // tunnelled, whatever the branches record (`parentBoxArrows` treats
        // the group as tunnelled only when every member is).
        if arrow.tunnelFrom && !entry.isForkBranch { strokes += tunnelMark(pts[0], direction(pts, 0), arrow.id) }
        if arrow.tunnelTo && !entry.isJoinBranch {
            // Step back from the tip: the parentheses belong on the arrow, clear of
            // the arrowhead — not past its end, inside the box it points at.
            let base = Point(x: last.x - dx * arrowHeadLength, y: last.y - dy * arrowHeadLength)
            strokes += tunnelMark(base, (dx: -dx, dy: -dy), arrow.id)
        }

        // Label (F59): an unoffset label auto-places clear of boxes, ICOM
        // codes and the frame; one the modeller has dragged keeps rendering
        // at `legacyLabelBase` + ldx/ldy exactly as before (`labelPosition`
        // makes that choice). A label whose displayed position lands far
        // enough from its own route gets a short squiggle back to it (F66),
        // FIPS 183 §3.2.2.3 rule 4 — its own role so it is never mistaken for
        // the arrow's own route. `labelPath` (S02) is the part of the route
        // the label belongs to — the trunk for a fork or join's
        // representative, the branch alone for a member with a label of its
        // own — or nil for a branch whose label the trunk already shows.
        var annotations: [DrawOp] = []
        if !label.isEmpty, let labelPath = entry.labelPath {
            // Placed for the text actually drawn (a bundle's term may be
            // wider or narrower than the arrow's own label); ldx/ldy still
            // come from the arrow.
            var labelled = arrow
            labelled.label = label
            let pos = labelPosition(labelPath, labelled, icomEnds: icomEnds, boxes: obstacles)
            annotations.append(.text(label,
                             at: Point(x: pos.x, y: pos.y),
                             style: TextStyle(size: 10.5, color: colour, anchor: pos.anchor,
                                              baseline: .middle, halo: 3.5),
                             role: .arrowLabel(arrow.id)))
            let width = textWidth(label, fontSize: 10.5)
            if let squiggle = squigglePoints(labelPath, pos, width), let first = squiggle.first {
                let commands: [PathCommand] = [.move(first)] + squiggle.dropFirst().map { .line($0) }
                annotations.append(.path(commands, fill: nil,
                                 stroke: StrokeStyle(color: colour, width: 0.9, roundJoins: true),
                                 role: .arrowLabel(arrow.id)))
            }
        }

        // ICOM code beside each boundary end (child diagrams only) — the
        // codes `drawnCodes` leaves to this arrow, so a boundary fork or join
        // (S02) writes its shared code once, at the trunk.
        let own = drawnCodes(entry, codes: codes)
        for end in ArrowEnd.allCases {
            guard let code = own[end] else { continue }
            let p = end == .from ? pts[0] : last
            let place = icomAnchor(arrow[end].side, p, code)
            annotations.append(.text(code, at: Point(x: place.x, y: place.y),
                             style: TextStyle(size: 9, face: .mono, weight: .bold, color: .icom, anchor: place.anchor),
                             role: .icom(arrow.id)))
        }
        return (strokes, annotations)
    }

    /// `drawnCodes(entry, codes)` — the ICOM codes `entry` draws at its two
    /// ends: its own boundary ends' codes (`icomCodes`), except that a branch
    /// of a boundary fork or join (S02) leaves the grouped end's code to the
    /// representative, which already draws the same code at the same point.
    /// A branch keeps its code only where the representative has none to
    /// draw. Shared by `arrow` and `icomRects`, so a label is scored against
    /// exactly the codes that are inked.
    public static func drawnCodes(_ entry: DrawnArrow, codes: [String: String]) -> [ArrowEnd: String] {
        var out: [ArrowEnd: String] = [:]
        for end in ArrowEnd.allCases {
            guard let code = icomCode(entry.arrow, end, codes: codes) else { continue }
            out[end] = code
        }
        if entry.isForkBranch, let rep = entry.fork, codeFor(rep, .from, codes: codes) != nil { out[.from] = nil }
        if entry.isJoinBranch, let rep = entry.join, codeFor(rep, .to, codes: codes) != nil { out[.to] = nil }
        return out
    }

    // Menlo/Consolas mono, matching the ICOM code's `TextStyle` and the SVG
    // writer's font-size — a flat per-character width, unlike the label's
    // Helvetica advance table, because every glyph of a monospace face is the
    // same width.
    static let icomFontSize = 9.0
    static let icomMonoAdvance = 0.602
    static let icomHalfH = 6.0

    static func icomMonoWidth(_ code: String) -> Double { Double(jsLength(code)) * icomMonoAdvance * icomFontSize }

    static func icomPlace(_ side: Side, _ p: Point) -> (x: Double, y: Double, anchor: TextAnchor) {
        switch side {
        case .left: return (p.x - 4, p.y - 5, .end)
        case .right: return (p.x + 4, p.y - 5, .start)
        case .top: return (p.x + 4, p.y - 4, .start)
        case .bottom: return (p.x + 4, p.y + 11, .start)
        }
    }

    /// `icomAnchor(side, p, code)` — `icomPlace`'s SVG placement, its x
    /// clamped back onto the sheet when `code`'s measured width would
    /// otherwise run past the frame's left or right edge (F59) — the "I10"
    /// case FIPS 183 B.2.4.2 leaves unaddressed. Only "left" and
    /// "right"-side codes sit close enough to an edge to need it: a
    /// "top"/"bottom" boundary anchor's own 0.02...0.98 clamp never lets its
    /// code reach the frame's far edge.
    static func icomAnchor(_ side: Side, _ p: Point, _ code: String) -> (x: Double, y: Double, anchor: TextAnchor) {
        let place = icomPlace(side, p)
        let w = icomMonoWidth(code)
        if place.anchor == .end { return (Swift.max(place.x, Sheet.frame.x + 4 + w), place.y, .end) }
        return (Swift.min(place.x, Sheet.frame.x + Sheet.frame.w - 4 - w), place.y, .start)
    }

    static func icomRect(_ side: Side, _ p: Point, _ code: String) -> SheetRect {
        let place = icomAnchor(side, p, code)
        let w = icomMonoWidth(code)
        let x0 = place.anchor == .end ? place.x - w : place.x
        return SheetRect(x: x0, y: place.y - icomHalfH, w: w, h: icomHalfH * 2)
    }

    /// The code for `arrow`'s `end`, if it is a boundary end with one —
    /// matched by `jsStrictEquals` on the "id:which" key, since arrow ids are
    /// compared by UTF-16 code unit, which a plain dictionary key cannot
    /// promise.
    static func icomCode(_ arrow: Arrow, _ end: ArrowEnd, codes: [String: String]) -> String? {
        guard arrow[end].kind == .boundary else { return nil }
        return codeFor(arrow.id, end, codes: codes)
    }

    /// `codes["id:which"]`, matched by code unit.
    static func codeFor(_ arrowId: String, _ end: ArrowEnd, codes: [String: String]) -> String? {
        let key = "\(arrowId):\(end.rawValue)"
        return codes.first(where: { jsStrictEquals($0.key, key) })?.value
    }

    /// Every ICOM code's rectangle for one diagram (F59) — computed once so a
    /// `labelPlacement` call can penalise landing on top of a code exactly
    /// where `arrow` will draw it: the codes `drawnCodes` leaves to each
    /// drawn arrow, at its drawn route's ends. Public: `HitTest.label`
    /// (IDEF0Editing) calls this too, so a label's hit test scores against
    /// the very same rectangles its rendering did.
    public static func icomRects(_ drawn: [DrawnArrow], codes: [String: String]) -> [SheetRect] {
        var rects: [SheetRect] = []
        for entry in drawn {
            let pts = entry.pts
            guard let last = pts.last else { continue }
            let own = drawnCodes(entry, codes: codes)
            for end in ArrowEnd.allCases {
                guard let code = own[end] else { continue }
                let p = end == .from ? pts[0] : last
                rects.append(icomRect(entry.arrow[end].side, p, code))
            }
        }
        return rects
    }

    /// `icomRects` for a diagram, from its own `drawnArrows`.
    public static func icomRects(_ model: IDEF0Model, _ diagram: Diagram) -> [SheetRect] {
        icomRects(drawnArrows(model, diagram), codes: model.icomCodes(diagram))
    }

    // MARK: Ports

    /// Radius of the open circle at a port's inner end.
    static let portRadius = 4.0
    static let portStubStroke = StrokeStyle(color: .muted, width: 1.2, dash: [4, 3])
    static let portRing = StrokeStyle(color: .ink, width: 1.4)

    /// The two-point path a port's label is placed against: the circle's
    /// vertical diameter. `labelPlacement` then offers the spots 12 units
    /// right of the circle's centre (start-anchored) and 12 units left of it
    /// (end-anchored) — beside the inner end, 8 clear of the rim — and scores
    /// them against the boxes, the ICOM codes (the port's own included) and
    /// the frame, so a right-edge port's label, which would run off the
    /// sheet, lands to the left of its circle instead. The same path, in the
    /// same order, as render.js.
    static func portLabelPath(_ shape: PortShape) -> [Point] {
        [Point(x: shape.inner.x, y: shape.inner.y - portRadius), Point(x: shape.inner.x, y: shape.inner.y + portRadius)]
    }

    /// The rectangle a port's ICOM code occupies, where `port` draws it.
    static func portCodeRect(_ port: ICOMPort) -> SheetRect {
        icomRect(port.side, portShape(port).edge, port.code)
    }

    /// `renderPort(port, { icomEnds, boxes })` — a parent-box ICOM concept not
    /// yet connected on this diagram (`IDEF0Model.ports`), drawn at the sheet
    /// edge: a dashed stub from `edge` to `inner` (`portShape`), an open
    /// circle at `inner`, the ICOM code at the edge end placed exactly as a
    /// boundary arrow's code would be (`icomAnchor`), and the label in a muted
    /// italic beside the inner end. Every op carries `.port(parentArrowId)`.
    /// A port is not an arrow: it is no routing obstacle and never reaches
    /// the ICOM/IDL/report exports.
    static func port(_ port: ICOMPort, icomEnds: [SheetRect], obstacles: [SheetRect]) -> [DrawOp] {
        let shape = portShape(port)
        let role = DrawRole.port(port.parentArrowId)
        var ops: [DrawOp] = [
            .path(roundedPathCommands([shape.edge, shape.inner]), fill: nil, stroke: portStubStroke, role: role),
            .circle(center: shape.inner, radius: portRadius, fill: .white, stroke: portRing, role: role),
        ]
        let place = icomAnchor(port.side, shape.edge, port.code)
        ops.append(.text(port.code, at: Point(x: place.x, y: place.y),
                         style: TextStyle(size: 9, face: .mono, weight: .bold, color: .icom, anchor: place.anchor),
                         role: role))
        if !port.label.isEmpty {
            let pos = labelPlacement(portLabelPath(shape), port.label, icomEnds: icomEnds, boxes: obstacles)
            ops.append(.text(port.label, at: Point(x: pos.x, y: pos.y),
                             style: TextStyle(size: 10.5, italic: true, color: .muted, anchor: pos.anchor, baseline: .middle),
                             role: role))
        }
        return ops
    }

    static func arrowHead(_ p: Point, _ dx: Double, _ dy: Double) -> [PathCommand] {
        let bx = p.x - dx * arrowHeadLength, by = p.y - dy * arrowHeadLength
        let px = -dy, py = dx
        return [
            .move(p),
            .line(Point(x: bx + px * arrowHeadHalfWidth, y: by + py * arrowHeadHalfWidth)),
            .line(Point(x: bx - px * arrowHeadHalfWidth, y: by - py * arrowHeadHalfWidth)),
            .close,
        ]
    }

    static func direction(_ pts: [Point], _ i: Int) -> (dx: Double, dy: Double) {
        let a = pts[i]
        let b = i + 1 < pts.count ? pts[i + 1] : pts[i]
        let l = hypotOrOne(b.x - a.x, b.y - a.y)
        return ((b.x - a.x) / l, (b.y - a.y) / l)
    }

    /// The parentheses that mark a tunnelled arrow end (§3.3.2.9).
    static func tunnelMark(_ p: Point, _ d: (dx: Double, dy: Double), _ arrowId: String) -> [DrawOp] {
        let px = -d.dy, py = d.dx
        func arc(_ offset: Double, _ bulge: Double) -> DrawOp {
            let cx = p.x + d.dx * offset, cy = p.y + d.dy * offset
            return .path([
                .move(Point(x: cx + px * 7, y: cy + py * 7)),
                .quad(control: Point(x: cx + d.dx * bulge, y: cy + d.dy * bulge), end: Point(x: cx - px * 7, y: cy - py * 7)),
            ], fill: nil, stroke: StrokeStyle(color: .ink, width: 1.4), role: .arrow(arrowId))
        }
        return [arc(5, -5), arc(13, 5)]
    }

    private static func hypotOrOne(_ x: Double, _ y: Double) -> Double {
        let h = (x * x + y * y).squareRoot()
        return h == 0 ? 1 : h
    }
}
