// idef0 — IDEF0 models on the command line.
//
// The same core as the Mac app, so a model checked, converted or reported here
// gives the bytes and findings the app and the web app give. Every command
// reads either format (project JSON or the XML interchange) and binds concepts
// on load, as both apps do. `--json` output is for the ontology toolkit: ids,
// not label text, are what joins it to other data.
//
// Exit status: 0 success, 1 the model has rule errors (validate), 2 usage or I/O.

import Foundation
import IDEF0Core
import IDEF0Render

let usage = """
    usage: idef0 <command> <model> [options]

      validate <model> [--json]                 check FIPS 183 rules; exit 1 on errors
      convert  <model> -o <out.json|out.xml>    write canonical project JSON or XML interchange
      idl      <model> [-o out.txt]             IDEF0 IDL listing
      report   <model> [--html] [-o out]        model report (Markdown, or HTML)
      concepts <model> [--json]                 glossary with usage, occurrences and drift
      render   <model> [--diagram NODE] [--scale N] -o <out.png|out.pdf|out.svg>

    <model> is a .idef0.json project or an IDEF0 XML file; "-" reads standard input.
    Options may come before or after <model>; -h or --help anywhere prints this.
    idl and report write to standard output unless -o names a file ("-o -" is
    standard output too). validate and concepts always write to standard output.
    convert and render write only to a file: its extension picks the format.
    render draws the root diagram unless --diagram names one; a PDF without
    --diagram holds the whole kit, one page a diagram. --scale is pixels per
    sheet unit for PNG (default 2); the image may be at most
    \(Int(SheetExport.maxImageSide)) pixels a side.
    Exit status: 0 success, 1 the model has rule errors (validate), 2 usage or I/O.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("idef0: \(message)\n".utf8))
    exit(2)
}

// MARK: - Arguments

/// The command line, parsed position-independently: the command comes first;
/// after it, options and the one <model> may come in any order. A token is an
/// option when it starts with "-" and is not "-" itself (standard input), so
/// a model file whose name starts with "-" is given as "./-name". The first
/// bare token is the model and a second one is an error, so a mistyped option
/// value never silently becomes the model.
struct Options {
    var command: String
    var input: String
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(command: String, _ args: ArraySlice<String>, valueFlags: Set<String>, boolFlags: Set<String>) {
        self.command = command
        var positionals: [String] = []
        var rest = args
        while let arg = rest.popFirst() {
            if arg == "-" || !arg.hasPrefix("-") {
                positionals.append(arg)
            } else if boolFlags.contains(arg) {
                flags.insert(arg)
            } else if valueFlags.contains(arg) {
                guard let value = rest.popFirst() else { fail("\(arg) needs a value") }
                values[arg] = value
            } else {
                fail("\(command): unknown option \(arg)")
            }
        }
        guard let input = positionals.first else { fail("\(command): missing <model>\n\n\(usage)") }
        if positionals.count > 1 { fail("\(command): unexpected argument \(positionals[1])") }
        self.input = input
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
let commands: [String: (values: Set<String>, bools: Set<String>)] = [
    "validate": ([], ["--json"]),
    "convert": (["-o"], []),
    "idl": (["-o"], []),
    "report": (["-o"], ["--html"]),
    "concepts": ([], ["--json"]),
    "render": (["-o", "--diagram", "--scale"], []),
]
guard let name = argv.first else { fail(usage) }
// Help wins wherever it appears, so `idef0 validate model.json --help` is an answer, not an error.
if name == "help" || argv.contains("-h") || argv.contains("--help") {
    print(usage)
    exit(0)
}
guard let spec = commands[name] else { fail("unknown command \(name)\n\n\(usage)") }
let options = Options(command: name, argv.dropFirst(), valueFlags: spec.values, boolFlags: spec.bools)

// MARK: - Input and output

/// Read either format. A file named .xml is XML; anything else, standard input
/// included, is sniffed the way the web app sniffs a dropped file: XML when
/// the text starts with "<", the project JSON otherwise.
func loadModel(_ path: String) -> IDEF0Model {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch { fail("cannot read \(path): \(error.localizedDescription)") }
    }
    let text = ModelFile.decodeText(data)
    let isXML = path.lowercased().hasSuffix(".xml")
    do {
        var model = try ModelFile.read(text, isXML: isXML)
        // Binding happens on every load — see IDEF0Core.bindAll — but its ids
        // exist only in memory until the file is saved; warn (F13) so a
        // pipeline built on this being id-stable notices before it depends on
        // ids `convert` never wrote. A file with no top-level `id` is the
        // same problem one level up — `ModelFile.read` already minted
        // `model.id` above — so it is checked the same way (JSON only,
        // mirroring the web app's `!raw.id` in json.js) and folded into the
        // same warning rather than needing a second one.
        let unbound = model.unboundCount()
        let idWasMinted = modelIdWasMissing(text, isXML: isXML)
        model.bindAll()
        if unbound > 0 || idWasMinted {
            var reasons: [String] = []
            if unbound > 0 { reasons.append("\(unbound) element\(unbound == 1 ? "" : "s") had no concept ids") }
            if idWasMinted { reasons.append("the model had no id") }
            FileHandle.standardError.write(Data(
                "idef0: \(path): \(reasons.joined(separator: " and ")); ids generated for this run are not stable — run `idef0 convert \(path) -o \(path)` to persist them\n"
                    .utf8))
        }
        return model
    } catch {
        fail("\(path): \(error)")
    }
}

/// `!raw.id` from the web app's json.js: true when the file's top-level `id`
/// is absent, null, or empty, so `ModelFile.read` had to mint one that
/// exists only in memory until the model is saved (F13). XML is not this
/// check's concern — pass the same `isXML` sniff `loadModel` already made.
func modelIdWasMissing(_ text: String, isXML: Bool) -> Bool {
    guard !isXML, let value = try? JSONValue.parse(text), case .object(let obj) = value else { return false }
    return !JSONValue.truthy(obj["id"])
}

/// Write a file atomically, reporting a failure the way Finder would word it
/// rather than as an NSError dump.
func write(_ data: Data, to path: String) {
    do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch { fail("cannot write \(path): \(error.localizedDescription)") }
    FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
}

/// Write to `-o` when it names a file, standard output when it is absent or
/// "-". Text written to standard output always ends in a newline.
func emit(_ text: String, to path: String?) {
    guard let path, path != "-" else {
        FileHandle.standardOutput.write(Data(text.utf8))
        if !text.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
        return
    }
    write(Data(text.utf8), to: path)
}

func json(_ value: JSONValue) -> String { value.stringified(indent: 2) }
func str(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
func obj(_ members: [(String, JSONValue)]) -> JSONValue { .object(JSONObject(members.map { JSONMember($0.0, $0.1) })) }

// MARK: - Commands

let model = loadModel(options.input)

switch options.command {
case "validate":
    let issues = validate(model)
    let summary = summarize(issues)
    if options.flags.contains("--json") {
        // The web app's issue shape, plus the diagram's node so a reader need not look it up.
        let list = issues.map { i in
            obj([
                ("severity", .string(i.severity.rawValue)), ("code", .string(i.code)), ("message", .string(i.message)),
                ("diagramId", str(i.diagramId)), ("node", str(model.diagram(i.diagramId)?.node)),
                ("kind", str(i.target?.rawValue)), ("id", str(i.targetId)),
            ])
        }
        emit(json(obj([
            ("errors", .number(Double(summary.errors))), ("warnings", .number(Double(summary.warnings))), ("issues", .array(list)),
        ])), to: nil)
    } else {
        for i in issues {
            let node = model.diagram(i.diagramId)?.node ?? "—"
            print("\(i.severity == .error ? "error  " : "warning") \(node.padding(toLength: 6, withPad: " ", startingAt: 0)) \(i.code): \(i.message)")
        }
        print(issues.isEmpty ? "No issues." : "\(summary.errors) error(s), \(summary.warnings) warning(s).")
    }
    exit(summary.errors > 0 ? 1 : 0)

case "convert":
    guard let out = options.values["-o"] else { fail("convert: missing -o <out.json|out.xml>") }
    let lower = out.lowercased()
    if lower.hasSuffix(".xml") {
        emit(XMLInterchange.toXml(model), to: out)
    } else if lower.hasSuffix(".json") {
        emit(ModelFile.serialize(model), to: out)
    } else {
        fail("convert: the output must end in .json or .xml")
    }

case "idl":
    emit(XMLInterchange.toIdl(model), to: options.values["-o"])

case "report":
    emit(options.flags.contains("--html") ? Report.html(model) : Report.markdown(model), to: options.values["-o"])

case "concepts":
    let counts = model.conceptUsage()
    let drifted = model.driftedOccurrences()
    if options.flags.contains("--json") {
        let concepts = model.glossary.map { c in
            obj([
                ("id", .string(c.id)), ("term", .string(c.term)), ("kind", .string(c.kind)), ("definition", .string(c.definition)),
                ("uses", .number(Double(counts[c.id] ?? 0))),
                ("occurrences", .array(model.occurrencesOf(c.id).map { o in
                    obj([("diagramId", .string(o.diagramId)), ("node", .string(o.node)), ("kind", .string(o.kind.rawValue)),
                         ("id", .string(o.id)), ("text", .string(o.text))])
                })),
            ])
        }
        // diagramId and conceptId (F90) let a consumer join straight to the
        // diagram and the glossary entry, rather than searching occurrences
        // by id or matching on `term` text — the ids-not-labels promise above.
        let drift = drifted.map { d in
            obj([("diagramId", .string(d.diagramId)), ("node", .string(d.node)), ("kind", .string(d.kind.rawValue)), ("id", .string(d.id)),
                 ("text", .string(d.text)), ("conceptId", .string(d.conceptId)), ("term", .string(d.term))])
        }
        emit(json(obj([("modelId", .string(model.id)), ("concepts", .array(concepts)), ("drift", .array(drift))])), to: nil)
    } else {
        for c in model.glossary {
            let nodes = model.occurrencesOf(c.id).map { $0.node }
            print("\(c.kind.padding(toLength: 9, withPad: " ", startingAt: 0)) \(c.term)  ×\(counts[c.id] ?? 0)  \(nodes.joined(separator: " "))")
        }
        let unused = model.unusedConcepts()
        if !unused.isEmpty { print("\nUnused: \(unused.map { $0.term }.joined(separator: ", "))") }
        if !drifted.isEmpty {
            print("\nText drifted from its concept's term:")
            for d in drifted { print("  \(d.node) \(d.kind.rawValue) \"\(d.text)\" → \(d.term)") }
        }
    }

case "render":
    guard let output = options.values["-o"] else { fail("render: missing -o <out.png|out.pdf|out.svg>") }
    let node = options.values["--diagram"]
    var scale = 2.0
    if let raw = options.values["--scale"] {
        // Sizes beyond what an image can be are the exporter's to refuse.
        guard let v = Double(raw), v.isFinite, v > 0 else { fail("--scale needs a positive finite number") }
        scale = v
    }
    let diagramId: String
    if let node {
        guard let hit = model.diagrams.first(where: { $0.value.node == node }) else { fail("render: no diagram \(node)") }
        diagramId = hit.key
    } else {
        diagramId = model.rootDiagramId
    }
    // Drawing and writing fail differently: the exporter says what is wrong
    // with the request, the file system what is wrong with the path.
    let bytes: Data
    do {
        switch URL(fileURLWithPath: output).pathExtension.lowercased() {
        case "png": bytes = try SheetExport.png(model, diagramId: diagramId, scale: scale)
        case "pdf": bytes = try SheetExport.pdf(model, diagramIds: node == nil ? SheetExport.kitDiagramIds(model) : [diagramId])
        case "svg":
            guard let svg = SVGWriter.diagram(model, diagramId: diagramId) else { fail("cannot write \(output): The model has no diagram \(diagramId).") }
            bytes = Data(svg.utf8)
        default: fail("render: unknown output type .\(URL(fileURLWithPath: output).pathExtension)")
        }
    } catch let failure as SheetExport.Failure {
        // The exporter's own sentence; its localizedDescription is only a type name.
        fail("cannot write \(output): \(failure.description)")
    } catch {
        fail("cannot write \(output): \(error.localizedDescription)")
    }
    write(bytes, to: output)

default:
    fail(usage)
}
