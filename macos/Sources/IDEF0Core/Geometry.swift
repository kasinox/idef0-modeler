// Anchor resolution and orthogonal arrow routing — a port of
// src/model/geometry.js.
//
// Every number here reaches the ontology toolkit or the SVG export, so the
// arithmetic follows the web app operation for operation: the same evaluation
// order, JavaScript's `Math.min`/`Math.max`/`Math.hypot`, `||` fallbacks that
// treat NaN as falsy, and stable in-place point removal.

// MARK: - Points and anchors

public struct Point: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// An endpoint resolved to sheet coordinates plus the outward normal of the
/// surface it sits on. `ok` is false when the endpoint names a missing box.
public struct Anchor: Hashable, Sendable {
    public var x, y, nx, ny: Double
    public var boundary: Bool
    public var ok: Bool

    public init(x: Double, y: Double, nx: Double, ny: Double, boundary: Bool, ok: Bool) {
        self.x = x; self.y = y; self.nx = nx; self.ny = ny; self.boundary = boundary; self.ok = ok
    }
}

/// `OUTWARD` — the unit normal pointing away from each side of a rectangle.
private func outward(_ side: Side) -> (nx: Double, ny: Double) {
    switch side {
    case .left: return (-1, 0)
    case .right: return (1, 0)
    case .top: return (0, -1)
    case .bottom: return (0, 1)
    }
}

/// Keeps an anchor off the very corner of its side, where it would read as
/// touching the neighbouring side.
private func clamp01(_ v: Double) -> Double { clamp(v, 0.02, 0.98) }

/// A boundary anchor sits on the drawing-area edge and its "outward" normal
/// points off-sheet.
private func boundaryAnchor(_ side: Side, _ pos: Double) -> Anchor {
    let (nx, ny) = outward(side)
    let p = clamp01(pos)
    let w = Sheet.work
    let pt: Point
    switch side {
    case .left: pt = Point(x: w.x, y: w.y + p * w.h)
    case .right: pt = Point(x: w.x2, y: w.y + p * w.h)
    case .top: pt = Point(x: w.x + p * w.w, y: w.y)
    case .bottom: pt = Point(x: w.x + p * w.w, y: w.y2)
    }
    return Anchor(x: pt.x, y: pt.y, nx: nx, ny: ny, boundary: true, ok: true)
}

/// `anchorOf(diagram, endpoint)`.
public func anchorOf(_ diagram: Diagram, _ endpoint: Endpoint) -> Anchor {
    if endpoint.kind == .boundary { return boundaryAnchor(endpoint.side, endpoint.pos) }
    let (nx, ny) = outward(endpoint.side)
    guard let box = diagram.findBox(endpoint.boxId) else {
        return Anchor(x: Sheet.work.x, y: Sheet.work.y, nx: nx, ny: ny, boundary: false, ok: false)
    }
    let p = clamp01(endpoint.pos)
    let pt: Point
    switch endpoint.side {
    case .left: pt = Point(x: box.x, y: box.y + p * box.h)
    case .right: pt = Point(x: box.x + box.w, y: box.y + p * box.h)
    case .top: pt = Point(x: box.x + p * box.w, y: box.y)
    case .bottom: pt = Point(x: box.x + p * box.w, y: box.y + box.h)
    }
    return Anchor(x: pt.x, y: pt.y, nx: nx, ny: ny, boundary: false, ok: true)
}

/// Where a port (see `IDEF0Model.ports`) is drawn: `edge` on the drawing-area
/// edge, `inner` the point its stub reaches into the drawing area.
public struct PortShape: Hashable, Sendable {
    public var edge: Point
    public var inner: Point
    public init(edge: Point, inner: Point) { self.edge = edge; self.inner = inner }
}

/// How far a port's stub reaches into the drawing area from the sheet edge.
private let portStub: Double = 26

/// `portShape(port)` — `edge` is the anchor of the port's boundary endpoint
/// (side, pos), `inner` the point `portStub` units inward from it, where the
/// open circle sits. The same arithmetic, in the same order, as geometry.js.
public func portShape(_ port: ICOMPort) -> PortShape {
    let a = boundaryAnchor(port.side, port.pos)
    return PortShape(
        edge: Point(x: a.x, y: a.y),
        inner: Point(x: a.x - a.nx * portStub, y: a.y - a.ny * portStub)
    )
}

/// `posOnSide(rect, side, pt)` — position 0…1 along `side` for an arbitrary point.
public func posOnSide(_ rect: SheetRect, _ side: Side, _ pt: Point) -> Double {
    let v = side == .left || side == .right
        ? (pt.y - rect.y) / rect.h
        : (pt.x - rect.x) / rect.w
    return clamp01(v)
}

/// `nearestSide(rect, pt)`. Ties go to the side listed first in the web app's
/// distance object — left, right, top, bottom — which is not `Side.allCases` order.
public func nearestSide(_ rect: SheetRect, _ pt: Point) -> (side: Side, pos: Double) {
    let d: [(Side, Double)] = [
        (.left, abs(pt.x - rect.x)),
        (.right, abs(pt.x - (rect.x + rect.w))),
        (.top, abs(pt.y - rect.y)),
        (.bottom, abs(pt.y - (rect.y + rect.h))),
    ]
    // `Object.keys(d).reduce((a, b) => (d[a] <= d[b] ? a : b))`.
    var best = d[0]
    for next in d.dropFirst() where !(best.1 <= next.1) { best = next }
    return (best.0, posOnSide(rect, best.0, pt))
}

// MARK: - Routing

/// How far a routed run stands off a box it has to get around.
private let laneGap: Double = 26
/// A boundary source held out into this margin (between the frame and the
/// drawing area) rather than looping under/over the box it nearly touches.
private let boundaryMargin: Double = 16

private let frameXLo = Sheet.frame.x + 4
private let frameXHi = Sheet.frame.x + Sheet.frame.w - 4
private let frameYLo = Sheet.frame.y + Sheet.headerHeight + 4
private let frameYHi = Sheet.frame.y + Sheet.frame.h - Sheet.footerHeight - 4

/// Keep a routed stub point off the frame border and the header/footer bands.
private func clampFrame(_ p: Point) -> Point {
    Point(x: jsMin(jsMax(p.x, frameXLo), frameXHi), y: jsMin(jsMax(p.y, frameYLo), frameYHi))
}

/// The stub point `stub` units out from anchor `p` (whose outward normal is
/// (nx, ny)) on the side the arrow actually runs — outside a box, but inside
/// the drawing area for the sheet boundary (an arrow never leaves the sheet).
private func stubPoint(_ p: Anchor, _ stub: Double, _ f: Double) -> Point {
    Point(x: p.x + p.nx * stub * f, y: p.y + p.ny * stub * f)
}

/// Whether `a`'s route runs "feedback" — against the left-to-right reading
/// order, doubling back to a box already passed. FIPS 183 §3.3.3 rule 12 gives
/// these a fixed shape, which also keeps the arrow clear of the boxes lying
/// between the two ends. Only a real box output can be a feedback source: a
/// boundary anchor has nothing behind it to double back over (see the
/// degenerate case in `routePoints`).
private func feedbackLike(_ a: Anchor, _ b: Anchor, _ s0: Point, _ s1: Point) -> Bool {
    let h0 = a.nx != 0
    return h0 && a.nx * (a.boundary ? -1 : 1) > 0 && !b.boundary && s1.x < s0.x - 1
}

/// `bendAxis(a, b, stub)` — the axis a route's middle run could be dragged
/// along ("x" or "y"), or nil when the route has no visible bend to grab: a
/// feedback (its shape is fixed), or ends whose runs already point straight
/// at each other. Shares the feedback test with `routePoints` so the two
/// never disagree about what counts as feedback.
public func bendAxis(_ a: Anchor, _ b: Anchor, stub: Double = Sheet.stub) -> String? {
    let f0: Double = a.boundary ? -1 : 1
    let f1: Double = b.boundary ? -1 : 1
    let s0 = stubPoint(a, stub, f0)
    let s1 = stubPoint(b, stub, f1)
    let h0 = a.nx != 0
    let h1 = b.nx != 0
    if feedbackLike(a, b, s0, s1) && !a.boundary { return nil }
    if h0 && h1 { return abs(s0.y - s1.y) > 0.5 ? "x" : nil }
    if !h0 && !h1 { return abs(s0.x - s1.x) > 0.5 ? "y" : nil }
    return nil
}

/// The first obstacle whose face the anchor sits flush against — the box an
/// L-shaped route is entering, so a corner can be routed clear of it.
private func targetRect(_ b: Anchor, _ obstacles: [SheetRect]) -> SheetRect? {
    if b.boundary { return nil }
    if b.nx != 0 {
        for bx in obstacles {
            let edge = b.nx < 0 ? bx.x : bx.x + bx.w
            if abs(edge - b.x) < 0.01 && bx.y <= b.y && b.y <= bx.y + bx.h { return bx }
        }
    } else {
        for bx in obstacles {
            let edge = b.ny < 0 ? bx.y : bx.y + bx.h
            if abs(edge - b.y) < 0.01 && bx.x <= b.x && b.x <= bx.x + bx.w { return bx }
        }
    }
    return nil
}

private func inWorkX(_ v: Double) -> Bool { v > Sheet.work.x + 4 && v < Sheet.work.x2 - 4 }
private func inWorkY(_ v: Double) -> Bool { v > Sheet.work.y + 4 && v < Sheet.work.y2 - 4 }

/// `routePoints(a, b, bend, obstacles, laneOffset)` — a rectilinear route
/// between two anchors. Both ends leave and enter perpendicular to their
/// surface, which is what makes IDEF0 arrows read correctly. `bend` pins the
/// middle run. `laneOffset` shifts a non-feedback middle run sideways (before
/// it is cleared of boxes) so parallel arrows between the same faces do not
/// draw on top of one another — see `routeArrow`, which supplies it; a direct
/// call defaults to unoffset.
public func routePoints(
    _ a: Anchor, _ b: Anchor, bend: Double? = nil, obstacles: [SheetRect] = [], laneOffset: Double = 0
) -> [Point] {
    let p0 = Point(x: a.x, y: a.y)
    let p1 = Point(x: b.x, y: b.y)
    let f0: Double = a.boundary ? -1 : 1
    let f1: Double = b.boundary ? -1 : 1
    let h0 = a.nx != 0
    let h1 = b.nx != 0

    // Ends that face each other across a gap of less than two stub-lengths:
    // reach only the midline between them, not the box beyond it. This also
    // keeps two boxes placed close together from being misread as a feedback
    // below (a short forward gap and a reversed one are never both possible).
    var facing = false
    var g = 0.0
    if h0 == h1 {
        let d0 = (h0 ? a.nx : a.ny) * f0
        let d1 = (h1 ? b.nx : b.ny) * f1
        g = (h0 ? b.x - a.x : b.y - a.y) * d0
        facing = d0 == -d1 && g > 0 && g < 2 * Sheet.stub
    }

    var s0: Point, s1: Point
    let feedback: Bool
    var skipClearance: Bool
    if facing {
        s0 = stubPoint(a, g / 2, f0)
        s1 = stubPoint(b, g / 2, f1)
        feedback = false
        skipClearance = true
    } else {
        s0 = stubPoint(a, Sheet.stub, f0)
        s1 = stubPoint(b, Sheet.stub, f1)
        let wouldBeFeedback = feedbackLike(a, b, s0, s1)
        feedback = wouldBeFeedback && !a.boundary
        skipClearance = false
        if wouldBeFeedback && a.boundary {
            // The source has nothing behind it to double back over: stand
            // off into the drawing margin instead of looping under/over the
            // box, or through it, the way the ordinary lanes would.
            s0 = Point(x: a.x + a.nx * boundaryMargin, y: a.y + a.ny * boundaryMargin)
            skipClearance = true
        }
    }
    s0 = clampFrame(s0)
    s1 = clampFrame(s1)

    var mids: [Point] = []

    if feedback {
        let overTop = !h1 && b.ny < 0
        let lane = overTop
            ? jsMax(laneAboveRaw(obstacles, s0.x, s1.x, jsMin(s0.y, s1.y)) + laneOffset, Sheet.work.y + 6)
            : jsMin(laneBelowRaw(obstacles, s0.x, s1.x, jsMax(s0.y, s1.y)) + laneOffset, Sheet.work.y2 - 6)
        mids.append(Point(x: s0.x, y: lane))
        mids.append(Point(x: s1.x, y: lane))
    } else if h0 && h1 {
        let mx = bend ?? (skipClearance
            ? (s0.x + s1.x) / 2
            : clearVertical(obstacles, (s0.x + s1.x) / 2 + laneOffset, s0.y, s1.y))
        if abs(s0.y - s1.y) > 0.5 {
            mids.append(Point(x: mx, y: s0.y))
            mids.append(Point(x: mx, y: s1.y))
        }
    } else if !h0 && !h1 {
        let my = bend ?? (skipClearance
            ? (s0.y + s1.y) / 2
            : clearHorizontal(obstacles, (s0.y + s1.y) / 2 + laneOffset, s0.x, s1.x))
        if abs(s0.x - s1.x) > 0.5 {
            mids.append(Point(x: s0.x, y: my))
            mids.append(Point(x: s1.x, y: my))
        }
    } else if h0 && !h1 {
        // A single corner at (s1.x, s0.y) can send the run through the
        // target box when the corner sits on the box side of the face it is
        // entering. Route a Z with a lane beside the box instead, unless
        // this route was already sent around the box some other way above.
        var z: Double?
        if !skipClearance, let t = targetRect(b, obstacles), (s0.y - b.y) * b.ny < 0 {
            var xc = s0.x < t.x ? t.x - laneGap : t.x + t.w + laneGap
            if !inWorkX(xc) { xc = s0.x < t.x ? t.x + t.w + laneGap : t.x - laneGap }
            z = xc
        }
        if let z {
            mids.append(Point(x: z, y: s0.y))
            mids.append(Point(x: z, y: s1.y))
        } else {
            mids.append(Point(x: s1.x, y: s0.y))
        }
    } else {
        var z: Double?
        if !skipClearance, let t = targetRect(b, obstacles), (s0.x - b.x) * b.nx < 0 {
            var yc = s0.y < t.y ? t.y - laneGap : t.y + t.h + laneGap
            if !inWorkY(yc) { yc = s0.y < t.y ? t.y + t.h + laneGap : t.y - laneGap }
            z = yc
        }
        if let z {
            mids.append(Point(x: s0.x, y: z))
            mids.append(Point(x: s1.x, y: z))
        } else {
            mids.append(Point(x: s0.x, y: s1.y))
        }
    }

    return simplify([p0, s0] + mids + [s1, p1])
}

/// `routeArrow(diagram, arrow)` — an arrow's route, offsetting its middle run
/// away from any other unpinned arrow that runs between the same pair of
/// faces (excluding one it forks or joins with, sharing an end anchor), so
/// parallel arrows read as separate lines rather than one drawn on top of
/// another. Every renderer and hit-test in both apps routes through this (not
/// `routePoints`) so what is drawn is what is clickable.
public func routeArrow(_ diagram: Diagram, _ arrow: Arrow) -> [Point] {
    let obstacles = diagram.boxes.map(\.rect)
    let a = anchorOf(diagram, arrow.from)
    let b = anchorOf(diagram, arrow.to)
    // A pinned bend, and a preview of an arrow not yet in the diagram
    // (nothing to group it against), route with no lane offset.
    if arrow.bend != nil || !diagram.arrows.contains(arrow) {
        return routePoints(a, b, bend: arrow.bend, obstacles: obstacles)
    }
    let offset = laneOffsetOf(diagram, arrow, a, b, obstacles)
    return routePoints(a, b, bend: nil, obstacles: obstacles, laneOffset: offset)
}

/// A run's grouping key: same orientation, same coordinate (within a unit),
/// overlapping extent along the run. Only plain H-H, V-V and feedback runs —
/// the ones a fixed lane offset actually separates — are grouped.
private struct RunInfo {
    enum Kind { case hh, vv, fb }
    var kind: Kind
    var coord: Double
    var lo: Double
    var hi: Double
    var heading: Double
    var key: Double
}

private func runOf(_ a: Anchor, _ b: Anchor, _ obstacles: [SheetRect]) -> RunInfo? {
    let h0 = a.nx != 0, h1 = b.nx != 0
    let f0: Double = a.boundary ? -1 : 1
    let f1: Double = b.boundary ? -1 : 1
    var facing = false
    var g = 0.0
    if h0 == h1 {
        let d0 = (h0 ? a.nx : a.ny) * f0
        let d1 = (h1 ? b.nx : b.ny) * f1
        g = (h0 ? b.x - a.x : b.y - a.y) * d0
        facing = d0 == -d1 && g > 0 && g < 2 * Sheet.stub
    }
    if facing { return nil }
    let s0 = stubPoint(a, Sheet.stub, f0)
    let s1 = stubPoint(b, Sheet.stub, f1)
    let wouldBeFeedback = feedbackLike(a, b, s0, s1)
    if wouldBeFeedback && a.boundary { return nil }
    if wouldBeFeedback {
        let overTop = !h1 && b.ny < 0
        let coord = overTop
            ? laneAboveRaw(obstacles, s0.x, s1.x, jsMin(s0.y, s1.y))
            : laneBelowRaw(obstacles, s0.x, s1.x, jsMax(s0.y, s1.y))
        return RunInfo(kind: .fb, coord: coord, lo: jsMin(s0.x, s1.x), hi: jsMax(s0.x, s1.x), heading: s1.x - s0.x, key: a.y)
    }
    if h0 && h1 {
        if abs(s0.y - s1.y) <= 0.5 { return nil }
        let coord = clearVertical(obstacles, (s0.x + s1.x) / 2, s0.y, s1.y)
        return RunInfo(kind: .hh, coord: coord, lo: jsMin(s0.y, s1.y), hi: jsMax(s0.y, s1.y), heading: s1.y - s0.y, key: a.y)
    }
    if !h0 && !h1 {
        if abs(s0.x - s1.x) <= 0.5 { return nil }
        let coord = clearHorizontal(obstacles, (s0.y + s1.y) / 2, s0.x, s1.x)
        return RunInfo(kind: .vv, coord: coord, lo: jsMin(s0.x, s1.x), hi: jsMax(s0.x, s1.x), heading: s1.x - s0.x, key: a.x)
    }
    return nil
}

private func sameEnd(_ x: Endpoint, _ y: Endpoint) -> Bool {
    guard x.kind == y.kind, x.side == y.side, x.pos == y.pos else { return false }
    return x.kind != .box || jsStrictEquals(x.boxId, y.boxId)
}

/// Whether two arrows fork or join — share the anchor at one end — and so are
/// meant to be drawn overlapping rather than spread into separate lanes.
private func sharesEndpoint(_ p: Arrow, _ q: Arrow) -> Bool {
    sameEnd(p.from, q.from) || sameEnd(p.from, q.to) || sameEnd(p.to, q.from) || sameEnd(p.to, q.to)
}

/// Whether two runs are close enough, and overlap enough, to be spread apart.
private func runsCollide(_ p: RunInfo, _ q: RunInfo) -> Bool {
    if p.kind != q.kind { return false }
    if abs(p.coord - q.coord) >= 1 { return false }
    return p.lo < q.hi && q.lo < p.hi
}

/// Every unpinned arrow's lane offset. Two arrows "collide" when their default
/// routes run parallel, at the same coordinate, with overlapping extent, and
/// they do not fork or join (share an end anchor). Colliding is transitive —
/// three arrows that pairwise overlap share one group even if a forking pair
/// among them is not itself spread apart — so the group, and every member's
/// offset within it, comes out the same no matter which member asks.
private func laneOffsetOf(_ diagram: Diagram, _ arrow: Arrow, _ a: Anchor, _ b: Anchor, _ obstacles: [SheetRect]) -> Double {
    let arrows = diagram.arrows
    guard let i = arrows.firstIndex(of: arrow) else { return 0 }
    let runs: [RunInfo?] = arrows.indices.map { j in
        let ar = arrows[j]
        if ar.bend != nil { return nil }
        let pa = j == i ? a : anchorOf(diagram, ar.from)
        let pb = j == i ? b : anchorOf(diagram, ar.to)
        return runOf(pa, pb, obstacles)
    }
    guard runs[i] != nil else { return 0 }
    // Breadth-first over the (symmetric) collision graph, so the group is the
    // same connected component regardless of which member it is computed from.
    var seen: Set<Int> = [i]
    var queue = [i]
    while !queue.isEmpty {
        let cur = queue.removeFirst()
        for j in arrows.indices where !seen.contains(j) {
            guard let rj = runs[j], let rc = runs[cur], runsCollide(rc, rj) else { continue }
            if sharesEndpoint(arrows[cur], arrows[j]) { continue }
            seen.insert(j)
            queue.append(j)
        }
    }
    guard seen.count >= 2 else { return 0 }
    var group = Array(seen)
    group.sort { runs[$0]!.key != runs[$1]!.key ? runs[$0]!.key < runs[$1]!.key : $0 < $1 }
    let heading = runs[group[0]]!.heading
    let ordered = heading >= 0 ? Array(group.reversed()) : group
    let n = ordered.count
    guard let k = ordered.firstIndex(of: i) else { return 0 }
    return (Double(k) - Double(n - 1) / 2) * 8
}

// MARK: Keeping clear of boxes

private func spansX(_ bx: SheetRect, _ x0: Double, _ x1: Double) -> Bool {
    bx.x + bx.w > jsMin(x0, x1) - 1 && bx.x < jsMax(x0, x1) + 1
}

private func spansY(_ bx: SheetRect, _ y0: Double, _ y1: Double) -> Bool {
    bx.y + bx.h > jsMin(y0, y1) - 1 && bx.y < jsMax(y0, y1) + 1
}

/// A y below every box between x0 and x1 — the "under" lane of a feedback,
/// before it is offset and clamped into the drawing area.
private func laneBelowRaw(_ obstacles: [SheetRect], _ x0: Double, _ x1: Double, _ floor: Double) -> Double {
    var y = floor
    for bx in obstacles where spansX(bx, x0, x1) { y = jsMax(y, bx.y + bx.h) }
    return y + laneGap
}

/// A y above every box between x0 and x1 — the "over" lane of a feedback,
/// before it is offset and clamped into the drawing area.
private func laneAboveRaw(_ obstacles: [SheetRect], _ x0: Double, _ x1: Double, _ ceil: Double) -> Double {
    var y = ceil
    for bx in obstacles where spansX(bx, x0, x1) { y = jsMin(y, bx.y) }
    return y - laneGap
}

/// Shift a vertical run sideways so it does not pass through a box.
private func clearVertical(_ obstacles: [SheetRect], _ x: Double, _ y0: Double, _ y1: Double) -> Double {
    let hits = obstacles.filter { bx in spansY(bx, y0, y1) && bx.x - 10 < x && bx.x + bx.w + 10 > x }
    if hits.isEmpty { return x }
    let left = jsMin(hits.map { $0.x }) - laneGap
    let right = jsMax(hits.map { $0.x + $0.w }) + laneGap
    let okL = left > Sheet.work.x + 4, okR = right < Sheet.work.x2 - 4
    if okL && (!okR || abs(left - x) <= abs(right - x)) { return left }
    return okR ? right : x
}

/// Shift a horizontal run so it does not pass through a box.
private func clearHorizontal(_ obstacles: [SheetRect], _ y: Double, _ x0: Double, _ x1: Double) -> Double {
    let hits = obstacles.filter { bx in spansX(bx, x0, x1) && bx.y - 10 < y && bx.y + bx.h + 10 > y }
    if hits.isEmpty { return y }
    let above = jsMin(hits.map { $0.y }) - laneGap
    let below = jsMax(hits.map { $0.y + $0.h }) + laneGap
    let okA = above > Sheet.work.y + 4, okB = below < Sheet.work.y2 - 4
    if okA && (!okB || abs(above - y) <= abs(below - y)) { return above }
    return okB ? below : y
}

/// Drop duplicate and collinear points so the path stays clean.
private func simplify(_ pts: [Point]) -> [Point] {
    var out: [Point] = []
    for p in pts {
        if let last = out.last, abs(last.x - p.x) < 0.4 && abs(last.y - p.y) < 0.4 { continue }
        out.append(p)
    }
    var i = out.count - 2
    while i >= 1 {
        let a = out[i - 1], b = out[i], c = out[i + 1]
        let collinearX = abs(a.x - b.x) < 0.4 && abs(b.x - c.x) < 0.4
        let collinearY = abs(a.y - b.y) < 0.4 && abs(b.y - c.y) < 0.4
        if collinearX || collinearY {
            // Only drop the vertex when both runs head the same way. A reversal
            // is the approach overshoot at a box face; removing it lets an arrow
            // enter from the wrong side, or collapse when a box sits flush
            // against the drawing edge.
            let sameDir = collinearX
                ? (b.y - a.y) * (c.y - b.y) >= 0
                : (b.x - a.x) * (c.x - b.x) >= 0
            if sameDir { out.remove(at: i) }
        }
        i -= 1
    }
    return out
}

// MARK: - Paths

/// One drawing step of a routed arrow.
public enum PathCommand: Hashable, Sendable {
    case move(Point)
    case line(Point)
    /// A quarter-circle corner: the SVG "A r r 0 0 sweep x y".
    case arc(radius: Double, sweepPositive: Bool, end: Point)
    /// A quadratic curve, used for the parentheses that mark a tunnel.
    case quad(control: Point, end: Point)
    /// Back to the start of the current subpath, as for an arrowhead.
    case close
}

/// The path for a routed polyline, unrounded, for renderers. FIPS 183
/// §3.2.1.3: "Arrows that bend shall be curved using only 90 degree arcs", so
/// each interior vertex becomes a quarter circle cut back along both runs.
/// The default radius is the web app's `CORNER_R`.
public func roundedPathCommands(_ pts: [Point], radius: Double = 7) -> [PathCommand] {
    guard let first = pts.first else { return [] }
    var out: [PathCommand] = [.move(first)]
    if pts.count == 1 { return out }
    for i in 1..<(pts.count - 1) {
        let a = pts[i - 1], p = pts[i], c = pts[i + 1]
        let lin = jsHypot(p.x - a.x, p.y - a.y)
        let lout = jsHypot(c.x - p.x, c.y - p.y)
        let rad = jsMin([radius, lin / 2, lout / 2])
        let ix = (p.x - a.x) / orOne(lin), iy = (p.y - a.y) / orOne(lin)
        let ox = (c.x - p.x) / orOne(lout), oy = (c.y - p.y) / orOne(lout)
        let cross = ix * oy - iy * ox
        // Collinear runs and reversals have no corner to round.
        if rad < 0.5 || abs(cross) < 0.5 {
            out.append(.line(p))
            continue
        }
        out.append(.line(Point(x: p.x - ix * rad, y: p.y - iy * rad)))
        out.append(.arc(radius: rad, sweepPositive: cross > 0, end: Point(x: p.x + ox * rad, y: p.y + oy * rad)))
    }
    out.append(.line(pts[pts.count - 1]))
    return out
}

/// `pointsToPath(pts, radius)` — SVG path data, every number rounded to a
/// tenth and printed as JavaScript prints it.
public func pointsToPath(_ pts: [Point], radius: Double = 7) -> String {
    func n(_ v: Double) -> String { jsNumberString(roundTenth(v)) }
    var d = ""
    for (i, command) in roundedPathCommands(pts, radius: radius).enumerated() {
        if i > 0 { d += " " }
        switch command {
        case .move(let p): d += "M\(n(p.x)) \(n(p.y))"
        case .line(let p): d += "L\(n(p.x)) \(n(p.y))"
        case .arc(let r, let sweep, let e): d += "A\(n(r)) \(n(r)) 0 0 \(sweep ? 1 : 0) \(n(e.x)) \(n(e.y))"
        case .quad(let c, let e): d += "Q\(n(c.x)) \(n(c.y)) \(n(e.x)) \(n(e.y))"
        case .close: d += "Z"
        }
    }
    return d
}

/// `pathLength(pts)` — total length of a polyline.
public func pathLength(_ pts: [Point]) -> Double {
    var total = 0.0
    if pts.count > 1 {
        for i in 1..<pts.count { total += jsHypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
    }
    return total
}

public struct PointOnPath: Hashable, Sendable {
    public var x, y, dx, dy: Double
    public init(x: Double, y: Double, dx: Double, dy: Double) {
        self.x = x; self.y = y; self.dx = dx; self.dy = dy
    }
}

/// `pointAt(pts, t)` — the point a fraction `t` along a polyline, with the
/// unit direction of the segment it falls on. An empty polyline, on which the
/// web app throws, yields the origin heading right.
public func pointAt(_ pts: [Point], _ t: Double) -> PointOnPath {
    guard let last = pts.last else { return PointOnPath(x: 0, y: 0, dx: 1, dy: 0) }
    let total = pathLength(pts)
    var want = total * t
    if pts.count > 1 {
        for i in 1..<pts.count {
            let seg = jsHypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            if want <= seg || i == pts.count - 1 {
                let hasLength = isTruthy(seg)
                let f = hasLength ? want / seg : 0
                return PointOnPath(
                    x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
                    y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * f,
                    dx: hasLength ? (pts[i].x - pts[i - 1].x) / seg : 1,
                    dy: hasLength ? (pts[i].y - pts[i - 1].y) / seg : 0
                )
            }
            want -= seg
        }
    }
    return PointOnPath(x: last.x, y: last.y, dx: 1, dy: 0)
}

public struct SegmentMid: Hashable, Sendable {
    public var x, y: Double
    public var horizontal: Bool
    public var length: Double
    public init(x: Double, y: Double, horizontal: Bool, length: Double) {
        self.x = x; self.y = y; self.horizontal = horizontal; self.length = length
    }
}

/// `longestSegmentMid(pts)` — the midpoint of the longest segment, where an
/// arrow label reads best; the first segment wins a tie. With fewer than two
/// points, on which the web app throws, the single point (or origin) is used.
public func longestSegmentMid(_ pts: [Point]) -> SegmentMid {
    guard pts.count >= 2 else {
        let p = pts.first ?? Point(x: 0, y: 0)
        return SegmentMid(x: p.x, y: p.y, horizontal: true, length: 0)
    }
    var best = 0.0, bi = 1
    for i in 1..<pts.count {
        let length = jsHypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        if length > best { best = length; bi = i }
    }
    let a = pts[bi - 1], b = pts[bi]
    let horizontal = abs(b.x - a.x) >= abs(b.y - a.y)
    return SegmentMid(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, horizontal: horizontal, length: best)
}

/// `distToPolyline(pts, pt)` — Infinity for fewer than two points.
public func distToPolyline(_ pts: [Point], _ pt: Point) -> Double {
    var best = Double.infinity
    if pts.count > 1 {
        for i in 1..<pts.count { best = jsMin(best, distToSegment(pts[i - 1], pts[i], pt)) }
    }
    return best
}

/// The point of segment `a`-`b` nearest `p`, clamped to the segment itself.
private func segmentClosestPoint(_ a: Point, _ b: Point, _ p: Point) -> Point {
    let vx = b.x - a.x, vy = b.y - a.y
    let len2 = vx * vx + vy * vy
    let t = isTruthy(len2) ? jsMax(0, jsMin(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2)) : 0
    return Point(x: a.x + t * vx, y: a.y + t * vy)
}

private func distToSegment(_ a: Point, _ b: Point, _ p: Point) -> Double {
    let c = segmentClosestPoint(a, b, p)
    return jsHypot(p.x - c.x, p.y - c.y)
}

/// `nearestPointOnPolyline(pts, pt)` (F66) — the point of `pts` nearest `pt`;
/// ties go to the earlier segment, as `distToPolyline`'s own `jsMin` scan
/// would light on first. The origin for a fewer-than-two-point polyline,
/// which no real route ever is.
public func nearestPointOnPolyline(_ pts: [Point], _ pt: Point) -> Point {
    var best: Point?
    var bestD = Double.infinity
    if pts.count > 1 {
        for i in 1..<pts.count {
            let c = segmentClosestPoint(pts[i - 1], pts[i], pt)
            let d = jsHypot(pt.x - c.x, pt.y - c.y)
            if d < bestD { bestD = d; best = c }
        }
    }
    return best ?? (pts.first ?? Point(x: 0, y: 0))
}

/// `pointInRect(r, p)` — edges count as inside.
public func pointInRect(_ r: SheetRect, _ p: Point) -> Bool {
    p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h
}

// MARK: - Labels (F59, F66)

/// Helvetica label text, matching the web canvas's `.arr-lbl` class and the
/// SVG export CSS's font-size (`SheetDrawing.arrow`) — both use this size.
private let labelFontSize = 10.5
/// A label's grabbable rectangle is a few units bigger than its measured
/// glyphs each way (F39): a click near the text, not only exactly on ink,
/// still lands, and the same slack keeps `labelPlacement`'s collision checks
/// from hugging a box or an ICOM code too closely.
private let labelPadX = 3.0
private let labelHalfH = 8.0

/// How far a label's displayed position must sit from its arrow's route
/// before it needs a squiggle to say the two belong together (FIPS 183
/// §3.2.2.3 rule 4).
private let squiggleMin = 18.0

/// `labelPlacement`'s or `labelPosition`'s result: where a label draws, and
/// which edge of its text that position anchors.
public struct LabelSpot: Hashable, Sendable {
    public var x, y: Double
    public var anchor: TextAnchor
    public init(x: Double, y: Double, anchor: TextAnchor) { self.x = x; self.y = y; self.anchor = anchor }
}

/// `labelRect(pos, width)` — the rectangle a label at `pos` occupies for
/// `width` sheet units of text: used both to score a placement candidate in
/// `labelPlacement` and to hit-test the label as drawn (`HitTest.label`), so
/// the two never disagree about where the label "is".
public func labelRect(_ pos: LabelSpot, _ width: Double) -> SheetRect {
    let x0: Double
    switch pos.anchor {
    case .middle: x0 = pos.x - width / 2
    case .end: x0 = pos.x - width
    case .start: x0 = pos.x
    }
    return SheetRect(x: x0 - labelPadX, y: pos.y - labelHalfH, w: width + labelPadX * 2, h: labelHalfH * 2)
}

private func rectsOverlap(_ a: SheetRect, _ b: SheetRect) -> Bool {
    a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

/// `legacyLabelBase(pts)` — the position `labelPosition` falls back to once a
/// label carries a manual ldx/ldy: the longest segment's midpoint, offset
/// above it (a horizontal run) or start-anchored just beside it (a vertical
/// one) — the fixed shape every arrow's label used before `labelPlacement`
/// existed, and still the base a manual offset is added to.
public func legacyLabelBase(_ pts: [Point]) -> LabelSpot {
    let mid = longestSegmentMid(pts)
    let off: (x: Double, y: Double) = mid.horizontal ? (0, -9) : (12, 0)
    return LabelSpot(x: mid.x + off.x, y: mid.y + off.y, anchor: mid.horizontal ? .middle : .start)
}

private struct LabelSegment {
    var a, b: Point
    var length: Double
    var index: Int
}

/// `labelPlacement(pts, text, icomEnds, boxes)` — where an arrow's label reads
/// best without colliding with a box, an ICOM code, or running off the frame
/// (FIPS 183 §3.2.2.3 rule 2e; B.2.4.2 #2 asks for a "reasonable" distance
/// from boxes). Candidates are every segment's midpoint, longest first (a tie
/// keeps the earlier segment, as `longestSegmentMid` itself would); a
/// horizontal segment offers a position above and below it, a vertical one a
/// start-anchored position 12 units out and an end-anchored one 12 units the
/// other way — `legacyLabelBase`'s own shape, so the first candidate of the
/// longest segment is identical to it and nothing moves when nothing
/// collides. Each candidate is scored against `boxes`, `icomEnds` and the
/// frame's unsafe margin (its border and the header/footer bands) with fixed
/// integer penalties, worst first: running off the frame is weighted above an
/// ICOM-code collision, which is weighted above a box overlap, because that
/// is the order in which the label actually gets harder to read — cut off
/// outright, glyphs interleaved with a 1-3 character code, or ink simply
/// crossing a box FIPS already draws the label over (F60). On a tie the first
/// minimal-penalty candidate wins, so both apps agree without depending on
/// how ties sort; a diagram cramped enough that nothing scores zero still
/// gets the least-bad placement rather than whichever candidate happened to
/// be default.
private let framePenalty = 3
private let icomPenalty = 2
private let boxPenalty = 1

public func labelPlacement(_ pts: [Point], _ text: String, icomEnds: [SheetRect] = [], boxes: [SheetRect] = []) -> LabelSpot {
    let width = textWidth(text, fontSize: labelFontSize)

    var segs: [LabelSegment] = []
    if pts.count > 1 {
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            segs.append(LabelSegment(a: a, b: b, length: jsHypot(b.x - a.x, b.y - a.y), index: i))
        }
    }
    segs.sort { $0.length != $1.length ? $0.length > $1.length : $0.index < $1.index }

    var candidates: [LabelSpot] = []
    for s in segs {
        let mx = (s.a.x + s.b.x) / 2, my = (s.a.y + s.b.y) / 2
        let horizontal = abs(s.b.x - s.a.x) >= abs(s.b.y - s.a.y)
        if horizontal {
            candidates.append(LabelSpot(x: mx, y: my - 9, anchor: .middle))
            candidates.append(LabelSpot(x: mx, y: my + 9, anchor: .middle))
        } else {
            candidates.append(LabelSpot(x: mx + 12, y: my, anchor: .start))
            candidates.append(LabelSpot(x: mx - 12, y: my, anchor: .end))
        }
    }
    if candidates.isEmpty {
        let p = pts.first ?? Point(x: 0, y: 0)
        candidates.append(LabelSpot(x: p.x, y: p.y, anchor: .middle))
    }

    var best = candidates[0]
    var bestPenalty = Int.max
    for c in candidates {
        let rect = labelRect(c, width)
        var penalty = 0
        if boxes.contains(where: { rectsOverlap(rect, $0) }) { penalty += boxPenalty }
        if icomEnds.contains(where: { rectsOverlap(rect, $0) }) { penalty += icomPenalty }
        if rect.x < frameXLo || rect.x + rect.w > frameXHi || rect.y < frameYLo || rect.y + rect.h > frameYHi { penalty += framePenalty }
        if penalty < bestPenalty { best = c; bestPenalty = penalty }
        if bestPenalty == 0 { break }
    }
    return best
}

/// `labelPosition(pts, arrow, icomEnds, boxes)` — where an arrow's label is
/// actually drawn: `labelPlacement`'s automatic choice while its offset is at
/// the default (0, 0), or `legacyLabelBase` plus ldx/ldy once the modeller has
/// dragged it. Every renderer and hit-test in both apps reads this, so what is
/// drawn is what is clickable — see `routeArrow`'s equivalent guarantee for
/// routes. ldx/ldy of 0 or NaN both count as "at the default", as `|| 0` reads
/// them on the web.
public func labelPosition(_ pts: [Point], _ arrow: Arrow, icomEnds: [SheetRect] = [], boxes: [SheetRect] = []) -> LabelSpot {
    let dx = isTruthy(arrow.ldx) ? arrow.ldx : 0
    let dy = isTruthy(arrow.ldy) ? arrow.ldy : 0
    if dx == 0 && dy == 0 { return labelPlacement(pts, arrow.label, icomEnds: icomEnds, boxes: boxes) }
    let base = legacyLabelBase(pts)
    return LabelSpot(x: base.x + dx, y: base.y + dy, anchor: base.anchor)
}

/// The closest point to `pt` that still lies in `rect` — on its border, for a
/// `pt` outside it, which is the only case `squigglePoints` calls this for.
private func clampToRect(_ pt: Point, _ rect: SheetRect) -> Point {
    Point(x: jsMin(jsMax(pt.x, rect.x), rect.x + rect.w), y: jsMin(jsMax(pt.y, rect.y), rect.y + rect.h))
}

/// `squigglePoints(pts, pos, width)` — FIPS 183 §3.2.2.3 rule 4's squiggle,
/// linking a label to its arrow "unless the ... relationship is obvious": a
/// short zig-zag from the near edge of the label's rectangle to the nearest
/// point on `pts`, returned only once the label's displayed position (`pos`,
/// from `labelPosition`) sits more than `squiggleMin` units from that nearest
/// point. An auto-placed label never needs one — every `labelPlacement`
/// candidate sits within 12 units of its own segment. nil otherwise.
public func squigglePoints(_ pts: [Point], _ pos: LabelSpot, _ width: Double) -> [Point]? {
    let target = nearestPointOnPolyline(pts, Point(x: pos.x, y: pos.y))
    if jsHypot(pos.x - target.x, pos.y - target.y) <= squiggleMin { return nil }
    let edge = clampToRect(target, labelRect(pos, width))
    let dx = target.x - edge.x, dy = target.y - edge.y
    let len = orOne(jsHypot(dx, dy))
    let ux = -dy / len, uy = dx / len
    let amp = 3.0
    return [
        edge,
        Point(x: edge.x + dx / 3 + ux * amp, y: edge.y + dy / 3 + uy * amp),
        Point(x: edge.x + dx * 2 / 3 - ux * amp, y: edge.y + dy * 2 / 3 - uy * amp),
        target,
    ]
}

// MARK: - JavaScript number semantics

/// A number used as a condition: 0 and NaN are falsy.
private func isTruthy(_ v: Double) -> Bool { !(v == 0 || v.isNaN) }

/// `v || 1`.
private func orOne(_ v: Double) -> Double { isTruthy(v) ? v : 1 }

/// `Math.min`: NaN wins, and −0 is less than +0. Swift's `min` does neither.
private func jsMin(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == b { return a.sign == .minus ? a : b }
    return a < b ? a : b
}

/// `Math.max`: NaN wins, and +0 is greater than −0.
private func jsMax(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == b { return a.sign == .plus ? a : b }
    return a > b ? a : b
}

/// `Math.min(...values)` — Infinity for no values.
private func jsMin(_ values: [Double]) -> Double { values.reduce(.infinity) { jsMin($0, $1) } }

/// `Math.max(...values)` — −Infinity for no values.
private func jsMax(_ values: [Double]) -> Double { values.reduce(-.infinity) { jsMax($0, $1) } }

/// `Math.hypot(a, b)` as V8 and JavaScriptCore compute it: both terms scaled
/// by the larger, squared with Kahan-compensated summation, then rescaled.
/// Not correctly rounded, so libm's `hypot` can differ in the last place.
func jsHypot(_ a: Double, _ b: Double) -> Double {
    let x = abs(a), y = abs(b)
    if x == .infinity || y == .infinity { return .infinity }
    if x.isNaN || y.isNaN { return .nan }
    let m = x > y ? x : y
    if m == 0 { return 0 }
    var sum = 0.0, compensation = 0.0
    for v in [x, y] {
        let n = v / m
        let summand = n * n - compensation
        let preliminary = sum + summand
        compensation = (preliminary - sum) - summand
        sum = preliminary
    }
    return sum.squareRoot() * m
}
