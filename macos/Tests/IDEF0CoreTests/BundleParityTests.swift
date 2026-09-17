// S01 structured editing — the core behind bundles, ports and auto-layout,
// pinned on hand-built cases the scenario goldens do not reach: every refusal
// and the model it leaves untouched, nested bundles and their un-combining,
// cycle safety, the merge rewrites, exact port geometry, the layout after
// each structural edit, and the file format's one new member. Every value
// here is what src/model/*.js and src/io/json.js give for the same edit under
// Node (tests/web/bundles.test.mjs makes the same checks there).
//
// `#expect`/`#require` cannot wrap a mutating call, so each edit's result is
// taken into a `let` first.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("BundleParity")
struct BundleParityTests {

    // MARK: Fixtures

    /// The bound sample, and its concepts by term.
    private static func sample() throws -> IDEF0Model {
        var m = try ModelFile.deserialize(Fixtures.sampleText)
        m.bindAll()
        return m
    }

    private static func id(_ m: IDEF0Model, _ term: String) throws -> String {
        try #require(m.findConcept(term), "concept \(term)").id
    }

    private static func diagram(_ m: IDEF0Model, _ node: String) throws -> Diagram {
        try #require(m.diagrams.values.first { $0.node == node }, "diagram \(node)")
    }

    private static func issues(_ m: IDEF0Model, _ code: String) -> [ValidationIssue] {
        validate(m).filter { $0.code == code }
    }

    // MARK: Combining

    @Test("combineConcepts makes a fresh, sorted glossary entry whose kind follows its members, and rewrites nothing else")
    func combine() throws {
        var m = try Self.sample()
        let before = m
        let co = try Self.id(m, "Customer Order"), rm = try Self.id(m, "Raw Materials"), wo = try Self.id(m, "Work Order")
        let bundle = try m.combineConcepts([co, rm], term: "  Inputs ")
        #expect(bundle.term == "Inputs", "trimmed, as every other naming path trims")
        #expect(bundle.kind == "data", "both members are data")
        #expect(bundle.definition == "")
        #expect(bundle.members == [co, rm])
        #expect(bundle.id.hasPrefix("gl_"))
        #expect(m.conceptById(bundle.id) == bundle)
        #expect(m.glossary.count == before.glossary.count + 1)
        #expect(m.glossary.map(\.term) == m.glossary.map(\.term).stableSorted { jsLocaleCompare($0, $1) < 0 }, "the glossary is re-sorted")
        // Nothing bound to a member moved: the diagrams are byte-identical.
        #expect(m.diagrams == before.diagrams)
        #expect(m.conceptById(co) == before.conceptById(co))
        #expect(m.bundleOf(co)?.id == bundle.id)
        #expect(m.bundleOf(rm)?.id == bundle.id)
        #expect(m.bundleOf(bundle.id) == nil)
        #expect(m.effectiveConceptId(co) == bundle.id)
        #expect(m.effectiveConceptId(bundle.id) == bundle.id)
        #expect(m.effectiveConceptId(wo) == wo)
        #expect(m.effectiveConceptId(nil) == nil && m.effectiveConceptId("") == "")
        #expect(bundle.isBundle && !(m.conceptById(co)?.isBundle ?? true))

        // A mechanism among data members makes the bundle 'other'.
        var mixed = try Self.sample()
        let pe = try Self.id(mixed, "Plant Equipment")
        let other = try mixed.combineConcepts([co, pe], term: "Mixed")
        #expect(other.kind == "other")
        #expect(Self.issues(mixed, "bundle-mixed-kind").map(\.message)
                == ["Bundle “Mixed” combines concepts of different kinds (data, mechanism). Its members should be of one kind."])
    }

    @Test("combineConcepts refuses fewer than two distinct ids, an unknown id and a member already bundled, changing nothing")
    func combineRefusals() throws {
        var m = try Self.sample()
        let co = try Self.id(m, "Customer Order"), rm = try Self.id(m, "Raw Materials"), wo = try Self.id(m, "Work Order")
        try m.combineConcepts([co, rm], term: "Inputs")
        let before = m
        #expect(throws: BundleError.tooFewMembers) { try m.combineConcepts([wo], term: "Solo") }
        #expect(throws: BundleError.tooFewMembers) { try m.combineConcepts([wo, wo], term: "Twice") }
        #expect(throws: BundleError.tooFewMembers) { try m.combineConcepts([], term: "None") }
        #expect(throws: BundleError.unknownConcept("gl_nope")) { try m.combineConcepts([wo, "gl_nope"], term: "Unknown") }
        #expect(throws: BundleError.unknownConcept("")) { try m.combineConcepts([wo, ""], term: "Blank") }
        #expect(throws: BundleError.alreadyMember(co)) { try m.combineConcepts([co, wo], term: "Refused") }
        #expect(m == before)
        // The refusals read as the web app's null: a description for the UI.
        #expect(BundleError.tooFewMembers.description == "A bundle combines at least two concepts.")
        #expect(BundleError.alreadyMember("x").description == "Concept x is already a member of a bundle.")
    }

    @Test("Bundles nest: the effective concept is the outermost bundle; un-combining an inner bundle splices its members into the outer, an outer one frees the inner")
    func nested() throws {
        var m = try Self.sample()
        let pristine = m
        let co = try Self.id(m, "Customer Order"), rm = try Self.id(m, "Raw Materials"), ps = try Self.id(m, "Production Schedule")
        let inner = try m.combineConcepts([co, rm], term: "Inputs")
        let outer = try m.combineConcepts([ps, inner.id], term: "Planning Inputs")
        #expect(outer.members == [ps, inner.id])
        #expect(outer.kind == "data")
        #expect(m.bundleOf(co)?.id == inner.id)
        #expect(m.bundleOf(inner.id)?.id == outer.id)
        #expect(m.effectiveConceptId(co) == outer.id)
        #expect(m.effectiveConceptId(rm) == outer.id)
        #expect(m.effectiveConceptId(ps) == outer.id)
        #expect(m.effectiveConceptId(inner.id) == outer.id)
        #expect(m.transitiveMembers(outer.id) == Set([ps, inner.id, co, rm].map(JSStringKey.init)))
        // A bundle already in a bundle cannot be combined again.
        #expect(throws: BundleError.alreadyMember(inner.id)) { try m.combineConcepts([inner.id, co], term: "Again") }

        // Un-combining the inner bundle: its members take its place, in order.
        // The entry comes back as the web app's does once its list is deleted: no members.
        var innerGone = m
        let removed = try innerGone.uncombineConcept(inner.id)
        #expect(removed.id == inner.id && removed.term == inner.term && removed.members.isEmpty)
        #expect(innerGone.conceptById(inner.id) == nil, "nothing denotes it, so it goes")
        #expect(innerGone.conceptById(outer.id)?.members == [ps, co, rm])
        #expect(innerGone.effectiveConceptId(co) == outer.id)

        // Un-combining the outer bundle: the inner one stands on its own again.
        var outerGone = m
        try outerGone.uncombineConcept(outer.id)
        #expect(outerGone.conceptById(outer.id) == nil)
        #expect(outerGone.conceptById(inner.id)?.members == [co, rm])
        #expect(outerGone.effectiveConceptId(co) == inner.id)
        #expect(outerGone.effectiveConceptId(ps) == ps)

        // Un-combining both is lossless: the model is the sample again.
        try innerGone.uncombineConcept(outer.id)
        #expect(innerGone == pristine)
    }

    @Test("uncombineConcept refuses a plain concept; removeConcept un-combines a bundle and drops a member from its bundle's list")
    func uncombineAndRemove() throws {
        var m = try Self.sample()
        let co = try Self.id(m, "Customer Order"), rm = try Self.id(m, "Raw Materials"), ps = try Self.id(m, "Production Schedule")
        let before = m
        #expect(throws: BundleError.notABundle(co)) { try m.uncombineConcept(co) }
        #expect(throws: BundleError.notABundle("gl_nope")) { try m.uncombineConcept("gl_nope") }
        #expect(m == before)
        #expect(BundleError.notABundle(co).description == "Concept \(co) is not a bundle.")

        let inner = try m.combineConcepts([co, rm], term: "Inputs")
        let outer = try m.combineConcepts([inner.id, ps], term: "Planning Inputs")

        // A member: gone from the glossary and from its bundle's list; its
        // arrows keep the dangling id, as deleting a concept always left them.
        var memberGone = m
        let removed = memberGone.removeConcept(rm)
        #expect(removed?.id == rm)
        #expect(memberGone.conceptById(rm) == nil)
        #expect(memberGone.conceptById(inner.id)?.members == [co])
        let a0 = try Self.diagram(memberGone, "A0")
        #expect(a0.arrows.first { $0.label == "Raw Materials" }?.conceptId == rm)
        #expect(memberGone.conceptUsage()[rm] == 2)
        #expect(Self.issues(memberGone, "bundle-thin").map(\.message)
                == ["Bundle “Inputs” has 1 member(s). A bundle combines at least two concepts (FIPS 183 §3.2.2.3)."])
        #expect(Self.issues(memberGone, "concept-unbound").count == 2, "the two Raw Materials arrows")

        // A bundle: un-combined, so its members move up into the outer bundle.
        var bundleGone = m
        let removedBundle = bundleGone.removeConcept(inner.id)
        #expect(removedBundle == inner, "removeConcept returns the entry as it was")
        #expect(bundleGone.conceptById(inner.id) == nil)
        #expect(bundleGone.conceptById(outer.id)?.members == [co, rm, ps])
        let none = bundleGone.removeConcept("gl_nope")
        #expect(none == nil)
    }

    @Test("uncombineConcept keeps a bundle something denotes as a plain concept, in its place in any outer bundle; removeConcept still removes it")
    func uncombineUsed() throws {
        var m = try Self.sample()
        let co = try Self.id(m, "Customer Order"), rm = try Self.id(m, "Raw Materials"), ps = try Self.id(m, "Production Schedule")
        let inner = try m.combineConcepts([co, rm], term: "Inputs")
        // An arrow drawn from the bundle's port is bound to the bundle itself.
        let a0 = try Self.diagram(m, "A0")
        let coArrow = try #require(a0.arrows.first { $0.label == "Customer Order" })
        m.updateDiagram(a0.id) { d in
            let i = d.arrows.firstIndex { $0.id == coArrow.id }!
            d.arrows[i].conceptId = inner.id
            d.arrows[i].label = "Inputs"
        }

        var kept = m
        let glossaryBefore = kept.glossary.count
        let out = try kept.uncombineConcept(inner.id)
        #expect(out.id == inner.id && out.members.isEmpty, "the entry comes back with no members")
        let plain = try #require(kept.conceptById(inner.id), "the entry stays")
        #expect(!plain.isBundle)
        #expect(plain.term == "Inputs" && plain.kind == "data" && plain.definition == "")
        #expect(kept.glossary.count == glossaryBefore, "nothing removed")
        #expect(kept.bundleOf(co) == nil && kept.bundleOf(rm) == nil)
        #expect(try Self.diagram(kept, "A0").arrows.first { $0.id == coArrow.id }?.conceptId == inner.id, "the arrow still denotes a concept")
        #expect(Self.issues(kept, "concept-unbound").isEmpty, "nothing dangles")
        #expect(!ModelFile.serialize(kept).contains("\"members\""), "the file carries no members list")

        // Nested: the kept entry keeps its place in the outer list, its
        // former members follow it, in order.
        var nested = m
        let outer = try nested.combineConcepts([ps, inner.id], term: "Planning Inputs")
        try nested.uncombineConcept(inner.id)
        #expect(nested.conceptById(outer.id)?.members == [ps, inner.id, co, rm])
        #expect(nested.effectiveConceptId(inner.id) == outer.id, "still stands for the outer bundle on the parent")
        #expect(nested.effectiveConceptId(co) == outer.id)
        #expect(Self.issues(nested, "bundle-member-dup").isEmpty)
        // Un-combining the outer bundle afterwards frees the plain survivor too.
        try nested.uncombineConcept(outer.id)
        #expect(nested.conceptById(outer.id) == nil, "nothing denotes the outer bundle")
        #expect(nested.bundleOf(inner.id) == nil)

        // removeConcept is deletion, used or not: the entry goes, and its
        // arrows keep the dangling id for concept-unbound, as removing any
        // concept does.
        var removed = m
        let outer2 = try removed.combineConcepts([ps, inner.id], term: "Planning Inputs")
        let gone = removed.removeConcept(inner.id)
        #expect(gone?.id == inner.id)
        #expect(removed.conceptById(inner.id) == nil)
        #expect(removed.conceptById(outer2.id)?.members == [ps, co, rm])
        #expect(try Self.diagram(removed, "A0").arrows.first { $0.id == coArrow.id }?.conceptId == inner.id)
        #expect(Self.issues(removed, "concept-unbound").count == 1)
    }

    // MARK: Malformed files

    @Test("A cycle in a hand-edited file ends every walk and is reported once per bundle on it; a concept listed twice is reported each time")
    func cyclesAndDuplicates() throws {
        var m = IDEF0Model.create(title: "Loop")
        m.purpose = "p"; m.viewpoint = "v"
        m.glossary = [
            Concept(id: "gA", term: "A", kind: "data", members: ["gB", "gX"]),
            Concept(id: "gB", term: "B", kind: "data", members: ["gA"]),
            Concept(id: "gC", term: "C", kind: "data", members: ["gX", "gX", "gY"]),
            Concept(id: "gX", term: "X", kind: "data"),
            Concept(id: "gY", term: "Y", kind: "data"),
        ]
        // The climb stops where it would visit a bundle again: X → A → B → (A).
        #expect(m.effectiveConceptId("gX") == "gB")
        #expect(m.effectiveConceptId("gA") == "gB")
        #expect(m.effectiveConceptId("gB") == "gA")
        #expect(m.bundleOf("gX")?.id == "gA", "the first bundle listing it, in glossary order")
        #expect(m.transitiveMembers("gA").contains(JSStringKey("gA")))
        #expect(!m.transitiveMembers("gC").contains(JSStringKey("gC")))
        let rows = validate(m).filter { $0.code.hasPrefix("bundle-") }.map { "\($0.code) | \($0.message)" }
        // Errors first, then warnings, as the validator always orders them.
        #expect(rows == [
            "bundle-cycle | Bundle “A” contains itself through its members. Un-combine it to break the cycle.",
            "bundle-cycle | Bundle “B” contains itself through its members. Un-combine it to break the cycle.",
            "bundle-member-dup | “X” is a member of both “A” and “C”. A concept belongs to at most one bundle.",
            "bundle-member-dup | Bundle “C” lists “X” more than once.",
            "bundle-thin | Bundle “B” has 1 member(s). A bundle combines at least two concepts (FIPS 183 §3.2.2.3).",
        ])
        // An issue with no occurrence to point at lands on A-0.
        let cycle = try #require(validate(m).first { $0.code == "bundle-cycle" })
        #expect(cycle.severity == .error && cycle.diagramId == m.rootDiagramId && cycle.target == nil && cycle.targetId == nil)
        // A dangling member counts for nothing but the thin check.
        m.glossary.append(Concept(id: "gD", term: "D", kind: "data", members: ["g_gone", "gY"]))
        #expect(Self.issues(m, "bundle-thin").map(\.message).contains("Bundle “D” has 1 member(s). A bundle combines at least two concepts (FIPS 183 §3.2.2.3)."))
        #expect(m.effectiveConceptId("g_gone") == "gD")
    }

    // MARK: Merging

    @Test("A merge rewrites every members list fromId→intoId de-duplicated, is refused into the bundle's own member, absorbs a member merged into its bundle, and hands a bundle's members to a plain survivor")
    func merges() throws {
        var m = try Self.sample()
        let co = try Self.id(m, "Customer Order"), rm = try Self.id(m, "Raw Materials"), ps = try Self.id(m, "Production Schedule")
        let bundle = try m.combineConcepts([co, rm], term: "Inputs")

        // Rewrite and de-duplicate: Raw Materials merged into Customer Order.
        var rewritten = m
        let merged = rewritten.renameConcept(rm, to: "Customer Order")
        #expect(merged?.id == co)
        #expect(rewritten.conceptById(bundle.id)?.members == [co])
        #expect(rewritten.conceptById(rm) == nil)

        // Refused: the bundle into its own member, directly or through an inner bundle.
        var refused = m
        let before = refused
        let refusedRename = refused.renameConcept(bundle.id, to: "Customer Order")
        let refusedMerge = refused.mergeConcepts(from: bundle.id, into: co)
        #expect(refusedRename == nil && refusedMerge == nil)
        #expect(refused == before)
        var deep = m
        let outer = try deep.combineConcepts([bundle.id, ps], term: "Planning Inputs")
        let deepBefore = deep
        let refusedDeep = deep.mergeConcepts(from: outer.id, into: co)
        #expect(refusedDeep == nil, "Customer Order sits two levels below")
        #expect(deep == deepBefore)

        // Absorbed: a member merged into its own bundle leaves the list, and its
        // arrows now carry the bundle's id and term.
        var absorbed = m
        let survivor = absorbed.renameConcept(co, to: "Inputs")
        #expect(survivor?.id == bundle.id)
        #expect(absorbed.conceptById(bundle.id)?.members == [rm])
        #expect(absorbed.conceptById(co) == nil)
        let a0 = try Self.diagram(absorbed, "A0")
        #expect(a0.arrows.filter { $0.conceptId == bundle.id }.map(\.label) == ["Inputs"])
        // Two levels down as well: the member is dropped from the list that
        // held it rather than rewritten into a cycle.
        var deepAbsorbed = deep
        let deepSurvivor = deepAbsorbed.mergeConcepts(from: co, into: outer.id)
        #expect(deepSurvivor?.id == outer.id)
        #expect(deepAbsorbed.conceptById(bundle.id)?.members == [rm])
        #expect(deepAbsorbed.conceptById(outer.id)?.members == [bundle.id, ps])
        #expect(!deepAbsorbed.transitiveMembers(outer.id).contains(JSStringKey(outer.id)))

        // Inherited: a bundle merged into a plain concept stays a bundle under
        // the survivor's id, and the survivor keeps its own definition.
        var inherited = m
        let components = try Self.id(inherited, "Components")
        let plainSurvivor = inherited.renameConcept(bundle.id, to: "Components")
        #expect(plainSurvivor?.id == components)
        #expect(inherited.conceptById(components)?.members == [co, rm])
        #expect(inherited.conceptById(bundle.id) == nil)
        #expect(inherited.bundleOf(co)?.id == components)
    }

    // MARK: ICOM coding by effective concept

    @Test("Two arrows of one bundle on one box side share one ICOM code, and the child's ends pair with it by effective concept")
    func sharedCode() throws {
        var m = try Self.sample()
        let co = try Self.id(m, "Customer Order"), rm = try Self.id(m, "Raw Materials")
        let ctx = try #require(m.contextDiagram)
        let top = ctx.boxes[0]
        #expect(m.parentBoxArrows(ctx, top.id)[.left]?.map(\.code) == ["I1", "I2"])

        let bundle = try m.combineConcepts([co, rm], term: "Inputs")
        let left = try #require(m.parentBoxArrows(ctx, top.id)[.left])
        #expect(left.map(\.code) == ["I1"])
        #expect(left[0].arrows.map(\.label) == ["Customer Order", "Raw Materials"], "numbered by the lowest, listing both")
        #expect(left[0].arrow.conceptId == co)

        let a0 = try Self.diagram(m, "A0")
        let codes = m.icomCodes(a0)
        let coArrow = try #require(a0.arrows.first { $0.label == "Customer Order" })
        let rmArrow = try #require(a0.arrows.first { $0.label == "Raw Materials" })
        #expect(codes["\(coArrow.id):from"] == "I1" && codes["\(rmArrow.id):from"] == "I1")
        let pairing = m.icomPairing(a0)
        #expect(pairing.orphans.isEmpty && pairing.missing.isEmpty)
        #expect(m.ports(a0).isEmpty)
        // The unbundled specific is neither a relabel nor a concept mismatch.
        let issues = validate(m)
        #expect(!issues.contains { $0.code == "icom-relabel" || $0.code == "icom-concept-mismatch" })
        #expect(!issues.contains { $0.code.hasPrefix("bundle-") })
        // Binding the child end to the bundle itself pairs the same way.
        m.updateDiagram(a0.id) { d in
            let i = d.arrows.firstIndex { $0.id == rmArrow.id }!
            d.arrows[i].conceptId = bundle.id
        }
        let rebound = try Self.diagram(m, "A0")
        #expect(m.icomCodes(rebound)["\(rmArrow.id):from"] == "I1")
    }

    // MARK: Ports

    @Test("A freshly decomposed box has one port per parent ICOM entry, with the parent's side, position, code, label and concept; connecting one takes its code, disconnecting brings it back")
    func ports() throws {
        var m = try Self.sample()
        let a0 = try Self.diagram(m, "A0")
        let plan = try #require(a0.boxes.first { $0.name == "Plan Production" })
        #expect(m.ports(try #require(m.contextDiagram)).isEmpty, "the context diagram has no parent")
        #expect(m.ports(a0).isEmpty, "every parent arrow is already paired")

        let decomposed = m.decomposeBox(diagramId: a0.id, boxId: plan.id, count: 3)
        let childId = try #require(decomposed)
        let child = try #require(m.diagrams[childId])
        #expect(child.arrows.isEmpty, "decomposing seeds no arrows")
        #expect(child.boxes.map(\.number) == [1, 2, 3])
        let co = try #require(a0.arrows.first { $0.label == "Customer Order" })
        let ps = try #require(a0.arrows.first { $0.label == "Production Schedule" })
        let wo = try #require(a0.arrows.first { $0.label == "Work Order" && $0.from.pos == 0.5 })
        let ports = m.ports(child)
        #expect(ports == [
            ICOMPort(side: .left, pos: 0.5, code: "I1", label: "Customer Order", conceptId: co.conceptId, parentArrowId: co.id, role: .input),
            ICOMPort(side: .top, pos: 0.5, code: "C1", label: "Production Schedule", conceptId: ps.conceptId, parentArrowId: ps.id, role: .control),
            ICOMPort(side: .right, pos: 0.5, code: "O1", label: "Work Order", conceptId: wo.conceptId, parentArrowId: wo.id, role: .output),
        ])
        #expect(Self.issues(m, "icom-missing").count == 3, "a port is still the icom-missing error")

        // Where they are drawn: on the drawing-area edge, the stub 26 units in.
        #expect(portShape(ports[0]) == PortShape(edge: Point(x: 40, y: 443), inner: Point(x: 66, y: 443)))
        #expect(portShape(ports[1]) == PortShape(edge: Point(x: 550, y: 132), inner: Point(x: 550, y: 158)))
        #expect(portShape(ports[2]) == PortShape(edge: Point(x: 1060, y: 443), inner: Point(x: 1034, y: 443)))
        let clampedX = Sheet.work.x + 0.02 * Sheet.work.w
        #expect(portShape(ICOMPort(side: .bottom, pos: 0, code: "M1", label: "", conceptId: nil, parentArrowId: "x", role: .mechanism))
                == PortShape(edge: Point(x: clampedX, y: 754), inner: Point(x: clampedX, y: 728)), "the position is clamped like any anchor")

        // Connect I1 and O1 the way the canvas does.
        let first = child.boxes[0], last = child.boxes[2]
        m.updateDiagram(childId) { d in
            d.arrows.append(newArrow(label: ports[0].label, from: .boundary(ports[0].side, ports[0].pos), to: .box(first.id, .left, 0.5), conceptId: ports[0].conceptId))
            d.arrows.append(newArrow(label: ports[2].label, from: .box(last.id, .right, 0.5), to: .boundary(ports[2].side, ports[2].pos), conceptId: ports[2].conceptId))
        }
        let connected = try #require(m.diagrams[childId])
        #expect(m.ports(connected).map(\.code) == ["C1"])
        #expect(Set(m.icomCodes(connected).values) == ["I1", "O1"])
        #expect(Self.issues(m, "icom-missing").count == 1)
        // Disconnect I1 again.
        m.updateDiagram(childId) { d in d.arrows.removeFirst() }
        let disconnected = try #require(m.diagrams[childId])
        #expect(m.ports(disconnected).map(\.code) == ["I1", "C1"])
    }

    // MARK: Layout

    @Test("addBox, removeBox and moveBox keep numbers 1..n and the staircase; layoutBoxes never touches A-0")
    func layout() throws {
        var m = try Self.sample()
        let pristine = m
        let ctx = try #require(m.contextDiagram)
        let a0 = try Self.diagram(m, "A0")
        let rects = { (n: Int) in staircaseLayout(n) }

        // Four boxes: the sample is already on the staircase for four.
        #expect(a0.sortedBoxes.map(\.rect) == rects(4))

        // addBox: number 5, and everything on the staircase for five.
        let addedBox = m.addBox(diagramId: a0.id)
        let added = try #require(addedBox)
        #expect(added.number == 5 && added.name == "")
        var laid = try Self.diagram(m, "A0")
        #expect(laid.sortedBoxes.map(\.number) == [1, 2, 3, 4, 5])
        #expect(laid.sortedBoxes.map(\.rect) == rects(5))
        #expect(laid.boxes.last?.id == added.id, "appended, not reordered")
        #expect(!validate(m).contains { $0.code == "box-number-order" })

        // moveBox: the new box one step earlier swaps with Ship Product.
        let moved = m.moveBox(diagramId: a0.id, boxId: added.id, by: -1)
        #expect(moved)
        laid = try Self.diagram(m, "A0")
        #expect(laid.sortedBoxes.map { $0.name } == ["Plan Production", "Fabricate Components", "Assemble Product", "", "Ship Product"])
        #expect(laid.sortedBoxes.map(\.rect) == rects(5))
        // The first cannot move earlier, the last not later; only ±1 is a step.
        let planId = try #require(laid.boxes.first { $0.name == "Plan Production" }).id
        let shipId = try #require(laid.boxes.first { $0.name == "Ship Product" }).id
        let before = m
        let refusals = [
            m.moveBox(diagramId: a0.id, boxId: planId, by: -1),
            m.moveBox(diagramId: a0.id, boxId: shipId, by: 1),
            m.moveBox(diagramId: a0.id, boxId: planId, by: 2),
            m.moveBox(diagramId: a0.id, boxId: "bx_nope", by: 1),
            m.moveBox(diagramId: "dg_nope", boxId: planId, by: 1),
            m.moveBox(diagramId: ctx.id, boxId: ctx.boxes[0].id, by: 1),
        ]
        #expect(refusals == [false, false, false, false, false, false])
        #expect(m == before)

        // removeBox: the survivors compact to 1..4 on the staircase for four.
        m.removeBox(diagramId: a0.id, boxId: added.id)
        laid = try Self.diagram(m, "A0")
        #expect(laid.sortedBoxes.map(\.number) == [1, 2, 3, 4])
        #expect(laid.sortedBoxes.map(\.rect) == rects(4))
        #expect(laid.sortedBoxes.map(\.name) == ["Plan Production", "Fabricate Components", "Assemble Product", "Ship Product"])
        #expect(m.diagrams == pristine.diagrams, "back where the sample started")

        // A-0 is never laid out: its box stays where it is, numbered 0.
        var root = m
        root.updateDiagram(ctx.id) { $0.layoutBoxes() }
        #expect(root == m)
        root.updateDiagram(ctx.id) { $0.boxes = [] }
        let repairedBox = root.addBox(diagramId: ctx.id)
        let repaired = try #require(repairedBox)
        #expect(repaired.number == 0)
        #expect(repaired.rect == SheetRect(x: Sheet.work.x + 60, y: Sheet.work.y + 40, w: Sheet.boxDefault.w, h: Sheet.boxDefault.h))

        // layoutBoxes alone is geometry: gapped numbers keep their gaps and
        // their order; the structural edits are what compact them.
        var gapped = m
        gapped.updateDiagram(a0.id) { d in
            let i = d.boxes.firstIndex { $0.name == "Ship Product" }!
            d.boxes[i].number = 6
            d.boxes[i].x = 20
            d.layoutBoxes()
        }
        let g = try Self.diagram(gapped, "A0")
        #expect(g.sortedBoxes.map(\.number) == [1, 2, 3, 6])
        #expect(g.sortedBoxes.map(\.rect) == rects(4))
        gapped.addBox(diagramId: a0.id)
        let compacted = try Self.diagram(gapped, "A0")
        #expect(compacted.sortedBoxes.map(\.number) == [1, 2, 3, 4, 5])
    }

    // MARK: File format

    @Test("members is written after definition and before extras, only when non-empty, and reads back as ids")
    func fileFormat() throws {
        var m = try Self.sample()
        let co = try Self.id(m, "Customer Order"), rm = try Self.id(m, "Raw Materials")
        let bundle = try m.combineConcepts([co, rm], term: "Inputs")
        let text = ModelFile.serialize(m)
        #expect(text.contains("\"definition\": \"\",\n      \"members\": [\n        \"\(co)\",\n        \"\(rm)\"\n      ]\n    }"))
        #expect(text.components(separatedBy: "\"members\"").count == 2, "only the bundle carries it")
        let back = try ModelFile.deserialize(text)
        #expect(back == m)
        #expect(ModelFile.serialize(back) == text)

        // An extra on the bundle follows its members.
        var extras = m
        let i = try #require(extras.glossary.firstIndex { $0.id == bundle.id })
        extras.glossary[i].extras["source"] = .string("ISO")
        let withExtras = ModelFile.serialize(extras)
        #expect(withExtras.contains("      ],\n      \"source\": \"ISO\"\n    }"))
        #expect(try ModelFile.deserialize(withExtras) == extras)

        // Reading: ids coerced as `id` is, an empty list is no list, anything
        // but a list is no list, and none of it is an extra.
        let raw = #"{"id":"m1","created":"","revised":"","rootDiagramId":"d1","diagrams":{"d1":{"node":"A-0"}},"glossary":["#
            + #"{"id":"b","term":"B","kind":"data","definition":"","members":[7,"x",null]},"#
            + #"{"id":"e","term":"E","kind":"data","definition":"","members":[]},"#
            + #"{"id":"s","term":"S","kind":"data","definition":"","members":"x"}]}"#
        let read = try ModelFile.deserialize(raw)
        #expect(read.glossary.map(\.members) == [["7", "x", "null"], [], []])
        #expect(read.glossary.allSatisfy { $0.extras.isEmpty })
        #expect(ModelFile.serialize(read).components(separatedBy: "\"members\"").count == 2)
    }
}
