// Regression coverage for two related findings, both about Swift's canonical-
// equivalence `==` disagreeing with the web app's code-unit `===`:
//
// F71 — the model's synthesized Equatable calls an NFD spelling and its NFC
// twin equal, so an edit that only renormalizes Unicode text must not be
// mistaken for a no-op by anything that gates on `model == next`. The real
// gate (`IDEF0Document.apply`) lives in IDEF0Modeler and cannot be reached
// from this target, so this file checks the premise the fix relies on: two
// otherwise-identical models differing only in a string's normalization
// compare `==` but do not serialize to the same bytes.
//
// F75 — a handful of Core sites used to look ids up with plain `String`
// equality or `[String: String]`/`Set<String>`, which is exactly this same
// canonical-equivalence hazard, and so merged two NFC/NFD "twin" ids that
// happen to name different things (an XML/IDL export, the concept registry).
// `exactIcomCodes`, `conceptIndex`, `isConceptUsed` and `isRootDiagram` are
// the fix; these tests hold them to the web app's code-unit identity.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("Unicode twin identity (F71 premise, F75 exact-identity helpers)")
struct UnicodeTwinIdentityTests {
    // MARK: Byte-exact string search
    //
    // A plain `String.range(of:)`/`.contains(_:)` compares Characters — like
    // `==`, by canonical equivalence — so it is exactly as unsafe here as the
    // bug these tests are checking for: searching a haystack that holds both
    // an NFC and an NFD spelling for the NFD needle can report a match at the
    // NFC spelling's position instead. `Data.range(of:)` compares raw bytes
    // and has no such notion, so every search below goes through it.
    private static func byteRange(of needle: String, in haystack: Data, from: Data.Index? = nil) -> Range<Data.Index>? {
        haystack.range(of: Data(needle.utf8), in: (from ?? haystack.startIndex)..<haystack.endIndex)
    }

    /// The exact text between `<arrow id="id"…` and its matching `</arrow>`,
    /// found by raw bytes so an id that is a twin of another arrow's id in
    /// this same document cannot make the search land on the wrong one.
    private static func arrowBlock(id: String, in xml: String) throws -> String {
        let bytes = Data(xml.utf8)
        let openRange = try #require(byteRange(of: "<arrow id=\"\(id)\"", in: bytes))
        let closeRange = try #require(byteRange(of: "</arrow>", in: bytes, from: openRange.upperBound))
        return String(decoding: bytes[openRange.lowerBound..<closeRange.upperBound], as: UTF8.self)
    }

    // MARK: F71 — canonical equality hides a normalization-only edit

    @Test("renameConcept NFD to NFC compares canonically equal but serializes to different bytes")
    func renameConceptNormalizationChangesBytesNotEquality() throws {
        var model = IDEF0Model.create(title: "Shop")
        let ctx = model.rootDiagramId
        let box = try #require(model.contextDiagram?.boxes.first)
        let nfd = "Cafe\u{301} Menu"
        model.updateDiagram(ctx) { $0.boxes[0].name = nfd }
        // #require cannot wrap a mutating call, so the result is taken first.
        let bound = model.bindBox(diagramId: ctx, boxId: box.id)
        let concept = try #require(bound)
        #expect(Array(concept.term.unicodeScalars) == Array(nfd.unicodeScalars), "bound exactly as typed, not renormalized")

        var renamed = model
        let nfc = "Caf\u{E9} Menu"
        _ = renamed.renameConcept(concept.id, to: nfc)

        // The two spellings are canonically equivalent, so the box name and
        // glossary term Swift compares as unchanged...
        #expect(renamed == model, "NFC and NFD spellings must compare == under Swift's canonical equivalence")
        // ...yet the file they would be saved as is not the same file.
        let before = ModelFile.serialize(model), after = ModelFile.serialize(renamed)
        #expect(!before.utf8.elementsEqual(after.utf8), "the rename must still change the serialized bytes")
        // Concretely: the two spellings really do differ in UTF-8 bytes.
        #expect(Array(nfc.utf8) != Array(nfd.utf8))
    }

    @Test("setDiagramTitle NFD to NFC changes the serialized bytes despite comparing equal")
    func retitleNormalizationChangesBytesNotEquality() {
        let nfd = "Cafe\u{301}", nfc = "Caf\u{E9}"
        func fixedModel(title: String) -> IDEF0Model {
            var diagrams = OrderedMap<Diagram>()
            diagrams["dg_ctx"] = Diagram(id: "dg_ctx", node: "A-0", title: title)
            return IDEF0Model(id: "mdl_fixed", title: "T", created: "2026-01-01", revised: "2026-01-01",
                               diagrams: diagrams, rootDiagramId: "dg_ctx")
        }
        let a = fixedModel(title: nfd), b = fixedModel(title: nfc)
        #expect(a == b, "titles that are only Unicode-normalization variants compare equal")
        #expect(!ModelFile.serialize(a).utf8.elementsEqual(ModelFile.serialize(b).utf8))
    }

    // MARK: F75 — Concepts.swift's exact-identity helpers

    @Test("conceptIndex, isConceptUsed and isRootDiagram tell NFC/NFD twin ids apart")
    func exactIdentityHelpersDoNotMergeTwins() {
        let nfc = "gl_caf\u{E9}", nfd = "gl_cafe\u{301}"
        var diagrams = OrderedMap<Diagram>()
        var ctx = Diagram(id: "dg_ctx", node: "A-0", title: "T")
        ctx.boxes = [Box(id: "bx1", name: "A", number: 0, conceptId: nfc, x: 0, y: 0, w: 1, h: 1)]
        diagrams[ctx.id] = ctx
        var model = IDEF0Model(
            id: "mdl", title: "T", created: "2026-01-01", revised: "2026-01-01",
            glossary: [Concept(id: nfc, term: "A", kind: "activity"), Concept(id: nfd, term: "B", kind: "activity")],
            diagrams: diagrams, rootDiagramId: "dg_ctx"
        )

        #expect(model.conceptIndex(nfc) == 0)
        #expect(model.conceptIndex(nfd) == 1)
        #expect(model.conceptIndex("gl_missing") == nil)
        #expect(model.conceptIndex(nil) == nil)
        #expect(model.conceptIndex("") == nil)

        // Only the NFC entry is actually used by the box above; its NFD twin,
        // though canonically the "same" string, is unused.
        #expect(model.isConceptUsed(nfc))
        #expect(!model.isConceptUsed(nfd))
        // The public, merged `conceptUsage()` documents that it does not make
        // this distinction — both ids read as used through it.
        #expect(model.conceptUsage()[nfc] == 1)
        #expect(model.conceptUsage()[nfd] == 1)

        #expect(model.isRootDiagram("dg_ctx"))
        let nfdRoot = "dg_cafe\u{301}"
        model.rootDiagramId = "dg_caf\u{E9}"
        #expect(model.isRootDiagram("dg_caf\u{E9}"))
        #expect(!model.isRootDiagram(nfdRoot), "an NFD twin of the root id must not itself read as the root")
        #expect(!model.isRootDiagram(nil))
    }

    // MARK: F75 — exact ICOM codes, and the XML/IDL export built on them

    /// A-0 with a box carrying two ICOM inputs on its left, decomposed into A0
    /// whose two boundary arrows share ids that are NFC/NFD twins of each
    /// other — the shape the finding's `twin.idef0.json` reproduction used.
    private func twinIcomModel() -> (model: IDEF0Model, ctx: String, a0: String, nfcArrow: String, nfdArrow: String) {
        let nfcArrow = "ar_caf\u{E9}", nfdArrow = "ar_cafe\u{301}"
        let top = newBox(name: "Top", number: 0, x: 400, y: 300, w: 300, h: 170)
        var box = top
        box.childDiagramId = "dg_a0"

        var ctx = Diagram(id: "dg_ctx", node: "A-0", title: "Ctx")
        ctx.boxes = [box]
        ctx.arrows = [
            Arrow(id: "ar_p1", label: "P1", conceptId: "gl_1", from: .boundary(.left, 0.3), to: .box(box.id, .left, 0.3)),
            Arrow(id: "ar_p2", label: "P2", conceptId: "gl_2", from: .boundary(.left, 0.6), to: .box(box.id, .left, 0.6)),
        ]

        let childBox = newBox(name: "Child", number: 1, x: 100, y: 172, w: 190, h: 112)
        var a0 = Diagram(id: "dg_a0", node: "A0", title: "A0", parentBoxId: box.id)
        a0.boxes = [childBox]
        a0.arrows = [
            Arrow(id: nfcArrow, label: "P1", conceptId: "gl_1", from: .boundary(.left, 0.3), to: .box(childBox.id, .left, 0.3)),
            Arrow(id: nfdArrow, label: "P2", conceptId: "gl_2", from: .boundary(.left, 0.6), to: .box(childBox.id, .left, 0.6)),
        ]

        var diagrams = OrderedMap<Diagram>()
        diagrams[ctx.id] = ctx
        diagrams[a0.id] = a0
        let model = IDEF0Model(id: "mdl_twin", title: "Twin", created: "2026-01-01", revised: "2026-01-01",
                                diagrams: diagrams, rootDiagramId: ctx.id)
        return (model, ctx.id, a0.id, nfcArrow, nfdArrow)
    }

    @Test("icomPairing assigns twin-id arrows distinct codes, and exactIcomCodes keeps them apart")
    func exactIcomCodesDoesNotMergeTwinArrowIds() throws {
        let (model, _, a0, nfcArrow, nfdArrow) = twinIcomModel()
        let dg = try #require(model.diagrams[a0])

        let pairing = model.icomPairing(dg)
        #expect(pairing.orphans.isEmpty && pairing.missing.isEmpty, "both boundary arrows should pair by concept")
        // Keyed by JSStringKey, not plain String: `Dictionary(uniqueKeysWithValues:)`
        // would itself trap ("Duplicate values for key") on two ids Swift's
        // default String Hashable calls the same key.
        let byChildId = Dictionary(uniqueKeysWithValues: pairing.pairs.map { (JSStringKey($0.child.arrow.id), $0.code) })
        #expect(byChildId[JSStringKey(nfcArrow)] == "I1")
        #expect(byChildId[JSStringKey(nfdArrow)] == "I2")

        let exact = model.exactIcomCodes(dg)
        #expect(exact.count == 2, "two distinct arrow ids must keep two distinct entries")
        #expect(exact[JSStringKey("\(nfcArrow):from")] == "I1")
        #expect(exact[JSStringKey("\(nfdArrow):from")] == "I2")

        // Documented, not a bug: the public, canonically-keyed icomCodes(_:)
        // merges the twins into one dictionary entry.
        let merged = model.icomCodes(dg)
        #expect(merged.count == 1, "the public API is documented to merge Unicode-normalization twins")
    }

    @Test("toXml gives each twin-id boundary arrow its own icom code, not one shared code")
    func xmlKeepsTwinArrowCodesApart() throws {
        let (model, _, _, nfcArrow, nfdArrow) = twinIcomModel()
        let xml = XMLInterchange.toXml(model)

        // Each arrow's boundary end is its `<source>` (both arrows run
        // boundary -> box here); the block between its opening tag and
        // `</arrow>` must carry that arrow's own code, not its twin's.
        let nfcBlock = try Self.arrowBlock(id: nfcArrow, in: xml)
        let nfdBlock = try Self.arrowBlock(id: nfdArrow, in: xml)
        #expect(nfcBlock.contains(#"<source type="boundary" side="left" position="0.3" icom="I1"/>"#))
        #expect(nfdBlock.contains(#"<source type="boundary" side="left" position="0.6" icom="I2"/>"#))
        #expect(!nfcBlock.contains("icom=\"I2\""))
        #expect(!nfdBlock.contains("icom=\"I1\""))
    }

    @Test("toIdl gives each twin-id boundary arrow its own icom code")
    func idlKeepsTwinArrowCodesApart() throws {
        let (model, _, _, _, _) = twinIcomModel()
        let idl = XMLInterchange.toIdl(model)
        // Each child-diagram arrow's line names its own code — the parent
        // (context) diagram's own two boundary arrows correctly print
        // "BOUNDARY.I" instead, since a context diagram has no parent box to
        // pair against, so that text is not itself evidence of the twins
        // being confused; a merge would instead show one of these codes
        // twice, or "BOUNDARY.I" here where a real code is expected.
        #expect(idl.contains("FROM I1 TO BOX1"))
        #expect(idl.contains("FROM I2 TO BOX1"))
    }

    @Test("toXml writes context=\"true\" only for the exact root id, not an NFD/NFC twin of it")
    func xmlContextFlagIsNotWrittenForATwinOfTheRoot() {
        let nfc = "dg_caf\u{E9}", nfd = "dg_cafe\u{301}"
        var diagrams = OrderedMap<Diagram>()
        diagrams[nfc] = Diagram(id: nfc, node: "A-0", title: "Root")
        // A second, unrelated diagram whose id merely happens to be the
        // root's id under Unicode canonical equivalence.
        diagrams[nfd] = Diagram(id: nfd, node: "A0", title: "Not the root")
        let model = IDEF0Model(id: "mdl", title: "T", created: "2026-01-01", revised: "2026-01-01",
                                diagrams: diagrams, rootDiagramId: nfc)

        let xml = XMLInterchange.toXml(model)
        // A pure-ASCII needle, so plain `components(separatedBy:)` is safe
        // here — the hazard is only ever a needle that itself holds a
        // combining or precomposed character.
        let occurrences = xml.components(separatedBy: #" context="true""#).count - 1
        #expect(occurrences == 1, "exactly one diagram — the real root — is marked as context")
        let bytes = Data(xml.utf8)
        #expect(Self.byteRange(of: #"<diagram id="\#(nfc)" node="A-0" titleLocked="false" context="true">"#, in: bytes) != nil)
        #expect(Self.byteRange(of: #"<diagram id="\#(nfd)" node="A0" titleLocked="false">"#, in: bytes) != nil)
    }
}
