// buildSampleModel() against Fixtures/sample.idef0.json, which the golden
// generator made from the web app's own buildSampleModel(): bound, re-dated to
// 2026-09-14 and serialised. Ids are random on both sides, so every id is
// normalised by first appearance and none is held fixed.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("SampleParity")
struct SampleTests {

    @Test("buildSampleModel builds the web app's sample file, byte for byte up to ids")
    func matchesFixture() throws {
        var m = buildSampleModel()
        m.bindAll()
        m.created = "2026-09-14"
        m.revised = "2026-09-14"
        let expected = IdNormaliser.normalise(Fixtures.sampleText, fixed: [])
        let actual = IdNormaliser.normalise(ModelFile.serialize(m), fixed: [])
        #expect(textDiff(expected, actual) == nil, "\(textDiff(expected, actual) ?? "")")
    }

    @Test("buildSampleModel dates the model today")
    func datedToday() {
        let m = buildSampleModel()
        #expect(m.created == todayISO())
        #expect(m.revised == todayISO())
    }

    @Test("Every build has fresh ids, and only the glossary's four are fixed")
    func freshIds() {
        let a = buildSampleModel(), b = buildSampleModel()
        #expect(a.id != b.id)
        #expect(Set(a.diagrams.keys).isDisjoint(with: b.diagrams.keys))
        let boxIds = { (m: IDEF0Model) in Set(m.diagrams.values.flatMap { $0.boxes.map(\.id) }) }
        let arrowIds = { (m: IDEF0Model) in Set(m.diagrams.values.flatMap { $0.arrows.map(\.id) }) }
        #expect(boxIds(a).isDisjoint(with: boxIds(b)))
        #expect(arrowIds(a).isDisjoint(with: arrowIds(b)))
        #expect(a.glossary.map(\.id) == ["gl1", "gl2", "gl3", "gl4"])
    }

    @Test("The unbound sample: A-0 and A0, titled after their boxes, with no concepts on boxes or arrows")
    func unboundShape() throws {
        let m = buildSampleModel()
        #expect(m.diagrams.values.map(\.node) == ["A-0", "A0"])
        let ctx = try #require(m.contextDiagram)
        let a0 = try #require(m.diagrams.values.last)
        #expect(ctx.boxes.first?.childDiagramId == a0.id)
        #expect(a0.parentBoxId == ctx.boxes.first?.id)
        #expect(a0.title == "Manufacture Product")
        #expect(!a0.titleLocked)
        #expect(ctx.arrows.count == 8)
        #expect(a0.arrows.count == 13)
        #expect(m.diagrams.values.allSatisfy { d in d.boxes.allSatisfy { $0.conceptId == nil } && d.arrows.allSatisfy { $0.conceptId == nil } })
        #expect(m.status == "DRAFT")
    }
}
