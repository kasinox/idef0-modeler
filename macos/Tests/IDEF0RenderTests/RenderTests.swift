// The rendered sheet, checked by looking at pixels.
//
// Geometry parity with the web app is proven in IDEF0CoreTests; these tests
// prove the drawing *of* that geometry is right — that a rounded corner curves
// inwards, an arrowhead is filled, a box edge is inked. Each probe asks where
// ink must and must not be, so it fails on the mistakes that look plausible:
// the arc-direction probe, for one, passes 1 corner in 19 when the SVG arc
// centre's sign is flipped.

import CoreGraphics
import Foundation
import Testing
@testable import IDEF0Core
@testable import IDEF0Render

/// The sample model the core suites use, read from their fixture directory.
func sampleModel() throws -> IDEF0Model {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("IDEF0CoreTests/Fixtures/sample.idef0.json")
    var m = try ModelFile.deserialize(try String(contentsOf: url, encoding: .utf8))
    m.bindAll()
    return m
}

/// A rendered sheet whose pixels can be read back in sheet units.
struct Raster {
    let width: Int, height: Int, scale: Double
    private let luma: [UInt8]

    init(_ image: CGImage, scale: Double) {
        width = image.width; height = image.height; self.scale = scale
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        luma = bytes
    }

    /// Darkest luminance in a small square around a sheet point (0 is black).
    func darkest(_ x: Double, _ y: Double, radius: Int = 1) -> UInt8 {
        let cx = Int(x * scale), cy = Int(y * scale)
        var v: UInt8 = 255
        for dy in -radius...radius {
            for dx in -radius...radius {
                let px = cx + dx, py = cy + dy
                guard px >= 0, py >= 0, px < width, py < height else { continue }
                v = min(v, luma[py * width + px])
            }
        }
        return v
    }

    func isInked(_ x: Double, _ y: Double, radius: Int = 1) -> Bool { darkest(x, y, radius: radius) < 150 }
    func isClear(_ x: Double, _ y: Double) -> Bool { darkest(x, y, radius: 0) > 200 }
}

@Suite("Rendering")
struct RenderTests {
    static let scale = 2.0

    func renderA0() throws -> (IDEF0Model, Diagram, Raster) {
        let m = try sampleModel()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let image = try SheetExport.image(m, diagramId: a0.id, scale: Self.scale)
        return (m, a0, Raster(image, scale: Self.scale))
    }

    @Test("Every bend is a 90° arc curving inside its corner (FIPS 183 §3.2.1.3)")
    func cornersCurveInwards() throws {
        let (m, a0, raster) = try renderA0()
        var probed = 0
        // Every drawn route (S02: a fork's branches leave from the trunk).
        let drawn = SheetDrawing.drawnArrows(m, a0)
        for entry in drawn {
            let arrow = entry.arrow
            let pts = entry.pts
            for i in 1..<max(1, pts.count - 1) {
                let p = pts[i - 1], v = pts[i], n = pts[i + 1]
                let lin = hypot(v.x - p.x, v.y - p.y), lout = hypot(n.x - v.x, n.y - v.y)
                let r = min(7, lin / 2, lout / 2)
                let ix = (v.x - p.x) / lin, iy = (v.y - p.y) / lin
                let ox = (n.x - v.x) / lout, oy = (n.y - v.y) / lout
                guard abs(ix * oy - iy * ox) > 0.5, r >= 4 else { continue }
                probed += 1
                // The circle's centre sits inside the corner; its nearest point
                // to the sharp vertex must be inked, and the vertex itself clear.
                let cx = v.x - ix * r + ox * r, cy = v.y - iy * r + oy * r
                let d = hypot(v.x - cx, v.y - cy)
                let mx = cx + (v.x - cx) / d * r, my = cy + (v.y - cy) / d * r
                #expect(raster.isInked(mx, my), "\(arrow.label): arc not inked near (\(v.x), \(v.y))")
                // Where a branch turns off a fork's trunk (S02), the trunk
                // itself runs straight on through the vertex, for the other
                // branches; only a corner no other route passes through
                // must be clear.
                let onAnotherRoute = drawn.contains { other in
                    other.arrow.id != arrow.id && distToPolyline(other.pts, v) < 0.5
                }
                if !onAnotherRoute {
                    #expect(raster.isClear(v.x, v.y), "\(arrow.label): sharp corner inked at (\(v.x), \(v.y))")
                }
            }
        }
        #expect(probed >= 15, "only \(probed) corners probed")
    }

    @Test("Boxes are drawn with solid inked edges and a clear interior")
    func boxEdges() throws {
        let (_, a0, raster) = try renderA0()
        for b in a0.boxes {
            #expect(raster.isInked(b.x, b.y + b.h * 0.25), "\(b.name): left edge")
            #expect(raster.isInked(b.x + b.w, b.y + b.h * 0.75), "\(b.name): right edge")
            #expect(raster.isInked(b.x + b.w * 0.5, b.y), "\(b.name): top edge")
            #expect(raster.isClear(b.x + 6, b.y + 6), "\(b.name): interior corner")
        }
    }

    @Test("F60: a label placed over a box paints on top of the box fill, not under it")
    func labelPaintsOverBoxFill() throws {
        var m = try sampleModel()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        // A drawn label on a horizontal run — placed against its `labelPath`
        // (S02: the whole route of an ungrouped arrow).
        let entry = try #require(SheetDrawing.drawnArrows(m, a0).first { entry in
            !entry.label.isEmpty && entry.labelPath.map { longestSegmentMid($0).horizontal } == true
        })
        let arrow = entry.arrow
        // A box the moved label's own arrow does not touch, well inside its
        // fill and clear of both its centred name and its bottom-right
        // number — `boxEdges` above probes the same kind of interior point.
        let box = try #require(a0.boxes.first { b in !arrow.from.isOnBox(b.id) && !arrow.to.isOnBox(b.id) })
        let probeX = box.x + 8, probeY = box.y + box.h - 22

        let before = Raster(try SheetExport.image(m, diagramId: a0.id, scale: Self.scale), scale: Self.scale)
        #expect(before.isClear(probeX, probeY), "probe point should start clear, before the label moves there")

        let pts = try #require(entry.labelPath)
        let mid = longestSegmentMid(pts)
        let off = mid.horizontal ? (x: 0.0, y: -9.0) : (x: 12.0, y: 0.0)
        var updated = a0
        let i = try #require(updated.arrows.firstIndex { $0.id == arrow.id })
        updated.arrows[i].ldx = probeX - mid.x - off.x
        updated.arrows[i].ldy = probeY - mid.y - off.y
        m.diagrams[a0.id] = updated

        let after = Raster(try SheetExport.image(m, diagramId: a0.id, scale: Self.scale), scale: Self.scale)
        #expect(after.isInked(probeX, probeY), "the label should paint over the box fill drawn after its arrow, not be erased by it")
    }

    @Test("F59: every labelled arrow of the sample model auto-places clear of every ICOM code and stays on the printable sheet")
    func labelsAvoidIcomCodesAndTheFrame() throws {
        let m = try sampleModel()
        let frame = Sheet.frame
        for diagram in m.diagrams.values {
            let drawn = SheetDrawing.drawnArrows(m, diagram)
            let icomEnds = SheetDrawing.icomRects(drawn, codes: m.icomCodes(diagram))
            let boxes = diagram.boxes.map(\.rect)
            // Every label that is drawn (S02: a fork's branches whose label
            // the trunk shows draw none), where it is drawn.
            for entry in drawn where !entry.label.isEmpty {
                guard let labelPath = entry.labelPath else { continue }
                let arrow = entry.arrow
                let pos = labelPosition(labelPath, arrow, icomEnds: icomEnds, boxes: boxes)
                let rect = labelRect(pos, textWidth(arrow.label, fontSize: 10.5))
                let context = "\(diagram.node) \(arrow.label)"
                // The bug this fixes: 'Customer Order' collided with its own
                // 'I1' code, and 'Finished Product'/'Shipping Notice' ran
                // past the sheet's right edge — reproduced in both the Mac
                // PNG and a headless-Chrome render of the web SVG.
                #expect(
                    rect.x >= frame.x && rect.x + rect.w <= frame.x + frame.w
                        && rect.y >= frame.y && rect.y + rect.h <= frame.y + frame.h,
                    "\(context): label rect \(rect) runs off the frame"
                )
                for r in icomEnds {
                    let overlaps = rect.x < r.x + r.w && rect.x + rect.w > r.x && rect.y < r.y + r.h && rect.y + rect.h > r.y
                    #expect(!overlaps, "\(context): label rect \(rect) collides with an ICOM code rect \(r)")
                }
            }
        }
    }

    @Test("Every arrow ends in a filled arrowhead")
    func arrowheads() throws {
        let (m, a0, raster) = try renderA0()
        for entry in SheetDrawing.drawnArrows(m, a0) {
            let arrow = entry.arrow
            let pts = entry.pts
            let t = pts[pts.count - 1], p = pts[pts.count - 2]
            let l = max(hypot(t.x - p.x, t.y - p.y), 1)
            let dx = (t.x - p.x) / l, dy = (t.y - p.y) / l
            // Six units behind the tip and two off the axis lies inside the triangle.
            #expect(raster.isInked(t.x - dx * 6 - dy * 2, t.y - dy * 6 + dx * 2, radius: 0), "\(arrow.label): arrowhead not filled")
        }
    }

    @Test("The model's status is checked on the sheet, and only that one")
    func statusCheckbox() throws {
        let (m, _, raster) = try renderA0()
        let F = Sheet.frame
        for (i, status) in ModelStatus.allCases.enumerated() {
            let y = F.y + 16 + Double(i) * 19
            let filled = raster.darkest(577, y - 3, radius: 1) < 100
            #expect(filled == (status.rawValue == m.status), "\(status.rawValue) box filled: \(filled)")
        }
    }

    @Test("SVG export is well-formed and draws each arrow with the web app's path data")
    func svgMatchesGeometry() throws {
        let m = try sampleModel()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let svg = try #require(SVGWriter.diagram(m, diagramId: a0.id))
        _ = try XMLDocument(xmlString: svg, options: [])
        // Each arrow along its drawn route (S02: a fork's branches from the trunk).
        for entry in SheetDrawing.drawnArrows(m, a0) {
            let arrow = entry.arrow
            let pts = entry.pts
            #expect(svg.contains("d=\"\(pointsToPath(pts))\""), "\(arrow.label): path data differs from pointsToPath")
        }
    }

    @Test("The SVG header comment stays well-formed for a title with adjacent hyphens, escaped as the web escapes it")
    func svgCommentHyphens() throws {
        // XML forbids "--" inside a comment: both apps put a space between every
        // pair of adjacent hyphens, so "---" becomes "- - -" and not "- --".
        #expect(SVGWriter.commentText("Plan -- Build") == "Plan - - Build")
        #expect(SVGWriter.commentText("Make---Ship") == "Make- - -Ship")
        #expect(SVGWriter.commentText("----") == "- - - -")
        #expect(SVGWriter.commentText("a-b-") == "a-b-")
        // The pair is found by code unit, as the web regex finds it, even where a
        // combining mark makes the second hyphen part of a larger Character.
        #expect(Array(SVGWriter.commentText("a--\u{301}b").unicodeScalars) == Array("a- -\u{301}b".unicodeScalars))

        /// Whether two hyphens sit side by side, compared by UTF-16 code unit.
        func hasHyphenPair(_ s: String) -> Bool {
            let u = Array(s.utf16), hyphen = UInt16(UInt8(ascii: "-"))
            return u.indices.dropLast().contains { u[$0] == hyphen && u[$0 + 1] == hyphen }
        }

        var m = try sampleModel()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let cases = [
            ("Plan -- Build", "Plan - - Build"),
            ("Make---Ship", "Make- - -Ship"),
            ("R&D <--> Ops", "R&amp;D &lt;- -&gt; Ops"),
            ("Trailing-", "Trailing-"),
            ("x--\u{301}y", "x- -\u{301}y"),
        ]
        for (title, expected) in cases {
            var d = a0
            d.title = title
            m.diagrams[a0.id] = d
            let svg = try #require(SVGWriter.diagram(m, diagramId: a0.id))
            let head = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!--"
            #expect(svg.hasPrefix(head))
            let rest = String(svg.utf16.dropFirst(head.utf16.count))!
            let line = try #require(rest.split(separator: "\n", maxSplits: 1).first.map(String.init))
            #expect(line.hasSuffix(" -->"))
            let comment = String(line.utf16.dropLast(3))!
            #expect(!hasHyphenPair(comment), "\(title): \(comment)")
            #expect(Array(comment.unicodeScalars) == Array(" IDEF0 diagram A0: \(expected) ".unicodeScalars))
            _ = try XMLDocument(xmlString: svg, options: [])
        }
    }

    @Test("The frame labels' 0.04 em tracking reaches the SVG unrounded")
    func svgLetterSpacing() throws {
        let m = try sampleModel()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let svg = try #require(SVGWriter.diagram(m, diagramId: a0.id))
        // Ems are not sheet units: rounding to a tenth would write 0em.
        #expect(svg.contains("letter-spacing=\"0.04em\">USED AT:</text>"))
        #expect(!svg.contains("letter-spacing=\"0em\""))
    }

    @Test("An empty childDiagramId draws no node label; a dangling id still does, as render.js does")
    func emptyChildDiagramId() throws {
        var m = try sampleModel()
        // The node label sits just outside the box's bottom-right corner.
        func nodeLabels(_ model: IDEF0Model, _ d: Diagram, _ b: Box) -> [String] {
            SheetDrawing.build(model, diagramId: d.id).compactMap { op in
                guard case .text(let s, let at, _, let role) = op, role == .box(b.id),
                      at == Point(x: b.x + b.w + 4, y: b.y + b.h + 11) else { return nil }
                return s
            }
        }
        // The context box is decomposed into A0 and says so.
        let context = try #require(m.contextDiagram)
        let top = try #require(context.boxes.first)
        #expect(!(top.childDiagramId ?? "").isEmpty)
        #expect(nodeLabels(m, context, top) == [boxNode(context, top)])

        var a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let i = try #require(a0.boxes.firstIndex { $0.childDiagramId == nil })
        let box = a0.boxes[i]
        #expect(nodeLabels(m, a0, box).isEmpty)

        a0.boxes[i].childDiagramId = ""
        m.diagrams[a0.id] = a0
        #expect(nodeLabels(m, a0, box).isEmpty, "an empty string is no child")

        a0.boxes[i].childDiagramId = "not-a-diagram"
        m.diagrams[a0.id] = a0
        #expect(nodeLabels(m, a0, box) == [boxNode(a0, box)], "a dangling id is still truthy")
    }

    @Test("A scale that cannot make an image is refused with an error, not a trap")
    func invalidScales() throws {
        let m = try sampleModel()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        // Not finite, non-positive, under a pixel, and over the side limit (30 × 1100 > 32768).
        for scale in [Double.infinity, -.infinity, .nan, 1e300, 0, -2, 0.0001, 30] {
            #expect(throws: SheetExport.Failure.self, "scale \(scale)") {
                try SheetExport.image(m, diagramId: a0.id, scale: scale)
            }
        }
        #expect(String(describing: SheetExport.Failure.invalidScale(.infinity)).contains("32768"))
        // The usual export is untouched.
        let image = try SheetExport.image(m, diagramId: a0.id, scale: 1)
        #expect(image.width == Int(Sheet.size.w) && image.height == Int(Sheet.size.h))
    }

    @Test("The PDF kit has one page per diagram")
    func pdfKit() throws {
        let m = try sampleModel()
        let data = try SheetExport.pdf(m, diagramIds: SheetExport.kitDiagramIds(m))
        let doc = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(doc.numberOfPages == m.diagrams.count)
        let box = try #require(doc.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(box.width == 792 && box.height == 612, "landscape US Letter, got \(box)")
    }

    // MARK: S01 — ports and bundles

    private func role(of op: DrawOp) -> DrawRole {
        switch op {
        case .rect(_, _, _, let r), .line(_, _, _, let r), .path(_, _, _, let r), .text(_, _, _, let r),
             .circle(_, _, _, _, let r):
            return r
        }
    }

    /// The sample with Plan Production decomposed and nothing connected on
    /// the child yet: a port per parent ICOM entry (I1, C1, O1).
    private func decomposedChild() throws -> (IDEF0Model, Diagram) {
        var m = try sampleModel()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let plan = try #require(a0.boxes.first { $0.name == "Plan Production" })
        let childId = m.decomposeBox(diagramId: a0.id, boxId: plan.id, count: 3)
        let child = try #require(childId.flatMap { m.diagrams[$0] })
        return (m, child)
    }

    @Test("S01: a port draws an open ring at its inner end, a dashed stub in from the edge, and its code and label")
    func portsAreDrawn() throws {
        let (m, child) = try decomposedChild()
        let ports = m.ports(child)
        #expect(ports.map(\.code) == ["I1", "C1", "O1"])
        let raster = Raster(try SheetExport.image(m, diagramId: child.id, scale: Self.scale), scale: Self.scale)
        for p in ports {
            let s = portShape(p)
            // The ring: inked on its rim all four ways round, the sheet's own
            // white at its centre — an open circle, not a filled dot.
            for (dx, dy) in [(-4.0, 0.0), (4, 0), (0, -4), (0, 4)] {
                #expect(raster.isInked(s.inner.x + dx, s.inner.y + dy), "\(p.code): ring not inked at (\(dx), \(dy))")
            }
            #expect(raster.isClear(s.inner.x, s.inner.y), "\(p.code): ring centre should be open")
            // The stub: dashed 4 on, 3 off from the edge inwards — ink inside
            // the first dash, none in the first gap.
            let ux = (s.inner.x - s.edge.x) / 26, uy = (s.inner.y - s.edge.y) / 26
            #expect(raster.isInked(s.edge.x + ux * 2, s.edge.y + uy * 2, radius: 0), "\(p.code): first dash not inked")
            #expect(raster.isClear(s.edge.x + ux * 5.5, s.edge.y + uy * 5.5), "\(p.code): first gap inked")
        }

        // Every op of a port carries its parent arrow's id; the child has no
        // arrows, so nothing else is annotated. The SVG writes the ring as a
        // <circle> and the stub with the web app's own path data, dashed.
        let ops = SheetDrawing.build(m, diagramId: child.id)
        let portOps = ops.filter { if case .port = role(of: $0) { return true } else { return false } }
        #expect(portOps.count == ports.count * 4, "stub, ring, code and label per port")
        #expect(ports.allSatisfy { p in portOps.contains { role(of: $0) == .port(p.parentArrowId) } })
        let texts = portOps.compactMap { op -> String? in if case .text(let s, _, _, _) = op { return s } else { return nil } }
        #expect(texts == ["I1", "Customer Order", "C1", "Production Schedule", "O1", "Work Order"])
        #expect(!ops.contains { if case .arrow = role(of: $0) { return true } else { return false } })
        let svg = try #require(SVGWriter.diagram(m, diagramId: child.id))
        _ = try XMLDocument(xmlString: svg, options: [])
        for p in ports {
            let s = portShape(p)
            #expect(svg.contains("d=\"\(pointsToPath([s.edge, s.inner]))\" fill=\"none\" stroke=\"#5b6470\" stroke-width=\"1.2\" stroke-dasharray=\"4 3\""), "\(p.code): stub")
            #expect(svg.contains("<circle cx=\"\(jsNumberString(s.inner.x))\" cy=\"\(jsNumberString(s.inner.y))\" r=\"4\" fill=\"#ffffff\" stroke=\"#111418\" stroke-width=\"1.4\"/>"), "\(p.code): ring")
        }
        #expect(svg.contains("font-style=\"italic\" fill=\"#5b6470\" dominant-baseline=\"middle\">Customer Order</text>"),
                "the label is muted italic, centred on the ring")
    }

    @Test("S01: a port's label sits beside its ring — to the right, or to the left where the right would run off the sheet")
    func portLabelsBesideTheRing() throws {
        let (m, child) = try decomposedChild()
        let ops = SheetDrawing.build(m, diagramId: child.id)
        func label(_ p: ICOMPort) -> (Point, TextAnchor)? {
            for op in ops {
                if case .text(let s, let at, let style, let r) = op, r == .port(p.parentArrowId), s == p.label { return (at, style.anchor) }
            }
            return nil
        }
        for p in m.ports(child) {
            let s = portShape(p)
            let (at, anchor) = try #require(label(p), "\(p.code): no label op")
            #expect(at.y == s.inner.y, "\(p.code): centred on the ring")
            if p.side == .right {
                #expect(at.x == s.inner.x - 12 && anchor == .end, "\(p.code): left of the ring, since the right runs off the sheet")
            } else {
                #expect(at.x == s.inner.x + 12 && anchor == .start, "\(p.code): right of the ring")
            }
        }
    }

    @Test("S01: a bundle's hidden member draws nothing — its own route, inked before combining, is clear after — and the representative reads the bundle's term")
    func hiddenBundleMemberDrawsNothing() throws {
        var m = try sampleModel()
        let ctx = try #require(m.contextDiagram)
        let co = try #require(ctx.arrows.first { $0.label == "Customer Order" })
        let rm = try #require(ctx.arrows.first { $0.label == "Raw Materials" })
        let coPts = routeArrow(ctx, co), rmPts = routeArrow(ctx, rm)
        // A point on the hidden member's own route, well away from the
        // representative's — where the two drawings differ.
        let probe = longestSegmentMid(rmPts)
        #expect(distToPolyline(coPts, Point(x: probe.x, y: probe.y)) > 20)
        let before = Raster(try SheetExport.image(m, diagramId: ctx.id, scale: Self.scale), scale: Self.scale)
        #expect(before.isInked(probe.x, probe.y, radius: 0), "Raw Materials draws before it is bundled")

        let members = ["Customer Order", "Raw Materials"].compactMap { m.findConcept($0)?.id }
        _ = try m.combineConcepts(members, term: "Inputs")
        let bundled = try #require(m.diagrams[ctx.id])
        let drawn = SheetDrawing.drawnArrows(m, bundled)
        #expect(drawn.count == bundled.arrows.count - 1)
        #expect(drawn.first?.arrow.id == co.id && drawn.first?.label == "Inputs" && drawn.first?.hidden == [rm.id])
        #expect(!drawn.contains { $0.arrow.id == rm.id })
        #expect(drawn.dropFirst().allSatisfy { $0.label == $0.arrow.label && $0.hidden.isEmpty })

        let after = Raster(try SheetExport.image(m, diagramId: ctx.id, scale: Self.scale), scale: Self.scale)
        #expect(after.isClear(probe.x, probe.y), "the hidden member's route must not be inked")
        // The representative is routed as the one line it now is (S02: the
        // member that draws nothing spreads no lane), and inked there.
        let coDrawn = try #require(drawn.first { $0.arrow.id == co.id }).pts
        let coMid = longestSegmentMid(coDrawn)
        #expect(after.isInked(coMid.x, coMid.y, radius: 0), "the representative is drawn on its drawn route")
        let ops = SheetDrawing.build(m, diagramId: ctx.id)
        #expect(!ops.contains { role(of: $0) == .arrow(rm.id) || role(of: $0) == .arrowLabel(rm.id) })
        let labels = ops.compactMap { op -> (String, DrawRole)? in
            if case .text(let s, _, _, let r) = op, case .arrowLabel = r { return (s, r) } else { return nil }
        }
        #expect(labels.contains { $0 == ("Inputs", .arrowLabel(co.id)) })
        #expect(!labels.contains { $0.0 == "Customer Order" || $0.0 == "Raw Materials" })
    }
}
