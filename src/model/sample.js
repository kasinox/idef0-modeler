// A small, rule-clean demonstration model. Useful as a worked example of the
// conventions the checker enforces, and as something to poke at on first run.

import { createModel, newArrow, newDiagram, newBox, boxEnd, boundaryEnd, renumberNodes, staircaseLayout } from './model.js';
import { todayISO } from '../util.js';

export function buildSampleModel() {
  const m = createModel('Manufacture Product');
  m.author = 'A. Modeller';
  m.project = 'Plant Operations Baseline';
  m.status = 'DRAFT';
  m.revised = todayISO();
  m.purpose = 'To describe how the plant converts customer orders and raw materials into shipped product, as a baseline for measuring cycle time.';
  m.viewpoint = 'The production manager responsible for the plant floor.';

  const ctx = m.diagrams[m.rootDiagramId];
  const top = ctx.boxes[0];
  top.name = 'Manufacture Product';
  ctx.title = 'Manufacture Product';

  const ctxArrow = (label, from, to) => ctx.arrows.push(newArrow({ label, from, to }));
  ctxArrow('Customer Order', boundaryEnd('left', 0.33), boxEnd(top.id, 'left', 0.33));
  ctxArrow('Raw Materials', boundaryEnd('left', 0.66), boxEnd(top.id, 'left', 0.66));
  ctxArrow('Production Schedule', boundaryEnd('top', 0.26), boxEnd(top.id, 'top', 0.25));
  ctxArrow('Quality Standards', boundaryEnd('top', 0.72), boxEnd(top.id, 'top', 0.75));
  ctxArrow('Finished Product', boxEnd(top.id, 'right', 0.33), boundaryEnd('right', 0.33));
  ctxArrow('Shipping Notice', boxEnd(top.id, 'right', 0.66), boundaryEnd('right', 0.66));
  ctxArrow('Plant Equipment', boundaryEnd('bottom', 0.26), boxEnd(top.id, 'bottom', 0.25));
  ctxArrow('Production Staff', boundaryEnd('bottom', 0.72), boxEnd(top.id, 'bottom', 0.75));

  /* ---- A0: the decomposition of the context box ---- */
  const a0 = newDiagram({ node: 'A0', title: 'Manufacture Product', parentBoxId: top.id });
  const names = ['Plan Production', 'Fabricate Components', 'Assemble Product', 'Ship Product'];
  const layout = staircaseLayout(4);
  const bx = names.map((name, i) => newBox({ name, number: i + 1, ...layout[i] }));
  a0.boxes = bx;
  const [plan, fab, asm, ship] = bx;

  const arr = (label, from, to, extra = {}) => {
    const a = newArrow({ label, from, to });
    Object.assign(a, extra);
    a0.arrows.push(a);
  };

  // Boundary inputs, controls and mechanisms — these mirror the parent box.
  arr('Customer Order', boundaryEnd('left', 0.18), boxEnd(plan.id, 'left', 0.5));
  arr('Raw Materials', boundaryEnd('left', 0.45), boxEnd(fab.id, 'left', 0.5));
  arr('Production Schedule', boundaryEnd('top', 0.14), boxEnd(plan.id, 'top', 0.5));
  arr('Quality Standards', boundaryEnd('top', 0.55), boxEnd(fab.id, 'top', 0.85));
  arr('Plant Equipment', boundaryEnd('bottom', 0.36), boxEnd(fab.id, 'bottom', 0.5));
  arr('Production Staff', boundaryEnd('bottom', 0.62), boxEnd(asm.id, 'bottom', 0.5));

  // Internal flow.
  arr('Work Order', boxEnd(plan.id, 'right', 0.5), boxEnd(fab.id, 'top', 0.25));
  arr('Work Order', boxEnd(plan.id, 'right', 0.7), boxEnd(asm.id, 'top', 0.3));
  arr('Work Order', boxEnd(plan.id, 'right', 0.88), boxEnd(ship.id, 'top', 0.3));
  arr('Components', boxEnd(fab.id, 'right', 0.5), boxEnd(asm.id, 'left', 0.5));
  arr('Assembled Product', boxEnd(asm.id, 'right', 0.5), boxEnd(ship.id, 'left', 0.5));

  // Boundary outputs.
  arr('Finished Product', boxEnd(ship.id, 'right', 0.35), boundaryEnd('right', 0.80));
  arr('Shipping Notice', boxEnd(ship.id, 'right', 0.7), boundaryEnd('right', 0.88));

  m.diagrams[a0.id] = a0;
  top.childDiagramId = a0.id;

  m.glossary = [
    { id: 'gl1', term: 'Customer Order', kind: 'data', definition: 'A confirmed request for product, carrying quantity, specification and required date.' },
    { id: 'gl2', term: 'Work Order', kind: 'data', definition: 'The released instruction authorising a specific quantity to be made, derived from the production schedule.' },
    { id: 'gl3', term: 'Quality Standards', kind: 'data', definition: 'The dimensional and finish tolerances that fabricated and assembled product must meet.' },
    { id: 'gl4', term: 'Plant Equipment', kind: 'mechanism', definition: 'Machine tools, fixtures and handling equipment on the plant floor.' },
  ];

  renumberNodes(m);
  return m;
}
