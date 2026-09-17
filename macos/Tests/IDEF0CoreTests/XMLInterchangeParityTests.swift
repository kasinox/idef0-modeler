// XMLInterchange.swift against the web app: the sample's XML and IDL exports
// and its re-import (golden-exports.json), a round trip on every scenario, and
// a battery of hand-written files read the way idef0xml.js reads them.
//
// The battery's expectations were captured by running src/io/idef0xml.js in
// Chrome 152, whose DOMParser is the reference reader: `fromXml(xml)`, then
// `JSON.stringify(JSON.parse(serialize(m)))`, `toXml(m)` and `toIdl(m)`, each
// normalised as the goldens are, with no id held fixed. A rejected file records
// its message; Chrome's parser wording after "XML is not well formed: " is its
// own, so those compare by prefix.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("XMLInterchangeParity")
struct XMLInterchangeParityTests {

    private static let exports = Fixtures.json("golden-exports.json").objectValue!

    private static func sample() throws -> IDEF0Model {
        var m = try ModelFile.deserialize(Fixtures.sampleText)
        m.bindAll()
        return m
    }

    // MARK: Goldens

    @Test("The namespace is the web app's XML_NS")
    func namespace() {
        #expect(XMLInterchange.namespace == "urn:idef0-modeler:xml:1")
    }

    @Test("toXml writes the sample exactly as the web app")
    func sampleXml() throws {
        let golden = try #require(Self.exports["xml"]?.stringValue)
        let actual = XMLInterchange.toXml(try Self.sample())
        #expect(textDiff(golden, actual) == nil, "\(textDiff(golden, actual) ?? "")")
    }

    @Test("toIdl lists the sample exactly as the web app")
    func sampleIdl() throws {
        let golden = try #require(Self.exports["idl"]?.stringValue)
        let actual = XMLInterchange.toIdl(try Self.sample())
        #expect(textDiff(golden, actual) == nil, "\(textDiff(golden, actual) ?? "")")
    }

    @Test("fromXml re-imports the sample's XML to the web app's file, from either writer")
    func sampleReimport() throws {
        let golden = try #require(Self.exports["reimported"]?.stringValue)
        let goldenXml = try #require(Self.exports["xml"]?.stringValue)
        for (writer, xml) in [("web app", goldenXml), ("Swift", XMLInterchange.toXml(try Self.sample()))] {
            var m = try XMLInterchange.fromXml(xml)
            m.bindAll()
            let actual = IdNormaliser.normalise(ModelFile.serialize(m), fixed: IdNormaliser.fixedIds)
            #expect(textDiff(golden, actual) == nil, "\(writer): \(textDiff(golden, actual) ?? "")")
        }
    }

    @Test("ModelFile.read picks XML by type or by a leading \"<\", and project JSON otherwise")
    func readDispatch() throws {
        let xml = XMLInterchange.toXml(try Self.sample())
        let fromXml = try XMLInterchange.fromXml(xml)
        #expect(try ModelFile.read(xml) == fromXml)
        #expect(try ModelFile.read(xml, isXML: true) == fromXml)
        // Leading whitespace still routes to the XML reader, which, like DOMParser,
        // refuses anything before the declaration.
        #expect(throws: XMLInterchangeError.self) { try ModelFile.read("\n  " + xml) }
        #expect(try ModelFile.read(Fixtures.sampleText) == ModelFile.deserialize(Fixtures.sampleText))
        // A JSON file named .xml is still read as XML, and fails as the XML reader fails.
        #expect(throws: XMLInterchangeError.self) { try ModelFile.read(Fixtures.sampleText, isXML: true) }
    }

    @Test("A leading byte-order mark is dropped where the web app's file reading drops it")
    func byteOrderMark() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        // decodeText is Blob.text(): one mark goes, malformed bytes are substituted, not refused.
        #expect(ModelFile.decodeText(bom + Data("{}".utf8)) == "{}")
        #expect(ModelFile.decodeText(bom + bom + Data("{}".utf8)) == "\u{FEFF}{}", "only the first mark is a mark")
        #expect(ModelFile.decodeText(Data([0x7B, 0xFF, 0x7D])) == "{\u{FFFD}}")
        #expect(ModelFile.decodeText(Data()) == "")

        // A BOM-prefixed project file opens, whichever way the text arrives…
        let expected = try ModelFile.deserialize(Fixtures.sampleText)
        #expect(try ModelFile.read("\u{FEFF}" + Fixtures.sampleText) == expected)
        #expect(try ModelFile.read(ModelFile.decodeText(bom + Data(Fixtures.sampleText.utf8))) == expected)
        // …while deserialize itself stays as strict as JSON.parse.
        #expect(throws: ModelFileError.self) { try ModelFile.deserialize("\u{FEFF}" + Fixtures.sampleText) }

        // A BOM-prefixed XML file is XML whatever its name says.
        let xml = XMLInterchange.toXml(try Self.sample())
        #expect(try ModelFile.read("\u{FEFF}" + xml) == XMLInterchange.fromXml(xml))
        #expect(try ModelFile.read("\u{FEFF}" + xml, isXML: true) == XMLInterchange.fromXml(xml))
    }

    @Test("The XML sniff skips JavaScript's whitespace, no more and no less")
    func sniffWhitespace() throws {
        let xml = XMLInterchange.toXml(try Self.sample())
        // U+2028 is whitespace to trimStart, so this is XML — which the XML
        // reader then refuses, as DOMParser does, for what precedes the declaration.
        #expect(throws: XMLInterchangeError.self) { try ModelFile.read("\u{2028}" + xml) }
        // U+0085 is not, so this is project JSON, and fails as JSON.parse fails.
        #expect(throws: ModelFileError.self) { try ModelFile.read("\u{0085}" + xml) }
    }

    @Test("A scenario's XML reads back to the same XML and IDL", arguments: ScenarioReplayer.names)
    func scenarioRoundTrip(_ name: String) throws {
        let m = try ScenarioReplayer.model(for: name)
        let xml = XMLInterchange.toXml(m)
        let back = try XMLInterchange.fromXml(xml)
        #expect(textDiff(xml, XMLInterchange.toXml(back)) == nil, "\(name): \(textDiff(xml, XMLInterchange.toXml(back)) ?? "")")
        #expect(textDiff(XMLInterchange.toIdl(m), XMLInterchange.toIdl(back)) == nil, "\(name) IDL")
        #expect(back.glossary == m.glossary)
        #expect(back.rootDiagramId == m.rootDiagramId)
        #expect(back.diagrams.keys == m.diagrams.keys)
    }

    @Test("A scenario's file survives the XML round trip byte-for-byte", arguments: ScenarioReplayer.names)
    func scenarioFileRoundTrip(_ name: String) throws {
        // Every id in a scenario's model is explicit (the sample's own, or one
        // the scenario's ops supplied), so the round trip needs no id
        // normalisation to compare byte-for-byte.
        let m = try ScenarioReplayer.model(for: name)
        let back = try XMLInterchange.fromXml(XMLInterchange.toXml(m))
        let expected = ModelFile.serialize(m), actual = ModelFile.serialize(back)
        #expect(textDiff(expected, actual) == nil, "\(name): \(textDiff(expected, actual) ?? "")")
    }

    // MARK: F12 — v2 carries what v1 dropped; an old v1 file still reads exactly as before

    @Test("v2 write/read carries box refs, diagram notes (one holding a CR), full-precision numbers and extras")
    func v2Richness() throws {
        let xmlGolden = try #require(Self.exports["xmlRich"]?.stringValue)
        let reimportedGolden = try #require(Self.exports["reimportedRich"]?.stringValue)

        var m = try Self.sample()
        let ctxId = m.rootDiagramId
        m.updateDiagram(ctxId) { dg in
            var note = JSONObject()
            note["text"] = .string("Line1\rLine2")
            note["author"] = .string("Ada")
            dg.notes = [.object(note)]
            dg.boxes[0].refs = "SOP-17, Appendix B"
            dg.boxes[0].x = 100.123
        }
        m.extras["ontologyLinks"] = .array([.string("urn:x"), .string("urn:y")])
        m.glossary[0].extras["source"] = .string("ISO 9001")

        let xml = XMLInterchange.toXml(m)
        #expect(textDiff(xmlGolden, xml) == nil, "\(textDiff(xmlGolden, xml) ?? "")")

        var back = try XMLInterchange.fromXml(xml)
        back.bindAll()
        let reimported = IdNormaliser.normalise(ModelFile.serialize(back), fixed: IdNormaliser.fixedIds)
        #expect(textDiff(reimportedGolden, reimported) == nil, "\(textDiff(reimportedGolden, reimported) ?? "")")
    }

    @Test("An old file with no version attribute reads exactly as version 1 always did, even carrying the shapes version 2 writes")
    func v1BackwardCompatibility() throws {
        let xml = try #require(Self.exports["v1LegacyXml"]?.stringValue)
        let fileGolden = try #require(Self.exports["v1LegacyFile"]?.stringValue)
        let m = try XMLInterchange.fromXml(xml)
        let file = ModelFile.serialize(m)
        #expect(textDiff(fileGolden, file) == nil, "\(textDiff(fileGolden, file) ?? "")")

        #expect(m.title == "Padded Title", "version 1 trims header text")
        let dg = try #require(m.contextDiagram)
        #expect(dg.title == "Ctx")
        #expect(dg.titleLocked, "derived from the non-empty title — there is no titleLocked attribute to read")
        #expect(dg.notes.isEmpty, "the <notes> element is ignored without version 2")
        #expect(dg.boxes.first?.refs == "", "the <refs> element is ignored without version 2")
        #expect(m.extras.isEmpty, "the <extensions> element is ignored without version 2")
        #expect(m.glossary.first?.definition == "Def", "trimmed, as version 1 always trimmed")
    }

    @Test("version=\"2\" reads text untrimmed and restores titleLocked, refs, notes and extensions")
    func v2ExplicitRead() throws {
        let xml = try #require(Self.exports["v2ExplicitXml"]?.stringValue)
        let fileGolden = try #require(Self.exports["v2ExplicitFile"]?.stringValue)
        let m = try XMLInterchange.fromXml(xml)
        let file = ModelFile.serialize(m)
        #expect(textDiff(fileGolden, file) == nil, "\(textDiff(fileGolden, file) ?? "")")

        #expect(m.title == "  Padded  ", "version 2 reads header text untrimmed")
        let dg = try #require(m.contextDiagram)
        #expect(dg.titleLocked == false, "the attribute overrides what the non-empty title would otherwise derive")
        #expect(dg.boxes.first?.refs == "  SOP-9  ", "untrimmed, and read at all only because version is 2")
        #expect(dg.notes.first?.objectValue?["text"]?.stringValue == "line1\nline2")
        #expect(m.extras["ontologyLinks"]?.arrayValue?.first?.stringValue == "urn:z")
        #expect(m.glossary.first?.extras["source"]?.stringValue == "ISO")
    }

    // MARK: S01 — a bundle's members as <member> children of its <term>

    @Test("version=\"2\" reads <member> children as a bundle's members and writes them back; a member with no id is skipped, a dangling one kept")
    func memberElements() throws {
        let xml = try #require(Self.exports["memberXml"]?.stringValue)
        let fileGolden = try #require(Self.exports["memberFile"]?.stringValue)
        let writtenGolden = try #require(Self.exports["memberWritten"]?.stringValue)
        let m = try XMLInterchange.fromXml(xml)
        let file = ModelFile.serialize(m)
        #expect(textDiff(fileGolden, file) == nil, "\(textDiff(fileGolden, file) ?? "")")
        let written = XMLInterchange.toXml(m)
        #expect(textDiff(writtenGolden, written) == nil, "\(textDiff(writtenGolden, written) ?? "")")

        let bundle = try #require(m.conceptById("gb"))
        #expect(bundle.members == ["g1", "g2", "g_gone"], "the id-less members are skipped, the dangling one kept")
        #expect(bundle.definition == "Both", "the definition is the element's own text, the <member> children add none")
        #expect(m.conceptById("g1")?.members.isEmpty == true)
        #expect(m.bundleOf("g2")?.id == "gb")
        // And the bundle reads back from what the writer wrote.
        #expect(try XMLInterchange.fromXml(written).conceptById("gb")?.members == ["g1", "g2", "g_gone"])
    }

    @Test("A hand-formatted file's whitespace between <member> children is not read into the definition")
    func memberWhitespace() throws {
        let xml = try #require(Self.exports["memberXmlPretty"]?.stringValue)
        let fileGolden = try #require(Self.exports["memberFilePretty"]?.stringValue)
        let m = try XMLInterchange.fromXml(xml)
        let file = ModelFile.serialize(m)
        #expect(textDiff(fileGolden, file) == nil, "\(textDiff(fileGolden, file) ?? "")")
        #expect(m.conceptById("gb")?.definition == "Both")
        #expect(m.conceptById("gb")?.members == ["g1", "g2"])
    }

    @Test("An old file with no version attribute reads no <member> children")
    func v1IgnoresMembers() throws {
        let xml = try #require(Self.exports["v1MemberXml"]?.stringValue)
        let fileGolden = try #require(Self.exports["v1MemberFile"]?.stringValue)
        let m = try XMLInterchange.fromXml(xml)
        let file = ModelFile.serialize(m)
        #expect(textDiff(fileGolden, file) == nil, "\(textDiff(fileGolden, file) ?? "")")
        #expect(m.conceptById("gb")?.members.isEmpty == true)
        #expect(m.conceptById("gb")?.definition == "Both")
    }

    @Test("The sample with a bundle survives the XML round trip, members and shared codes included")
    func bundledRoundTrip() throws {
        let xmlGolden = try #require(Self.exports["xmlBundled"]?.stringValue)
        let reimportedGolden = try #require(Self.exports["reimportedBundled"]?.stringValue)
        var m = try Self.sample()
        let ids = try ["Customer Order", "Raw Materials"].map { try #require(m.findConcept($0)).id }
        try m.combineConcepts(ids, term: "Inputs")
        let xml = XMLInterchange.toXml(m)
        #expect(textDiff(xmlGolden, IdNormaliser.normalise(xml, fixed: IdNormaliser.fixedIds)) == nil,
                "\(textDiff(xmlGolden, IdNormaliser.normalise(xml, fixed: IdNormaliser.fixedIds)) ?? "")")
        var back = try XMLInterchange.fromXml(xml)
        back.bindAll()
        let reimported = IdNormaliser.normalise(ModelFile.serialize(back), fixed: IdNormaliser.fixedIds)
        #expect(textDiff(reimportedGolden, reimported) == nil, "\(textDiff(reimportedGolden, reimported) ?? "")")
        #expect(back.glossary == m.glossary)
    }

    // MARK: F21 — XML 1.0-forbidden characters, and whitespace inside attributes

    @Test("Forbidden control characters export as U+FFFD so the file always parses; tab, newline and CR round-trip exactly")
    func controlCharacterEscaping() throws {
        let xmlGolden = try #require(Self.exports["xmlCtrl"]?.stringValue)
        let reimportedGolden = try #require(Self.exports["reimportedCtrl"]?.stringValue)
        // Before the fix this export could not be read back at all.
        #expect(Self.exports["ctrlReadError"] == .null, "the web app read its own export back without error")

        var m = try Self.sample()
        let ctxId = m.rootDiagramId
        m.updateDiagram(ctxId) { dg in
            dg.boxes[0].note = "a\u{0B}b\u{01}c"
            dg.arrows[0].label = "CR\rHere"
        }
        m.glossary[0].term = "Tab\tNL\nEnd"

        let xml = XMLInterchange.toXml(m)
        #expect(textDiff(xmlGolden, xml) == nil, "\(textDiff(xmlGolden, xml) ?? "")")

        var back = try XMLInterchange.fromXml(xml)
        back.bindAll()
        let reimported = IdNormaliser.normalise(ModelFile.serialize(back), fixed: IdNormaliser.fixedIds)
        #expect(textDiff(reimportedGolden, reimported) == nil, "\(textDiff(reimportedGolden, reimported) ?? "")")

        // U+000B and U+0001 are gone, replaced with U+FFFD; the tab and
        // newline inside the attribute, and the CR inside text, survive.
        #expect(back.diagrams[ctxId]?.boxes.first?.note == "a\u{FFFD}b\u{FFFD}c")
        #expect(back.diagrams[ctxId]?.arrows.first?.label == "CR\rHere")
        #expect(back.glossary.first?.term == "Tab\tNL\nEnd")
    }

    // MARK: F25 — IDL quoting

    @Test("toIdl escapes quotes, backslashes and newlines, in that order, in every quoted field")
    func idlQuoting() throws {
        let idlGolden = try #require(Self.exports["idlEscaped"]?.stringValue)

        var m = try Self.sample()
        m.title = "Model \"Q\"\\Path"
        m.author = "A\nB"
        let ctxId = m.rootDiagramId
        m.updateDiagram(ctxId) { dg in
            dg.arrows[0].label = "Order \"rush\"\nline2"
            dg.boxes[0].name = "Do \"x\"\\y"
        }

        let idl = XMLInterchange.toIdl(m)
        #expect(textDiff(idlGolden, idl) == nil, "\(textDiff(idlGolden, idl) ?? "")")
    }

    // MARK: Reading, as DOMParser reads

    struct ReaderCase: Sendable, CustomTestStringConvertible {
        let name: String
        let xml: String
        /// `JSON.stringify(JSON.parse(serialize(fromXml(xml))))`, normalised.
        let file: String
        /// `toXml` of the imported model, where the case exercises the writer.
        let written: String?
        let idl: String
        /// Whether `toXml(fromXml(toXml(m)))` gives back `toXml(m)` in the web app.
        /// True for every case here: `toXml` escapes a literal CR in text (and
        /// TAB/LF inside an attribute) rather than writing it raw, so nothing
        /// in this battery is lost to the parser's line-ending normalisation.
        let roundTrips: Bool
        init(_ name: String, xml: String, file: String, written: String?, idl: String, roundTrips: Bool) {
            self.name = name; self.xml = xml; self.file = file; self.written = written; self.idl = idl
            self.roundTrips = roundTrips
        }
        var testDescription: String { name }
    }

    static let readerCases: [ReaderCase] = [
        ReaderCase(
            "minimal",
            xml: "<idef0Model><diagrams><diagram/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"new2\":{\"id\":\"new2\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"new2\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "empty-header-elements",
            xml: "<idef0Model id=\"\"><header><title/><author>  </author><status></status><created></created></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS \n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "header-anywhere",
            xml: "<idef0Model id=\"m1\"><meta><header><author> Deep  Author </author></header></meta><header><author>Second</author><title>T</title><revised>2020-02-02</revised></header><diagrams><diagram id=\"d1\"><header><project>From diagram</project></header></diagram></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"m1\",\"title\":\"T\",\"author\":\"Deep  Author\",\"project\":\"From diagram\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"2020-02-02\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"T\"\n  AUTHOR \"Deep  Author\"  PROJECT \"From diagram\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "glossary-defaults",
            xml: "<idef0Model><glossary><term/><term id=\"\" name=\"\" kind=\"\">  Def  </term><term id=\"g2\" name=\"Work Order\" kind=\"data\">x<b>y</b><!--c-->z</term></glossary><other><glossary><term id=\"g3\" name=\"Nested\"/></glossary></other><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[{\"id\":\"new2\",\"term\":\"\",\"kind\":\"other\",\"definition\":\"\"},{\"id\":\"new3\",\"term\":\"\",\"kind\":\"other\",\"definition\":\"Def\"},{\"id\":\"g2\",\"term\":\"Work Order\",\"kind\":\"data\",\"definition\":\"xyz\"},{\"id\":\"g3\",\"term\":\"Nested\",\"kind\":\"other\",\"definition\":\"\"}],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "diagram-defaults",
            xml: "<idef0Model><diagrams><diagram id=\"d1\" node=\"\" parentBox=\"\"><title>  </title><cNumber> C1 </cNumber></diagram><diagram id=\"d2\" node=\"A3\" parentBox=\"bx_p\" context=\"false\"><activities><activity><title>not mine</title></activity></activities><title>Direct</title><cNumber></cNumber></diagram></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"C1\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d2\":{\"id\":\"d2\",\"node\":\"A3\",\"title\":\"Direct\",\"titleLocked\":true,\"parentBoxId\":\"new2\",\"cNumber\":\"\",\"notes\":[],\"boxes\":[{\"id\":\"new3\",\"name\":\"\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"}],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "nested-structure",
            xml: "<idef0Model><diagrams><diagram id=\"outer\"><diagrams><diagram id=\"inner\"><title>Inner</title></diagram></diagrams><wrap><activities><activity id=\"a1\" number=\"2\"><name>Deep</name></activity></activities></wrap><activities><activity id=\"a0\"><name><b>Nested</b> name</name></activity></activities></diagram></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"outer\":{\"id\":\"outer\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[{\"id\":\"a1\",\"name\":\"Deep\",\"number\":2,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"a0\",\"name\":\"Nested name\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"}],\"arrows\":[]},\"inner\":{\"id\":\"inner\",\"node\":\"A0\",\"title\":\"Inner\",\"titleLocked\":true,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"outer\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\n    ACTIVITY A1 \"Nested name\"\n    ACTIVITY A2 \"Deep\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "box-numbers",
            xml: "<idef0Model><diagrams><diagram id=\"d1\" node=\"A0\"><activities><activity id=\"n-missing\"/><activity id=\"n-empty\" number=\"\"/><activity id=\"n-abc\" number=\"abc\"/><activity id=\"n-zero\" number=\"0\"/><activity id=\"n-neg\" number=\"-3\"/><activity id=\"n-space\" number=\" 7 \"/><activity id=\"n-exp\" number=\"1e1\"/><activity id=\"n-hex\" number=\"0x2\"/><activity id=\"n-inf\" number=\"Infinity\"/><activity id=\"n-plus\" number=\"+4\"/><activity id=\"n-dash\" number=\"-\"/></activities></diagram></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[{\"id\":\"n-missing\",\"name\":\"\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-empty\",\"name\":\"\",\"number\":0,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-abc\",\"name\":\"\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-zero\",\"name\":\"\",\"number\":0,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-neg\",\"name\":\"\",\"number\":-3,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-space\",\"name\":\"\",\"number\":7,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-exp\",\"name\":\"\",\"number\":10,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-hex\",\"name\":\"\",\"number\":2,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-inf\",\"name\":\"\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-plus\",\"name\":\"\",\"number\":4,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"n-dash\",\"name\":\"\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"}],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<idef0Model xmlns=\"urn:idef0-modeler:xml:1\" version=\"2\" id=\"new1\">\n  <header>\n    <title>Imported Model</title>\n    <author></author>\n    <project></project>\n    <status>WORKING</status>\n    <created></created>\n    <revised></revised>\n    <purpose></purpose>\n    <viewpoint></viewpoint>\n  </header>\n  <glossary>\n  </glossary>\n  <diagrams>\n    <diagram id=\"d1\" node=\"A0\" titleLocked=\"false\" context=\"true\">\n      <title></title>\n      <activities>\n        <activity id=\"n-missing\" number=\"1\" node=\"A1\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-empty\" number=\"0\" node=\"A0\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-abc\" number=\"1\" node=\"A1\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-zero\" number=\"0\" node=\"A0\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-neg\" number=\"-3\" node=\"A-3\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-space\" number=\"7\" node=\"A7\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-exp\" number=\"10\" node=\"A10\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-hex\" number=\"2\" node=\"A2\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-inf\" number=\"1\" node=\"A1\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-plus\" number=\"4\" node=\"A4\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"n-dash\" number=\"1\" node=\"A1\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n  </diagrams>\n  <root diagram=\"d1\"/>\n</idef0Model>",
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\n    ACTIVITY A-3 \"\"\n    ACTIVITY A0 \"\"\n    ACTIVITY A0 \"\"\n    ACTIVITY A1 \"\"\n    ACTIVITY A1 \"\"\n    ACTIVITY A1 \"\"\n    ACTIVITY A1 \"\"\n    ACTIVITY A2 \"\"\n    ACTIVITY A4 \"\"\n    ACTIVITY A7 \"\"\n    ACTIVITY A10 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "bounds",
            xml: "<idef0Model><diagrams><diagram id=\"d1\" node=\"A0\"><activities><activity id=\"b-none\" number=\"1\"/><activity id=\"b-empty\" number=\"2\"><bounds/></activity><activity id=\"b-odd\" number=\"3\"><bounds x=\"\" y=\"abc\" width=\" 12.5 \" height=\"1e2\"/></activity><activity id=\"b-more\" number=\"4\"><bounds x=\"-0\" y=\"0b11\" width=\"5.\" height=\".5\"/><bounds x=\"999\"/></activity><activity id=\"b-round\" number=\"5\"><bounds x=\"1.005\" y=\"0.005\" width=\"-0.005\" height=\"100.456\"/></activity><activity id=\"b-weird\" number=\"6\"><bounds x=\"1_0\" y=\"Infinity\" width=\"-Infinity\" height=\"0o17\"/></activity><activity id=\"b-attrs\" number=\"7\" concept=\"\" detail=\"\" node=\"ignored\"><x><bounds x=\"1\"/></x><note>  kept  note </note></activity></activities></diagram></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[{\"id\":\"b-none\",\"name\":\"\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"b-empty\",\"name\":\"\",\"number\":2,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"b-odd\",\"name\":\"\",\"number\":3,\"conceptId\":null,\"x\":0,\"y\":100,\"w\":12.5,\"h\":100,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"b-more\",\"name\":\"\",\"number\":4,\"conceptId\":null,\"x\":0,\"y\":3,\"w\":5,\"h\":0.5,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"b-round\",\"name\":\"\",\"number\":5,\"conceptId\":null,\"x\":1.005,\"y\":0.005,\"w\":-0.005,\"h\":100.456,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"b-weird\",\"name\":\"\",\"number\":6,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":15,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"},{\"id\":\"b-attrs\",\"name\":\"\",\"number\":7,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"kept  note\",\"refs\":\"\"}],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<idef0Model xmlns=\"urn:idef0-modeler:xml:1\" version=\"2\" id=\"new1\">\n  <header>\n    <title>Imported Model</title>\n    <author></author>\n    <project></project>\n    <status>WORKING</status>\n    <created></created>\n    <revised></revised>\n    <purpose></purpose>\n    <viewpoint></viewpoint>\n  </header>\n  <glossary>\n  </glossary>\n  <diagrams>\n    <diagram id=\"d1\" node=\"A0\" titleLocked=\"false\" context=\"true\">\n      <title></title>\n      <activities>\n        <activity id=\"b-none\" number=\"1\" node=\"A1\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"b-empty\" number=\"2\" node=\"A2\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n        <activity id=\"b-odd\" number=\"3\" node=\"A3\">\n          <name></name>\n          <bounds x=\"0\" y=\"100\" width=\"12.5\" height=\"100\"/>\n        </activity>\n        <activity id=\"b-more\" number=\"4\" node=\"A4\">\n          <name></name>\n          <bounds x=\"0\" y=\"3\" width=\"5\" height=\"0.5\"/>\n        </activity>\n        <activity id=\"b-round\" number=\"5\" node=\"A5\">\n          <name></name>\n          <bounds x=\"1.005\" y=\"0.005\" width=\"-0.005\" height=\"100.456\"/>\n        </activity>\n        <activity id=\"b-weird\" number=\"6\" node=\"A6\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"15\"/>\n        </activity>\n        <activity id=\"b-attrs\" number=\"7\" node=\"A7\">\n          <name></name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n          <note>kept  note</note>\n        </activity>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n  </diagrams>\n  <root diagram=\"d1\"/>\n</idef0Model>",
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\n    ACTIVITY A1 \"\"\n    ACTIVITY A2 \"\"\n    ACTIVITY A3 \"\"\n    ACTIVITY A4 \"\"\n    ACTIVITY A5 \"\"\n    ACTIVITY A6 \"\"\n    ACTIVITY A7 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "endpoints",
            xml: "<idef0Model><diagrams><diagram id=\"d1\" node=\"A0\"><activities><activity id=\"bx9\" number=\"1\"><name>Nine</name></activity></activities><arrows><arrow id=\"e-none\"/><arrow id=\"e-bare\"><label> Bare </label><source/><destination/></arrow><arrow id=\"e-pos\"><source type=\"boundary\" side=\"top\" position=\"abc\"/><destination type=\"boundary\" side=\"bottom\" position=\"\"/></arrow><arrow id=\"e-side\" concept=\"\"><source side=\"\" position=\"0.4\"/><destination type=\"activity\" activity=\"bx9\" side=\"top\" position=\"0.25\"/></arrow><arrow id=\"e-type\"><source type=\"ACTIVITY\" activity=\"bx9\" side=\"right\" position=\"0.3\"/><destination type=\"activity\" activity=\"bx_missing\" side=\"left\" position=\"1e-1\" tunnelled=\"true\"/></arrow><arrow id=\"e-tunnel\"><source type=\"boundary\" side=\"left\" position=\"0.5\" tunnelled=\"TRUE\"/><destination type=\"activity\" activity=\"bx9\" side=\"bottom\" position=\"0.5\" tunnelled=\"true\"/></arrow><arrow id=\"e-route1\"><route/><labelOffset/></arrow><arrow id=\"e-route2\"><route bend=\"abc\"/><labelOffset dx=\"3.456\" dy=\"abc\"/></arrow><arrow id=\"e-route3\"><route bend=\"0\"/><labelOffset dx=\"0\" dy=\"0\"/></arrow><arrow id=\"e-route4\"><route bend=\"\"/><labelOffset dx=\"\" dy=\"-2.345\"/><note> n </note></arrow><arrow id=\"e-route5\"><x><route bend=\"5\"/></x><route bend=\"640.456\"/></arrow></arrows></diagram></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[{\"id\":\"bx9\",\"name\":\"Nine\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"}],\"arrows\":[{\"id\":\"e-none\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"e-bare\",\"label\":\"Bare\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0},\"to\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"e-pos\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"top\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"bottom\",\"pos\":0},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"e-side\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.4},\"to\":{\"type\":\"box\",\"boxId\":\"bx9\",\"side\":\"top\",\"pos\":0.25},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"e-type\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"right\",\"pos\":0.3},\"to\":{\"type\":\"box\",\"boxId\":\"new2\",\"side\":\"left\",\"pos\":0.1},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":true,\"note\":\"\"},{\"id\":\"e-tunnel\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"to\":{\"type\":\"box\",\"boxId\":\"bx9\",\"side\":\"bottom\",\"pos\":0.5},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":true,\"note\":\"\"},{\"id\":\"e-route1\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"e-route2\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"bend\":null,\"ldx\":3.456,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"e-route3\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"bend\":0,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"e-route4\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"bend\":0,\"ldx\":0,\"ldy\":-2.345,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"n\"},{\"id\":\"e-route5\",\"label\":\"\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"bend\":640.456,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"}]}},\"rootDiagramId\":\"d1\"}",
            written: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<idef0Model xmlns=\"urn:idef0-modeler:xml:1\" version=\"2\" id=\"new1\">\n  <header>\n    <title>Imported Model</title>\n    <author></author>\n    <project></project>\n    <status>WORKING</status>\n    <created></created>\n    <revised></revised>\n    <purpose></purpose>\n    <viewpoint></viewpoint>\n  </header>\n  <glossary>\n  </glossary>\n  <diagrams>\n    <diagram id=\"d1\" node=\"A0\" titleLocked=\"false\" context=\"true\">\n      <title></title>\n      <activities>\n        <activity id=\"bx9\" number=\"1\" node=\"A1\">\n          <name>Nine</name>\n          <bounds x=\"100\" y=\"100\" width=\"190\" height=\"112\"/>\n        </activity>\n      </activities>\n      <arrows>\n        <arrow id=\"e-none\" role=\"unknown\">\n          <label></label>\n          <source type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"left\" position=\"0.5\"/>\n        </arrow>\n        <arrow id=\"e-bare\" role=\"unknown\">\n          <label>Bare</label>\n          <source type=\"boundary\" side=\"left\" position=\"0\"/>\n          <destination type=\"boundary\" side=\"left\" position=\"0\"/>\n        </arrow>\n        <arrow id=\"e-pos\" role=\"unknown\">\n          <label></label>\n          <source type=\"boundary\" side=\"top\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"bottom\" position=\"0\"/>\n        </arrow>\n        <arrow id=\"e-side\" role=\"control\">\n          <label></label>\n          <source type=\"boundary\" side=\"left\" position=\"0.4\"/>\n          <destination type=\"activity\" activity=\"bx9\" side=\"top\" position=\"0.25\"/>\n        </arrow>\n        <arrow id=\"e-type\" role=\"input\">\n          <label></label>\n          <source type=\"boundary\" side=\"right\" position=\"0.3\"/>\n          <destination type=\"activity\" activity=\"new2\" side=\"left\" position=\"0.1\" tunnelled=\"true\"/>\n        </arrow>\n        <arrow id=\"e-tunnel\" role=\"mechanism\">\n          <label></label>\n          <source type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <destination type=\"activity\" activity=\"bx9\" side=\"bottom\" position=\"0.5\" tunnelled=\"true\"/>\n        </arrow>\n        <arrow id=\"e-route1\" role=\"unknown\">\n          <label></label>\n          <source type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"left\" position=\"0.5\"/>\n        </arrow>\n        <arrow id=\"e-route2\" role=\"unknown\">\n          <label></label>\n          <source type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <labelOffset dx=\"3.456\" dy=\"0\"/>\n        </arrow>\n        <arrow id=\"e-route3\" role=\"unknown\">\n          <label></label>\n          <source type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <route bend=\"0\"/>\n        </arrow>\n        <arrow id=\"e-route4\" role=\"unknown\">\n          <label></label>\n          <source type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <route bend=\"0\"/>\n          <labelOffset dx=\"0\" dy=\"-2.345\"/>\n          <note>n</note>\n        </arrow>\n        <arrow id=\"e-route5\" role=\"unknown\">\n          <label></label>\n          <source type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <route bend=\"640.456\"/>\n        </arrow>\n      </arrows>\n    </diagram>\n  </diagrams>\n  <root diagram=\"d1\"/>\n</idef0Model>",
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\n    ARROW \"\" UNKNOWN FROM BOUNDARY.I TO BOUNDARY.I\n    ARROW \"Bare\" UNKNOWN FROM BOUNDARY.I TO BOUNDARY.I\n    ARROW \"\" UNKNOWN FROM BOUNDARY.C TO BOUNDARY.M\n    ARROW \"\" CONTROL FROM BOUNDARY.I TO BOX1\n    ARROW \"\" INPUT FROM BOUNDARY.O TO BOX? TUNNELLED\n    ARROW \"\" MECHANISM FROM BOUNDARY.I TO BOX1 TUNNELLED\n    ARROW \"\" UNKNOWN FROM BOUNDARY.I TO BOUNDARY.I\n    ARROW \"\" UNKNOWN FROM BOUNDARY.I TO BOUNDARY.I\n    ARROW \"\" UNKNOWN FROM BOUNDARY.I TO BOUNDARY.I\n    ARROW \"\" UNKNOWN FROM BOUNDARY.I TO BOUNDARY.I\n    ARROW \"\" UNKNOWN FROM BOUNDARY.I TO BOUNDARY.I\n    ACTIVITY A1 \"Nine\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "root-attr",
            xml: "<idef0Model><diagrams><diagram id=\"d1\" context=\"true\"/><diagram id=\"d2\"/></diagrams><root diagram=\"d2\"/></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d2\":{\"id\":\"d2\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d2\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "root-attr-dangling",
            xml: "<idef0Model><diagrams><diagram id=\"d1\"/><diagram id=\"d2\" context=\"true\"/><diagram id=\"d3\" context=\"true\"/></diagrams><root diagram=\"nope\"/></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d2\":{\"id\":\"d2\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d3\":{\"id\":\"d3\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d2\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "root-first-element",
            xml: "<idef0Model><diagrams><diagram id=\"d1\"/><diagram id=\"d2\"/></diagrams><x><root/></x><root diagram=\"d2\"/></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d2\":{\"id\":\"d2\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "root-nested",
            xml: "<idef0Model><diagrams><diagram id=\"d1\"/><diagram id=\"d2\"/></diagrams><x><root diagram=\"d2\"/></x></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d2\":{\"id\":\"d2\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d2\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "context-empty-id",
            xml: "<idef0Model><diagrams><diagram context=\"true\"/><diagram id=\"d9\" context=\"true\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"new2\":{\"id\":\"new2\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d9\":{\"id\":\"d9\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"new2\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "context-true-only",
            xml: "<idef0Model><diagrams><diagram id=\"d1\" context=\"TRUE\"/><diagram id=\"d2\" context=\"true\"/></diagrams><root diagram=\"\"/></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d2\":{\"id\":\"d2\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d2\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "integer-ids",
            xml: "<idef0Model><diagrams><diagram id=\"b\"/><diagram id=\"7\"/><diagram id=\"3\"/><diagram id=\"01\"/><diagram id=\"4294967295\"/><diagram id=\"4294967294\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"3\":{\"id\":\"3\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"7\":{\"id\":\"7\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"4294967294\":{\"id\":\"4294967294\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"b\":{\"id\":\"b\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"01\":{\"id\":\"01\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"4294967295\":{\"id\":\"4294967295\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"3\"}",
            written: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<idef0Model xmlns=\"urn:idef0-modeler:xml:1\" version=\"2\" id=\"new1\">\n  <header>\n    <title>Imported Model</title>\n    <author></author>\n    <project></project>\n    <status>WORKING</status>\n    <created></created>\n    <revised></revised>\n    <purpose></purpose>\n    <viewpoint></viewpoint>\n  </header>\n  <glossary>\n  </glossary>\n  <diagrams>\n    <diagram id=\"3\" node=\"A0\" titleLocked=\"false\" context=\"true\">\n      <title></title>\n      <activities>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n    <diagram id=\"7\" node=\"A0\" titleLocked=\"false\">\n      <title></title>\n      <activities>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n    <diagram id=\"4294967294\" node=\"A0\" titleLocked=\"false\">\n      <title></title>\n      <activities>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n    <diagram id=\"b\" node=\"A0\" titleLocked=\"false\">\n      <title></title>\n      <activities>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n    <diagram id=\"01\" node=\"A0\" titleLocked=\"false\">\n      <title></title>\n      <activities>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n    <diagram id=\"4294967295\" node=\"A0\" titleLocked=\"false\">\n      <title></title>\n      <activities>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n  </diagrams>\n  <root diagram=\"3\"/>\n</idef0Model>",
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "namespaced",
            xml: "<i:idef0Model xmlns:i=\"urn:idef0-modeler:xml:1\" id=\"m1\"><i:header><i:title>NS</i:title></i:header><i:diagrams><i:diagram id=\"d0\"/><i:diagram id=\"d1\" i:context=\"true\"><i:activities><i:activity i:id=\"x\" id=\"bx_1\"/></i:activities></i:diagram></i:diagrams><i:root i:diagram=\"d1\"/></i:idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"m1\",\"title\":\"NS\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d0\":{\"id\":\"d0\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[{\"id\":\"new1\",\"name\":\"\",\"number\":1,\"conceptId\":null,\"x\":100,\"y\":100,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"}],\"arrows\":[]}},\"rootDiagramId\":\"d0\"}",
            written: nil,
            idl: "MODEL \"NS\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "foreign-namespace",
            xml: "<idef0Model xmlns=\"urn:other\" version=\"9\"><header><title>Other</title></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Other\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"Other\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "text-content",
            xml: "<idef0Model><header><title><![CDATA[<Raw>]]> &amp; <!-- c --><b>Bold</b> <i>It</i>&#233;<?pi x?></title><purpose>line1\r\n\tline2  </purpose><viewpoint>\n  <p>a</p>\n  <p>b</p>\n</viewpoint></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"<Raw> & Bold Ité\",\"author\":\"\",\"project\":\"\",\"purpose\":\"line1\\n\\tline2\",\"viewpoint\":\"a\\n  b\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"<Raw> & Bold Ité\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"line1 line2\"\n  VIEWPOINT \"a b\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "dtd-entities",
            xml: "<!DOCTYPE idef0Model [<!ENTITY co \"Acme &#38;#38; Co\">]><idef0Model><header><author>&co;</author><title><b>x</b> <b>y</b></title></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"x y\",\"author\":\"Acme & Co\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"x y\"\n  AUTHOR \"Acme & Co\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "encoding-declared",
            xml: "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n<idef0Model><header><title>Café ☕</title></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Café ☕\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"Café ☕\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "prolog-and-comments",
            xml: "<?xml version=\"1.0\"?>\n<!-- lead -->\n<idef0Model><header><title>P</title></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>\n<!-- tail -->\n",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"P\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"P\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "rich",
            xml: "<idef0Model id=\"mdl_rich\" version=\"1\" xmlns=\"urn:idef0-modeler:xml:1\"><header><title>Rich &amp; &quot;Q&quot;</title><author>O&apos;Hara</author><project>P</project><status>DRAFT</status><created>2026-01-02</created><revised>2026-01-03</revised><purpose>To  show\n\teverything </purpose><viewpoint> V </viewpoint></header><glossary><term id=\"gl_a\" name=\"First\" kind=\"activity\">Def &lt;1&gt;</term><term id=\"gl_b\" name=\"In\" kind=\"data\"/></glossary><diagrams><diagram id=\"dg_c\" node=\"A-0\" context=\"true\"><title>Ctx</title><activities><activity id=\"bx_top\" number=\"0\" node=\"A0\" concept=\"gl_top\" detail=\"dg_k\"><name>Top</name><bounds x=\"400\" y=\"358\" width=\"300\" height=\"170\"/></activity></activities><arrows><arrow id=\"ar_in\" role=\"input\" concept=\"gl_b\"><label>In</label><source type=\"boundary\" side=\"left\" position=\"0.5\"/><destination type=\"activity\" activity=\"bx_top\" side=\"left\" position=\"0.5\"/></arrow><arrow id=\"ar_in2\"><label>Second In</label><source type=\"boundary\" side=\"left\" position=\"0.7\"/><destination type=\"activity\" activity=\"bx_top\" side=\"left\" position=\"0.7\"/></arrow><arrow id=\"ar_ctl\"><label>Ctl</label><source type=\"boundary\" side=\"top\" position=\"0.5\"/><destination type=\"activity\" activity=\"bx_top\" side=\"top\" position=\"0.5\" tunnelled=\"true\"/></arrow><arrow id=\"ar_out\"><label>Out</label><source type=\"activity\" activity=\"bx_top\" side=\"right\" position=\"0.5\"/><destination type=\"boundary\" side=\"right\" position=\"0.5\"/></arrow><arrow id=\"ar_call\"><label>Caller</label><source type=\"activity\" activity=\"bx_top\" side=\"bottom\" position=\"0.5\"/><destination type=\"boundary\" side=\"bottom\" position=\"0.5\"/></arrow></arrows></diagram><diagram id=\"dg_k\" node=\"A0\" parentBox=\"bx_top\"><title>Kid</title><cNumber>C&amp;7</cNumber><activities><activity id=\"bx_2\" number=\"2\" concept=\"\"><name>Second</name><bounds x=\"100.123\" y=\"-0.005\" width=\"190\" height=\"112\"/><note>boxed &amp; noted</note></activity><activity id=\"bx_1\" number=\"1\" concept=\"gl_a\"><name>First</name><bounds x=\"1.005\" y=\"172\" width=\"190\" height=\"112\"/></activity></activities><arrows><arrow id=\"ar_t\"><label>Tunnelled In</label><source type=\"boundary\" side=\"left\" position=\"0.005\" tunnelled=\"true\"/><destination type=\"activity\" activity=\"bx_1\" side=\"left\" position=\"0.25\"/><route bend=\"640.456\"/><labelOffset dx=\"0\" dy=\"-6\"/><note>a &lt; b</note></arrow><arrow id=\"ar_c\" concept=\"gl_b\"><label>Renamed In</label><source type=\"boundary\" side=\"left\" position=\"0.9\"/><destination type=\"activity\" activity=\"bx_1\" side=\"left\" position=\"0.75\"/></arrow><arrow id=\"ar_c2\"><label>second  IN</label><source type=\"boundary\" side=\"left\" position=\"0.1\"/><destination type=\"activity\" activity=\"bx_1\" side=\"left\" position=\"0.8\"/></arrow><arrow id=\"ar_o\"><label>Out</label><source type=\"activity\" activity=\"bx_2\" side=\"right\" position=\"0.5\"/><destination type=\"boundary\" side=\"right\" position=\"0.5\" tunnelled=\"true\"/></arrow><arrow id=\"ar_o2\"><label>Extra Out</label><source type=\"activity\" activity=\"bx_2\" side=\"right\" position=\"0.7\"/><destination type=\"boundary\" side=\"right\" position=\"0.7\"/></arrow><arrow id=\"ar_lost\"><label>Lost</label><source type=\"activity\" activity=\"bx_gone\" side=\"right\" position=\"0.5\"/><destination type=\"activity\" activity=\"bx_1\" side=\"top\" position=\"0.5\"/><labelOffset dx=\"2.345\" dy=\"0\"/></arrow><arrow id=\"ar_free\"><label>Free</label><source type=\"boundary\" side=\"top\" position=\"0.3\"/><destination type=\"boundary\" side=\"bottom\" position=\"0.3\"/></arrow></arrows></diagram><diagram id=\"dg_orphan\" node=\"A9\" parentBox=\"bx_nowhere\"><title>Orphan</title></diagram></diagrams><root diagram=\"dg_c\"/></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Rich & \\\"Q\\\"\",\"author\":\"O'Hara\",\"project\":\"P\",\"purpose\":\"To  show\\n\\teverything\",\"viewpoint\":\"V\",\"status\":\"DRAFT\",\"created\":\"2026-01-02\",\"revised\":\"2026-01-03\",\"glossary\":[{\"id\":\"new2\",\"term\":\"First\",\"kind\":\"activity\",\"definition\":\"Def <1>\"},{\"id\":\"new3\",\"term\":\"In\",\"kind\":\"data\",\"definition\":\"\"}],\"diagrams\":{\"new4\":{\"id\":\"new4\",\"node\":\"A-0\",\"title\":\"Ctx\",\"titleLocked\":true,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[{\"id\":\"new5\",\"name\":\"Top\",\"number\":0,\"conceptId\":\"new6\",\"x\":400,\"y\":358,\"w\":300,\"h\":170,\"childDiagramId\":\"new7\",\"note\":\"\",\"refs\":\"\"}],\"arrows\":[{\"id\":\"new8\",\"label\":\"In\",\"conceptId\":\"new3\",\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.5},\"to\":{\"type\":\"box\",\"boxId\":\"new5\",\"side\":\"left\",\"pos\":0.5},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"new9\",\"label\":\"Second In\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.7},\"to\":{\"type\":\"box\",\"boxId\":\"new5\",\"side\":\"left\",\"pos\":0.7},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"new10\",\"label\":\"Ctl\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"top\",\"pos\":0.5},\"to\":{\"type\":\"box\",\"boxId\":\"new5\",\"side\":\"top\",\"pos\":0.5},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":true,\"note\":\"\"},{\"id\":\"new11\",\"label\":\"Out\",\"conceptId\":null,\"from\":{\"type\":\"box\",\"boxId\":\"new5\",\"side\":\"right\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"right\",\"pos\":0.5},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"new12\",\"label\":\"Caller\",\"conceptId\":null,\"from\":{\"type\":\"box\",\"boxId\":\"new5\",\"side\":\"bottom\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"bottom\",\"pos\":0.5},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"}]},\"new7\":{\"id\":\"new7\",\"node\":\"A0\",\"title\":\"Kid\",\"titleLocked\":true,\"parentBoxId\":\"new5\",\"cNumber\":\"C&7\",\"notes\":[],\"boxes\":[{\"id\":\"new13\",\"name\":\"Second\",\"number\":2,\"conceptId\":null,\"x\":100.123,\"y\":-0.005,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"boxed & noted\",\"refs\":\"\"},{\"id\":\"new14\",\"name\":\"First\",\"number\":1,\"conceptId\":\"new2\",\"x\":1.005,\"y\":172,\"w\":190,\"h\":112,\"childDiagramId\":null,\"note\":\"\",\"refs\":\"\"}],\"arrows\":[{\"id\":\"new15\",\"label\":\"Tunnelled In\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.005},\"to\":{\"type\":\"box\",\"boxId\":\"new14\",\"side\":\"left\",\"pos\":0.25},\"bend\":640.456,\"ldx\":0,\"ldy\":-6,\"tunnelFrom\":true,\"tunnelTo\":false,\"note\":\"a < b\"},{\"id\":\"new16\",\"label\":\"Renamed In\",\"conceptId\":\"new3\",\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.9},\"to\":{\"type\":\"box\",\"boxId\":\"new14\",\"side\":\"left\",\"pos\":0.75},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"new17\",\"label\":\"second  IN\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"left\",\"pos\":0.1},\"to\":{\"type\":\"box\",\"boxId\":\"new14\",\"side\":\"left\",\"pos\":0.8},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"new18\",\"label\":\"Out\",\"conceptId\":null,\"from\":{\"type\":\"box\",\"boxId\":\"new13\",\"side\":\"right\",\"pos\":0.5},\"to\":{\"type\":\"boundary\",\"side\":\"right\",\"pos\":0.5},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":true,\"note\":\"\"},{\"id\":\"new19\",\"label\":\"Extra Out\",\"conceptId\":null,\"from\":{\"type\":\"box\",\"boxId\":\"new13\",\"side\":\"right\",\"pos\":0.7},\"to\":{\"type\":\"boundary\",\"side\":\"right\",\"pos\":0.7},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"new20\",\"label\":\"Lost\",\"conceptId\":null,\"from\":{\"type\":\"box\",\"boxId\":\"new21\",\"side\":\"right\",\"pos\":0.5},\"to\":{\"type\":\"box\",\"boxId\":\"new14\",\"side\":\"top\",\"pos\":0.5},\"bend\":null,\"ldx\":2.345,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"},{\"id\":\"new22\",\"label\":\"Free\",\"conceptId\":null,\"from\":{\"type\":\"boundary\",\"side\":\"top\",\"pos\":0.3},\"to\":{\"type\":\"boundary\",\"side\":\"bottom\",\"pos\":0.3},\"bend\":null,\"ldx\":0,\"ldy\":0,\"tunnelFrom\":false,\"tunnelTo\":false,\"note\":\"\"}]},\"new23\":{\"id\":\"new23\",\"node\":\"A9\",\"title\":\"Orphan\",\"titleLocked\":true,\"parentBoxId\":\"new24\",\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"new4\"}",
            written: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<idef0Model xmlns=\"urn:idef0-modeler:xml:1\" version=\"2\" id=\"new1\">\n  <header>\n    <title>Rich &amp; &quot;Q&quot;</title>\n    <author>O&apos;Hara</author>\n    <project>P</project>\n    <status>DRAFT</status>\n    <created>2026-01-02</created>\n    <revised>2026-01-03</revised>\n    <purpose>To  show\n\teverything</purpose>\n    <viewpoint>V</viewpoint>\n  </header>\n  <glossary>\n    <term id=\"new2\" name=\"First\" kind=\"activity\">Def &lt;1&gt;</term>\n    <term id=\"new3\" name=\"In\" kind=\"data\"></term>\n  </glossary>\n  <diagrams>\n    <diagram id=\"new4\" node=\"A-0\" titleLocked=\"true\" context=\"true\">\n      <title>Ctx</title>\n      <activities>\n        <activity id=\"new5\" number=\"0\" node=\"A0\" concept=\"new6\" detail=\"new7\">\n          <name>Top</name>\n          <bounds x=\"400\" y=\"358\" width=\"300\" height=\"170\"/>\n        </activity>\n      </activities>\n      <arrows>\n        <arrow id=\"new8\" role=\"input\" concept=\"new3\">\n          <label>In</label>\n          <source type=\"boundary\" side=\"left\" position=\"0.5\"/>\n          <destination type=\"activity\" activity=\"new5\" side=\"left\" position=\"0.5\"/>\n        </arrow>\n        <arrow id=\"new9\" role=\"input\">\n          <label>Second In</label>\n          <source type=\"boundary\" side=\"left\" position=\"0.7\"/>\n          <destination type=\"activity\" activity=\"new5\" side=\"left\" position=\"0.7\"/>\n        </arrow>\n        <arrow id=\"new10\" role=\"control\">\n          <label>Ctl</label>\n          <source type=\"boundary\" side=\"top\" position=\"0.5\"/>\n          <destination type=\"activity\" activity=\"new5\" side=\"top\" position=\"0.5\" tunnelled=\"true\"/>\n        </arrow>\n        <arrow id=\"new11\" role=\"output\">\n          <label>Out</label>\n          <source type=\"activity\" activity=\"new5\" side=\"right\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"right\" position=\"0.5\"/>\n        </arrow>\n        <arrow id=\"new12\" role=\"call\">\n          <label>Caller</label>\n          <source type=\"activity\" activity=\"new5\" side=\"bottom\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"bottom\" position=\"0.5\"/>\n        </arrow>\n      </arrows>\n    </diagram>\n    <diagram id=\"new7\" node=\"A0\" titleLocked=\"true\" parentBox=\"new5\">\n      <title>Kid</title>\n      <cNumber>C&amp;7</cNumber>\n      <activities>\n        <activity id=\"new13\" number=\"2\" node=\"A2\">\n          <name>Second</name>\n          <bounds x=\"100.123\" y=\"-0.005\" width=\"190\" height=\"112\"/>\n          <note>boxed &amp; noted</note>\n        </activity>\n        <activity id=\"new14\" number=\"1\" node=\"A1\" concept=\"new2\">\n          <name>First</name>\n          <bounds x=\"1.005\" y=\"172\" width=\"190\" height=\"112\"/>\n        </activity>\n      </activities>\n      <arrows>\n        <arrow id=\"new15\" role=\"input\">\n          <label>Tunnelled In</label>\n          <source type=\"boundary\" side=\"left\" position=\"0.005\" tunnelled=\"true\"/>\n          <destination type=\"activity\" activity=\"new14\" side=\"left\" position=\"0.25\"/>\n          <route bend=\"640.456\"/>\n          <labelOffset dx=\"0\" dy=\"-6\"/>\n          <note>a &lt; b</note>\n        </arrow>\n        <arrow id=\"new16\" role=\"input\" concept=\"new3\">\n          <label>Renamed In</label>\n          <source type=\"boundary\" side=\"left\" position=\"0.9\" icom=\"I1\"/>\n          <destination type=\"activity\" activity=\"new14\" side=\"left\" position=\"0.75\"/>\n        </arrow>\n        <arrow id=\"new17\" role=\"input\">\n          <label>second  IN</label>\n          <source type=\"boundary\" side=\"left\" position=\"0.1\" icom=\"I2\"/>\n          <destination type=\"activity\" activity=\"new14\" side=\"left\" position=\"0.8\"/>\n        </arrow>\n        <arrow id=\"new18\" role=\"output\">\n          <label>Out</label>\n          <source type=\"activity\" activity=\"new13\" side=\"right\" position=\"0.5\"/>\n          <destination type=\"boundary\" side=\"right\" position=\"0.5\" tunnelled=\"true\"/>\n        </arrow>\n        <arrow id=\"new19\" role=\"output\">\n          <label>Extra Out</label>\n          <source type=\"activity\" activity=\"new13\" side=\"right\" position=\"0.7\"/>\n          <destination type=\"boundary\" side=\"right\" position=\"0.7\" icom=\"O1\"/>\n        </arrow>\n        <arrow id=\"new20\" role=\"control\">\n          <label>Lost</label>\n          <source type=\"activity\" activity=\"new21\" side=\"right\" position=\"0.5\"/>\n          <destination type=\"activity\" activity=\"new14\" side=\"top\" position=\"0.5\"/>\n          <labelOffset dx=\"2.345\" dy=\"0\"/>\n        </arrow>\n        <arrow id=\"new22\" role=\"unknown\">\n          <label>Free</label>\n          <source type=\"boundary\" side=\"top\" position=\"0.3\"/>\n          <destination type=\"boundary\" side=\"bottom\" position=\"0.3\"/>\n        </arrow>\n      </arrows>\n    </diagram>\n    <diagram id=\"new23\" node=\"A9\" titleLocked=\"true\" parentBox=\"new24\">\n      <title>Orphan</title>\n      <activities>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n  </diagrams>\n  <root diagram=\"new4\"/>\n</idef0Model>",
            idl: "MODEL \"Rich & \\\"Q\\\"\"\n  AUTHOR \"O'Hara\"  PROJECT \"P\"  STATUS DRAFT\n  PURPOSE \"To show everything\"\n  VIEWPOINT \"V\"\n\n  DIAGRAM A-0 \"Ctx\"\n    ARROW \"In\" INPUT FROM BOUNDARY.I TO BOX0\n    ARROW \"Second In\" INPUT FROM BOUNDARY.I TO BOX0\n    ARROW \"Ctl\" CONTROL FROM BOUNDARY.C TO BOX0 TUNNELLED\n    ARROW \"Out\" OUTPUT FROM BOX0 TO BOUNDARY.O\n    ARROW \"Caller\" CALL FROM BOX0 TO BOUNDARY.M\n    ACTIVITY A0 \"Top\"\n      DIAGRAM A0 \"Kid\"\n        ARROW \"Tunnelled In\" INPUT FROM BOUNDARY.I TO BOX1 TUNNELLED\n        ARROW \"Renamed In\" INPUT FROM I1 TO BOX1\n        ARROW \"second  IN\" INPUT FROM I2 TO BOX1\n        ARROW \"Out\" OUTPUT FROM BOX2 TO BOUNDARY.O TUNNELLED\n        ARROW \"Extra Out\" OUTPUT FROM BOX2 TO O1\n        ARROW \"Lost\" CONTROL FROM BOX? TO BOX1\n        ARROW \"Free\" UNKNOWN FROM BOUNDARY.C TO BOUNDARY.M\n        ACTIVITY A1 \"First\"\n        ACTIVITY A2 \"Second\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "combining-marks",
            xml: "<idef0Model><header><title>&quot;&#x301; &amp;&#x200D; &lt;&#x20DD; &apos;&#x308;</title><author>e&#x301;&gt;</author></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"\\\"\u{301} &\u{200D} <\u{20DD} '\u{308}\",\"author\":\"e\u{301}>\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<idef0Model xmlns=\"urn:idef0-modeler:xml:1\" version=\"2\" id=\"new1\">\n  <header>\n    <title>&quot;\u{301} &amp;\u{200D} &lt;\u{20DD} &apos;\u{308}</title>\n    <author>e\u{301}&gt;</author>\n    <project></project>\n    <status>WORKING</status>\n    <created></created>\n    <revised></revised>\n    <purpose></purpose>\n    <viewpoint></viewpoint>\n  </header>\n  <glossary>\n  </glossary>\n  <diagrams>\n    <diagram id=\"d1\" node=\"A0\" titleLocked=\"false\" context=\"true\">\n      <title></title>\n      <activities>\n      </activities>\n      <arrows>\n      </arrows>\n    </diagram>\n  </diagrams>\n  <root diagram=\"d1\"/>\n</idef0Model>",
            idl: "MODEL \"\\\"\u{301} &\u{200D} <\u{20DD} '\u{308}\"\n  AUTHOR \"e\u{301}>\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "mixed-content-whitespace",
            xml: "<idef0Model><header><title><b>x</b> &amp; <b>y</b></title><author><b>p</b><![CDATA[ ]]><b>q</b></author><project>a&#13;&#10;b</project><purpose><i>1</i>\n<!-- c -->\n<i>2</i></purpose></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"x & y\",\"author\":\"p q\",\"project\":\"a\\r\\nb\",\"purpose\":\"1\\n\\n2\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"x & y\"\n  AUTHOR \"p q\"  PROJECT \"a\\nb\"  STATUS WORKING\n  PURPOSE \"1 2\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            // Before F21, toXml wrote a literal CR in text and idlQuote did not
            // escape it either, so re-parsing the exported XML (which turns a
            // raw CRLF into a bare LF) changed the text. Both are now escaped
            // on export, so the round trip is stable.
            roundTrips: true
        ),
        ReaderCase(
            "dtd-attlist-default",
            xml: "<!DOCTYPE idef0Model [<!ATTLIST diagram context CDATA \"true\"><!ATTLIST diagram node CDATA \"A7\"><!ENTITY co \"Acme\">]><idef0Model><header><title><b>a</b> <b>&co;</b></title></header><diagrams><diagram id=\"d1\" context=\"false\"/><diagram id=\"d2\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"a Acme\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A7\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]},\"d2\":{\"id\":\"d2\",\"node\":\"A7\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d2\"}",
            written: nil,
            idl: "MODEL \"a Acme\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A7 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "dtd-external-undeclared-entity",
            xml: "<!DOCTYPE idef0Model SYSTEM \"idef0.dtd\"><idef0Model><header><author>A&undeclared;B</author></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Imported Model\",\"author\":\"AB\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"Imported Model\"\n  AUTHOR \"AB\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "utf16-declared",
            xml: "<?xml version=\"1.0\" encoding=\"UTF-16\"?><idef0Model><header><title>Ünï</title></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"Ünï\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"Ünï\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
        ReaderCase(
            "bom-and-leading-space",
            xml: "\u{FEFF}  \n<idef0Model><header><title>B</title></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
            file: "{\"schema\":\"idef0-modeler/1\",\"id\":\"new1\",\"title\":\"B\",\"author\":\"\",\"project\":\"\",\"purpose\":\"\",\"viewpoint\":\"\",\"status\":\"WORKING\",\"created\":\"\",\"revised\":\"\",\"glossary\":[],\"diagrams\":{\"d1\":{\"id\":\"d1\",\"node\":\"A0\",\"title\":\"\",\"titleLocked\":false,\"parentBoxId\":null,\"cNumber\":\"\",\"notes\":[],\"boxes\":[],\"arrows\":[]}},\"rootDiagramId\":\"d1\"}",
            written: nil,
            idl: "MODEL \"B\"\n  AUTHOR \"\"  PROJECT \"\"  STATUS WORKING\n  PURPOSE \"\"\n  VIEWPOINT \"\"\n\n  DIAGRAM A0 \"\"\nEND MODEL",
            roundTrips: true
        ),
    ]

    @Test("fromXml reads each file as the web app does; toXml and toIdl write it back the same", arguments: readerCases)
    func reader(_ c: ReaderCase) throws {
        let m = try XMLInterchange.fromXml(c.xml)

        let fileJSON = try JSONValue.parse(IdNormaliser.normalise(ModelFile.serialize(m), fixed: []))
        let file = fileJSON.stringified(indent: 0)
        let detail = jsonDiff(try JSONValue.parse(c.file), fileJSON, tolerance: 0) ?? textDiff(c.file, file) ?? ""
        #expect(textDiff(c.file, file) == nil, "\(c.name) file: \(detail)")

        let xml = XMLInterchange.toXml(m)
        if let written = c.written {
            let actual = IdNormaliser.normalise(xml, fixed: [])
            #expect(textDiff(written, actual) == nil, "\(c.name) toXml: \(textDiff(written, actual) ?? "")")
        }
        let idl = IdNormaliser.normalise(XMLInterchange.toIdl(m), fixed: [])
        #expect(textDiff(c.idl, idl) == nil, "\(c.name) toIdl: \(textDiff(c.idl, idl) ?? "")")

        let again = XMLInterchange.toXml(try XMLInterchange.fromXml(xml))
        #expect((xml == again) == c.roundTrips, "\(c.name) round trip: \(textDiff(xml, again) ?? "identical")")
    }

    // MARK: Rejection

    struct ErrorCase: Sendable, CustomTestStringConvertible {
        let name: String
        let xml: String
        let message: String
        /// Compare only up to the parser's own detail.
        let prefixOnly: Bool
        init(_ name: String, xml: String, message: String, prefixOnly: Bool) {
            self.name = name; self.xml = xml; self.message = message; self.prefixOnly = prefixOnly
        }
        var testDescription: String { name }
    }

    static let errorCases: [ErrorCase] = [
        ErrorCase("err-empty",
                  xml: "",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-unclosed",
                  xml: "<idef0Model>",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-text",
                  xml: "not xml",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-mismatch",
                  xml: "<idef0Model></idef0Mode>",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-two-roots",
                  xml: "<idef0Model/><idef0Model/>",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-entity",
                  xml: "<idef0Model><header><title>&nbsp;</title></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-prefix",
                  xml: "<x:idef0Model/>",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-dup-attr",
                  xml: "<idef0Model id=\"a\" id=\"b\"/>",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-version",
                  xml: "<?xml version=\"2.0\"?><idef0Model/>",
                  message: "XML is not well formed: ", prefixOnly: true),
        ErrorCase("err-wrong-root",
                  xml: "<model><diagrams><diagram id=\"d1\"/></diagrams></model>",
                  message: "Expected <idef0Model>, found <model>.", prefixOnly: false),
        ErrorCase("err-wrong-root-prefixed",
                  xml: "<m:idef0model xmlns:m=\"urn:idef0-modeler:xml:1\"/>",
                  message: "Expected <idef0Model>, found <idef0model>.", prefixOnly: false),
        ErrorCase("err-no-diagrams",
                  xml: "<idef0Model><header><title>Nothing</title></header></idef0Model>",
                  message: "The file declares no context (A-0) diagram.", prefixOnly: false),
        ErrorCase("err-diagram-outside-diagrams",
                  xml: "<idef0Model><diagram id=\"d1\" context=\"true\"/><root diagram=\"d1\"/></idef0Model>",
                  message: "The file declares no context (A-0) diagram.", prefixOnly: false),
        ErrorCase("err-parsererror-element",
                  xml: "<idef0Model><diagrams><diagram id=\"d1\"/></diagrams><note><parsererror>  Boom here\nsecond line</parsererror></note></idef0Model>",
                  message: "XML is not well formed: Boom here", prefixOnly: false),
        // A later <diagram> with an id already read used to replace the earlier one.
        ErrorCase("err-duplicate-ids",
                  xml: "<idef0Model><diagrams><diagram id=\"d1\"><title>A</title></diagram><diagram id=\"d2\"><title>Two</title></diagram><diagram id=\"d1\"><title>B</title></diagram></diagrams></idef0Model>",
                  message: "Diagram d1 appears more than once.", prefixOnly: false),
        ErrorCase("err-parsererror-root",
                  xml: "<parsererror>root\nlevel</parsererror>",
                  message: "XML is not well formed: root", prefixOnly: false),
    ]

    @Test("fromXml rejects what the web app rejects, with its message", arguments: errorCases)
    func rejects(_ c: ErrorCase) {
        do {
            let m = try XMLInterchange.fromXml(c.xml)
            Issue.record("\(c.name): accepted, root \(m.rootDiagramId)")
        } catch let e as XMLInterchangeError {
            #expect(e.description == e.message)
            if c.prefixOnly {
                #expect(e.message.hasPrefix(c.message) && e.message.count > c.message.count, "\(c.name): \(e.message)")
            } else {
                #expect(e.message == c.message, "\(c.name): \(e.message)")
            }
        } catch {
            Issue.record("\(c.name): threw \(type(of: error)) \(error)")
        }
    }

    // MARK: Values the Swift model cannot hold

    @Test("A fractional box number truncates; the web app keeps 2.7 and -1.5")
    func fractionalBoxNumber() throws {
        let m = try XMLInterchange.fromXml("<idef0Model><diagrams><diagram id=\"d1\" node=\"A0\"><activities><activity id=\"bx_f\" number=\"2.7\"><name>F</name></activity><activity id=\"bx_g\" number=\"-1.5\"/></activities></diagram></diagrams></idef0Model>")
        let boxes = try #require(m.diagrams["d1"]?.boxes)
        #expect(boxes.map(\.number) == [2, -1])
        #expect(boxes.map(\.name) == ["F", ""])
    }

    @Test("An entity expanding to whitespace alone between child elements is lost; the web app keeps \"a b\"")
    func entityWhitespace() throws {
        // XMLDocument drops the blank text node; XMLParser never reports entity text.
        let m = try XMLInterchange.fromXml("<!DOCTYPE idef0Model [<!ENTITY sp \" \">]><idef0Model><header><title><b>a</b>&sp;<b>b</b></title></header><diagrams><diagram id=\"d1\"/></diagrams></idef0Model>")
        #expect(m.title == "ab")
    }

    @Test("An unknown side reads as left; the web app keeps the string (\"diagonal\", \"Left\")")
    func unknownSide() throws {
        let m = try XMLInterchange.fromXml("<idef0Model><diagrams><diagram id=\"d1\" node=\"A0\"><activities><activity id=\"bx_s\" number=\"1\"/></activities><arrows><arrow id=\"ar_s\"><source side=\"diagonal\" position=\"0.2\"/><destination type=\"activity\" activity=\"bx_s\" side=\"Left\" position=\"0.4\"/></arrow></arrows></diagram></diagrams></idef0Model>")
        let arrow = try #require(m.diagrams["d1"]?.arrows.first)
        #expect(arrow.from == .boundary(.left, 0.2))
        #expect(arrow.to == Endpoint(kind: .box, boxId: m.diagrams["d1"]?.boxes.first?.id, side: .left, pos: 0.4))
    }

    @Test("An activity endpoint naming no activity has no box id, and writes as the web app writes it")
    func activityEndpointWithoutId() throws {
        let golden = Self.exports
        let xml = try #require(golden["noIdXml"]?.stringValue)
        let m = try XMLInterchange.fromXml(xml)
        let arrow = try #require(m.diagrams["d1"]?.arrows.first)
        #expect(arrow.from.kind == .box)
        #expect(arrow.from.boxId == nil)
        // Both apps write the missing reference as `"boxId": null` in the file.
        let fileGolden = try #require(golden["noIdFile"]?.stringValue)
        let file = IdNormaliser.normalise(ModelFile.serialize(m), fixed: [])
        #expect(textDiff(fileGolden, file) == nil, "\(textDiff(fileGolden, file) ?? "")")
        let compact = try JSONValue.parse(ModelFile.serialize(m)).stringified(indent: 0)
        #expect(compact.contains(#""from":{"type":"box","boxId":null,"side":"right","pos":0.2}"#), "\(compact)")
        let written = try #require(golden["noIdWritten"]?.stringValue)
        let idl = try #require(golden["noIdIdl"]?.stringValue)
        #expect(textDiff(written, IdNormaliser.normalise(XMLInterchange.toXml(m), fixed: [])) == nil)
        #expect(textDiff(idl, IdNormaliser.normalise(XMLInterchange.toIdl(m), fixed: [])) == nil)
    }

    @Test("fromXml starts from a fresh model: new id, WORKING, and no invented dates")
    func freshFallbacks() throws {
        let m = try XMLInterchange.fromXml("<idef0Model><diagrams><diagram/></diagrams></idef0Model>")
        #expect(m.id.hasPrefix("mdl_"))
        #expect(m.created == "")
        #expect(m.revised == "")
        #expect(m.status == "WORKING")
        #expect(m.title == "Imported Model")
        let dg = try #require(m.contextDiagram)
        #expect(dg.id.hasPrefix("dg_"))
        #expect(m.extras.isEmpty)
    }
}
