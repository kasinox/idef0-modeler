// The concept registry against goldens captured from the web app: glossary
// order, usage counts, occurrences, drift, binding and the rename/merge edits,
// down to the bytes of the file they leave behind.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("ConceptsParity")
struct ConceptsParityTests {

    // MARK: Golden access

    private static let scenarios = Fixtures.json("golden-scenarios.json").objectValue!

    private static func golden(_ scenario: String) -> JSONObject {
        scenarios[scenario]!.objectValue!
    }

    private static func goldenConcepts(_ scenario: String) -> JSONObject {
        golden(scenario)["concepts"]!.objectValue!
    }

    /// The `concepts` section exactly as the generator built it:
    /// glossary [[id,term,kind,definition]], usage [[id,count]] in glossary
    /// order, occurrences [[id,[occurrence]]], unused ids, drift.
    private static func conceptsSection(_ m: IDEF0Model) -> JSONObject {
        let usage = m.conceptUsage()
        var o = JSONObject()
        o["glossary"] = .array(m.glossary.map { .array([.string($0.id), .string($0.term), .string($0.kind), .string($0.definition)]) })
        o["usage"] = .array(m.glossary.map { .array([.string($0.id), .number(Double(usage[$0.id] ?? 0))]) })
        o["occurrences"] = .array(m.glossary.map { g in
            .array([.string(g.id), .array(m.occurrencesOf(g.id).map { occ in
                var e = JSONObject()
                e["diagramId"] = .string(occ.diagramId)
                e["node"] = .string(occ.node)
                e["kind"] = .string(occ.kind.rawValue)
                e["id"] = .string(occ.id)
                e["text"] = .string(occ.text)
                return .object(e)
            })])
        })
        o["unused"] = .array(m.unusedConcepts().map { .string($0.id) })
        o["drift"] = .array(m.driftedOccurrences().map { d in
            var e = JSONObject()
            e["diagramId"] = .string(d.diagramId)
            e["node"] = .string(d.node)
            e["kind"] = .string(d.kind.rawValue)
            e["id"] = .string(d.id)
            e["text"] = .string(d.text)
            e["conceptId"] = .string(d.conceptId)
            e["term"] = .string(d.term)
            return .object(e)
        })
        // S01: `[id, bundleOf(id)?.id ?? null, effectiveConceptId(id), members]`.
        o["bundles"] = .array(m.glossary.map { g in
            .array([.string(g.id), m.bundleOf(g.id).map { .string($0.id) } ?? .null,
                    m.effectiveConceptId(g.id).map(JSONValue.string) ?? .null, .array(g.members.map(JSONValue.string))])
        })
        return o
    }

    private static func checkSection(_ scenario: String, _ m: IDEF0Model, keys: [String]? = nil) {
        let expected = goldenConcepts(scenario)
        let actual = conceptsSection(m)
        for key in keys ?? expected.keys {
            let d = jsonDiff(expected[key]!, actual[key]!, path: "\(scenario).concepts.\(key)")
            #expect(d == nil, "\(d ?? "")")
        }
    }

    private static func checkFile(_ scenario: String, _ m: IDEF0Model) {
        let expected = golden(scenario)["file"]!.stringValue!
        let d = textDiff(expected, ModelFile.serialize(m))
        #expect(d == nil, "\(scenario).file: \(d ?? "")")
    }

    private static func sample() throws -> IDEF0Model {
        try ModelFile.deserialize(Fixtures.sampleText)
    }

    /// The first arrow on the diagram with node `node` labelled `label`.
    private static func arrowLocation(_ m: IDEF0Model, node: String, label: String) throws -> (String, Int) {
        let dg = try #require(m.diagrams.values.first { $0.node == node })
        let i = try #require(dg.arrows.firstIndex { $0.label == label })
        return (dg.id, i)
    }

    // MARK: Scenarios

    @Test("baseline: bindAll on the bound sample is a no-op and the concepts section matches")
    func baseline() throws {
        var m = try Self.sample()
        let before = m
        m.bindAll()
        #expect(m == before)
        Self.checkSection("baseline", m)
        let d = textDiff(Fixtures.sampleText, ModelFile.serialize(m))
        #expect(d == nil, "\(d ?? "")")
        Self.checkFile("baseline", m)
    }

    @Test("rename-merge: a rename, then a rename onto an existing term that merges")
    func renameMerge() throws {
        var m = try Self.sample()
        m.bindAll()
        let workOrder = try #require(m.findConcept("Work Order"))
        let renameResult = m.renameConcept(workOrder.id, to: "Job Ticket")
        let renamed = try #require(renameResult)
        #expect(renamed.id == workOrder.id)
        #expect(renamed.term == "Job Ticket")
        #expect(renamed.definition == workOrder.definition)

        let components = try #require(m.findConcept("Components"))
        let assembled = try #require(m.findConcept("Assembled Product"))
        let mergeResult = m.renameConcept(components.id, to: "Assembled Product")
        let merged = try #require(mergeResult)
        #expect(merged.id == assembled.id)
        #expect(m.conceptById(components.id) == nil)

        Self.checkSection("rename-merge", m)
        Self.checkFile("rename-merge", m)
    }

    @Test("merge-keeps-definition: mergeConcepts carries the source's definition to a blank survivor (F15)")
    func mergeKeepsDefinition() throws {
        var m = try Self.sample()
        m.bindAll()
        let workOrder = try #require(m.findConcept("Work Order"))
        #expect(!workOrder.definition.isEmpty)
        let components = try #require(m.findConcept("Components"))
        #expect(components.definition.isEmpty)

        // renameConcept(workOrder, "Components") merges, since "Components"
        // already names a different concept; the survivor (Components) had no
        // definition, so it takes the source's rather than losing it.
        let mergeResult = m.renameConcept(workOrder.id, to: "Components")
        let merged = try #require(mergeResult)
        #expect(merged.id == components.id)
        #expect(merged.term == "Components")
        #expect(merged.definition == workOrder.definition)
        #expect(m.conceptById(workOrder.id) == nil)
        Self.checkSection("merge-keeps-definition", m)
        Self.checkFile("merge-keeps-definition", m)
    }

    @Test("relabel: an arrow relabelled away from its concept is reported as drift")
    func relabel() throws {
        var m = try Self.sample()
        m.bindAll()
        let (dgId, i) = try Self.arrowLocation(m, node: "A0", label: "Customer Order")
        m.updateDiagram(dgId) { $0.arrows[i].label = "Customer Records" }
        Self.checkSection("relabel", m, keys: ["drift"])
        Self.checkSection("relabel", m)
        Self.checkFile("relabel", m)
    }

    @Test("relabel-keeps-concept-on-drift: relabelArrow keeps the id and drifts when a boundary arrow shares its concept with its ICOM counterpart (F11 rule 4)")
    func relabelKeepsConceptOnDrift() throws {
        var m = try Self.sample()
        m.bindAll()
        let (dgId, i) = try Self.arrowLocation(m, node: "A0", label: "Raw Materials")
        let arrowId = m.diagrams[dgId]!.arrows[i].id
        let before = try #require(m.diagrams[dgId]?.arrows[i].conceptId)

        let result = m.relabelArrow(diagramId: dgId, arrowId: arrowId, to: "Raw Materials (Steel Stock)")
        #expect(result?.id == before)
        #expect(m.diagrams[dgId]?.arrows[i].conceptId == before)
        let drift = m.driftedOccurrences()
        #expect(drift.contains {
            jsStrictEquals($0.id, arrowId) && $0.text == "Raw Materials (Steel Stock)" && jsStrictEquals($0.conceptId, before)
        })
        Self.checkFile("relabel-keeps-concept-on-drift", m)
    }

    @Test("relabel-rename-in-place: relabelBox follows the F11 rules — a matching term keeps its id, an existing term rebinds, a sole undefined use renames in place, and empty text clears the binding")
    func relabelRenameInPlace() throws {
        var m = try Self.sample()
        m.bindAll()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let ship = try #require(a0.boxes.first { $0.name == "Ship Product" })
        let shipConceptId = try #require(ship.conceptId)

        // Rule 2: renormalises to the current term — keep the id, no drift.
        let caseChange = m.relabelBox(diagramId: a0.id, boxId: ship.id, to: "  SHIP PRODUCT  ")
        #expect(caseChange?.id == shipConceptId)
        #expect(m.diagrams[a0.id]?.findBox(ship.id)?.name == "SHIP PRODUCT")
        #expect(m.driftedOccurrences().isEmpty)

        // Rule 5: a typo fix on a sole, undefined use renames the concept in
        // place rather than leaving it dangling or spawning a duplicate.
        let typo = m.relabelBox(diagramId: a0.id, boxId: ship.id, to: "Ship Products")
        #expect(typo?.id == shipConceptId)
        #expect(typo?.term == "Ship Products")

        // Rule 3: an existing term rebinds — an explicit reuse of vocabulary —
        // leaving the concept it had behind unused rather than renamed onto it.
        let plan = try #require(m.diagrams[a0.id]?.boxes.first { $0.name == "Plan Production" })
        let planConceptId = try #require(plan.conceptId)
        let reused = m.relabelBox(diagramId: a0.id, boxId: ship.id, to: "Plan Production")
        #expect(reused?.id == planConceptId)
        #expect(m.unusedConcepts().contains { jsStrictEquals($0.id, shipConceptId) })
        // The golden file is the state after both of the scenario's relabelBox
        // ops (the typo fix, then the rebind onto "Plan Production"); the
        // scenario has no third op, so this is checked here, not after "typo".
        Self.checkFile("relabel-rename-in-place", m)

        // Rule 1: empty text clears the binding.
        let cleared = m.relabelBox(diagramId: a0.id, boxId: ship.id, to: "   ")
        #expect(cleared == nil)
        #expect(m.diagrams[a0.id]?.findBox(ship.id)?.conceptId == nil)
        #expect(m.diagrams[a0.id]?.findBox(ship.id)?.name == "")
    }

    @Test("unbound: a dangling conceptId leaves its concept unused and uncounted")
    func unbound() throws {
        var m = try Self.sample()
        m.bindAll()
        let (dgId, i) = try Self.arrowLocation(m, node: "A0", label: "Components")
        m.updateDiagram(dgId) { $0.arrows[i].conceptId = "gl_doesnotexist" }
        Self.checkSection("unbound", m, keys: ["usage", "occurrences", "unused"])
        Self.checkSection("unbound", m)
        #expect(m.conceptUsage()["gl_doesnotexist"] == 1)
        #expect(m.occurrencesOf("gl_doesnotexist").count == 1)
        Self.checkFile("unbound", m)
    }

    @Test("orphan-restore: bindAll restores an orphan conceptId as a new glossary entry when nothing else holds its term (F14)")
    func orphanRestore() throws {
        var m = try Self.sample()
        m.bindAll()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let ship = try #require(a0.boxes.first { $0.name == "Ship Product" })
        let shipIndex = try #require(a0.boxIndex(ship.id))
        // A hand-edit that renames the box and gives it an id no glossary
        // entry defines — as a foreign file's dangling reference would.
        m.updateDiagram(a0.id) { d in
            d.boxes[shipIndex].name = "Package Product"
            d.boxes[shipIndex].conceptId = "ext_ontology_1"
        }
        m.bindAll()

        let restored = try #require(m.conceptById("ext_ontology_1"))
        #expect(restored.term == "Package Product")
        #expect(restored.kind == "activity")
        #expect(restored.definition.isEmpty)
        #expect(m.diagrams[a0.id]?.findBox(ship.id)?.conceptId == "ext_ontology_1")
        Self.checkFile("orphan-restore", m)
    }

    @Test("orphan-collision: bindAll leaves an orphan conceptId alone when its text already names a different concept (F14)")
    func orphanCollision() throws {
        var m = try Self.sample()
        m.bindAll()
        let (dgId, i) = try Self.arrowLocation(m, node: "A0", label: "Components")
        let existing = try #require(m.findConcept("Components"))
        // A dangling id whose text collides with an existing, differently-id'd
        // concept: the id is not silently rewritten onto that concept.
        m.updateDiagram(dgId) { $0.arrows[i].conceptId = "ext_ontology_2" }
        m.bindAll()

        #expect(m.diagrams[dgId]?.arrows[i].conceptId == "ext_ontology_2")
        #expect(m.conceptById("ext_ontology_2") == nil)
        #expect(m.conceptById(existing.id)?.term == "Components")
        Self.checkFile("orphan-collision", m)
    }

    @Test("Every scenario's saved model yields that scenario's concepts section")
    func everyScenarioQueries() throws {
        // The queries are pure functions of the model, and each golden file is
        // the whole model state, so every scenario — decompositions included —
        // is checked without replaying edits that belong to other modules.
        #expect(Self.scenarios.count == ScenarioReplayer.names.count)
        for member in Self.scenarios {
            let text = member.value.objectValue!["file"]!.stringValue!
            let m = try ModelFile.deserialize(text)
            Self.checkSection(member.key, m)
        }
    }

    // MARK: Binding

    @Test("bindAll on a model with every binding stripped rebuilds the glossary")
    func bindAllFromScratch() throws {
        var m = try Self.sample()
        m.glossary = []
        for id in m.diagrams.keys {
            m.updateDiagram(id) { d in
                for i in d.boxes.indices { d.boxes[i].conceptId = nil }
                for i in d.arrows.indices { d.arrows[i].conceptId = nil }
            }
        }
        m.bindAll()

        // Every named box and labelled arrow is bound to the concept for its text.
        for (_, dg) in m.diagrams {
            for b in dg.boxes {
                let c = try #require(m.conceptById(b.conceptId), "box \(b.name)")
                #expect(c.term == b.name)
                #expect(c.kind == "activity")
            }
            for a in dg.arrows {
                let c = try #require(m.conceptById(a.conceptId), "arrow \(a.label)")
                #expect(c.term == a.label)
            }
        }
        // New concepts carry no definition or extras, and ids shaped like uid('gl').
        #expect(m.glossary.allSatisfy { $0.definition.isEmpty && $0.extras.isEmpty && $0.id.hasPrefix("gl_") })
        #expect(Set(m.glossary.map(\.id)).count == m.glossary.count)

        // Terms in the golden baseline's order; kinds follow the first place each
        // term was met: an arrow into a box's bottom is a mechanism, else data.
        let baseline = Self.goldenConcepts("baseline")["glossary"]!.arrayValue!.map { $0.arrayValue! }
        #expect(m.glossary.map(\.term) == baseline.map { $0[1].stringValue! })
        #expect(m.glossary.map(\.kind) == baseline.map { $0[2].stringValue! })

        #expect(m.unusedConcepts().isEmpty)
        #expect(m.driftedOccurrences().isEmpty)
        let usage = m.conceptUsage()
        #expect(m.glossary.map { usage[$0.id] ?? 0 } == Self.goldenConcepts("baseline")["usage"]!.arrayValue!.map {
            guard case .number(let n) = $0.arrayValue![1] else { return -1 }
            return Int(n)
        })

        // A second pass changes nothing.
        let once = m
        m.bindAll()
        #expect(m == once)
    }

    @Test("unboundCount is zero on the bound sample and equals the number of named elements on a stripped copy (F13)")
    func unboundCountMatchesBindAllsWork() throws {
        let bound = try Self.sample()
        #expect(bound.unboundCount() == 0)

        var stripped = try Self.sample()
        stripped.glossary = []
        var named = 0
        for id in stripped.diagrams.keys {
            stripped.updateDiagram(id) { d in
                for i in d.boxes.indices {
                    d.boxes[i].conceptId = nil
                    if !jsTrim(d.boxes[i].name).isEmpty { named += 1 }
                }
                for i in d.arrows.indices {
                    d.arrows[i].conceptId = nil
                    if !jsTrim(d.arrows[i].label).isEmpty { named += 1 }
                }
            }
        }
        #expect(named > 0)
        #expect(stripped.unboundCount() == named)

        // `bindAll` clears exactly what `unboundCount` counted.
        stripped.bindAll()
        #expect(stripped.unboundCount() == 0)
    }

    @Test("Unnamed boxes and unlabelled arrows stay unbound; kinds follow the destination side")
    func bindingRules() throws {
        var m = try Self.sample()
        let a0 = try #require(m.diagrams.values.first { $0.node == "A0" })
        let plan = a0.boxes[0], fab = a0.boxes[1]
        var blank = newBox(name: "  ", number: 5, x: 700, y: 150)
        blank.conceptId = "stale"
        let mech = newArrow(label: "Robot  Arm", from: .boundary(.bottom, 0.1), to: .box(fab.id, .bottom, 0.2))
        let call = newArrow(label: "Robot arm", from: .box(plan.id, .bottom, 0.3), to: .boundary(.bottom, 0.4))
        let unlabelled = newArrow(label: "", from: .boundary(.left, 0.9), to: .box(plan.id, .left, 0.9))
        m.updateDiagram(a0.id) { d in
            d.boxes.append(blank)
            d.arrows.append(contentsOf: [call, mech, unlabelled])
        }
        let count = m.glossary.count
        m.bindAll()

        let after = try #require(m.diagram(a0.id))
        // A blank name with a non-empty conceptId is an orphan whose text is
        // blank: bindAll leaves the id alone rather than nulling it, since the
        // validator ignores blank text anyway (F14).
        #expect(after.findBox(blank.id)?.conceptId == "stale")
        #expect(after.arrows.first { $0.id == unlabelled.id }?.conceptId == nil)
        // The call arrow is met first and is data; the mechanism shares its term,
        // so it binds to the same concept rather than creating a second.
        let robot = try #require(m.findConcept("robot arm"))
        #expect(robot.term == "Robot arm")
        #expect(robot.kind == "data")
        #expect(after.arrows.first { $0.id == mech.id }?.conceptId == robot.id)
        #expect(m.glossary.count == count + 1)
        // Drift is the normalised comparison: "Robot  Arm" is not drift.
        #expect(m.driftedOccurrences().isEmpty)

        var fresh = try Self.sample()
        fresh.updateDiagram(a0.id) { $0.arrows.append(mech) }
        let bindResult = fresh.bindArrow(diagramId: a0.id, arrowId: mech.id)
        let bound = try #require(bindResult)
        #expect(bound.kind == "mechanism")
        #expect(bound.term == "Robot  Arm")
        let noArrow = fresh.bindArrow(diagramId: a0.id, arrowId: "ar_nope")
        let noDiagram = fresh.bindBox(diagramId: "dg_nope", boxId: plan.id)
        let planConcept = fresh.bindBox(diagramId: a0.id, boxId: plan.id)
        #expect(noArrow == nil)
        #expect(noDiagram == nil)
        #expect(planConcept?.id == plan.conceptId)
    }

    // MARK: Registry edges

    @Test("Lookups, resolve, rename and merge follow the JavaScript guards")
    func registryEdges() throws {
        var m = try Self.sample()
        #expect(m.conceptById(nil) == nil)
        #expect(m.conceptById("") == nil)
        #expect(m.findConcept("   ") == nil)
        #expect(m.findConcept("  customer\t ORDER ")?.id == "gl1")
        #expect(m.occurrencesOf(nil).isEmpty)
        #expect(m.occurrencesOf("").isEmpty)

        let before = m
        // Mutating calls cannot sit inside #expect, so each result is taken first.
        let blankTerm = m.resolveConcept(" \n ")
        let existing = m.resolveConcept("WORK ORDER", kind: "mechanism")
        let noSuchConcept = m.renameConcept("gl_nope", to: "X")
        let blankRename = m.renameConcept("gl1", to: "  ")
        let noSuchTarget = m.mergeConcepts(from: "gl1", into: "gl_nope")
        let selfMerge = m.mergeConcepts(from: "gl1", into: "gl1")
        #expect(blankTerm == nil)
        #expect(existing?.id == "gl2")
        #expect(existing?.kind == "data")
        #expect(noSuchConcept == nil)
        #expect(blankRename == nil)
        #expect(noSuchTarget == nil)
        #expect(selfMerge?.id == "gl1")
        #expect(m == before)

        let createResult = m.resolveConcept("  Aardvark  ")
        let created = try #require(createResult)
        #expect(created.term == "Aardvark")
        #expect(created.kind == "other")
        #expect(m.glossary.first?.id == created.id)

        // Renaming to a different spelling of its own term is a rename, not a merge.
        let respelled = m.renameConcept("gl1", to: "customer order")
        let renamed = try #require(respelled)
        #expect(renamed.id == "gl1")
        #expect(m.occurrencesOf("gl1").allSatisfy { $0.text == "customer order" })
    }

    // MARK: normTerm

    @Test("normTerm trims, collapses and lower-cases as the web app does")
    func normTermGolden() {
        for entry in Fixtures.json("golden-util.json").objectValue!["strings"]!.arrayValue! {
            let o = entry.objectValue!
            let s = o["s"]!.stringValue!
            #expect(normTerm(s) == o["collapsed"]!.stringValue!, "normTerm(\(s.debugDescription))")
        }
        // toLowerCase's context-sensitive and multi-scalar mappings (checked in V8).
        #expect(normTerm("ΟΔΟΣ") == "οδος")
        #expect(normTerm("ΟΔΟΣ ΚΑΙ") == "οδος και")
        #expect(normTerm("Σ") == "σ")
        #expect(normTerm("AΣ.") == "aς.")
        #expect(normTerm("ΑΣ\u{301}Β") == "ασ\u{301}β")
        #expect(normTerm("ΑΣ\u{301}") == "ας\u{301}")
        #expect(normTerm("İstanbul") == "i\u{307}stanbul")
        #expect(normTerm("ẞ") == "ß")
    }
}
