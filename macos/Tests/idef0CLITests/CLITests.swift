// The `idef0` command line, run as a process.
//
// The CLI is the ontology toolkit's entry point: its exit codes, the key sets
// and order of its `--json` output, and the bytes `convert` writes are a
// contract other programs rely on. These tests run the binary SwiftPM built
// next to this test bundle (the test target depends on the executable, so
// `swift test` builds it first) and pin that contract.

import Foundation
import Testing
@testable import IDEF0Core

// MARK: - Running the binary

/// A class only so `Bundle(for:)` can find this test bundle.
private final class BundleMarker {}

/// The built `idef0`, found beside the test bundle rather than at a hard-coded
/// build path, so a different `--build-path` or architecture still finds it.
private let binary: URL = Bundle(for: BundleMarker.self).bundleURL
    .deletingLastPathComponent().appendingPathComponent("idef0")

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("IDEF0CoreTests/Fixtures")

/// The canonical sample model, exactly as the web app serialises it.
private let samplePath = fixtures.appendingPathComponent("sample.idef0.json").path

private func sampleBytes() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: samplePath)) }

private func sampleModel() throws -> IDEF0Model {
    var m = try ModelFile.deserialize(String(decoding: try sampleBytes(), as: UTF8.self))
    m.bindAll()
    return m
}

struct CLIRun {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self) }
}

/// A scratch directory removed when the test ends.
final class Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("idef0CLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func write(_ data: Data, _ name: String) throws -> String {
        let p = path(name)
        try data.write(to: URL(fileURLWithPath: p))
        return p
    }
}

/// Run `idef0` with `arguments`, feeding `stdin` (empty when nil). Output goes
/// to files rather than pipes, so a large output cannot fill a pipe and hang.
func idef0(_ arguments: [String], stdin: Data? = nil) throws -> CLIRun {
    try #require(FileManager.default.isExecutableFile(atPath: binary.path), "idef0 is not built at \(binary.path)")
    let scratch = try Scratch()
    let inPath = try scratch.write(stdin ?? Data(), "stdin")
    let outPath = try scratch.write(Data(), "stdout"), errPath = try scratch.write(Data(), "stderr")
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: inPath))
    process.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
    process.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: errPath))
    try process.run()
    process.waitUntilExit()
    return CLIRun(
        status: process.terminationStatus,
        stdout: try Data(contentsOf: URL(fileURLWithPath: outPath)),
        stderr: try Data(contentsOf: URL(fileURLWithPath: errPath))
    )
}

private func parse(_ run: CLIRun) throws -> JSONObject {
    try #require(try JSONValue.parse(run.out).objectValue)
}

/// The sample with a change applied, written as project JSON.
private func modifiedSample(_ scratch: Scratch, _ name: String, _ change: (inout IDEF0Model) -> Void) throws -> (path: String, model: IDEF0Model) {
    var m = try sampleModel()
    change(&m)
    return (try scratch.write(Data(ModelFile.serialize(m).utf8), name), m)
}

private let issueKeys = ["severity", "code", "message", "diagramId", "node", "kind", "id"]

// MARK: - validate

@Suite("idef0 validate")
struct ValidateCommandTests {
    @Test func cleanSampleExitsZero() throws {
        let run = try idef0(["validate", samplePath])
        #expect(run.status == 0)
        #expect(run.out.hasSuffix("0 error(s), \(summarize(validate(try sampleModel())).warnings) warning(s).\n"))
        #expect(run.err.isEmpty)
    }

    @Test func jsonShapeIsPinned() throws {
        let run = try idef0(["validate", samplePath, "--json"])
        #expect(run.status == 0)
        let top = try parse(run)
        #expect(top.keys == ["errors", "warnings", "issues"])
        let model = try sampleModel()
        let expected = validate(model)
        let issues = try #require(top["issues"]?.arrayValue)
        #expect(issues.count == expected.count)
        #expect(top["errors"] == .number(0))
        #expect(top["warnings"] == .number(Double(summarize(expected).warnings)))
        for (value, issue) in zip(issues, expected) {
            let o = try #require(value.objectValue)
            #expect(o.keys == issueKeys)
            #expect(o["severity"] == .string(issue.severity.rawValue))
            #expect(o["code"] == .string(issue.code))
            #expect(o["message"] == .string(issue.message))
            #expect(o["diagramId"] == issue.diagramId.map { .string($0) } ?? .null)
        }
    }

    @Test func optionsMayPrecedeTheModel() throws {
        let after = try idef0(["validate", samplePath, "--json"])
        let before = try idef0(["validate", "--json", samplePath])
        #expect(before.status == 0)
        #expect(before.stdout == after.stdout)
    }

    @Test func modelWithErrorsExitsOneAndNamesTheBox() throws {
        let scratch = try Scratch()
        var boxId = "", diagramId = "", node = ""
        let (path, _) = try modifiedSample(scratch, "broken.idef0.json") { m in
            diagramId = m.rootDiagramId
            node = m.diagrams[diagramId]!.node
            boxId = m.diagrams[diagramId]!.boxes[0].id
            m.diagrams[diagramId]!.boxes[0].name = ""
        }
        let text = try idef0(["validate", path])
        #expect(text.status == 1)
        #expect(text.out.contains("box-name"))

        let run = try idef0(["validate", path, "--json"])
        #expect(run.status == 1)
        let top = try parse(run)
        #expect(top.keys == ["errors", "warnings", "issues"])
        guard case .number(let errors)? = top["errors"] else { Issue.record("errors is not a number"); return }
        #expect(errors >= 1)
        let issues = try #require(top["issues"]?.arrayValue).compactMap(\.objectValue)
        for o in issues { #expect(o.keys == issueKeys) }
        let hit = try #require(issues.first { $0["code"] == .string("box-name") })
        #expect(hit["severity"] == .string("error"))
        #expect(hit["diagramId"] == .string(diagramId))
        #expect(hit["node"] == .string(node))
        #expect(hit["kind"] == .string("box"))
        #expect(hit["id"] == .string(boxId))
    }
}

// MARK: - concepts

@Suite("idef0 concepts")
struct ConceptsCommandTests {
    @Test func jsonShapeIsPinned() throws {
        let model = try sampleModel()
        let run = try idef0(["concepts", "--json", samplePath])
        #expect(run.status == 0)
        let top = try parse(run)
        #expect(top.keys == ["modelId", "concepts", "drift"])
        #expect(top["modelId"] == .string(model.id))
        let concepts = try #require(top["concepts"]?.arrayValue).compactMap(\.objectValue)
        #expect(concepts.count == model.glossary.count)
        #expect(concepts.map { $0["id"] } == model.glossary.map { .string($0.id) })
        var occurrences = 0
        for c in concepts {
            #expect(c.keys == ["id", "term", "kind", "definition", "uses", "occurrences"])
            for o in try #require(c["occurrences"]?.arrayValue).compactMap(\.objectValue) {
                #expect(o.keys == ["diagramId", "node", "kind", "id", "text"])
                occurrences += 1
            }
        }
        #expect(occurrences > 0)
    }

    @Test func driftCarriesIdsAndTerms() throws {
        let scratch = try Scratch()
        var boxId = "", conceptId = "", term = "", diagramId = ""
        let (path, _) = try modifiedSample(scratch, "drifted.idef0.json") { m in
            let d = m.rootDiagramId
            diagramId = d
            boxId = m.diagrams[d]!.boxes[0].id
            conceptId = m.diagrams[d]!.boxes[0].conceptId!
            term = m.glossary.first { jsStrictEquals($0.id, conceptId) }!.term
            m.diagrams[d]!.boxes[0].name = "Make Something Else"
        }
        let run = try idef0(["concepts", path, "--json"])
        #expect(run.status == 0)
        let top = try parse(run)
        let drift = try #require(top["drift"]?.arrayValue).compactMap(\.objectValue)
        let hit = try #require(drift.first)
        // diagramId and conceptId (F90) let a consumer join straight to the
        // diagram and the glossary entry, rather than matching on `term` text.
        #expect(hit.keys == ["diagramId", "node", "kind", "id", "text", "conceptId", "term"])
        #expect(hit["diagramId"] == .string(diagramId))
        #expect(hit["id"] == .string(boxId))
        #expect(hit["kind"] == .string("box"))
        #expect(hit["text"] == .string("Make Something Else"))
        #expect(hit["conceptId"] == .string(conceptId))
        #expect(hit["term"] == .string(term))
    }
}

// MARK: - convert, idl, report

@Suite("idef0 convert")
struct ConvertCommandTests {
    @Test func jsonIsByteIdenticalToTheSample() throws {
        let scratch = try Scratch()
        let out = scratch.path("out.idef0.json")
        let run = try idef0(["convert", samplePath, "-o", out])
        #expect(run.status == 0)
        #expect(run.err == "wrote \(out)\n")
        let written = try Data(contentsOf: URL(fileURLWithPath: out))
        #expect(written == (try sampleBytes()))
        #expect(written == Data(ModelFile.serialize(try sampleModel()).utf8))
    }

    @Test func xmlIsTheInterchangeWriterOutput() throws {
        let scratch = try Scratch()
        let out = scratch.path("out.xml")
        let run = try idef0(["convert", "-o", out, samplePath])
        #expect(run.status == 0)
        let written = try Data(contentsOf: URL(fileURLWithPath: out))
        #expect(written == Data(XMLInterchange.toXml(try sampleModel()).utf8))
    }

    /// Standard input has no name, so its format is sniffed: XML when it starts with "<".
    @Test func standardInputIsSniffed() throws {
        let scratch = try Scratch()
        let xml = scratch.path("sample.xml")
        #expect(try idef0(["convert", samplePath, "-o", xml]).status == 0)

        let fromXML = scratch.path("from-xml.json")
        let xmlRun = try idef0(["convert", "-", "-o", fromXML], stdin: try Data(contentsOf: URL(fileURLWithPath: xml)))
        #expect(xmlRun.status == 0)
        let expected = Data(ModelFile.serialize(try XMLInterchange.fromXml(String(decoding: try Data(contentsOf: URL(fileURLWithPath: xml)), as: UTF8.self))).utf8)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fromXML)) == expected)

        let fromJSON = scratch.path("from-json.json")
        let jsonRun = try idef0(["convert", "-", "-o", fromJSON], stdin: try sampleBytes())
        #expect(jsonRun.status == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fromJSON)) == (try sampleBytes()))

        let validated = try idef0(["validate", "--json", "-"], stdin: try sampleBytes())
        #expect(validated.status == 0)
        #expect(validated.stdout == (try idef0(["validate", "--json", samplePath])).stdout)
    }

    @Test func outputNeedsAKnownExtension() throws {
        let run = try idef0(["convert", samplePath, "-o", "-"])
        #expect(run.status == 2)
        #expect(run.err.contains("convert: the output must end in .json or .xml"))
    }
}

@Suite("idef0 idl and report")
struct TextCommandTests {
    @Test func idlGoesToStandardOutputOrTheFile() throws {
        let idl = XMLInterchange.toIdl(try sampleModel())
        let expected = idl.hasSuffix("\n") ? idl : idl + "\n"
        let run = try idef0(["idl", samplePath])
        #expect(run.status == 0)
        #expect(run.out == expected)
        #expect(try idef0(["idl", samplePath, "-o", "-"]).out == expected)

        let scratch = try Scratch()
        let out = scratch.path("model.idl.txt")
        let toFile = try idef0(["idl", "-o", out, samplePath])
        #expect(toFile.status == 0)
        #expect(toFile.stdout.isEmpty)
        #expect(try String(contentsOf: URL(fileURLWithPath: out), encoding: .utf8) == idl)
    }

    @Test func reportIsMarkdownOrHTML() throws {
        let model = try sampleModel()
        let md = try idef0(["report", samplePath])
        #expect(md.status == 0)
        #expect(md.out.contains(model.title))
        let html = try idef0(["report", "--html", samplePath])
        #expect(html.status == 0)
        #expect(html.out.contains("<html") || html.out.contains("<!doctype") || html.out.contains("<!DOCTYPE"))
    }
}

// MARK: - render

@Suite("idef0 render")
struct RenderCommandTests {
    @Test(arguments: [
        ("png", Data([0x89, 0x50, 0x4E, 0x47])),
        ("pdf", Data("%PDF".utf8)),
    ])
    func writesANonEmptyImage(ext: String, magic: Data) throws {
        let scratch = try Scratch()
        let out = scratch.path("sheet.\(ext)")
        let run = try idef0(["render", samplePath, "-o", out])
        #expect(run.status == 0)
        #expect(run.err == "wrote \(out)\n")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        #expect(bytes.count > magic.count)
        #expect(bytes.prefix(magic.count) == magic)
    }

    @Test func writesSVGForANamedDiagram() throws {
        let scratch = try Scratch()
        let model = try sampleModel()
        let child = try #require(model.diagrams.values.first { !jsStrictEquals($0.id, model.rootDiagramId) })
        let out = scratch.path("child.svg")
        let run = try idef0(["render", "--diagram", child.node, "-o", out, samplePath])
        #expect(run.status == 0)
        let text = try String(contentsOf: URL(fileURLWithPath: out), encoding: .utf8)
        #expect(text.contains("<svg"))
        #expect(text == SVGWriter.diagram(model, diagramId: child.id))
    }

    @Test func refusalsExitTwo() throws {
        let scratch = try Scratch()
        let noSuchNode = try idef0(["render", samplePath, "--diagram", "A999", "-o", scratch.path("x.png")])
        #expect(noSuchNode.err == "idef0: render: no diagram A999\n")
        #expect(noSuchNode.status == 2)
        let badScale = try idef0(["render", samplePath, "--scale", "zero", "-o", scratch.path("x.png")])
        #expect(badScale.status == 2)
        let hugeScale = try idef0(["render", samplePath, "--scale", "1000", "-o", scratch.path("x.png")])
        #expect(hugeScale.status == 2)
        #expect(hugeScale.err.hasPrefix("idef0: cannot write \(scratch.path("x.png")): A scale of 1000"))
        let badType = try idef0(["render", samplePath, "-o", scratch.path("x.gif")])
        #expect(badType.status == 2)
        #expect(!FileManager.default.fileExists(atPath: scratch.path("x.png")))
    }
}

// MARK: - Usage and I/O errors

@Suite("idef0 arguments")
struct ArgumentTests {
    @Test(arguments: [["--help"], ["-h"], ["help"], ["validate", "--help"], ["validate", samplePath, "--help"], ["render", "-h", samplePath]])
    func helpAnywherePrintsUsage(args: [String]) throws {
        let run = try idef0(args)
        #expect(run.status == 0)
        #expect(run.out.hasPrefix("usage: idef0 <command> <model> [options]"))
        #expect(run.err.isEmpty)
    }

    @Test func usageErrorsExitTwo() throws {
        let none = try idef0([])
        #expect(none.status == 2)
        #expect(none.err.contains("usage: idef0"))

        let unknown = try idef0(["frobnicate", samplePath])
        #expect(unknown.status == 2)
        #expect(unknown.err.hasPrefix("idef0: unknown command frobnicate"))

        let missing = try idef0(["validate", "--json"])
        #expect(missing.status == 2)
        #expect(missing.err.hasPrefix("idef0: validate: missing <model>"))

        let option = try idef0(["validate", samplePath, "--bogus"])
        #expect(option.status == 2)
        #expect(option.err == "idef0: validate: unknown option --bogus\n")

        let extra = try idef0(["validate", samplePath, "extra"])
        #expect(extra.status == 2)
        #expect(extra.err == "idef0: validate: unexpected argument extra\n")

        let noValue = try idef0(["idl", samplePath, "-o"])
        #expect(noValue.status == 2)
        #expect(noValue.err == "idef0: -o needs a value\n")

        let noOutput = try idef0(["convert", samplePath])
        #expect(noOutput.status == 2)
    }

    @Test func unreadableModelExitsTwo() throws {
        let scratch = try Scratch()
        let absent = scratch.path("absent.idef0.json")
        let run = try idef0(["validate", absent])
        #expect(run.status == 2)
        #expect(run.err.hasPrefix("idef0: cannot read \(absent): "))
        #expect(!run.err.contains("NSCocoaErrorDomain"))

        let junk = try scratch.write(Data("not json".utf8), "junk.idef0.json")
        let bad = try idef0(["validate", junk])
        #expect(bad.status == 2)
        #expect(bad.err.hasPrefix("idef0: \(junk): Not valid JSON"))
    }

    @Test(arguments: [["convert", "out.json"], ["idl", "out.txt"], ["render", "out.png"], ["render", "out.svg"]])
    func unwritableOutputExitsTwoWithAReadableReason(pair: [String]) throws {
        let scratch = try Scratch()
        let out = scratch.path("no-such-dir/\(pair[1])")
        let run = try idef0([pair[0], samplePath, "-o", out])
        #expect(run.status == 2)
        #expect(run.err.hasPrefix("idef0: cannot write \(out): "))
        #expect(!run.err.contains("NSCocoaErrorDomain"))
        #expect(!run.err.contains("Code="))
    }
}
