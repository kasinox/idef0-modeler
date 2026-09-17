// Translating a Swift model's ids into the ids a golden scenario recorded.
//
// A golden numbers generated ids (new1, new2…) by first appearance across its
// whole record, so comparing one section in isolation would number them
// differently. Correspondence by position avoids that: the k-th diagram in
// `model.diagrams`, its j-th box and j-th arrow, and the j-th glossary concept
// are the same objects in both implementations whenever the port is correct —
// and if it is not, the structural comparisons fail first and say so.

import Foundation
@testable import IDEF0Core

struct GoldenIdMap {
    private(set) var ids: [String: String] = [:]

    init(model: IDEF0Model, golden: JSONObject) {
        let diagrams = golden["diagrams"]?.arrayValue ?? []
        for (k, entry) in model.diagrams.enumerated() where k < diagrams.count {
            guard let g = diagrams[k].objectValue else { continue }
            if let gid = g["id"]?.stringValue { ids[entry.key] = gid }
            let boxes = g["boxes"]?.arrayValue ?? []
            for (j, b) in entry.value.boxes.enumerated() where j < boxes.count {
                if let gid = boxes[j].objectValue?["id"]?.stringValue { ids[b.id] = gid }
            }
            let arrows = g["arrows"]?.arrayValue ?? []
            for (j, a) in entry.value.arrows.enumerated() where j < arrows.count {
                if let gid = arrows[j].objectValue?["id"]?.stringValue { ids[a.id] = gid }
            }
        }
        let glossary = golden["concepts"]?.objectValue?["glossary"]?.arrayValue ?? []
        for (j, c) in model.glossary.enumerated() where j < glossary.count {
            if let gid = glossary[j].arrayValue?.first?.stringValue { ids[c.id] = gid }
        }
    }

    /// The golden's id for a Swift id; ids the model does not hold pass through.
    func callAsFunction(_ id: String?) -> String? {
        guard let id else { return nil }
        return ids[id] ?? id
    }
}
