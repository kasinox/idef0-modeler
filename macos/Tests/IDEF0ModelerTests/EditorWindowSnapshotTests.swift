// The whole editor window, laid out and drawn offscreen by AppKit — sidebar,
// canvas and inspector — without screen recording. The test checks the layout
// and writes the image to .build/renders/ for a person to look at.

import AppKit
import SwiftUI
import Testing
@testable import IDEF0Core
@testable import IDEF0Modeler

@MainActor
@Suite("Editor window", .serialized)
struct EditorWindowSnapshotTests {
    /// Every view of a type in a view hierarchy.
    func views<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        (root as? T).map { [$0] } ?? [] + root.subviews.flatMap { views(of: type, in: $0) }
    }

    func render(_ document: IDEF0Document, size: CGSize, configure: (EditorWindow) -> EditorWindow = { $0 }) throws -> (NSView, NSBitmapImageRep) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: configure(EditorWindow(document: document)))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its split view and inspector columns.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (host, rep)
    }

    static var renders: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/renders", isDirectory: true)
    }

    @Test("The editor lays out a sidebar, a sized canvas and an inspector")
    func layout() async throws {
        let doc = IDEF0Document(model: buildSampleModel())
        let (host, rep) = try render(doc, size: CGSize(width: 1440, height: 900))
        let canvases = views(of: SheetCanvasView.self, in: host)
        let canvas = try #require(canvases.first, "no canvas in the window")
        #expect(canvas.frame.width > 500 && canvas.frame.height > 400, "canvas is \(canvas.frame.size)")
        #expect(canvas.scale > 0.3, "the sheet is fitted to the canvas, scale \(canvas.scale)")
        // The canvas does not fill the window: the side columns are laid out beside it.
        let inWindow = canvas.convert(canvas.bounds, to: nil)
        #expect(inWindow.minX > 150, "no sidebar to the left of the canvas")
        #expect(inWindow.maxX < 1440 - 150, "no inspector to the right of the canvas")
        // The zoom readout follows the fitted scale once deferred main-actor work has run.
        for _ in 0..<5 { await Task.yield() }
        #expect(abs((canvas.state?.zoom ?? 0) - Double(canvas.scale)) < 0.001,
                "status bar zoom \(canvas.state?.zoom ?? 0) vs canvas scale \(canvas.scale)")

        // Capture again so the saved image shows the settled status bar.
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(abs((canvas.state?.zoom ?? 0) - Double(canvas.scale)) < 0.001,
                "captured zoom \(canvas.state?.zoom ?? 0) vs canvas scale \(canvas.scale)")

        try FileManager.default.createDirectory(at: Self.renders, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: Self.renders.appendingPathComponent("editor-window.png"))
    }

    /// Each side panel drawn on its own, outside the glass containers that
    /// offscreen caching cannot draw, so their contents can be looked at.
    @Test("Side panels render on their own")
    func panelSnapshots() throws {
        _ = NSApplication.shared
        let doc = IDEF0Document(model: buildSampleModel())
        let a0 = try #require(doc.model.diagrams.values.first { $0.node == "A0" })
        let state = EditorState(diagramId: a0.id)
        state.selection = .box(a0.boxes[1].id)
        let panels: [(String, AnyView, CGSize)] = [
            ("sidebar-tree.png", AnyView(SidebarView(document: doc, state: state)), CGSize(width: 300, height: 700)),
            ("inspector-box.png", AnyView(InspectorView(document: doc, state: state)), CGSize(width: 340, height: 900)),
        ]
        try FileManager.default.createDirectory(at: Self.renders, withIntermediateDirectories: true)
        for (name, view, size) in panels {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: Self.renders.appendingPathComponent(name))
            // Glass controls draw blank offscreen, but the lists and forms
            // below them must not: count pixels that differ from the background.
            let inked = stride(from: rep.pixelsHigh / 12, to: rep.pixelsHigh, by: 3).reduce(0) { n, y in
                n + stride(from: 0, to: rep.pixelsWide, by: 3).filter { x in
                    (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.6
                }.count
            }
            #expect(inked > 200, "\(name) looks blank: \(inked) bright pixels below the picker")
        }
    }
}
