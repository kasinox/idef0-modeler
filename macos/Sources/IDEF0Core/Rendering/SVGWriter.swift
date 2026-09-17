// The display list as a standalone SVG document.
//
// Styles are written inline on each element rather than through classes, so
// the file renders the same anywhere — a browser, Inkscape, a document tool —
// with no stylesheet to lose. Coordinates and sizes are rounded to a tenth of
// a sheet unit; letter-spacing is in ems and written as is.

public enum SVGWriter {
    public static func document(_ ops: [DrawOp], comment: String? = nil) -> String {
        let w = n(Sheet.size.w), h = n(Sheet.size.h)
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        if let comment { out += "<!-- \(commentText(comment)) -->\n" }
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">\n"
        for op in ops { out += "  " + element(op) + "\n" }
        return out + "</svg>\n"
    }

    /// The document for one diagram of a model, as exported. The header
    /// comment is escaped as the web app's `diagramToSvgString` escapes it.
    public static func diagram(_ model: IDEF0Model, diagramId: String) -> String? {
        guard let d = model.diagrams[diagramId] else { return nil }
        return document(SheetDrawing.build(model, diagramId: diagramId),
                        comment: "IDEF0 diagram \(escapeXml(d.node)): \(escapeXml(d.title))")
    }

    /// XML forbids "--" inside a comment. A space goes between every pair of
    /// adjacent hyphens ("--" → "- -", "---" → "- - -") — the same rule as the
    /// web's `commentText` (`/-(?=-)/g` → `"- "`), so both headers read alike.
    /// It walks scalars, as that regex walks code units: one replacing pass
    /// would leave "---" as "- --", and a `Character` search would miss the
    /// pair in "--" + a combining mark.
    static func commentText(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var afterHyphen = false
        for scalar in s.unicodeScalars {
            if afterHyphen && scalar == "-" { out.append(" ") }
            out.append(scalar)
            afterHyphen = scalar == "-"
        }
        return String(out)
    }

    static func element(_ op: DrawOp) -> String {
        switch op {
        case .rect(let r, let fill, let stroke, _):
            return "<rect x=\"\(n(r.x))\" y=\"\(n(r.y))\" width=\"\(n(r.w))\" height=\"\(n(r.h))\"\(paint(fill: fill, stroke: stroke))/>"
        case .line(let a, let b, let stroke, _):
            return "<line x1=\"\(n(a.x))\" y1=\"\(n(a.y))\" x2=\"\(n(b.x))\" y2=\"\(n(b.y))\"\(paint(fill: nil, stroke: stroke))/>"
        case .path(let commands, let fill, let stroke, _):
            return "<path d=\"\(pathData(commands))\"\(paint(fill: fill, stroke: stroke))/>"
        case .circle(let c, let radius, let fill, let stroke, _):
            return "<circle cx=\"\(n(c.x))\" cy=\"\(n(c.y))\" r=\"\(n(radius))\"\(paint(fill: fill, stroke: stroke))/>"
        case .text(let s, let at, let style, _):
            var attrs = "x=\"\(n(at.x))\" y=\"\(n(at.y))\""
            attrs += " font-family=\"\(style.face == .mono ? "Menlo, Consolas, monospace" : "Helvetica, Arial, sans-serif")\""
            attrs += " font-size=\"\(n(style.size))\""
            switch style.weight {
            case .regular: break
            case .semibold: attrs += " font-weight=\"600\""
            case .bold: attrs += " font-weight=\"700\""
            }
            if style.italic { attrs += " font-style=\"italic\"" }
            attrs += " fill=\"\(style.color.hexString)\""
            if style.anchor != .start { attrs += " text-anchor=\"\(style.anchor.rawValue)\"" }
            if style.baseline == .middle { attrs += " dominant-baseline=\"middle\"" }
            // In ems, not sheet units: `n` would round the frame labels' 0.04 to 0.
            if style.letterSpacing != 0 { attrs += " letter-spacing=\"\(jsNumberString(style.letterSpacing))em\"" }
            if let halo = style.halo {
                attrs += " stroke=\"#ffffff\" stroke-width=\"\(n(halo))\" stroke-linejoin=\"round\" paint-order=\"stroke\""
            }
            return "<text \(attrs)>\(escapeXml(s))</text>"
        }
    }

    static func paint(fill: RGBA?, stroke: StrokeStyle?) -> String {
        var s = " fill=\"\(fill.map(\.hexString) ?? "none")\""
        if let stroke {
            s += " stroke=\"\(stroke.color.hexString)\" stroke-width=\"\(n(stroke.width))\""
            if !stroke.dash.isEmpty { s += " stroke-dasharray=\"\(stroke.dash.map(n).joined(separator: " "))\"" }
            if stroke.roundJoins { s += " stroke-linejoin=\"round\"" }
        }
        return s
    }

    /// Path data in the same notation `pointsToPath` writes.
    public static func pathData(_ commands: [PathCommand]) -> String {
        commands.map { c -> String in
            switch c {
            case .move(let p): return "M\(n(p.x)) \(n(p.y))"
            case .line(let p): return "L\(n(p.x)) \(n(p.y))"
            case .arc(let r, let sweep, let e): return "A\(n(r)) \(n(r)) 0 0 \(sweep ? 1 : 0) \(n(e.x)) \(n(e.y))"
            case .quad(let c, let e): return "Q\(n(c.x)) \(n(c.y)) \(n(e.x)) \(n(e.y))"
            case .close: return "Z"
            }
        }.joined(separator: " ")
    }

    static func n(_ v: Double) -> String { jsNumberString(roundTenth(v)) }
}
