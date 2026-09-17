// The foundation layer against goldens captured from the web app: file bytes,
// number formatting, string escaping, word wrapping, collation and the
// repairs `deserialize` performs on malformed files.

import Foundation
import Testing
@testable import IDEF0Core

@Suite("Foundation parity with the web app")
struct FoundationParityTests {

    // MARK: The project file

    @Test("The sample model reads and writes back byte for byte")
    func sampleRoundTripsByteForByte() throws {
        let text = Fixtures.sampleText
        let model = try ModelFile.deserialize(text)
        let written = ModelFile.serialize(model)
        #expect(textDiff(text, written) == nil, "\(textDiff(text, written) ?? "")")
    }

    @Test("The sample model decodes to the structure the web app built")
    func sampleStructure() throws {
        let model = try ModelFile.deserialize(Fixtures.sampleText)
        #expect(model.diagrams.count == 2)
        #expect(model.contextDiagram?.node == "A-0")
        #expect(model.contextDiagram?.boxes.first?.number == 0)
        let a0 = try #require(model.diagrams.values.first { $0.node == "A0" })
        #expect(a0.boxes.map(\.name) == ["Plan Production", "Fabricate Components", "Assemble Product", "Ship Product"])
        #expect(a0.arrows.count == 13)
        #expect(model.glossary.count == 16)
        #expect(model.glossary.allSatisfy { !$0.id.isEmpty })
    }

    @Test("deserialize repairs malformed files exactly as json.js does")
    func deserializeRepairs() throws {
        let golden = Fixtures.json("golden-deserialize.json").objectValue!
        let cases = golden["cases"]!.arrayValue!
        for (i, c) in cases.enumerated() {
            let o = c.objectValue!
            let input = o["text"]!.stringValue!
            // Case 6 carries numbers and booleans in string fields. The web app
            // writes them back unchanged and then cannot validate the model;
            // this app coerces them to strings. Asserted separately below.
            if i == 6 { continue }
            let expected = o["out"]!.stringValue!
            var repairs: [String] = []
            // Generated ids are random; the golden numbers them new1, new2… in order
            // of appearance, separately in the file and in the repairs.
            let actual = IdNormaliser.normalise(ModelFile.serialize(try ModelFile.deserialize(input, repairs: &repairs)), fixed: [])
            #expect(textDiff(expected, actual) == nil, "case \(i): \(textDiff(expected, actual) ?? "")")
            let expectedRepairs = o["repairs"]?.arrayValue?.map { $0.stringValue! } ?? []
            let actualRepairs = repairs.isEmpty
                ? [] : IdNormaliser.normalise(repairs.joined(separator: "\n"), fixed: []).components(separatedBy: "\n")
            #expect(actualRepairs == expectedRepairs, "case \(i) repairs")
        }
    }

    private static func deserializeCase(_ i: Int) throws -> (text: String, model: IDEF0Model, repairs: [String]) {
        let golden = Fixtures.json("golden-deserialize.json").objectValue!
        let text = golden["cases"]!.arrayValue![i].objectValue!["text"]!.stringValue!
        var repairs: [String] = []
        let model = try ModelFile.deserialize(text, repairs: &repairs)
        return (text, model, repairs)
    }

    @Test("Unknown members of diagrams, boxes and arrows are kept in file order; an endpoint's are not")
    func elementExtras() throws {
        let (_, model, repairs) = try Self.deserializeCase(7)
        let d1 = try #require(model.diagrams["d1"])
        #expect(d1.extras.keys == ["5", "iri"])
        #expect(d1.boxes[0].extras.keys == ["10", "iri", "prov", "__proto__"])
        #expect(d1.boxes[1].extras.isEmpty && d1.boxes[2].extras.isEmpty)
        #expect(d1.arrows[0].extras.keys == ["7", "cost", "iri"])
        #expect(d1.arrows[0].from == .box("b1", .right, 0.5))
        #expect(d1.arrows[0].to == .boundary(.right, 0.5))
        #expect(model.diagrams["d2"]?.extras.isEmpty == true)
        #expect(model.diagrams["d5"]?.extras.keys == ["zz"])
        #expect(model.extras.isEmpty)
        #expect(repairs.count == 2)

        // An edit that changes a known member leaves the annotations alone.
        var edited = model
        edited.diagrams["d1"]?.boxes[0].name = "Done"
        let written = try JSONValue.parse(ModelFile.serialize(edited))
        let box = written.objectValue!["diagrams"]!.objectValue!["d1"]!.objectValue!["boxes"]!.arrayValue![0].objectValue!
        #expect(box["name"] == .string("Done"))
        #expect(box["iri"] == .string("urn:b1"))
        #expect(box.keys.last == "__proto__")
    }

    @Test("Missing ids are generated, never the text \"null\", and repairs stay off the model")
    func idRepairs() throws {
        let (_, model, repairs) = try Self.deserializeCase(8)
        let ids = model.glossary.map(\.id)
        #expect(ids.count == 4)
        #expect(ids[0].hasPrefix("gl_") && ids[1].hasPrefix("gl_") && ids[0] != ids[1])
        #expect(Array(ids[2...]) == ["7", "g2"])
        #expect(model.glossary[1].term == "null" && model.glossary[1].definition == "")
        let d1 = try #require(model.diagrams["d1"])
        #expect(d1.boxes.map(\.id).filter { $0.hasPrefix("bx_") }.count == 3)
        #expect(Set(d1.boxes.map(\.id)).count == 4)
        #expect(d1.arrows.map(\.id).filter { $0.hasPrefix("ar_") }.count == 3)
        #expect(d1.arrows[0].from.kind == .box && d1.arrows[0].from.boxId == nil)
        #expect(repairs.count == 10)
        #expect(repairs.contains("Glossary entry 2 is not an object; it was dropped."))
        #expect(model.extras.isEmpty)
        #expect(!ModelFile.serialize(model).contains("repair"))
        // The throwing overload reads the same file.
        #expect(try ModelFile.deserialize(Self.deserializeCase(8).text).glossary.count == 4)
    }

    @Test("A file without dates, or with null dates, keeps them empty")
    func missingDates() throws {
        for i in [9, 10] {
            let (_, model, _) = try Self.deserializeCase(i)
            #expect(model.created == "" && model.revised == "", "case \(i)")
        }
        // A new model still gets today's date.
        #expect(IDEF0Model.create(title: "New").created == todayISO())
    }

    @Test("Non-string scalars in string fields are coerced — a deliberate divergence")
    func scalarCoercionDivergence() throws {
        let golden = Fixtures.json("golden-deserialize.json").objectValue!
        let input = golden["cases"]!.arrayValue![6].objectValue!["text"]!.stringValue!
        let model = try ModelFile.deserialize(input)
        #expect(model.author == "42")
        #expect(model.project == "true")
        #expect(model.diagrams["d1"]?.cNumber == "7")
        #expect(model.diagrams["d1"]?.boxes.first?.name == "")
        #expect(model.diagrams["d1"]?.boxes.first?.number == 0)
    }

    @Test("Unusable files fail with the web app's messages")
    func deserializeErrors() throws {
        let golden = Fixtures.json("golden-deserialize.json").objectValue!
        for e in golden["errors"]!.arrayValue! {
            let o = e.objectValue!
            let input = o["text"]!.stringValue!
            let expected = o["error"]!.stringValue!
            do {
                _ = try ModelFile.deserialize(input)
                Issue.record("expected \(input) to fail with \(expected)")
            } catch let error as ModelFileError {
                if expected.hasPrefix("Not valid JSON:") {
                    #expect(error.description.hasPrefix("Not valid JSON:"))
                } else {
                    #expect(error.description == expected, "input \(input)")
                }
            }
        }
    }

    // MARK: JavaScript semantics

    @Test("Numbers print as JavaScript's String(n) and round as Math.round")
    func numbers() {
        for entry in Fixtures.json("golden-util.json").objectValue!["numbers"]!.arrayValue! {
            let o = entry.objectValue!
            guard case .number(let v) = o["v"]!, case .number(let r) = o["round"]! else {
                Issue.record("malformed number entry"); continue
            }
            #expect(jsNumberString(v) == o["s"]!.stringValue!, "String(\(o["s"]!.stringValue!))")
            #expect(jsRound(v) == r, "Math.round(\(v))")
            switch o["r10"]! {
            case .number(let r10): #expect(roundTenth(v) == r10, "Math.round(\(v) * 10) / 10")
            // JSON.stringify writes Infinity as null: the largest double overflows when scaled by 10.
            case .null: #expect(!roundTenth(v).isFinite, "Math.round(\(v) * 10) / 10 should overflow")
            default: Issue.record("malformed r10 for \(v)")
            }
        }
        #expect(jsNumberString(-0.0) == "0")
    }

    @Test("Strings escape, slug, trim and collapse like the web app")
    func strings() {
        for entry in Fixtures.json("golden-util.json").objectValue!["strings"]!.arrayValue! {
            let o = entry.objectValue!
            let s = o["s"]!.stringValue!
            #expect(jsonQuote(s) == o["json"]!.stringValue!, "JSON.stringify(\(s.debugDescription))")
            #expect(escapeXml(s) == o["xml"]!.stringValue!, "escapeXml(\(s.debugDescription))")
            #expect(slugify(s) == o["slug"]!.stringValue!, "slugify(\(s.debugDescription))")
            #expect(jsTrim(s) == o["trim"]!.stringValue!, "trim(\(s.debugDescription))")
            #expect(jsCollapseWhitespace(jsTrim(s)).lowercased() == o["collapsed"]!.stringValue!, "normTerm(\(s.debugDescription))")
        }
    }

    @Test("wrapText breaks lines exactly as util.js does")
    func wrap() {
        for entry in Fixtures.json("golden-util.json").objectValue!["wraps"]!.arrayValue! {
            let o = entry.objectValue!
            guard case .number(let w) = o["w"]!, case .number(let fs) = o["fs"]!, case .number(let ml) = o["ml"]! else { continue }
            let expected = o["lines"]!.arrayValue!.map { $0.stringValue! }
            let actual = wrapText(o["t"]!.stringValue!, width: w, fontSize: fs, maxLines: Int(ml))
            #expect(actual == expected, "wrapText(\(o["t"]!.stringValue!.debugDescription), \(w), \(fs), \(Int(ml)))")
        }
    }

    @Test("fitText truncates a single line exactly as util.js does")
    func fit() {
        for entry in Fixtures.json("golden-util.json").objectValue!["fits"]!.arrayValue! {
            let o = entry.objectValue!
            guard case .number(let w) = o["w"]!, case .number(let fs) = o["fs"]! else { continue }
            let expected = o["s"]!.stringValue!
            let actual = fitText(o["t"]!.stringValue!, width: w, fontSize: fs)
            #expect(actual == expected, "fitText(\(o["t"]!.stringValue!.debugDescription), \(w), \(fs))")
        }
    }

    // MARK: box-name-fit (F62)
    //
    // goldens.html's shared `scenarios` array (consumed by ValidateParityTests
    // and ScenarioParityTests) is out of this package's scope — it is
    // authorized for util cases only, to avoid collisions with sibling wave-4
    // packages editing the same array — so box-name-fit coverage lives here
    // instead, against the same web app modules directly (node against
    // src/model/validate.js and src/util.js), rather than through a new
    // golden-scenarios.json entry.

    @Test("boxNameLines caps and ellipsizes at a finite box height, but a NaN height disables both, exactly as util.js's Math.max/Math.min(NaN) does")
    func boxNameLinesPropagatesNaNHeight() {
        let name = "aaa bbbb ccc dddd eee ffff ggg hhhh iii jjjj kkk llll mmm nnnn ooo"
        // node running src/util.js: boxNameLines(name, 88, NaN, 3, 10) — Math.max(1,
        // Math.min(4, Math.floor((NaN - 18) / 16))) is NaN, so wrapText's own
        // `lines.length === maxLines` / `=== maxLines - 1` checks never fire and
        // every word is placed, uncapped and never ellipsized.
        #expect(boxNameLines(name, w: 88, h: .nan, number: 3, fontSize: 10) == [
            "aaa bbbb ccc", "dddd eee ffff", "ggg hhhh iii jjjj", "kkk llll mmm", "nnnn ooo",
        ])
        // Same name and width at a finite height (maxLines caps to 3): capped and
        // the last line ellipsized, per node running the same call with h = 70.
        #expect(boxNameLines(name, w: 88, h: 70, number: 3, fontSize: 10) == [
            "aaa bbbb ccc", "dddd eee ffff", "ggg hhhh ii…",
        ])
    }

    @Test("validate() raises box-name-fit exactly as validate.js does when a box's name cannot fit even at the smallest font")
    func boxNameFitWarningFiresLikeValidateJS() throws {
        // The same one-context, one-child model, run through node's
        // deserialize + validate (src/io/json.js, src/model/validate.js): the
        // child's only box keeps its full name in the input but cannot show it
        // even at the smallest font the renderer tries, so validate.js emits
        // exactly one 'box-name-fit' warning, on A1, worded as below.
        let text = #"""
{"schema":"idef0-modeler/1","id":"mdl_fit","title":"Fit","purpose":"Test","viewpoint":"Tester","status":"WORKING","created":"2026-09-14","revised":"2026-09-14",
"glossary":[],
"rootDiagramId":"dg_ctx",
"diagrams":{
 "dg_ctx":{"id":"dg_ctx","node":"A-0","title":"Fit","parentBoxId":null,"boxes":[
    {"id":"bx_top","name":"Manufacture Product","number":0,"conceptId":null,"x":400,"y":358,"w":300,"h":170,"childDiagramId":"dg_child"}],
  "arrows":[
    {"id":"ar_i","label":"In","from":{"type":"boundary","side":"left","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"left","pos":0.5}},
    {"id":"ar_c","label":"Ctl","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_top","side":"top","pos":0.5}},
    {"id":"ar_o","label":"Out","from":{"type":"box","boxId":"bx_top","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}
  ]},
 "dg_child":{"id":"dg_child","node":"A0","title":"Child","parentBoxId":"bx_top","boxes":[
    {"id":"bx_c1","name":"Coordinate Long Range Manufacturing Plans For The Whole Plant","number":1,"conceptId":null,"x":100,"y":100,"w":110,"h":70,"childDiagramId":null}],
  "arrows":[
    {"id":"ar_ci","label":"In","from":{"type":"boundary","side":"left","pos":0.5},"to":{"type":"box","boxId":"bx_c1","side":"left","pos":0.5}},
    {"id":"ar_cc","label":"Ctl","from":{"type":"boundary","side":"top","pos":0.5},"to":{"type":"box","boxId":"bx_c1","side":"top","pos":0.5}},
    {"id":"ar_co","label":"Out","from":{"type":"box","boxId":"bx_c1","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}
  ]}
}}
"""#
        let model = try ModelFile.deserialize(text)
        let issues = validate(model)
        let fit = issues.filter { $0.code == "box-name-fit" }
        #expect(fit == [ValidationIssue(
            severity: .warning, code: "box-name-fit",
            message: "A1 is too small to show its full name (FIPS 183 §3.2.1.3)",
            diagramId: "dg_child", target: .box, targetId: "bx_c1")])
    }

    @Test("Terms collate as localeCompare does")
    func collation() {
        let golden = Fixtures.json("golden-util.json").objectValue!
        for entry in golden["locale"]!.arrayValue! {
            let t = entry.arrayValue!
            guard case .number(let sign) = t[2] else { continue }
            let a = t[0].stringValue!, b = t[1].stringValue!
            #expect(jsLocaleCompare(a, b) == Int(sign), "\(a.debugDescription).localeCompare(\(b.debugDescription))")
        }
        let terms = golden["sortedTerms"]!.arrayValue!.map { $0.stringValue! }
        #expect(terms.reversed().stableSorted { jsLocaleCompare($0, $1) < 0 } == terms)
    }

    // MARK: The JSON layer itself

    @Test("Parsing keeps member order and JSON.parse's duplicate-key rule")
    func parserOrderAndDuplicates() throws {
        let v = try JSONValue.parse(#"{"b":1,"a":2,"b":3,"2":"x","1":"y"}"#)
        let o = try #require(v.objectValue)
        #expect(o.keys == ["b", "a", "2", "1"])
        #expect(o["b"] == .number(3))
        #expect(v.stringified(indent: 0) == #"{"1":"y","2":"x","b":3,"a":2}"#)
    }

    @Test("Compact and indented output match JSON.stringify")
    func stringifyLayout() throws {
        let v = try JSONValue.parse(#"{"a":[1,{"b":[]}],"c":{}}"#)
        #expect(v.stringified(indent: 0) == #"{"a":[1,{"b":[]}],"c":{}}"#)
        #expect(v.stringified(indent: 2) == "{\n  \"a\": [\n    1,\n    {\n      \"b\": []\n    }\n  ],\n  \"c\": {}\n}")
    }
}
