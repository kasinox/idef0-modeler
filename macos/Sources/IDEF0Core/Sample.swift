// A small, rule-clean demonstration model — a port of src/model/sample.js.
// A worked example of the conventions the checker enforces, and something to
// poke at on first run.

/// `buildSampleModel()`. Every call makes fresh ids and dates the model today,
/// as the web app does; Fixtures/sample.idef0.json is one such build, bound and
/// re-dated.
public func buildSampleModel() -> IDEF0Model {
    var m = IDEF0Model.create(title: "Manufacture Product")
    m.author = "A. Modeller"
    m.project = "Plant Operations Baseline"
    m.status = ModelStatus.draft.rawValue
    m.revised = todayISO()
    m.purpose = "To describe how the plant converts customer orders and raw materials into shipped product, as a baseline for measuring cycle time."
    m.viewpoint = "The production manager responsible for the plant floor."

    let contextId = m.rootDiagramId
    guard var ctx = m.diagrams[contextId], !ctx.boxes.isEmpty else { return m }
    ctx.boxes[0].name = "Manufacture Product"
    ctx.title = "Manufacture Product"
    let top = ctx.boxes[0].id

    func ctxArrow(_ label: String, _ from: Endpoint, _ to: Endpoint) {
        ctx.arrows.append(newArrow(label: label, from: from, to: to))
    }
    ctxArrow("Customer Order", .boundary(.left, 0.33), .box(top, .left, 0.33))
    ctxArrow("Raw Materials", .boundary(.left, 0.66), .box(top, .left, 0.66))
    ctxArrow("Production Schedule", .boundary(.top, 0.26), .box(top, .top, 0.25))
    ctxArrow("Quality Standards", .boundary(.top, 0.72), .box(top, .top, 0.75))
    ctxArrow("Finished Product", .box(top, .right, 0.33), .boundary(.right, 0.33))
    ctxArrow("Shipping Notice", .box(top, .right, 0.66), .boundary(.right, 0.66))
    ctxArrow("Plant Equipment", .boundary(.bottom, 0.26), .box(top, .bottom, 0.25))
    ctxArrow("Production Staff", .boundary(.bottom, 0.72), .box(top, .bottom, 0.75))

    // A0: the decomposition of the context box.
    var a0 = newDiagram(node: "A0", title: "Manufacture Product", parentBoxId: top)
    let names = ["Plan Production", "Fabricate Components", "Assemble Product", "Ship Product"]
    let layout = staircaseLayout(4)
    a0.boxes = names.enumerated().map { i, name in
        newBox(name: name, number: i + 1, x: layout[i].x, y: layout[i].y, w: layout[i].w, h: layout[i].h)
    }
    let (plan, fab, asm, ship) = (a0.boxes[0].id, a0.boxes[1].id, a0.boxes[2].id, a0.boxes[3].id)

    func arr(_ label: String, _ from: Endpoint, _ to: Endpoint) {
        a0.arrows.append(newArrow(label: label, from: from, to: to))
    }

    // Boundary inputs, controls and mechanisms — these mirror the parent box.
    arr("Customer Order", .boundary(.left, 0.18), .box(plan, .left, 0.5))
    arr("Raw Materials", .boundary(.left, 0.45), .box(fab, .left, 0.5))
    arr("Production Schedule", .boundary(.top, 0.14), .box(plan, .top, 0.5))
    arr("Quality Standards", .boundary(.top, 0.55), .box(fab, .top, 0.85))
    arr("Plant Equipment", .boundary(.bottom, 0.36), .box(fab, .bottom, 0.5))
    arr("Production Staff", .boundary(.bottom, 0.62), .box(asm, .bottom, 0.5))

    // Internal flow.
    arr("Work Order", .box(plan, .right, 0.5), .box(fab, .top, 0.25))
    arr("Work Order", .box(plan, .right, 0.7), .box(asm, .top, 0.3))
    arr("Work Order", .box(plan, .right, 0.88), .box(ship, .top, 0.3))
    arr("Components", .box(fab, .right, 0.5), .box(asm, .left, 0.5))
    arr("Assembled Product", .box(asm, .right, 0.5), .box(ship, .left, 0.5))

    // Boundary outputs.
    arr("Finished Product", .box(ship, .right, 0.35), .boundary(.right, 0.80))
    arr("Shipping Notice", .box(ship, .right, 0.7), .boundary(.right, 0.88))

    ctx.boxes[0].childDiagramId = a0.id
    m.diagrams[contextId] = ctx
    m.diagrams[a0.id] = a0

    m.glossary = [
        Concept(id: "gl1", term: "Customer Order", kind: "data", definition: "A confirmed request for product, carrying quantity, specification and required date."),
        Concept(id: "gl2", term: "Work Order", kind: "data", definition: "The released instruction authorising a specific quantity to be made, derived from the production schedule."),
        Concept(id: "gl3", term: "Quality Standards", kind: "data", definition: "The dimensional and finish tolerances that fabricated and assembled product must meet."),
        Concept(id: "gl4", term: "Plant Equipment", kind: "mechanism", definition: "Machine tools, fixtures and handling equipment on the plant floor."),
    ]

    m.renumberNodes()
    return m
}
