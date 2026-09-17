// PNG and PDF output of IDEF0 sheets.

import CoreGraphics
import Foundation
import IDEF0Core
import ImageIO
import UniformTypeIdentifiers

public enum SheetExport {
    public enum Failure: Error, CustomStringConvertible {
        case noSuchDiagram(String)
        case invalidScale(Double)
        case couldNotCreateContext
        case couldNotEncode

        public var description: String {
            switch self {
            case .noSuchDiagram(let id): return "The model has no diagram \(id)."
            case .invalidScale(let s):
                return "A scale of \(jsNumberString(s)) gives an image smaller than 1 pixel or larger than \(Int(maxImageSide)) pixels a side."
            case .couldNotCreateContext: return "Could not create a drawing context."
            case .couldNotEncode: return "Could not encode the image."
            }
        }
    }

    /// The most pixels an exported image may have on a side: about 30× the
    /// sheet, past which a bitmap is gigabytes and no viewer wants it.
    public static let maxImageSide = 32_768.0

    /// One diagram as a bitmap. `scale` is pixels per sheet unit: 1 gives an
    /// 1100 × 850 image, 2 gives 2200 × 1700. A scale that is not finite, or
    /// gives an image under a pixel or over `maxImageSide` a side, is refused
    /// before any conversion to `Int` — which traps rather than throws.
    public static func image(_ model: IDEF0Model, diagramId: String, scale: Double = 2, options: DrawingOptions = .export) throws -> CGImage {
        guard model.diagrams[diagramId] != nil else { throw Failure.noSuchDiagram(diagramId) }
        let pw = (Sheet.size.w * scale).rounded(), ph = (Sheet.size.h * scale).rounded()
        guard scale.isFinite, pw >= 1, ph >= 1, pw <= maxImageSide, ph <= maxImageSide else {
            throw Failure.invalidScale(scale)
        }
        let width = Int(pw), height = Int(ph)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.couldNotCreateContext }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        SheetRenderer.withSheetSpace(ctx, height: CGFloat(height), scale: CGFloat(scale)) {
            SheetRenderer.draw(SheetDrawing.build(model, diagramId: diagramId, options: options), in: ctx)
        }
        guard let image = ctx.makeImage() else { throw Failure.couldNotEncode }
        return image
    }

    /// One diagram as PNG data.
    public static func png(_ model: IDEF0Model, diagramId: String, scale: Double = 2, options: DrawingOptions = .export) throws -> Data {
        let image = try image(model, diagramId: diagramId, scale: scale, options: options)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.couldNotEncode
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.couldNotEncode }
        return data as Data
    }

    /// Diagrams as a PDF, one landscape US Letter page each — the sheet is an
    /// 11 × 8.5 inch form at 100 units per inch. Pass `kitDiagramIds` for the
    /// FIPS 183 "kit" of every diagram.
    public static func pdf(_ model: IDEF0Model, diagramIds: [String]) throws -> Data {
        for id in diagramIds where model.diagrams[id] == nil { throw Failure.noSuchDiagram(id) }
        let pointsPerUnit = 72.0 / 100.0
        var mediaBox = CGRect(x: 0, y: 0, width: Sheet.size.w * pointsPerUnit, height: Sheet.size.h * pointsPerUnit)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextTitle as String: model.title,
                  kCGPDFContextAuthor as String: model.author,
                  kCGPDFContextCreator as String: "IDEF0 Modeler",
              ] as CFDictionary)
        else { throw Failure.couldNotCreateContext }
        for id in diagramIds {
            ctx.beginPDFPage(nil)
            SheetRenderer.withSheetSpace(ctx, height: mediaBox.height, scale: pointsPerUnit) {
                SheetRenderer.draw(SheetDrawing.build(model, diagramId: id), in: ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Every diagram, in the order a reader walks the decomposition.
    public static func kitDiagramIds(_ model: IDEF0Model) -> [String] {
        model.diagramTree().map(\.diagram.id)
    }
}
