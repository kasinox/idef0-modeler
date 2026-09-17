// swift-tools-version: 6.0
//
// IDEF0 Modeler for macOS — the native front-end to the same model the web app
// edits. `IDEF0Core` is a Foundation-only port of the web app's model layer and
// reads and writes the identical `.idef0.json` bytes.

import PackageDescription

let package = Package(
    name: "IDEF0Modeler",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IDEF0Core", targets: ["IDEF0Core"]),
        .library(name: "IDEF0Render", targets: ["IDEF0Render"]),
        .library(name: "IDEF0Editing", targets: ["IDEF0Editing"]),
        .executable(name: "IDEF0Modeler", targets: ["IDEF0Modeler"]),
        .executable(name: "idef0", targets: ["idef0"]),
    ],
    targets: [
        // The model, validation, concepts, XML, reports and the display list.
        // Foundation only, and in parity with the web app's src/model and src/io.
        .target(
            name: "IDEF0Core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // CoreGraphics and CoreText rendering of the display list: PNG, PDF,
        // and the drawing the editor's canvas shows.
        .target(
            name: "IDEF0Render",
            dependencies: ["IDEF0Core"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The editing canvas's rules and every edit, with no AppKit.
        .target(
            name: "IDEF0Editing",
            dependencies: ["IDEF0Core"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The macOS app. Language mode 5: AppKit and SwiftUI document APIs still
        // carry isolation annotations that Swift 6 mode rejects in practice.
        .executableTarget(
            name: "IDEF0Modeler",
            dependencies: ["IDEF0Core", "IDEF0Render", "IDEF0Editing"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The command-line tool.
        .executableTarget(
            name: "idef0",
            dependencies: ["IDEF0Core", "IDEF0Render"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IDEF0CoreTests",
            dependencies: ["IDEF0Core"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IDEF0RenderTests",
            dependencies: ["IDEF0Core", "IDEF0Render"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IDEF0EditingTests",
            dependencies: ["IDEF0Editing", "IDEF0Core"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Drives the real canvas view with synthesized events in an offscreen window.
        .testTarget(
            name: "IDEF0ModelerTests",
            dependencies: ["IDEF0Modeler", "IDEF0Editing", "IDEF0Core"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs the built `idef0` binary as a process: the dependency on the
        // executable target makes `swift test` build it first.
        .testTarget(
            name: "idef0CLITests",
            dependencies: ["idef0", "IDEF0Core"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
