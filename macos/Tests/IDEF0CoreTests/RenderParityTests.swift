// F67: SheetDrawing.build (Drawing.swift), a port of src/ui/render.js, has
// text layout — box names, box numbers and node labels, arrow labels and
// their squiggles, ICOM codes, tunnel marks, and the sheet frame's own
// AUTHOR/DATE/PROJECT/NODE/TITLE/NUMBER values and PURPOSE/VIEWPOINT
// statement — that no golden compared against render.js before this file.
// golden-render.json is built by goldens.html: it renders the sample plus
// five purpose-built models (a fresh unnamed box, a tunnelled arrow, a mix of
// one manually moved label and the rest auto-placed; a title long enough to
// make fitText shrink it to an ellipsis and the PURPOSE/VIEWPOINT statement
// wrap across both of its lines; S01's ports — a box decomposed and none of
// its parent concepts connected yet, so the child draws a stub, a ring, a
// code and a label per port; S01's bundles — two inputs combined, so the
// context diagram draws the pair once, labelled with the bundle's term,
// while the child's two branches fork off one boundary line, each keeping
// its own specific label; and S02's forks and joins — the
// 'fork-join-drawn' scenario, whose three-way fork, join and boundary fork
// each draw as one trunk with branches, one label and, at a boundary, one
// code) through render.js's own
// `renderDiagram`, then walks the resulting SVG for its text/path/rect/circle
// elements, grouped by the same role SheetDrawing.build's DrawRole uses
// (sheet, box, arrow, arrowLabel, icom, port).
//
// Deliberately excluded from the comparison: styling (fill, stroke, dash,
// italic) and the frame's grid `<line>`s (a separate DrawOp case this golden
// does not record either). That exclusion is exactly where the documented
// macOS rendering deviations live — the status checkbox is filled with an
// inline style in both apps, but an *unnamed* box is drawn with a solid
// outline on the Mac where the web app also uses a solid outline (FIPS 183
// §3.2.1.3 requires solid lines for every box), so today there is no styling
// divergence to paper over; this header records where one would be hidden if
// a future change introduced it.
//
// Text content and anchors compare exactly; every coordinate goes through
// jsonDiff's default relative tolerance (1e-9), the same one the geometry
// parity suite uses for its `Math.hypot`-derived fields. A `path` op's `d`
// string compares exactly too: both apps round path coordinates to a tenth of
// a sheet unit before formatting (`SVGWriter.n` / render.js's local `r`), the
// same convention GeometryParityTests already relies on for `pointsToPath`.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("RenderParity")
struct RenderParityTests {

    private static let golden = Fixtures.json("golden-render.json").arrayValue!

    /// The six models golden-render.json records, built the same way
    /// goldens.html builds them — directly on a cloned diagram, not through
    /// the scenario op DSL, since ldx/ldy and a long title have no op there
    /// (the fork-join case alone replays its scenario's ops).
    private static func models() throws -> [(name: String, model: IDEF0Model)] {
        var sample = try ModelFile.deserialize(Fixtures.sampleText)
        sample.bindAll()

        var mixed = try ModelFile.deserialize(Fixtures.sampleText)
        mixed.bindAll()
        let a0Id = try #require(mixed.diagrams.first { $0.value.node == "A0" }?.key)
        mixed.updateDiagram(a0Id) { dg in
            dg.boxes.append(Box(id: "bx_rndunnamed", name: "", number: dg.boxes.count + 1, x: 700, y: 150, w: 120, h: 80))
            if let i = dg.arrows.firstIndex(where: { $0.label == "Raw Materials" }) { dg.arrows[i].tunnelFrom = true }
            if let i = dg.arrows.firstIndex(where: { $0.label == "Customer Order" }) { dg.arrows[i].ldx = 90; dg.arrows[i].ldy = 60 }
        }

        var longTitle = try ModelFile.deserialize(Fixtures.sampleText)
        longTitle.bindAll()
        let title = "A Considerably Longer Diagram Title Than the NODE/TITLE Cell Can Hold — And Then Some More Words Piled On Top, Just To Be Certain It Overflows The Cell."
        longTitle.title = title
        longTitle.updateDiagram(longTitle.rootDiagramId) { dg in dg.title = title; dg.titleLocked = true }
        longTitle.purpose = "To describe, at considerably greater length than the two-line PURPOSE band on the printed form can show without wrapping its text across more than a single visual row, exactly how and why this particular model is meant to be read, interpreted and acted upon by everyone downstream who consults it later."
        longTitle.viewpoint = "From the perspective of a reader who arrives with no prior context whatsoever and who still needs the whole picture in a single unhurried pass through the sheet, reading it line by patiently wrapped line from top to bottom."

        // S01 ports: Plan Production decomposed and nothing connected on the
        // child, so it draws a port per parent ICOM entry (I1, C1, O1). The
        // child's fresh box ids are random in both apps, so both give them
        // the same fixed spelling (no arrow refers to them).
        var ports = try ModelFile.deserialize(Fixtures.sampleText)
        ports.bindAll()
        let portsA0 = try #require(ports.diagrams.first { $0.value.node == "A0" }?.key)
        let plan = try #require(ports.diagrams[portsA0]?.boxes.first { $0.name == "Plan Production" }?.id)
        // `#require` cannot wrap a mutating call: the result goes into a `let` first.
        let decomposed = ports.decomposeBox(diagramId: portsA0, boxId: plan, count: 3)
        let childId = try #require(decomposed)
        ports.updateDiagram(childId) { dg in
            for i in dg.boxes.indices { dg.boxes[i].id = "bx_rndp\(i + 1)" }
        }

        // S01 bundles: Customer Order and Raw Materials combined into
        // "Inputs" — one drawn arrow for the pair on A-0, two branches on A0.
        var bundle = try ModelFile.deserialize(Fixtures.sampleText)
        bundle.bindAll()
        let members = ["Customer Order", "Raw Materials"].compactMap { bundle.findConcept($0)?.id }
        #expect(members.count == 2)
        _ = try bundle.combineConcepts(members, term: "Inputs")

        // S02 forks and joins: the 'fork-join-drawn' scenario's model.
        let forkJoin = try ScenarioReplayer.model(for: "fork-join-drawn")

        return [
            ("sample", sample), ("render-mixed", mixed), ("render-long-title", longTitle),
            ("render-ports", ports), ("render-bundle", bundle), ("render-fork-join", forkJoin),
        ]
    }

    @Test("Every diagram's text/path/rect ops match render.js, grouped by role and excluding styling")
    func rendersMatchWebApp() throws {
        let cases = try Self.models()
        #expect(cases.count == Self.golden.count)
        for (name, model) in cases {
            let goldenCase = try #require(Self.golden.first { $0.objectValue?["name"]?.stringValue == name }?.objectValue)
            let goldenDiagrams = try #require(goldenCase["diagrams"]?.objectValue)
            #expect(goldenDiagrams.count == model.diagrams.count, "\(name): diagram count")
            for (_, diagram) in model.diagrams {
                let expected = try #require(goldenDiagrams[diagram.node], "\(name)/\(diagram.node): no golden")
                let ops = SheetDrawing.build(model, diagramId: diagram.id)
                let actual = renderOpsJSON(ops)
                let diff = jsonDiff(expected, actual, path: "\(name)/\(diagram.node)")
                #expect(diff == nil, "\(diff ?? "")")
            }
        }
    }

    // MARK: DrawOp -> the same {role, id, tag, ...} shape goldens.html posts

    private func roleFields(_ role: DrawRole) -> (role: String, id: String?) {
        switch role {
        case .sheet: return ("sheet", nil)
        case .box(let id): return ("box", id)
        case .arrow(let id): return ("arrow", id)
        case .arrowLabel(let id): return ("arrowLabel", id)
        case .icom(let id): return ("icom", id)
        case .port(let id): return ("port", id)
        }
    }

    /// `[DrawOp]` -> golden-render.json's own per-op shape. `.line` (the
    /// frame's grid lines) is skipped, matching goldens.html, which never
    /// walks a `<line>` element either.
    private func renderOpsJSON(_ ops: [DrawOp]) -> JSONValue {
        var out: [JSONValue] = []
        for op in ops {
            switch op {
            case .line:
                continue
            case .rect(let r, _, _, let role):
                let (roleName, id) = roleFields(role)
                var o = JSONObject()
                o["role"] = .string(roleName)
                o["id"] = id.map(JSONValue.string) ?? .null
                o["tag"] = .string("rect")
                o["x"] = .number(r.x)
                o["y"] = .number(r.y)
                o["w"] = .number(r.w)
                o["h"] = .number(r.h)
                out.append(.object(o))
            case .path(let commands, _, _, let role):
                let (roleName, id) = roleFields(role)
                var o = JSONObject()
                o["role"] = .string(roleName)
                o["id"] = id.map(JSONValue.string) ?? .null
                o["tag"] = .string("path")
                o["d"] = .string(SVGWriter.pathData(commands))
                out.append(.object(o))
            case .circle(let c, let radius, _, _, let role):
                let (roleName, id) = roleFields(role)
                var o = JSONObject()
                o["role"] = .string(roleName)
                o["id"] = id.map(JSONValue.string) ?? .null
                o["tag"] = .string("circle")
                o["cx"] = .number(c.x)
                o["cy"] = .number(c.y)
                o["r"] = .number(radius)
                out.append(.object(o))
            case .text(let text, let at, let style, let role):
                let (roleName, id) = roleFields(role)
                var o = JSONObject()
                o["role"] = .string(roleName)
                o["id"] = id.map(JSONValue.string) ?? .null
                o["tag"] = .string("text")
                o["text"] = .string(text)
                o["x"] = .number(at.x)
                o["y"] = .number(at.y)
                o["anchor"] = .string(style.anchor.rawValue)
                out.append(.object(o))
            }
        }
        return .array(out)
    }
}
