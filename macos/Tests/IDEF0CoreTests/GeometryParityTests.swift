// Anchors, routing and path data against goldens captured by running the web
// app's src/model/geometry.js: 500 random routing cases, 200 nearest-side
// cases, and every arrow of the sample model under the scenarios whose edits
// only touch arrow geometry.
//
// Everything is compared exactly except distances, which go through `jsonDiff`'s
// relative tolerance because `Math.hypot` is not correctly rounded.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("GeometryParity")
struct GeometryParityTests {

    // MARK: Random routing cases

    @Test("500 random routes: anchors, points, path data, label spot, length, pointAt and distance")
    func randomRoutes() throws {
        let routes = try #require(Fixtures.json("golden-geometry.json").objectValue?["routes"]?.arrayValue)
        #expect(routes.count == 500)
        var checked = 0
        for (i, value) in routes.enumerated() {
            let c = try #require(value.objectValue)
            let boxes = try #require(c["boxes"]?.arrayValue).map(box(from:))
            let diagram = Diagram(id: "golden", node: "A0", title: "", boxes: boxes)
            let from = try endpoint(c["from"]), to = try endpoint(c["to"])
            let bend: Double? = c["bend"]?.isNull == false ? number(c["bend"]) : nil

            let a = anchorOf(diagram, from)
            let b = anchorOf(diagram, to)
            let pts = routePoints(a, b, bend: bend, obstacles: boxes.map(\.rect))

            expectSame(c["A"], json(a), "route \(i) A")
            expectSame(c["B"], json(b), "route \(i) B")
            expectSame(c["pts"], json(pts), "route \(i) pts")
            #expect(pointsToPath(pts) == c["path"]?.stringValue, "route \(i) path")
            expectSame(c["mid"], json(longestSegmentMid(pts)), "route \(i) mid")
            expectSame(c["len"], .number(pathLength(pts)), "route \(i) len")
            expectSame(c["at25"], json(pointAt(pts, 0.25)), "route \(i) at25")
            expectSame(c["dist"], .number(distToPolyline(pts, Point(x: 550, y: 440))), "route \(i) dist", tolerance: 1e-9)
            // F66.
            expectSame(c["nearestPt"], json(nearestPointOnPolyline(pts, Point(x: 550, y: 440))), "route \(i) nearestPt", tolerance: 1e-9)
            checked += 9
        }
        #expect(checked == 4500)
    }

    // MARK: Routing edge cases (F57, F58)

    @Test("Flush and near-edge boxes: facing ends closer than two stubs, the frame clamp, a degenerate boundary source, and an L-route that would cross its own target box")
    func edgeCases() throws {
        let cases = try #require(Fixtures.json("golden-edge-cases.json").arrayValue)
        #expect(cases.count == 12)
        for value in cases {
            let c = try #require(value.objectValue)
            let name = c["name"]?.stringValue ?? "?"
            let boxes = try #require(c["boxes"]?.arrayValue).map(box(from:))
            let diagram = Diagram(id: "edge", node: "A0", title: "", boxes: boxes)
            let from = try endpoint(c["from"]), to = try endpoint(c["to"])

            let a = anchorOf(diagram, from)
            let b = anchorOf(diagram, to)
            let pts = routePoints(a, b, obstacles: boxes.map(\.rect))

            expectSame(c["A"], json(a), "\(name) A")
            expectSame(c["B"], json(b), "\(name) B")
            expectSame(c["pts"], json(pts), "\(name) pts")
            #expect(pointsToPath(pts) == c["path"]?.stringValue, "\(name) path")
            expectSame(c["mid"], json(longestSegmentMid(pts)), "\(name) mid")
        }
    }

    // MARK: Lane groups (F61)

    @Test("Parallel arrows between the same faces spread into separate lanes; a fork keeps one overlapping route; a pinned bend is excluded")
    func laneGroups() throws {
        let groups = try #require(Fixtures.json("golden-lane-groups.json").arrayValue)
        #expect(groups.count == 4)
        for value in groups {
            let g = try #require(value.objectValue)
            let name = g["name"]?.stringValue ?? "?"
            let boxes = try #require(g["boxes"]?.arrayValue).map(box(from:))
            let arrowValues = try #require(g["arrows"]?.arrayValue)
            let arrows = try arrowValues.map(laneGroupArrow(from:))
            let diagram = Diagram(id: "lanes", node: "A0", title: "", boxes: boxes, arrows: arrows)
            let expectedRoutes = try #require(g["routes"]?.objectValue)

            for arrow in arrows {
                let pts = routeArrow(diagram, arrow)
                expectSame(expectedRoutes[arrow.id], json(pts), "\(name) \(arrow.label) pts")
            }
        }
    }

    // MARK: Nearest side

    @Test("200 nearest-side and point-in-rect cases")
    func nearest() throws {
        let cases = try #require(Fixtures.json("golden-geometry.json").objectValue?["nearest"]?.arrayValue)
        #expect(cases.count == 200)
        for (i, value) in cases.enumerated() {
            let c = try #require(value.objectValue)
            let r = try rect(c["rect"])
            let p = try point(c["pt"])
            let ns = nearestSide(r, p)
            let expected = try #require(c["ns"]?.objectValue)
            #expect(ns.side.rawValue == expected["side"]?.stringValue, "nearest \(i) side")
            expectSame(expected["pos"], .number(ns.pos), "nearest \(i) pos")
            #expect(c["inRect"] == .bool(pointInRect(r, p)), "nearest \(i) inRect")
        }
    }

    // MARK: Scenario diagrams

    /// Scenarios whose edits touch only arrows, so they replay here without
    /// the model operations. The rest are covered by the full scenario harness.
    static let geometryScenarios = [
        "baseline", "swap-controls", "tunnelled-boundary", "ctx-tunnel", "feedback", "orphan", "missing",
    ]

    @Test("Every arrow of a scenario routes as the web app routed it", arguments: geometryScenarios)
    func scenario(_ name: String) throws {
        var model = try ModelFile.deserialize(Fixtures.sampleText)
        try replay(name, on: &model)

        let golden = try #require(Fixtures.json("golden-scenarios.json").objectValue?[name]?.objectValue)
        let diagrams = try #require(golden["diagrams"]?.arrayValue)
        #expect(diagrams.count == model.diagrams.count, "\(name): diagram count")
        for dv in diagrams {
            let dg = try #require(dv.objectValue)
            let id = try #require(dg["id"]?.stringValue)
            let diagram = try #require(model.diagrams[id], "\(name): no diagram \(id)")
            let arrows = try #require(dg["arrows"]?.arrayValue)
            #expect(arrows.count == diagram.arrows.count, "\(name) \(diagram.node): arrow count")
            let obstacles = diagram.boxes.map(\.rect)
            for av in arrows {
                let ga = try #require(av.objectValue)
                let arrowId = try #require(ga["id"]?.stringValue)
                let arrow = try #require(diagram.arrows.first { $0.id == arrowId }, "\(name): no arrow \(arrowId)")
                let context = "\(name) \(diagram.node) \(arrow.label)"

                let a = anchorOf(diagram, arrow.from)
                let b = anchorOf(diagram, arrow.to)
                let pts = routePoints(a, b, bend: arrow.bend, obstacles: obstacles)

                expectSame(ga["from"], json(a), "\(context) from")
                expectSame(ga["to"], json(b), "\(context) to")
                expectSame(ga["pts"], json(pts), "\(context) pts")
                #expect(pointsToPath(pts) == ga["path"]?.stringValue, "\(context) path")
                expectSame(ga["mid"], json(longestSegmentMid(pts)), "\(context) mid")
                expectSame(ga["at"], json(pointAt(pts, 0.5)), "\(context) at")
                expectSame(ga["dist"], .number(distToPolyline(pts, Point(x: 500, y: 400))), "\(context) dist", tolerance: 1e-9)
            }
        }
    }

    // MARK: Renderer commands and edge cases

    @Test("Path data is the rounded rendering of the renderer's commands")
    func commandsMatchPathData() {
        let pts = [Point(x: 40, y: 243.96), Point(x: 70, y: 243.96), Point(x: 70, y: 228), Point(x: 100, y: 228)]
        let commands = roundedPathCommands(pts)
        #expect(commands == [
            .move(Point(x: 40, y: 243.96)),
            .line(Point(x: 63, y: 243.96)),
            .arc(radius: 7, sweepPositive: false, end: Point(x: 70, y: 243.96 - 7)),
            .line(Point(x: 70, y: 235)),
            .arc(radius: 7, sweepPositive: true, end: Point(x: 77, y: 228)),
            .line(Point(x: 100, y: 228)),
        ])
        #expect(pointsToPath(pts) == "M40 244 L63 244 A7 7 0 0 0 70 237 L70 235 A7 7 0 0 1 77 228 L100 228")
    }

    @Test("Degenerate inputs behave as geometry.js does")
    func degenerate() {
        #expect(pointsToPath([]) == "")
        #expect(pointsToPath([Point(x: 1.25, y: -0.04)]) == "M1.3 0")
        #expect(distToPolyline([Point(x: 1, y: 1)], Point(x: 0, y: 0)) == .infinity)
        // F66: the origin's own point stands in for "nearest" on a fewer-than-two-point polyline.
        #expect(nearestPointOnPolyline([Point(x: 1, y: 1)], Point(x: 0, y: 0)) == Point(x: 1, y: 1))
        #expect(nearestPointOnPolyline([], Point(x: 5, y: 5)) == Point(x: 0, y: 0))
        #expect(pointAt([Point(x: 3, y: 4)], 0.5) == PointOnPath(x: 3, y: 4, dx: 1, dy: 0))

        // Equal distances go to the first of left, right, top, bottom.
        let corner = nearestSide(SheetRect(x: 0, y: 0, w: 100, h: 100), Point(x: 100, y: 0))
        #expect(corner.side == .right && corner.pos == 0.02)

        // A missing box anchors at the drawing area's corner and is not ok.
        let diagram = Diagram(id: "d", node: "A0", title: "")
        let anchor = anchorOf(diagram, .box("nope", .top, 0.5))
        #expect(anchor == Anchor(x: Sheet.work.x, y: Sheet.work.y, nx: 0, ny: -1, boundary: false, ok: false))
    }

    // MARK: Label placement (F59, F66)

    /// Every labelled arrow of every sample diagram, in its real box and ICOM
    /// context — including the shipped 'Customer Order'/I1 collision and the
    /// 'Finished Product'/'Shipping Notice' frame overflow this fixes.
    @Test("Every labelled arrow of the sample model auto-places, or offsets, exactly as the web app does")
    func labelPlacementSampleDiagrams() throws {
        let diagrams = try #require(Fixtures.json("golden-labels.json").objectValue?["diagrams"]?.arrayValue)
        #expect(diagrams.count == 2)
        for dv in diagrams {
            let d = try #require(dv.objectValue)
            let node = d["node"]?.stringValue ?? "?"
            let icomEnds = try rects(d["icomEnds"])
            let boxes = try rects(d["boxes"])
            let arrows = try #require(d["arrows"]?.arrayValue)
            for av in arrows {
                let a = try #require(av.objectValue)
                let label = a["label"]?.stringValue ?? "?"
                let context = "\(node) \(label)"
                let pts = try points(a["pts"])
                let arrow = Arrow(
                    id: a["id"]?.stringValue ?? "", label: label, from: .boundary(.left, 0.5), to: .boundary(.right, 0.5),
                    ldx: number(a["ldx"]), ldy: number(a["ldy"])
                )
                expectSame(a["auto"], json(labelPlacement(pts, label, icomEnds: icomEnds, boxes: boxes)), "\(context) auto")
                expectSame(a["base"], json(legacyLabelBase(pts)), "\(context) base")
                let displayed = labelPosition(pts, arrow, icomEnds: icomEnds, boxes: boxes)
                expectSame(a["displayed"], json(displayed), "\(context) displayed")
                let width = textWidth(label, fontSize: 10.5)
                expectSame(a["rect"], json(labelRect(displayed, width)), "\(context) rect")
                expectSame(a["squiggle"], jsonOptionalPoints(squigglePoints(pts, displayed, width)), "\(context) squiggle", tolerance: 1e-9)
            }
        }
    }

    /// The same arrows, manually dragged: a small offset stays close enough
    /// to its route that no squiggle is drawn; a large one gets one back.
    @Test("A manually offset label keeps ldx/ldy meaning, and squiggles back to its route once far enough away")
    func labelPlacementDragged() throws {
        let cases = try #require(Fixtures.json("golden-labels.json").objectValue?["dragged"]?.arrayValue)
        #expect(cases.count == 3)
        for value in cases {
            let c = try #require(value.objectValue)
            let label = c["label"]?.stringValue ?? "?"
            let ldx = number(c["ldx"]), ldy = number(c["ldy"])
            let context = "\(label) (\(ldx), \(ldy))"
            let pts = try points(c["pts"])
            let arrow = Arrow(id: "a", label: label, from: .boundary(.left, 0.5), to: .boundary(.right, 0.5), ldx: ldx, ldy: ldy)
            expectSame(c["auto"], json(labelPlacement(pts, label)), "\(context) auto")
            expectSame(c["base"], json(legacyLabelBase(pts)), "\(context) base")
            let displayed = labelPosition(pts, arrow)
            expectSame(c["displayed"], json(displayed), "\(context) displayed")
            let width = textWidth(label, fontSize: 10.5)
            expectSame(c["rect"], json(labelRect(displayed, width)), "\(context) rect")
            expectSame(c["squiggle"], jsonOptionalPoints(squigglePoints(pts, displayed, width)), "\(context) squiggle", tolerance: 1e-9)
        }
    }

    /// Hand-built cases `labelPlacement`'s own candidate order and penalty
    /// weights: a clean default, a tie between equal segments, a vertical
    /// run whose blocked side is passed over, a diagram cramped enough that
    /// every candidate collides with something (where the frame penalty
    /// outweighing a box penalty, and an ICOM penalty outweighing a box
    /// penalty, decide the outcome), and a long label clamped onto the sheet.
    @Test("labelPlacement's candidate order and penalty weights match the web app's, case by case")
    func labelPlacementBattery() throws {
        let cases = try #require(Fixtures.json("golden-labels.json").objectValue?["battery"]?.arrayValue)
        #expect(cases.count == 7)
        for value in cases {
            let c = try #require(value.objectValue)
            let name = c["name"]?.stringValue ?? "?"
            let pts = try points(c["pts"])
            let text = c["text"]?.stringValue ?? ""
            let icomEnds = try rects(c["icomEnds"])
            let boxes = try rects(c["boxes"])
            let placement = labelPlacement(pts, text, icomEnds: icomEnds, boxes: boxes)
            expectSame(c["placement"], json(placement), "\(name) placement")
            expectSame(c["rect"], json(labelRect(placement, textWidth(text, fontSize: 10.5))), "\(name) rect")
        }
    }

    /// A squiggle links a far-off label back to its route (FIPS 183
    /// §3.2.2.3 rule 4); one close enough — auto-placed labels always are —
    /// gets none. The threshold test is strictly '>', so exactly at it is
    /// still "close enough".
    @Test("squigglePoints appears only once a label sits more than 18 units from its route, identically in both apps")
    func squiggleCases() throws {
        let cases = try #require(Fixtures.json("golden-squiggles.json").arrayValue)
        #expect(cases.count == 5)
        for value in cases {
            let c = try #require(value.objectValue)
            let name = c["name"]?.stringValue ?? "?"
            let pts = try points(c["pts"])
            let pos = try labelSpot(c["pos"])
            let width = number(c["width"])
            expectSame(c["nearest"], json(nearestPointOnPolyline(pts, Point(x: pos.x, y: pos.y))), "\(name) nearest", tolerance: 1e-9)
            expectSame(c["squiggle"], jsonOptionalPoints(squigglePoints(pts, pos, width)), "\(name) squiggle", tolerance: 1e-9)
        }
    }
}

// MARK: - Replaying scenario edits

/// Applies the arrow-only ops of scenarios.json: setArrow, swapPos, addArrow, removeArrow.
private func replay(_ name: String, on model: inout IDEF0Model) throws {
    let scenarios = try #require(Fixtures.json("scenarios.json").arrayValue)
    let scenario = try #require(scenarios.first { $0.objectValue?["name"]?.stringValue == name }?.objectValue)
    for opValue in try #require(scenario["ops"]?.arrayValue) {
        let op = try #require(opValue.objectValue)
        let node = try #require(op["diagram"]?.stringValue)
        let diagramId = try #require(model.diagrams.values.first { $0.node == node }?.id)
        let kind = op["op"]?.stringValue
        let replayed: Void? = try model.updateDiagram(diagramId) { d in
            switch kind {
            case "setArrow":
                let i = try arrowIndex(in: d, op)
                let field = op["field"]?.stringValue
                let value = op["value"] == .bool(true)
                switch field {
                case "tunnelFrom": d.arrows[i].tunnelFrom = value
                case "tunnelTo": d.arrows[i].tunnelTo = value
                default: Issue.record("setArrow \(field ?? "?") is not an arrow-geometry edit")
                }
            case "swapPos":
                let labels = try #require(op["labels"]?.arrayValue).compactMap(\.stringValue)
                let end = try #require(ArrowEnd(rawValue: op["end"]?.stringValue ?? ""))
                let i = try #require(d.arrows.firstIndex { $0.label == labels[0] })
                let j = try #require(d.arrows.firstIndex { $0.label == labels[1] })
                let p = d.arrows[i][end].pos
                d.arrows[i][end].pos = d.arrows[j][end].pos
                d.arrows[j][end].pos = p
            case "addArrow":
                let bend: Double? = op["bend"]?.isNull == false ? number(op["bend"]) : nil
                d.arrows.append(Arrow(
                    id: try #require(op["id"]?.stringValue),
                    label: op["label"]?.stringValue ?? "",
                    from: try scenarioEndpoint(op["from"], in: d),
                    to: try scenarioEndpoint(op["to"], in: d),
                    bend: bend
                ))
            case "removeArrow":
                let i = try arrowIndex(in: d, op)
                d.arrows.remove(at: i)
            default:
                Issue.record("\(name): op \(kind ?? "?") is not an arrow-geometry edit")
            }
        }
        #expect(replayed != nil)
    }
}

private func arrowIndex(in d: Diagram, _ op: JSONObject) throws -> Int {
    if let label = op["label"]?.stringValue {
        return try #require(d.arrows.firstIndex { $0.label == label }, "no arrow labelled \(label)")
    }
    return Int(number(op["index"]))
}

/// A scenario endpoint names its box by name rather than id.
private func scenarioEndpoint(_ v: JSONValue?, in d: Diagram) throws -> Endpoint {
    let o = try #require(v?.objectValue)
    let side = try #require(Side(rawValue: o["side"]?.stringValue ?? ""))
    let pos = number(o["pos"])
    if o["type"]?.stringValue == "box" {
        let boxName = try #require(o["box"]?.stringValue)
        let box = try #require(d.boxes.first { $0.name == boxName }, "no box named \(boxName)")
        return .box(box.id, side, pos)
    }
    return .boundary(side, pos)
}

// MARK: - Golden values in and out

private func number(_ v: JSONValue?) -> Double {
    if case .number(let n)? = v { return n }
    Issue.record("expected a number, got \(v?.stringified(indent: 0) ?? "undefined")")
    return .nan
}

private func box(from v: JSONValue) -> Box {
    let o = v.objectValue ?? JSONObject()
    return Box(
        id: o["id"]?.stringValue ?? "", name: "", number: 0,
        x: number(o["x"]), y: number(o["y"]), w: number(o["w"]), h: number(o["h"])
    )
}

private func endpoint(_ v: JSONValue?) throws -> Endpoint {
    let o = try #require(v?.objectValue)
    let side = try #require(Side(rawValue: o["side"]?.stringValue ?? ""))
    let pos = number(o["pos"])
    if o["type"]?.stringValue == "box" {
        return Endpoint(kind: .box, boxId: o["boxId"]?.stringValue, side: side, pos: pos)
    }
    return .boundary(side, pos)
}

/// An arrow from golden-lane-groups.json: id, label, from, to, bend.
private func laneGroupArrow(from v: JSONValue) throws -> Arrow {
    let o = try #require(v.objectValue)
    let bend: Double? = o["bend"]?.isNull == false ? number(o["bend"]) : nil
    return Arrow(
        id: try #require(o["id"]?.stringValue), label: o["label"]?.stringValue ?? "",
        from: try endpoint(o["from"]), to: try endpoint(o["to"]), bend: bend
    )
}

private func rect(_ v: JSONValue?) throws -> SheetRect {
    let o = try #require(v?.objectValue)
    return SheetRect(x: number(o["x"]), y: number(o["y"]), w: number(o["w"]), h: number(o["h"]))
}

private func point(_ v: JSONValue?) throws -> Point {
    let o = try #require(v?.objectValue)
    return Point(x: number(o["x"]), y: number(o["y"]))
}

private func rects(_ v: JSONValue?) throws -> [SheetRect] {
    try (v?.arrayValue ?? []).map(rect)
}

private func points(_ v: JSONValue?) throws -> [Point] {
    try (v?.arrayValue ?? []).map(point)
}

/// A `labelPlacement`/`labelPosition` result: `{x, y, anchor}`, `anchor` one
/// of "start", "middle" or "end".
private func labelSpot(_ v: JSONValue?) throws -> LabelSpot {
    let o = try #require(v?.objectValue)
    let anchor = try #require(TextAnchor(rawValue: o["anchor"]?.stringValue ?? ""))
    return LabelSpot(x: number(o["x"]), y: number(o["y"]), anchor: anchor)
}

private func object(_ members: [(String, JSONValue)]) -> JSONValue {
    .object(JSONObject(members.map { JSONMember($0.0, $0.1) }))
}

private func json(_ a: Anchor) -> JSONValue {
    object([("x", .number(a.x)), ("y", .number(a.y)), ("nx", .number(a.nx)), ("ny", .number(a.ny)),
            ("boundary", .bool(a.boundary)), ("ok", .bool(a.ok))])
}

private func json(_ pts: [Point]) -> JSONValue {
    .array(pts.map { object([("x", .number($0.x)), ("y", .number($0.y))]) })
}

private func json(_ m: SegmentMid) -> JSONValue {
    object([("x", .number(m.x)), ("y", .number(m.y)), ("horizontal", .bool(m.horizontal)), ("length", .number(m.length))])
}

private func json(_ p: PointOnPath) -> JSONValue {
    object([("x", .number(p.x)), ("y", .number(p.y)), ("dx", .number(p.dx)), ("dy", .number(p.dy))])
}

private func json(_ p: Point) -> JSONValue {
    object([("x", .number(p.x)), ("y", .number(p.y))])
}

private func json(_ r: SheetRect) -> JSONValue {
    object([("x", .number(r.x)), ("y", .number(r.y)), ("w", .number(r.w)), ("h", .number(r.h))])
}

private func json(_ s: LabelSpot) -> JSONValue {
    object([("x", .number(s.x)), ("y", .number(s.y)), ("anchor", .string(s.anchor.rawValue))])
}

/// `squigglePoints`'s optional result: `null`, or the same shape `json(_
/// pts:)` writes for a route.
private func jsonOptionalPoints(_ pts: [Point]?) -> JSONValue {
    guard let pts else { return .null }
    return json(pts)
}

/// Exact unless a tolerance is given; the golden value must be present.
private func expectSame(
    _ expected: JSONValue?, _ actual: JSONValue, _ context: String, tolerance: Double = 0,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let expected else {
        Issue.record("\(context): missing from the golden", sourceLocation: sourceLocation)
        return
    }
    let diff = jsonDiff(expected, actual, tolerance: tolerance)
    #expect(diff == nil, "\(context): \(diff ?? "")", sourceLocation: sourceLocation)
}
