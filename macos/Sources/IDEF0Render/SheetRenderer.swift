// Draws the core's display list with CoreGraphics and CoreText.
//
// This is the only drawing code in the app: the editor's canvas, PNG export
// and PDF export all call `draw(_:in:)`, so the screen and every exported file
// agree by construction — the same property the web app gets from rendering
// its screen and its exports through one module.

import CoreGraphics
import CoreText
import Foundation
import IDEF0Core

public enum SheetRenderer {
    /// Draw into a context whose user space is sheet units with the origin at
    /// the top left and y increasing downwards. Callers set that transform up;
    /// see `withSheetSpace` for bitmap and PDF contexts, whose native y is up.
    public static func draw(_ ops: [DrawOp], in ctx: CGContext) {
        for op in ops {
            switch op {
            case .rect(let r, let fill, let stroke, _):
                let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
                if let fill {
                    ctx.setFillColor(cg(fill))
                    ctx.fill(rect)
                }
                if let stroke {
                    apply(stroke, ctx)
                    ctx.stroke(rect)
                }
            case .line(let a, let b, let stroke, _):
                apply(stroke, ctx)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: a.x, y: a.y))
                ctx.addLine(to: CGPoint(x: b.x, y: b.y))
                ctx.strokePath()
            case .path(let commands, let fill, let stroke, _):
                let path = cgPath(commands)
                if let fill {
                    ctx.addPath(path)
                    ctx.setFillColor(cg(fill))
                    ctx.fillPath()
                }
                if let stroke {
                    ctx.addPath(path)
                    apply(stroke, ctx)
                    ctx.strokePath()
                }
            case .circle(let center, let radius, let fill, let stroke, _):
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                if let fill {
                    ctx.setFillColor(cg(fill))
                    ctx.fillEllipse(in: rect)
                }
                if let stroke {
                    apply(stroke, ctx)
                    ctx.strokeEllipse(in: rect)
                }
            case .text(let string, let at, let style, _):
                drawText(string, at: at, style: style, in: ctx)
            }
        }
    }

    /// Run `body` with `ctx` transformed so that sheet units are scaled by
    /// `scale` and y increases downwards, for a context of the given height.
    public static func withSheetSpace(_ ctx: CGContext, height: CGFloat, scale: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: scale, y: -scale)
        body()
        ctx.restoreGState()
    }

    // MARK: Paths

    /// The core's path commands as a CGPath. An arc is written the way SVG
    /// specifies it — endpoints, radius and sweep — so the centre is recovered
    /// with the SVG implementation notes' endpoint-to-centre conversion.
    public static func cgPath(_ commands: [PathCommand]) -> CGPath {
        let path = CGMutablePath()
        var current = CGPoint.zero
        for c in commands {
            switch c {
            case .move(let p):
                current = CGPoint(x: p.x, y: p.y)
                path.move(to: current)
            case .line(let p):
                current = CGPoint(x: p.x, y: p.y)
                path.addLine(to: current)
            case .quad(let control, let end):
                current = CGPoint(x: end.x, y: end.y)
                path.addQuadCurve(to: current, control: CGPoint(x: control.x, y: control.y))
            case .close:
                path.closeSubpath()
            case .arc(let radius, let sweepPositive, let end):
                let target = CGPoint(x: end.x, y: end.y)
                addSVGArc(path, from: current, to: target, radius: radius, sweepPositive: sweepPositive)
                current = target
            }
        }
        return path
    }

    /// A small arc (large-arc-flag 0) of a circle from `p1` to `p2`.
    static func addSVGArc(_ path: CGMutablePath, from p1: CGPoint, to p2: CGPoint, radius: Double, sweepPositive: Bool) {
        let x1p = (p1.x - p2.x) / 2, y1p = (p1.y - p2.y) / 2
        let d2 = x1p * x1p + y1p * y1p
        guard d2 > 0, radius > 0 else { path.addLine(to: p2); return }
        var r = radius
        // A radius too small to span the endpoints is scaled up, as SVG requires.
        if d2 > r * r { r = d2.squareRoot() }
        let radicand = max(0, (r * r - d2) / d2)
        // SVG F.6.5: the root's sign is + when large-arc ≠ sweep. Large-arc is
        // always 0 here, so a positive sweep takes +.
        let coef = radicand.squareRoot() * (sweepPositive ? 1 : -1)
        let cxp = coef * y1p, cyp = -coef * x1p
        let center = CGPoint(x: cxp + (p1.x + p2.x) / 2, y: cyp + (p1.y + p2.y) / 2)
        let start = atan2(p1.y - center.y, p1.x - center.x)
        let endAngle = atan2(p2.y - center.y, p2.x - center.x)
        // Sweep 1 runs towards increasing angles, which CoreGraphics calls
        // counter-clockwise in the path's own coordinate space.
        path.addArc(center: center, radius: r, startAngle: start, endAngle: endAngle, clockwise: !sweepPositive)
    }

    // MARK: Text

    static func drawText(_ string: String, at: Point, style: TextStyle, in ctx: CGContext) {
        guard !string.isEmpty else { return }
        let font = ctFont(style)
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if style.letterSpacing != 0 {
            attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = style.letterSpacing * style.size
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)

        var x = at.x
        switch style.anchor {
        case .start: break
        case .middle: x -= width / 2
        case .end: x -= width
        }
        // SVG's `dominant-baseline: middle` aligns the middle of the x-height.
        let baselineY = style.baseline == .middle ? at.y + CTFontGetXHeight(font) / 2 : at.y

        ctx.saveGState()
        // The context's y runs downwards, so glyphs are flipped back upright.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baselineY)
        if let halo = style.halo {
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineWidth(halo)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            CTLineDraw(line, ctx)
            ctx.textPosition = CGPoint(x: x, y: baselineY)
        }
        ctx.setTextDrawingMode(.fill)
        ctx.setFillColor(cg(style.color))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func ctFont(_ style: TextStyle) -> CTFont {
        let base = CTFontCreateWithName((style.face == .mono ? "Menlo" : "Helvetica") as CFString, style.size, nil)
        var traits: CTFontSymbolicTraits = []
        if style.weight != .regular { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, style.size, nil, traits, traits) ?? base
    }

    // MARK: Paint

    static func apply(_ stroke: StrokeStyle, _ ctx: CGContext) {
        ctx.setStrokeColor(cg(stroke.color))
        ctx.setLineWidth(stroke.width)
        ctx.setLineJoin(stroke.roundJoins ? .round : .miter)
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: stroke.dash.map { CGFloat($0) })
    }

    static func cg(_ c: RGBA) -> CGColor { CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }
}
