// Exporting a model whose decomposition loops back on itself.
//
// `kitDiagramIds` walks the decomposition tree, so before diagramTree kept the
// diagrams on its current path this recursed until the process died (SIGSEGV
// on `idef0 render -o kit.pdf`). The kit is now finite: every diagram the walk
// reaches, each time it is reached, and no more.

import CoreGraphics
import Foundation
import Testing
@testable import IDEF0Core
@testable import IDEF0Render

@Suite("CycleExport")
struct CycleExportTests {

    /// A-0 → A0, whose box 1 names A0 itself and whose box 2 names A-0.
    private static let cyclic = #"""
{"schema":"idef0-modeler/1","id":"mdl_cyc","title":"Cyclic","purpose":"P","viewpoint":"V","status":"WORKING","created":"2026-09-14","revised":"2026-09-14","glossary":[],
"rootDiagramId":"dg_ctx",
"diagrams":{
 "dg_ctx":{"id":"dg_ctx","node":"A-0","title":"Cyclic","parentBoxId":null,"boxes":[
    {"id":"bx_top","name":"Run Plant","number":0,"x":400,"y":300,"w":300,"h":170,"childDiagramId":"dg_a0"}],
  "arrows":[{"id":"ar_out","label":"Goods","from":{"type":"box","boxId":"bx_top","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}]},
 "dg_a0":{"id":"dg_a0","node":"A0","title":"Run Plant","parentBoxId":"bx_top","boxes":[
    {"id":"bx_1","name":"Take Order","number":1,"x":100,"y":172,"w":190,"h":112,"childDiagramId":"dg_a0"},
    {"id":"bx_2","name":"Ship Goods","number":2,"x":500,"y":330,"w":190,"h":112,"childDiagramId":"dg_ctx"}],
  "arrows":[{"id":"ar_a0out","label":"Goods","from":{"type":"box","boxId":"bx_2","side":"right","pos":0.5},"to":{"type":"boundary","side":"right","pos":0.5}}]}
}}
"""#

    @Test("The kit of a cyclic model is the diagrams the walk reaches, and it ends")
    func cyclicKit() throws {
        let m = try ModelFile.deserialize(Self.cyclic)
        let ids = SheetExport.kitDiagramIds(m)
        #expect(ids == ["dg_ctx", "dg_a0"])
        let data = try SheetExport.pdf(m, diagramIds: ids)
        let doc = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(doc.numberOfPages == ids.count)
    }
}
