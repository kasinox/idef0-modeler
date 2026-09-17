// F13's CLI-visible half: a load that had to mint ids the file did not carry
// — concepts `bindAll` had to bind, or a top-level `id` the file lacked —
// must say so on stderr, since those ids exist only for this run until the
// model is saved (`idef0 convert ... -o ...`). Reuses the `idef0`/`Scratch`
// helpers `CLITests.swift` defines (both file-internal, not file-private).
//
// Before this file, the only stderr assertion anywhere in the suite was
// `cleanSampleExitsZero`'s `run.err.isEmpty` — a negative check on a model
// that already carries every id, never a positive check of this warning's
// wording for a file that does not.

import Foundation
import Testing
@testable import IDEF0Core

/// A minimal, valid project file: one named, unbound box, no glossary, and —
/// unless `withId` is set — no top-level `id` either, so both F13 triggers
/// (`bindAll` has work to do, and `ModelFile.read` must mint a model id) can
/// be exercised independently.
private func minimalModelJSON(withId: Bool = false, named: Bool = true) -> String {
    let idMember = withId ? "\"id\": \"mdl_fixed_for_test\", " : ""
    let name = named ? "Do Something" : ""
    return """
    { \(idMember)"diagrams": { "d1": { "id": "d1", "node": "A0", "title": "Test",
      "boxes": [ { "id": "bx1", "name": "\(name)" } ], "arrows": [] } },
      "rootDiagramId": "d1" }
    """
}

@Suite("idef0 F13 load-repair warning")
struct LoadRepairWarningTests {
    @Test("a file with no top-level id warns, in every command that loads a model")
    func noIdWarns() throws {
        let scratch = try Scratch()
        let path = try scratch.write(Data(minimalModelJSON(withId: false).utf8), "noid.idef0.json")
        // Exit status is not this test's concern: this minimal model may well
        // fail real FIPS 183 rules, independent of F13's load-time warning.
        let run = try idef0(["validate", path])
        #expect(run.err.contains("the model had no id"))
        #expect(run.err.contains("ids generated for this run are not stable"))
        #expect(run.err.contains("idef0 convert \(path) -o \(path)"))
    }

    @Test("an unbound box warns about elements, not the model id, when the file already has one")
    func unboundOnlyWarns() throws {
        let scratch = try Scratch()
        let path = try scratch.write(Data(minimalModelJSON(withId: true).utf8), "unbound.idef0.json")
        let run = try idef0(["validate", path])
        #expect(run.err.contains("1 element had no concept ids"))
        #expect(!run.err.contains("model had no id"))
    }

    @Test("both repairs are named in one warning, joined by \"and\"")
    func bothRepairsJoinedInOneWarning() throws {
        let scratch = try Scratch()
        let path = try scratch.write(Data(minimalModelJSON(withId: false).utf8), "bare.idef0.json")
        let run = try idef0(["validate", path])
        #expect(run.err.contains("1 element had no concept ids and the model had no id;"))
    }

    @Test("a file with an id and nothing left to bind warns about neither")
    func fullyBoundFileIsSilent() throws {
        let scratch = try Scratch()
        let path = try scratch.write(Data(minimalModelJSON(withId: true, named: false).utf8), "empty.idef0.json")
        let run = try idef0(["validate", path])
        #expect(run.err.isEmpty)
    }

    @Test("concepts --json still warns on stderr for a file with no id, on every run")
    func conceptsJsonAlsoWarns() throws {
        let scratch = try Scratch()
        let path = try scratch.write(Data(minimalModelJSON(withId: false).utf8), "noid.idef0.json")
        for _ in 0..<2 {
            let run = try idef0(["concepts", path, "--json"])
            #expect(run.status == 0)
            #expect(run.err.contains("the model had no id"))
        }
    }
}
