// Concepts: the model's vocabulary as identified things rather than as text —
// a port of src/model/concepts.js.
//
// FIPS 183 §3.2.2 already describes IDEF0 ontologically — functions, objects,
// the roles objects play relative to functions. What it lacks is identity. A
// box denotes an *activity* concept and an arrow an *object* concept, each
// carrying a `conceptId` into `glossary`, so whatever reads the model joins on
// an identifier instead of on display text.
//
// The label stays on the box or arrow because §3.3.2.4 lets a child diagram
// give an arrow a more specific label than its parent carries. What travels
// between parent and child is the concept id.

// MARK: - Terms

/// `normTerm(s)` — the key two terms are compared on: trimmed, runs of
/// whitespace collapsed, lower-cased. "Work  order" and "work order" are one term.
public func normTerm(_ s: String) -> String {
    jsLowercase(jsCollapseWhitespace(jsTrim(s)))
}

// MARK: - Query results

public enum OccurrenceKind: String, Hashable, Sendable {
    case box, arrow
}

/// Why `combineConcepts` or `uncombineConcept` refused — each the case where
/// the web app returns null and leaves the model as it was.
public enum BundleError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Fewer than two distinct member ids were given.
    case tooFewMembers
    /// An id names no glossary concept.
    case unknownConcept(String)
    /// An id is already a member of a bundle; a concept belongs to at most one.
    case alreadyMember(String)
    /// The bundle would contain itself.
    case wouldNest
    /// The id names no bundle (a plain concept, or nothing).
    case notABundle(String)

    public var description: String {
        switch self {
        case .tooFewMembers: return "A bundle combines at least two concepts."
        case .unknownConcept(let id): return "No concept \(id) to combine."
        case .alreadyMember(let id): return "Concept \(id) is already a member of a bundle."
        case .wouldNest: return "A bundle cannot contain itself."
        case .notABundle(let id): return "Concept \(id) is not a bundle."
        }
    }
}

/// One place a concept is used. A box is reported by its own node number, an
/// arrow by the node of the diagram it appears on.
public struct ConceptOccurrence: Hashable, Sendable {
    public var diagramId: String
    public var node: String
    public var kind: OccurrenceKind
    public var id: String
    public var text: String

    public init(diagramId: String, node: String, kind: OccurrenceKind, id: String, text: String) {
        self.diagramId = diagramId; self.node = node; self.kind = kind; self.id = id; self.text = text
    }
}

/// A box or arrow whose authored text no longer matches its concept's term.
/// `node` is the diagram's node for both kinds, as the web app reports it.
/// `diagramId` and `conceptId` (F90) let a consumer join straight to the
/// diagram and the glossary entry, rather than searching occurrences by id or
/// matching on `term` text.
public struct DriftedOccurrence: Hashable, Sendable {
    public var diagramId: String
    public var node: String
    public var kind: OccurrenceKind
    public var id: String
    public var text: String
    public var conceptId: String
    public var term: String

    public init(diagramId: String, node: String, kind: OccurrenceKind, id: String, text: String, conceptId: String, term: String) {
        self.diagramId = diagramId; self.node = node; self.kind = kind; self.id = id
        self.text = text; self.conceptId = conceptId; self.term = term
    }
}

// MARK: - The registry

extension IDEF0Model {
    /// `conceptById(m, id)` — nil for a missing or empty id, as `id ? … : null` is.
    public func conceptById(_ id: String?) -> Concept? {
        guard let id, !id.isEmpty else { return nil }
        return glossary.first { jsStrictEquals($0.id, id) }
    }

    /// The glossary index of the entry `id` names, by code-unit identity — nil
    /// for a missing or empty id, or one that only canonically equals a
    /// glossary id rather than matching it exactly (`conceptById`'s notion of
    /// "no such concept"). Lets a caller outside this module (IDEF0Editing has
    /// no access to `jsStrictEquals`) look up or edit a glossary entry without
    /// falling back to Swift's canonical-equivalence `==`, which would treat
    /// NFC and NFD spellings of an id as the same entry.
    public func conceptIndex(_ id: String?) -> Int? {
        guard let id, !id.isEmpty else { return nil }
        return glossary.firstIndex { jsStrictEquals($0.id, id) }
    }

    /// Whether any box or arrow denotes `id`, by code-unit identity. Unlike
    /// the public, merged `conceptUsage()`, an id that is only a canonical
    /// twin of a used id does not count here — the check a removal needs
    /// before it may delete a glossary entry.
    public func isConceptUsed(_ id: String) -> Bool {
        exactConceptUsage()[JSStringKey(id)] != nil
    }

    /// Whether `id` names the context (A-0) diagram, by code-unit identity —
    /// the root check every "this is the top diagram" rule (tunnels, deleting
    /// the last box, the XML `context` flag) needs, since Swift's canonical
    /// `==` would treat an NFD id as naming the NFC root too.
    public func isRootDiagram(_ id: String?) -> Bool {
        jsStrictEquals(id, rootDiagramId)
    }

    /// `findConcept(m, term)` — the first glossary entry with the same `normTerm`.
    public func findConcept(_ term: String) -> Concept? {
        let k = normTerm(term)
        guard !k.isEmpty else { return nil }
        return glossary.first { jsStrictEquals(normTerm($0.term), k) }
    }

    /// `resolveConcept(m, term, kind)` — the concept for `term`, created (and the
    /// glossary re-sorted) when the model does not hold it yet. A new concept has
    /// no definition and no extras; `kind` is ignored when the term already exists.
    @discardableResult
    public mutating func resolveConcept(_ term: String, kind: String = "other") -> Concept? {
        let t = jsTrim(term)
        guard !t.isEmpty else { return nil }
        if let found = findConcept(t) { return found }
        let c = Concept(id: uid("gl"), term: t, kind: kind, definition: "")
        glossary.append(c)
        sortGlossary()
        return c
    }

    /// `bindBox(m, box)` — a box denotes an activity (§3.2.2). An unnamed box is
    /// left unbound: its `conceptId` becomes nil. Does nothing when there is no such box.
    @discardableResult
    public mutating func bindBox(diagramId: String, boxId: String) -> Concept? {
        guard let i = diagrams[diagramId]?.boxIndex(boxId) else { return nil }
        return bindBox(diagramId: diagramId, at: i)
    }

    /// `bindArrow(m, arrow)` — the concept kind follows the role the arrow's
    /// destination side gives it. Does nothing when there is no such arrow.
    @discardableResult
    public mutating func bindArrow(diagramId: String, arrowId: String) -> Concept? {
        guard let i = diagrams[diagramId]?.arrowIndex(arrowId) else { return nil }
        return bindArrow(diagramId: diagramId, at: i)
    }

    /// Whether `bindAll()` would still give this box or arrow a new
    /// `conceptId`. An unbound element (no id) needs it only when it has text
    /// to bind; an orphan id — one that names no glossary entry — needs it
    /// only when its text is non-blank and names no *other* concept either
    /// (F14: a blank-text orphan keeps its id for the validator to ignore, and
    /// a term clash keeps its id so 'concept-unbound' reports it, rather than
    /// being silently rewritten).
    private func needsBinding(conceptId: String?, text: String) -> Bool {
        if conceptById(conceptId) != nil { return false }
        let t = jsTrim(text)
        guard let conceptId, !conceptId.isEmpty else { return !t.isEmpty }
        if t.isEmpty { return false }
        return findConcept(t) == nil
    }

    /// How many boxes and arrows `bindAll()` would still have to bind —
    /// checked before binding, since `bindAll` is idempotent and leaves
    /// nothing to count afterward. Lets a caller (the Mac document, the CLI)
    /// tell the user that a load bound something that now needs saving to
    /// keep it (F13).
    public func unboundCount() -> Int {
        var n = 0
        for (_, dg) in diagrams {
            for b in dg.boxes where needsBinding(conceptId: b.conceptId, text: b.name) { n += 1 }
            for a in dg.arrows where needsBinding(conceptId: a.conceptId, text: a.label) { n += 1 }
        }
        return n
    }

    /// `bindAll(m)` — bind every box and arrow that is not already bound.
    /// Idempotent and cheap enough to run on every load, which is how a model
    /// written before concepts existed acquires them.
    public mutating func bindAll() {
        // Positions, not ids: a diagram holding two boxes with one id binds both,
        // as the web app does walking its arrays.
        for diagramId in diagrams.keys {
            let boxCount = diagrams[diagramId]?.boxes.count ?? 0
            for i in 0..<boxCount {
                guard let box = diagrams[diagramId]?.boxes[i] else { continue }
                bindOrRestoreBox(diagramId: diagramId, at: i, box: box)
            }
            let arrowCount = diagrams[diagramId]?.arrows.count ?? 0
            for i in 0..<arrowCount {
                guard let arrow = diagrams[diagramId]?.arrows[i] else { continue }
                bindOrRestoreArrow(diagramId: diagramId, at: i, arrow: arrow)
            }
        }
    }

    // MARK: Relabelling (F11)

    /// A box's name changed by an edit — as opposed to `bindBox`'s load-time
    /// binding. Implements the rules `relabelledConceptId` documents; a box
    /// has no ICOM counterpart, so rule (4) never applies to it.
    @discardableResult
    public mutating func relabelBox(diagramId: String, boxId: String, to text: String) -> Concept? {
        guard let i = diagrams[diagramId]?.boxIndex(boxId) else { return nil }
        let t = jsTrim(text)
        updateDiagram(diagramId) { $0.boxes[i].name = t }
        guard !t.isEmpty else {
            updateDiagram(diagramId) { $0.boxes[i].conceptId = nil }
            return nil
        }
        let before = conceptById(diagrams[diagramId]?.boxes[i].conceptId)
        let newId = relabelledConceptId(before: before, text: t, createKind: ConceptKind.activity.rawValue, counterpartId: nil)
        updateDiagram(diagramId) { $0.boxes[i].conceptId = newId }
        return conceptById(newId)
    }

    /// An arrow's label changed by an edit — as opposed to `bindArrow`'s
    /// load-time binding. A child elaborating its parent's label (§3.3.2.4),
    /// or a typo fixed on an undefined term nothing else uses, keeps its
    /// conceptId instead of being silently moved to a new or unrelated
    /// concept (F11).
    @discardableResult
    public mutating func relabelArrow(diagramId: String, arrowId: String, to text: String) -> Concept? {
        guard let i = diagrams[diagramId]?.arrowIndex(arrowId) else { return nil }
        let t = jsTrim(text)
        updateDiagram(diagramId) { $0.arrows[i].label = t }
        guard !t.isEmpty else {
            updateDiagram(diagramId) { $0.arrows[i].conceptId = nil }
            return nil
        }
        guard let dg = diagrams[diagramId] else { return nil }
        let arrow = dg.arrows[i]
        let before = conceptById(arrow.conceptId)
        let counterpartId = before != nil ? icomCounterpartConceptId(dg, arrow) : nil
        let newId = relabelledConceptId(before: before, text: t, createKind: arrowConceptKind(arrow).rawValue, counterpartId: counterpartId)
        updateDiagram(diagramId) { $0.arrows[i].conceptId = newId }
        return conceptById(newId)
    }

    /// Decide the conceptId a relabelled box or arrow should carry, given the
    /// concept it denoted before the edit (or nil, if it was unbound) and its
    /// new trimmed text `t`. In order: (2) `t` renormalises to the current
    /// concept's own term — keep the id. (3) `findConcept(t)` names a
    /// different concept — rebind to it, an explicit reuse of existing
    /// vocabulary. (4) the current concept is shared with an ICOM counterpart
    /// of this element — keep the id and let the text drift (`counterpartId`
    /// is nil for a box, which never has one). (5) nothing else uses the
    /// concept, and it carries no definition or extras — rename it in place,
    /// keeping its id, rather than leave a defined-looking term dangling or
    /// spawn a near-duplicate. (6) otherwise resolve or create a concept by
    /// `t`, as `bindBox`/`bindArrow` do. (Rule 1, the empty-text case, is
    /// handled by the caller.)
    private mutating func relabelledConceptId(before: Concept?, text t: String, createKind: String, counterpartId: String?) -> String? {
        if let before {
            if jsStrictEquals(normTerm(t), normTerm(before.term)) { return before.id }
            if let found = findConcept(t), !jsStrictEquals(found.id, before.id) { return found.id }
            if let counterpartId, jsStrictEquals(counterpartId, before.id) { return before.id }
            let usage = exactConceptUsage()[JSStringKey(before.id)] ?? 0
            if usage <= 1, jsTrim(before.definition).isEmpty, before.extras.isEmpty,
               let gi = glossary.firstIndex(where: { jsStrictEquals($0.id, before.id) }) {
                glossary[gi].term = t
                sortGlossary()
                return before.id
            }
        }
        return resolveConcept(t, kind: createKind)?.id
    }

    /// The concept id an ICOM counterpart of `arrow` carries, if it has one
    /// (§3.3.2.4): a boundary arrow's counterpart is the parent's paired
    /// arrow; an arrow touching a box with a child diagram has its
    /// counterpart among that diagram's boundary arrows. Only arrows have
    /// counterparts — a box's activity concept is never shared with anything else.
    private func icomCounterpartConceptId(_ dg: Diagram, _ arrow: Arrow) -> String? {
        if (arrow.from.kind == .boundary || arrow.to.kind == .boundary), !jsStrictEquals(dg.id, rootDiagramId) {
            if let p = icomPairing(dg).pairs.first(where: { jsStrictEquals($0.child.arrow.id, arrow.id) }) {
                return p.parent.arrow.conceptId
            }
        }
        var boxIds: [JSStringKey] = []
        if arrow.from.kind == .box, let bid = arrow.from.boxId { boxIds.append(JSStringKey(bid)) }
        if arrow.to.kind == .box, let bid = arrow.to.boxId, !boxIds.contains(JSStringKey(bid)) { boxIds.append(JSStringKey(bid)) }
        for boxId in boxIds {
            guard let box = dg.findBox(boxId.string), let child = childDiagram(of: box) else { continue }
            if let p = icomPairing(child).pairs.first(where: { pair in pair.parent.arrows.contains { jsStrictEquals($0.id, arrow.id) } }) {
                return p.child.arrow.conceptId
            }
        }
        return nil
    }

    /// `renameConcept(m, id, term)` — rename a concept and carry every box and
    /// arrow that denotes it along. Renaming onto a term the model already holds
    /// says the two are one thing, so the concepts merge instead.
    @discardableResult
    public mutating func renameConcept(_ id: String, to term: String) -> Concept? {
        let t = jsTrim(term)
        guard conceptById(id) != nil, !t.isEmpty,
              let index = glossary.firstIndex(where: { jsStrictEquals($0.id, id) }) else { return nil }
        if let clash = findConcept(t), !jsStrictEquals(clash.id, id) {
            return mergeConcepts(from: id, into: clash.id)
        }
        glossary[index].term = t
        let renamed = glossary[index]
        for diagramId in diagrams.keys {
            updateDiagram(diagramId) { d in
                for i in d.boxes.indices where jsStrictEquals(d.boxes[i].conceptId, id) { d.boxes[i].name = t }
                for i in d.arrows.indices where jsStrictEquals(d.arrows[i].conceptId, id) { d.arrows[i].label = t }
            }
        }
        sortGlossary()
        return renamed
    }

    /// `mergeConcepts(m, fromId, intoId)` — fold one concept into another: every
    /// reference moves across and takes the surviving term, and `fromId` leaves
    /// the glossary. Returns the surviving concept, untouched when the ids are
    /// equal. Refuses — nil, and nothing changes — when `fromId` is a bundle
    /// that holds `intoId` at any depth: merging the general concept into one
    /// of its own specifics would put the survivor inside itself. Otherwise
    /// every members list is rewritten fromId→intoId and de-duplicated, a
    /// bundle never lists itself, and the survivor takes over the source's
    /// members, so a bundle merged into a plain concept stays a bundle under
    /// the surviving id.
    @discardableResult
    public mutating func mergeConcepts(from fromId: String, into intoId: String) -> Concept? {
        guard conceptById(intoId) != nil, !jsStrictEquals(fromId, intoId) else { return conceptById(intoId) }
        let from = conceptById(fromId)
        if from != nil, transitiveMembers(fromId).contains(JSStringKey(intoId)) { return nil }
        // Members of two different bundles cannot be one concept without
        // putting the survivor in both bundles; un-combine one first.
        if let fromBundle = bundleOf(fromId), let intoBundle = bundleOf(intoId),
           !jsStrictEquals(fromBundle.id, intoBundle.id) { return nil }
        // The survivor's definition wins if it has one; otherwise the
        // source's definition, if it has one, is not lost with it (F15).
        if let intoIndex = glossary.firstIndex(where: { jsStrictEquals($0.id, intoId) }),
           jsTrim(glossary[intoIndex].definition).isEmpty,
           let from, !jsTrim(from.definition).isEmpty {
            glossary[intoIndex].definition = from.definition
        }
        rewriteMembers(from: fromId, into: intoId)
        if let from, !from.members.isEmpty, let intoIndex = glossary.firstIndex(where: { jsStrictEquals($0.id, intoId) }) {
            let inherited = from.members.map { jsStrictEquals($0, fromId) ? intoId : $0 }
            glossary[intoIndex].members = dedupeMembers(glossary[intoIndex].members + inherited, ownId: intoId)
        }
        guard let into = conceptById(intoId) else { return nil }
        for diagramId in diagrams.keys {
            updateDiagram(diagramId) { d in
                for i in d.boxes.indices where jsStrictEquals(d.boxes[i].conceptId, fromId) {
                    d.boxes[i].conceptId = intoId
                    d.boxes[i].name = into.term
                }
                for i in d.arrows.indices where jsStrictEquals(d.arrows[i].conceptId, fromId) {
                    d.arrows[i].conceptId = intoId
                    d.arrows[i].label = into.term
                }
            }
        }
        glossary = glossary.filter { !jsStrictEquals($0.id, fromId) }
        return into
    }

    // MARK: Bundles (FIPS 183 §3.2.2.3)

    /// The glossary index of the first entry whose `members` lists `id`.
    private func bundleIndexOf(_ id: String) -> Int? {
        glossary.firstIndex { g in g.members.contains { jsStrictEquals($0, id) } }
    }

    /// `bundleOf(m, id)` — the bundle whose `members` lists `id` (the first in
    /// glossary order, should a malformed file list a concept in two), else
    /// nil. A nil or empty id is in no bundle.
    public func bundleOf(_ id: String?) -> Concept? {
        guard let id, !id.isEmpty, let i = bundleIndexOf(id) else { return nil }
        return glossary[i]
    }

    /// `effectiveConceptId(m, id)` — the outermost bundle enclosing `id`, else
    /// `id` itself: the concept an ICOM position stands for once its specifics
    /// are bundled. Cycle-safe: a bundle already visited ends the climb, so a
    /// malformed file cannot loop. A nil or empty id comes back unchanged.
    public func effectiveConceptId(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return id }
        var cur = id
        var seen: Set<JSStringKey> = [JSStringKey(cur)]
        while true {
            guard let b = bundleOf(cur), !seen.contains(JSStringKey(b.id)) else { return cur }
            seen.insert(JSStringKey(b.id))
            cur = b.id
        }
    }

    /// `transitiveMembers(m, id)` — every concept reachable from `id` through
    /// members lists, at any depth (cycle-safe). Whether `id` itself is in the
    /// set says whether it sits on a cycle.
    /// `transitiveMembers(m, id)` as ids, by code units, in discovery order —
    /// the public face of the Set the validator and merge rules use.
    public func transitiveMemberIds(_ id: String?) -> [String] {
        var out: [String] = []
        var seen = Set<JSStringKey>()
        var stack: [String] = conceptById(id)?.members ?? []
        while let x = stack.popLast() {
            let key = JSStringKey(x)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(x)
            stack.append(contentsOf: conceptById(x)?.members ?? [])
        }
        return out
    }

    func transitiveMembers(_ id: String?) -> Set<JSStringKey> {
        var out = Set<JSStringKey>()
        var stack: [String] = conceptById(id)?.members ?? []
        while let x = stack.popLast() {
            let key = JSStringKey(x)
            if out.contains(key) { continue }
            out.insert(key)
            if let cx = conceptById(x) { stack.append(contentsOf: cx.members) }
        }
        return out
    }

    /// A members list with repeats dropped (the first occurrence stays) and
    /// any entry naming the list's own bundle dropped too.
    private func dedupeMembers(_ members: [String], ownId: String) -> [String] {
        var seen = Set<JSStringKey>()
        return members.filter { x in
            if jsStrictEquals(x, ownId) || seen.contains(JSStringKey(x)) { return false }
            seen.insert(JSStringKey(x))
            return true
        }
    }

    /// Every members list with `fromId` replaced by `intoId`, de-duplicated.
    /// In `intoId`'s own list, and in the lists below it, `fromId` is dropped
    /// rather than rewritten: a member merged into its own bundle (or an
    /// ancestor of it) is absorbed, and rewriting it there would make the
    /// bundle contain itself.
    private mutating func rewriteMembers(from fromId: String, into intoId: String) {
        let below = transitiveMembers(intoId)
        for i in glossary.indices where !glossary[i].members.isEmpty {
            let g = glossary[i]
            let absorbs = jsStrictEquals(g.id, intoId) || below.contains(JSStringKey(g.id))
            let rewritten = absorbs
                ? g.members.filter { !jsStrictEquals($0, fromId) }
                : g.members.map { jsStrictEquals($0, fromId) ? intoId : $0 }
            glossary[i].members = dedupeMembers(rewritten, ownId: g.id)
        }
    }

    /// `combineConcepts(m, memberIds, term)` — combine two or more concepts
    /// into a new bundle: a fresh glossary entry `{ id, term, kind,
    /// definition: "", members }` whose kind is the members' kind when they
    /// all agree and "other" otherwise. The members' own entries, and every
    /// box and arrow bound to them, are left as they are — a bundle is looked
    /// up from its members, never written into an occurrence, which is what
    /// makes un-combining lossless. Throws (where the web app returns null),
    /// changing nothing, when fewer than two distinct ids are given, an id
    /// names no concept, an id is already a member of a bundle, or the result
    /// would nest a bundle inside itself.
    @discardableResult
    public mutating func combineConcepts(_ memberIds: [String], term: String) throws -> Concept {
        var ids: [String] = []
        for id in memberIds where !ids.contains(where: { jsStrictEquals($0, id) }) { ids.append(id) }
        if ids.count < 2 { throw BundleError.tooFewMembers }
        let id = uid("gl")
        for x in ids {
            if conceptById(x) == nil { throw BundleError.unknownConcept(x) }
            if bundleOf(x) != nil { throw BundleError.alreadyMember(x) }
            if jsStrictEquals(x, id) || transitiveMembers(x).contains(JSStringKey(id)) { throw BundleError.wouldNest }
        }
        let kinds = ids.map { conceptById($0)!.kind }
        let kind = kinds.allSatisfy { jsStrictEquals($0, kinds[0]) } ? kinds[0] : ConceptKind.other.rawValue
        let bundle = Concept(id: id, term: jsTrim(term), kind: kind, definition: "", members: ids)
        glossary.append(bundle)
        sortGlossary()
        return bundle
    }

    /// `uncombineConcept(m, bundleId)` — dissolve a bundle. Its members stand
    /// on their own again, and if the bundle was itself a member of an outer
    /// bundle they join that list at its position, in order. What becomes of
    /// the entry depends on whether anything denotes it: an arrow drawn from
    /// the bundle's port (or a box, by a hand-edit) is bound to the bundle id
    /// itself, so the entry is kept as a plain concept — its members list
    /// dropped, its place in any outer bundle kept, its former members
    /// inserted after it — and nothing is left dangling. When nothing uses
    /// it, the entry goes, and its members simply take its place. Nothing
    /// bound to a member changes either way. Throws (where the web app
    /// returns null) when `bundleId` is not a bundle. Returns the entry with
    /// no members, as the web app's does once its list is deleted.
    @discardableResult
    public mutating func uncombineConcept(_ bundleId: String) throws -> Concept {
        guard let b = conceptById(bundleId), b.isBundle else { throw BundleError.notABundle(bundleId) }
        let kept = isConceptUsed(bundleId)
        if let oi = bundleIndexOf(bundleId),
           let at = glossary[oi].members.firstIndex(where: { jsStrictEquals($0, bundleId) }) {
            glossary[oi].members.replaceSubrange(kept ? (at + 1)..<(at + 1) : at..<(at + 1), with: b.members)
        }
        if kept {
            if let i = glossary.firstIndex(where: { jsStrictEquals($0.id, bundleId) }) { glossary[i].members = [] }
        } else {
            glossary = glossary.filter { !jsStrictEquals($0.id, bundleId) }
        }
        var plain = b
        plain.members = []
        return plain
    }

    /// `removeConcept(m, id)` — delete a glossary entry, the one place both
    /// apps remove a concept. A bundle is un-combined first (its members
    /// survive, spliced into any outer bundle) and then removed whether or
    /// not anything used it; a member is dropped from every bundle's list;
    /// boxes and arrows bound to the concept keep their now-dangling id, as
    /// they always have, for `concept-unbound` to report. Returns the removed
    /// entry, or nil when `id` names none.
    @discardableResult
    public mutating func removeConcept(_ id: String) -> Concept? {
        guard let c = conceptById(id) else { return nil }
        if c.isBundle { _ = try? uncombineConcept(id) }
        for i in glossary.indices where glossary[i].members.contains(where: { jsStrictEquals($0, id) }) {
            glossary[i].members = glossary[i].members.filter { !jsStrictEquals($0, id) }
        }
        glossary = glossary.filter { !jsStrictEquals($0.id, id) }
        return c
    }

    // MARK: Queries

    /// `occurrencesOf(m, conceptId)` — every place a concept is used, in diagram
    /// order, boxes before arrows: the basis of any cross-diagram analysis.
    public func occurrencesOf(_ conceptId: String?) -> [ConceptOccurrence] {
        guard let conceptId, !conceptId.isEmpty else { return [] }
        var out: [ConceptOccurrence] = []
        for (_, dg) in diagrams {
            for b in dg.boxes where jsStrictEquals(b.conceptId, conceptId) {
                out.append(ConceptOccurrence(diagramId: dg.id, node: boxNode(dg, b), kind: .box, id: b.id, text: b.name))
            }
            for a in dg.arrows where jsStrictEquals(a.conceptId, conceptId) {
                out.append(ConceptOccurrence(diagramId: dg.id, node: dg.node, kind: .arrow, id: a.id, text: a.label))
            }
        }
        return out
    }

    /// `conceptUsage(m)` — conceptId → how many boxes and arrows carry it. Ids
    /// that name no concept are counted too; an unused concept has no entry.
    /// Keyed as a Swift dictionary is, so two ids that differ only in Unicode
    /// normalisation share an entry here, though not in the queries below.
    public func conceptUsage() -> [String: Int] {
        var n: [String: Int] = [:]
        for (key, count) in exactConceptUsage() { n[key.string, default: 0] += count }
        return n
    }

    /// `conceptUsage(m)` as the web app's `Map` keys it — by code units — for
    /// the queries here and the validator.
    func exactConceptUsage() -> [JSStringKey: Int] {
        var n: [JSStringKey: Int] = [:]
        for (_, dg) in diagrams {
            for b in dg.boxes { if let id = b.conceptId, !id.isEmpty { n[JSStringKey(id), default: 0] += 1 } }
            for a in dg.arrows { if let id = a.conceptId, !id.isEmpty { n[JSStringKey(id), default: 0] += 1 } }
        }
        return n
    }

    /// `unusedConcepts(m)` — concepts the model defines but never uses, in glossary order.
    public func unusedConcepts() -> [Concept] {
        let used = exactConceptUsage()
        return glossary.filter { used[JSStringKey($0.id)] == nil }
    }

    /// `driftedOccurrences(m)` — places where the authored text has drifted from
    /// its concept's term. Legitimate under §3.3.2.4 when a child elaborates a
    /// parent's label, so it is information, not an error. Blank text is not drift.
    public func driftedOccurrences() -> [DriftedOccurrence] {
        var out: [DriftedOccurrence] = []
        for (_, dg) in diagrams {
            for b in dg.boxes {
                if let c = conceptById(b.conceptId), !jsTrim(b.name).isEmpty, !jsStrictEquals(normTerm(b.name), normTerm(c.term)) {
                    out.append(DriftedOccurrence(diagramId: dg.id, node: dg.node, kind: .box, id: b.id, text: b.name, conceptId: c.id, term: c.term))
                }
            }
            for a in dg.arrows {
                if let c = conceptById(a.conceptId), !jsTrim(a.label).isEmpty, !jsStrictEquals(normTerm(a.label), normTerm(c.term)) {
                    out.append(DriftedOccurrence(diagramId: dg.id, node: dg.node, kind: .arrow, id: a.id, text: a.label, conceptId: c.id, term: c.term))
                }
            }
        }
        return out
    }

    // MARK: Private

    /// Bind the box at a position, which `bindAll` needs and `bindBox` resolves to.
    @discardableResult
    private mutating func bindBox(diagramId: String, at index: Int) -> Concept? {
        guard let box = diagrams[diagramId]?.boxes[index] else { return nil }
        let c = resolveConcept(box.name, kind: ConceptKind.activity.rawValue)
        updateDiagram(diagramId) { $0.boxes[index].conceptId = c?.id }
        return c
    }

    @discardableResult
    private mutating func bindArrow(diagramId: String, at index: Int) -> Concept? {
        guard let arrow = diagrams[diagramId]?.arrows[index] else { return nil }
        let c = resolveConcept(arrow.label, kind: arrowConceptKind(arrow).rawValue)
        updateDiagram(diagramId) { $0.arrows[index].conceptId = c?.id }
        return c
    }

    /// Bind or restore one box, as `bindAll` needs. An unbound box (no
    /// `conceptId`) binds by text, as `bindBox` always has. A non-empty
    /// `conceptId` that names no glossary entry is an orphan — from a
    /// hand-edited or foreign file — and is never silently rewritten by a
    /// label lookup (F14): restoring the concept under the orphan id, when
    /// nothing else already holds its term, loses nothing that was on disk; a
    /// term that already names a different concept leaves the id alone, so
    /// 'concept-unbound' reports the clash rather than quietly rebinding to
    /// someone else's concept.
    private mutating func bindOrRestoreBox(diagramId: String, at index: Int, box: Box) {
        guard needsBinding(conceptId: box.conceptId, text: box.name) else { return }
        guard let conceptId = box.conceptId, !conceptId.isEmpty else {
            bindBox(diagramId: diagramId, at: index)
            return
        }
        glossary.append(Concept(id: conceptId, term: jsTrim(box.name), kind: ConceptKind.activity.rawValue, definition: ""))
        sortGlossary()
    }

    /// The arrow counterpart of `bindOrRestoreBox`.
    private mutating func bindOrRestoreArrow(diagramId: String, at index: Int, arrow: Arrow) {
        guard needsBinding(conceptId: arrow.conceptId, text: arrow.label) else { return }
        guard let conceptId = arrow.conceptId, !conceptId.isEmpty else {
            bindArrow(diagramId: diagramId, at: index)
            return
        }
        glossary.append(Concept(id: conceptId, term: jsTrim(arrow.label), kind: arrowConceptKind(arrow).rawValue, definition: ""))
        sortGlossary()
    }

    /// `sortGlossary` — stable, by `localeCompare` on the term.
    private mutating func sortGlossary() {
        glossary = glossary.stableSorted { jsLocaleCompare($0.term, $1.term) < 0 }
    }
}

/// `arrowKind(arrow)` — an arrow into a box's bottom is a mechanism (§3.2.2);
/// every other arrow is data.
private func arrowConceptKind(_ arrow: Arrow) -> ConceptKind {
    arrow.to.kind == .box && arrow.to.side == .bottom ? .mechanism : .data
}
