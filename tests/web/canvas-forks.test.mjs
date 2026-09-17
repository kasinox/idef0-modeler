// S02: the canvas's fork-and-join rules (src/ui/canvas.js) against the
// stand-in DOM in support/fake-dom.mjs — a press on the trunk selecting the
// representative and one on a branch the branch, the one drawn label hit
// where it is drawn, and an endpoint drag on a grouped end moving every
// member's pos together as one undo step, or leaving the group alone when it
// reconnects elsewhere. Nothing paints (`requestAnimationFrame` never calls
// back); the endpoint handle a press would land on is stood in for by a node
// carrying `data-end`, as the overlay's handle does.
// Run with:  node --test tests/web/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom, FakeNode } from './support/fake-dom.mjs';

installFakeDom();
document.getElementById('inline-editor').appendChild(new FakeNode('input'));
document.getElementById('canvas-wrap').getBoundingClientRect = () => ({ width: 1200, height: 900, left: 0, top: 0 });
globalThis.DOMPoint = class { constructor(x, y) { this.x = x; this.y = y; } matrixTransform() { return { x: this.x, y: this.y }; } };

const CV = await import(new URL('../../src/ui/canvas.js', import.meta.url));
const { store, loadModel, goToDiagram, markSaved, undoLabel, undo } = await import(new URL('../../src/state/store.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));
const { contextDiagram } = await import(new URL('../../src/model/model.js', import.meta.url));
const { labelPosition, rectOf, anchorOf } = await import(new URL('../../src/model/geometry.js', import.meta.url));
const { icomRects, drawnArrows, renderDiagram } = await import(new URL('../../src/ui/render.js', import.meta.url));
const M = await import(new URL('../../src/model/model.js', import.meta.url));

CV.initCanvas();
const root = document.getElementById('canvas');
root.childNodes[0].getScreenCTM = () => ({ inverse: () => ({}) });

const pointer = (type, pt, extra = {}) => root.dispatch(type, { clientX: pt.x, clientY: pt.y, button: 0, pointerId: 1, ...extra });
const labelCtx = (dg) => ({ icomEnds: icomRects(store.model, dg), boxes: dg.boxes.map(rectOf) });
/** A press on the selected arrow's `which` end handle: the overlay's circle carries `data-end`. */
function pressHandle(which, pt) {
  const handle = new FakeNode('circle');
  handle.setAttribute('data-end', which);
  handle.dataset.end = which;
  pointer('pointerdown', pt, { target: handle });
}

function loaded() {
  loadModel(buildSampleModel());
  markSaved('sample.idef0.json');
  const m = store.model;
  const a0 = m.diagrams[contextDiagram(m).boxes[0].childDiagramId];
  goToDiagram(a0.id);
  return a0;
}
const workOrders = (dg) => dg.arrows.filter((a) => a.label === 'Work Order');

test('a press on the trunk selects the representative, on a branch the branch; the one label is hit where it is drawn', () => {
  const a0 = loaded();
  const [rep, mid, last] = workOrders(a0);
  const trunk = drawnArrows(store.model, a0).find((e) => e.arrow === rep).forkTrunk;
  const onTrunk = { x: (trunk[0].x + trunk[1].x) / 2, y: trunk[0].y };
  assert.equal(CV.arrowAt(a0, onTrunk), rep, 'every route coincides there; the trunk is the representative');
  const midRoute = CV.routeOf(a0, mid);
  assert.equal(CV.arrowAt(a0, { x: midRoute[1].x, y: (midRoute[1].y + midRoute[2].y) / 2 }), mid, 'the drop into Assemble Product is its own');
  const lastRoute = CV.routeOf(a0, last);
  assert.equal(CV.arrowAt(a0, { x: (midRoute[1].x + lastRoute[1].x) / 2, y: lastRoute[1].y }), last, 'the run past the second turn is its own');
  pointer('pointerdown', onTrunk); pointer('pointerup', onTrunk);
  assert.deepEqual(store.ui.selection, { kind: 'arrow', id: rep.id });
  // One label, the representative's, placed against the trunk; the branches draw none.
  const pos = labelPosition(trunk, rep, labelCtx(a0));
  assert.equal(CV.labelAt(a0, { x: pos.x, y: pos.y }), rep);
  assert.deepEqual(CV.labelPathOf(a0, rep), trunk);
  assert.equal(CV.labelPathOf(a0, mid), CV.routeOf(a0, mid), 'a branch with no label drawn still edits its own on its route');
  for (const a of [mid, last]) {
    const own = labelPosition(CV.routeOf(a0, a), a, labelCtx(a0));
    assert.notEqual(CV.labelAt(a0, { x: own.x, y: own.y }), a, 'no label of its own to hit');
  }
  assert.deepEqual(CV.endGroupOf(a0, mid.id, 'from').map((g) => g.id), workOrders(a0).map((a) => a.id));
  assert.deepEqual(CV.endGroupOf(a0, mid.id, 'to').map((g) => g.id), [mid.id], 'not grouped at its to end');
});

test('dragging a grouped end along its face moves every member\'s pos together, as one "Move arrow end" step; undo restores all three', () => {
  const a0 = loaded();
  const [rep, mid, last] = workOrders(a0);
  const plan = a0.boxes.find((b) => b.name === 'Plan Production');
  store.ui.selection = { kind: 'arrow', id: mid.id };
  const start = CV.routeOf(a0, mid)[0];
  assert.ok(Math.abs(start.y - anchorOf(a0, rep.from).y) < 1e-9, 'the handle sits at the trunk, the representative\'s pos');
  pressHandle('from', start);
  const target = { x: plan.x + plan.w + 3, y: plan.y + plan.h * 0.2 };
  pointer('pointermove', target);
  pointer('pointerup', target);
  const live = store.model.diagrams[a0.id];
  const after = workOrders(live);
  assert.equal(after.length, 3);
  for (const a of after) {
    assert.equal(a.from.type, 'box');
    assert.equal(a.from.boxId, plan.id);
    assert.equal(a.from.side, 'right');
    assert.ok(Math.abs(a.from.pos - 0.2) < 0.02, `moved together to ${a.from.pos}`);
    assert.equal(a.bend, null);
  }
  assert.deepEqual(after.map((a) => a.to), [rep, mid, last].map((a) => a.to), 'the other ends are untouched');
  assert.equal(undoLabel(), 'Move arrow end');
  assert.equal(store._undo.length, 1, 'one step for the whole group');
  undo();
  assert.deepEqual(workOrders(store.model.diagrams[a0.id]).map((a) => a.from.pos), [0.5, 0.7, 0.88]);
});

test('reconnecting a grouped end to another side or box moves only that arrow: it leaves the group, and the others are put back as they were', () => {
  const a0 = loaded();
  const [rep, mid, last] = workOrders(a0);
  const plan = a0.boxes.find((b) => b.name === 'Plan Production');
  store.ui.selection = { kind: 'arrow', id: last.id };
  pressHandle('from', CV.routeOf(a0, last)[0]);
  // First along the face — all three follow — then onto the bottom side.
  pointer('pointermove', { x: plan.x + plan.w + 3, y: plan.y + plan.h * 0.3 });
  assert.ok(workOrders(store.model.diagrams[a0.id]).every((a) => Math.abs(a.from.pos - 0.3) < 0.02));
  const bottom = { x: plan.x + plan.w * 0.5, y: plan.y + plan.h + 3 };
  pointer('pointermove', bottom);
  pointer('pointerup', bottom);
  const after = workOrders(store.model.diagrams[a0.id]);
  assert.deepEqual(after.map((a) => a.from), [rep.from, mid.from, { ...after[2].from }], 'the two left behind are exactly as stored before');
  assert.equal(after[2].from.side, 'bottom');
  assert.equal(after[2].from.boxId, plan.id);
  assert.equal(undoLabel(), 'Move arrow end');
  assert.equal(store._undo.length, 1);
  // Alone on the bottom, the moved arrow is no longer a branch of the fork.
  const live = store.model.diagrams[a0.id];
  assert.equal(CV.endGroupOf(live, after[2].id, 'from').length, 1);
  assert.deepEqual(CV.endGroupOf(live, after[0].id, 'from').map((g) => g.id), [after[0].id, after[1].id]);
});

test('a branch whose trunks overlap keeps a two-point label path, so its dragged label is hit-tested (and rendered) without throwing', () => {
  const a0 = loaded();
  const ps = a0.arrows.find((a) => a.label === 'Production Staff');
  // A second Production Staff between the same faces, with its own label
  // and a lower pos: the representative of both groups; the sample's arrow
  // is a branch that is all trunk, and its label has been dragged.
  const { newArrow, boundaryEnd } = M;
  const dup = newArrow({ label: 'Shift Crew', from: boundaryEnd('bottom', 0.14), to: { ...ps.to, pos: 0.3 }, conceptId: ps.conceptId });
  a0.arrows.push(dup);
  ps.ldx = 7; ps.ldy = -5;
  const path = CV.labelPathOf(a0, ps);
  assert.ok(path.length >= 2);
  assert.deepEqual(path, CV.routeOf(a0, ps));
  const pos = labelPosition(path, ps, labelCtx(a0));
  // Two labels on one route: the representative's auto-placed one sits on
  // the same segment, so either may be hit there — what matters is that the
  // hit test reads the dragged label from a two-point path.
  assert.ok([ps, dup].includes(CV.labelAt(a0, { x: pos.x, y: pos.y })), 'the dragged label is hit-tested where it is drawn');
  assert.doesNotThrow(() => renderDiagram(store.model, a0));
});
