// Writing a model or a diagram out in every format the web app offers.

import AppKit
import IDEF0Core
import IDEF0Render
import UniformTypeIdentifiers

enum Exporter {
    /// Ask where to save, then write. Returns silently if the modeller cancels.
    @MainActor
    private static func save(_ data: Data, name: String, type: UTType) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    private static func baseName(_ e: EditorContext) -> String { slugify(e.document.model.title) }

    /// One diagram's file name, as the web app's exportImage names it:
    /// `slugify(title)-slugify(node).ext`, so A-0 is `-a-0`, not `-A-0`.
    static func diagramFileName(_ model: IDEF0Model, _ diagram: Diagram, ext: String) -> String {
        "\(slugify(model.title))-\(slugify(diagram.node)).\(ext)"
    }

    private static func diagram(_ e: EditorContext) -> Diagram? { e.document.model.diagrams[e.state.diagramId] }

    @MainActor
    static func svg(_ e: EditorContext) throws {
        guard let d = diagram(e), let text = SVGWriter.diagram(e.document.model, diagramId: d.id) else { return }
        try save(Data(text.utf8), name: diagramFileName(e.document.model, d, ext: "svg"), type: .svg)
    }

    @MainActor
    static func png(_ e: EditorContext) throws {
        guard let d = diagram(e) else { return }
        try save(try SheetExport.png(e.document.model, diagramId: d.id, scale: 2), name: diagramFileName(e.document.model, d, ext: "png"), type: .png)
    }

    /// One diagram, or the FIPS 183 kit: every diagram in decomposition order.
    @MainActor
    static func pdf(_ e: EditorContext, allDiagrams: Bool) throws {
        let m = e.document.model
        guard let d = diagram(e) else { return }
        let ids = allDiagrams ? SheetExport.kitDiagramIds(m) : [d.id]
        // The web app prints a single diagram rather than naming a file; the
        // name follows its SVG and PNG so the three exports of a diagram agree.
        let name = allDiagrams ? "\(baseName(e))-kit.pdf" : diagramFileName(m, d, ext: "pdf")
        try save(try SheetExport.pdf(m, diagramIds: ids), name: name, type: .pdf)
    }

    @MainActor
    static func xml(_ e: EditorContext) throws {
        try save(Data(XMLInterchange.toXml(e.document.model).utf8), name: "\(baseName(e)).idef0.xml", type: .xml)
    }

    @MainActor
    static func idl(_ e: EditorContext) throws {
        try save(Data(XMLInterchange.toIdl(e.document.model).utf8), name: "\(baseName(e)).idl.txt", type: .plainText)
    }

    @MainActor
    static func report(_ e: EditorContext, html: Bool) throws {
        let m = e.document.model
        if html {
            try save(Data(Report.html(m).utf8), name: "\(baseName(e))-report.html", type: .html)
        } else {
            try save(Data(Report.markdown(m).utf8), name: "\(baseName(e))-report.md", type: UTType(filenameExtension: "md") ?? .plainText)
        }
    }
}
