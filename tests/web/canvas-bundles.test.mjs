// S01: the canvas's bundle-aware hit tests and inline editor (src/ui/canvas.js)
// against the stand-in DOM in support/fake-dom.mjs — a hidden member drawing
// no route of its own, a press on the representative's drawn line selecting
// it, labels hit and edited as drawn, the editor renaming the bundle where
// the drawn label is its term, and the per-render frame the pointer events
// read. The canvas is initialised
// for real here: the fake gives it an editor input, a sized wrap and an
// identity screen transform, so pointer events at sheet coordinates land where
// they say. Nothing paints (`requestAnimationFrame` never calls back).
// Run with:  node --test tests/web/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom, FakeNode } from './support/fake-dom.mjs';

installFakeDom();
document.getElementById('inline-editor').appendChild(new FakeNode('input'));
document.getElementById('canvas-wrap').getBoundingClientRect = () => ({ width: 1200, height: 900, left: 0, top: 0 });
// `toModel` maps a pointer through the viewport's screen matrix; the fake's
// is the identity, so clientX/clientY are sheet units.
globalThis.DOMPoint = class { constructor(x, y) { this.x = x; this.y = y; } matrixTransform() { return { x: this.x, y: this.y }; } };

const CV = await import(new URL('../../src/ui/canvas.js', import.meta.url));
const { store, commit, loadModel, goToDiagram, markSaved, undoLabel, undo } = await import(new URL('../../src/state/store.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));
const { contextDiagram } = await import(new URL('../../src/model/model.js', import.meta.url));
const { combineConcepts, conceptById, findConcept, uncombineConcept } = await import(new URL('../../src/model/concepts.js', import.meta.url));
const { routeArrow, longestSegmentMid, distToPolyline, labelPosition, rectOf } = await import(new URL('../../src/model/geometry.js', import.meta.url));
const { icomRects } = await import(new URL('../../src/ui/render.js', import.meta.url));

CV.initCanvas();
const root = document.getElementById('canvas');
root.childNodes[0].getScreenCTM = () => ({ inverse: () => ({}) });
const input = document.getElementById('inline-editor').querySelector('input');

const id = (term) => findConcept(store.model, term).id;
const arrow = (dg, label) => dg.arrows.find((a) => a.label === label);
const mid = (dg, a) => { const p = longestSegmentMid(routeArrow(dg, a)); return { x: p.x, y: p.y }; };
/** The midpoint of the route `a` is actually drawn along (S02, `routeOf`). */
const drawnMid = (dg, a) => { const p = longestSegmentMid(CV.routeOf(dg, a)); return { x: p.x, y: p.y }; };
const labelCtx = (dg) => ({ icomEnds: icomRects(store.model, dg), boxes: dg.boxes.map(rectOf) });
const pointer = (type, pt, extra = {}) => root.dispatch(type, { clientX: pt.x, clientY: pt.y, button: 0, pointerId: 1, ...extra });
const pressAt = (pt) => { pointer('pointerdown', pt); pointer('pointerup', pt); };
const doubleClickAt = (pt) => root.dispatch('dblclick', { clientX: pt.x, clientY: pt.y, altKey: false });
const typeEnter = (text) => { input.value = text; input.dispatch('keydown', { key: 'Enter' }); };

/** The sample with Customer Order and Raw Materials combined into "Inputs":
 *  on A-0 the pair is one drawn line, on A0 two lone branches. */
function bundled() {
  loadModel(buildSampleModel());
  markSaved('sample.idef0.json');
  const m = store.model;
  const ctx = contextDiagram(m);
  const a0 = m.diagrams[ctx.boxes[0].childDiagramId];
  commit('Combine Concepts', (mm) => combineConcepts(mm, [id('Customer Order'), id('Raw Materials')], 'Inputs'));
  return { ctx: store.model.diagrams[ctx.id], a0: store.model.diagrams[a0.id] };
}

test('a hidden member has no route to press; a press on the representative\'s drawn line selects it; labels are hit and read as drawn; a lone branch keeps its own', () => {
  const { ctx, a0 } = bundled();
  goToDiagram(ctx.id);
  const co = arrow(ctx, 'Customer Order'), rm = arrow(ctx, 'Raw Materials');
  // The hidden member's own route is not drawn (S02: only drawn arrows are
  // routed), so a press on it, clear of the representative's line, finds nothing.
  const ghost = mid(ctx, rm);
  assert.ok(distToPolyline(CV.routeOf(ctx, co), ghost) > 9, 'the ghost is on the hidden route only');
  assert.equal(CV.arrowAt(ctx, ghost), null, 'no ink there, nothing to press');
  const probe = drawnMid(ctx, co);
  assert.equal(CV.arrowAt(ctx, probe), co, 'the one line drawn for the pair');
  assert.equal(CV.representativeOf(ctx, rm), co);
  assert.equal(CV.representativeOf(ctx, co), co);
  assert.equal(CV.drawnLabelOf(ctx, co), 'Inputs');
  assert.equal(CV.drawnLabelOf(ctx, rm), 'Raw Materials', 'not drawn at all, so it reads as its own');
  // The representative, alone among the drawn arrows on its faces, is routed
  // as the one line it is: no lane is spread for the member that draws nothing.
  assert.deepEqual(CV.routeOf(ctx, co), routeArrow({ ...ctx, arrows: ctx.arrows.filter((a) => a !== rm) }, co));
  // The label is hit where "Inputs" is drawn, placed and measured as that text.
  const pos = labelPosition(CV.labelPathOf(ctx, co), { ...co, label: 'Inputs' }, labelCtx(ctx));
  assert.equal(CV.labelAt(ctx, { x: pos.x, y: pos.y }), co);
  const rmPos = labelPosition(routeArrow(ctx, rm), rm, labelCtx(ctx));
  assert.notEqual(CV.labelAt(ctx, { x: rmPos.x, y: rmPos.y }), rm, 'a hidden member has no label to hit');
  // Through the pointer: the press selects the representative.
  pressAt(probe);
  assert.deepEqual(store.ui.selection, { kind: 'arrow', id: co.id });
  assert.equal(store._undo.length, 1, 'a press is not an edit');

  // A0: each branch alone on its faces draws, and reads, its own label —
  // forked off one boundary line (S02: the same left edge, the same bundle),
  // so a press on the trunk selects the representative and one on the
  // branch selects the branch.
  goToDiagram(a0.id);
  const coA0 = arrow(a0, 'Customer Order'), rmA0 = arrow(a0, 'Raw Materials');
  assert.equal(CV.drawnLabelOf(a0, coA0), 'Customer Order');
  assert.equal(CV.drawnLabelOf(a0, rmA0), 'Raw Materials');
  assert.equal(CV.representativeOf(a0, rmA0), rmA0);
  const rmRoute = CV.routeOf(a0, rmA0);
  assert.deepEqual(rmRoute[0], CV.routeOf(a0, coA0)[0], 'the branch leaves from the trunk');
  assert.equal(CV.arrowAt(a0, rmRoute[rmRoute.length - 1]), rmA0, 'its own end is its own');
  assert.equal(CV.arrowAt(a0, rmRoute[0]), coA0, 'the trunk is the representative');
});

test('the inline editor on a representative shows the bundle\'s term and renames the bundle ("Rename Concept"); a blank term is refused; a lone member edits its own label', () => {
  const { ctx, a0 } = bundled();
  goToDiagram(ctx.id);
  const co = arrow(ctx, 'Customer Order'), rm = arrow(ctx, 'Raw Materials');
  const members = [id('Customer Order'), id('Raw Materials')];
  doubleClickAt(drawnMid(ctx, co));
  assert.equal(input.value, 'Inputs', 'the drawn text, not the arrow\'s own label');
  assert.equal(document.activeElement, input);
  typeEnter('  Order Inputs ');
  assert.equal(undoLabel(), 'Rename Concept');
  assert.equal(findConcept(store.model, 'Inputs'), null);
  assert.deepEqual(findConcept(store.model, 'Order Inputs').members, members, 'the bundle, renamed');
  const live = store.model.diagrams[ctx.id];
  assert.equal(arrow(live, 'Customer Order').id, co.id, 'the members\' own labels are untouched');
  assert.equal(CV.drawnLabelOf(live, arrow(live, 'Customer Order')), 'Order Inputs', 'the frame follows the edit');
  assert.equal(store.ui.hint, '');

  // A blank term is refused, as it is everywhere a bundle is named.
  const depth = store._undo.length;
  doubleClickAt(drawnMid(ctx, co));
  typeEnter('   ');
  assert.equal(store._undo.length, depth);
  assert.equal(store.ui.hint, 'A bundle needs a term.');
  assert.equal(findConcept(store.model, 'Order Inputs').term, 'Order Inputs');
  assert.equal(document.getElementById('inline-editor').hidden, true, 'the editor closed');

  // Undo restores the term, and the frame reads it again.
  undo();
  assert.equal(CV.drawnLabelOf(store.model.diagrams[ctx.id], arrow(store.model.diagrams[ctx.id], 'Customer Order')), 'Inputs');

  // A branch alone on its faces edits the arrow's own label, as it always did.
  goToDiagram(a0.id);
  const coA0 = arrow(a0, 'Customer Order');
  doubleClickAt(mid(a0, coA0));
  assert.equal(input.value, 'Customer Order');
  typeEnter('Customer Orders');
  assert.equal(undoLabel(), 'Label arrow');
  assert.equal(store.model.diagrams[a0.id].arrows.find((a) => a.id === coA0.id).label, 'Customer Orders');
  assert.deepEqual(findConcept(store.model, 'Inputs').members, members, 'the bundle is not what changed');
});

test('the frame is derived once per model revision: un-combining refreshes it, and a hover ring found on the old model is dropped', () => {
  const { ctx } = bundled();
  goToDiagram(ctx.id);
  const co = arrow(ctx, 'Customer Order'), rm = arrow(ctx, 'Raw Materials');
  assert.equal(CV.representativeOf(ctx, rm), co);
  // Un-combine: nothing denotes the bundle, so it goes, and both draw alone.
  commit('Un-combine Concept', (mm) => uncombineConcept(mm, findConcept(mm, 'Inputs').id));
  const live = store.model.diagrams[ctx.id];
  assert.equal(live, ctx, 'the same diagram object, edited in place');
  assert.equal(CV.representativeOf(live, rm), rm, 'a fresh frame for the new revision');
  assert.equal(CV.drawnLabelOf(live, co), 'Customer Order');
  assert.equal(CV.arrowAt(live, mid(live, rm)), rm);
  // Undo the un-combine (the store swaps in its snapshot, so compare by id);
  // a hover ring found on this model is dropped by the next revision.
  undo();
  assert.equal(CV.representativeOf(store.model.diagrams[ctx.id], rm).id, co.id);
  store.ui.tool = 'arrow';
  const b = ctx.boxes[0];
  pointer('pointermove', { x: b.x - 4, y: b.y + b.h / 2 });
  assert.equal(CV.getHover()?.boxId, b.id, 'the arrow tool offers the box side under the pointer');
  commit('Edit arrow note', (mm) => { mm.diagrams[ctx.id].arrows[0].note = 'edited'; });
  const liveCtx = store.model.diagrams[ctx.id];
  assert.equal(CV.arrowAt(liveCtx, drawnMid(liveCtx, arrow(liveCtx, 'Customer Order'))).id, co.id, 'derived again on the new revision');
  assert.equal(CV.getHover(), null, 'the ring found on the old model is gone');
  store.ui.tool = 'select';
  assert.equal(conceptById(store.model, id('Customer Order')).term, 'Customer Order');
});
