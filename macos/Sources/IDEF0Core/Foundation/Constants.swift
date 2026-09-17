// Geometry of the standard IDEF0 sheet plus the IDEF0 vocabulary — a port of
// src/model/types.js. Every model coordinate is in sheet units: an 11 × 8.5
// landscape page at 100 units per inch.

public struct SheetRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    public var x2: Double { x + w }
    public var y2: Double { y + h }
}

public struct SheetSize: Hashable, Sendable {
    public var w: Double
    public var h: Double
    public init(w: Double, h: Double) { self.w = w; self.h = h }
}

public enum Sheet {
    public static let size = SheetSize(w: 1100, h: 850)
    /// Outer frame of the IDEF0 form.
    public static let frame = SheetRect(x: 24, y: 24, w: 1052, h: 802)
    /// Header band: Used At / Author / Notes / Status / Context.
    public static let headerHeight: Double = 92
    /// Footer band: Node / Title / Number.
    public static let footerHeight: Double = 56
    /// The drawing area — everywhere a modeller may place boxes and arrows.
    public static let work = SheetRect(
        x: frame.x + 16,
        y: frame.y + headerHeight + 16,
        w: frame.w - 32,
        h: frame.h - headerHeight - footerHeight - 32
    )
    public static let boxDefault = SheetSize(w: 190, h: 112)
    public static let boxMin = SheetSize(w: 110, h: 70)
    /// Length of the straight stub an arrow travels before it may turn.
    public static let stub: Double = 22
    /// How many boxes a decomposition diagram holds (FIPS 183 §3.3.3 rule 4).
    public static let decompMin = 3
    public static let decompMax = 6
}

/// The four sides of a box, in the order the web app's `SIDES` lists them.
public enum Side: String, CaseIterable, Hashable, Sendable {
    case left, top, right, bottom

    /// The IDEF0 role of an arrow touching a box on this side.
    public var role: Role {
        switch self {
        case .left: return .input
        case .top: return .control
        case .right: return .output
        case .bottom: return .mechanism
        }
    }

    /// The ICOM letter for this side.
    public var icomLetter: String {
        switch self {
        case .left: return "I"
        case .top: return "C"
        case .right: return "O"
        case .bottom: return "M"
        }
    }

    public var isHorizontalNormal: Bool { self == .left || self == .right }
}

public enum Role: String, CaseIterable, Hashable, Sendable {
    case input, control, output, mechanism, call, unknown

    public var label: String {
        switch self {
        case .input: return "Input"
        case .control: return "Control"
        case .output: return "Output"
        case .mechanism: return "Mechanism"
        case .call: return "Call"
        case .unknown: return "Unclassified"
        }
    }
}

/// FIPS 183 model status values, in presentation order.
public enum ModelStatus: String, CaseIterable, Hashable, Sendable {
    case working = "WORKING"
    case draft = "DRAFT"
    case recommended = "RECOMMENDED"
    case publication = "PUBLICATION"
}

/// Kinds of glossary concept, in presentation order.
public enum ConceptKind: String, CaseIterable, Hashable, Sendable {
    case activity, data, mechanism, other
}
