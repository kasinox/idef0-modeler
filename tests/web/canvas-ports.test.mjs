// S01: the canvas's port logic (src/ui/canvas.js) against the stand-in DOM in
// support/fake-dom.mjs — the geometric hit test, which end of the arrow a
// port becomes, and `connectPort`, the commit a port drag ends in. The
// pointer handlers themselves need a real SVG (getScreenCTM) and are
// exercised in a browser; everything they decide is in these exports.
// Run with:  node --test tests/web/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom } from './support/fake-dom.mjs';

installFakeDom();

const { portAt, portArrowEnds, connectPort, anchorAt } = await import(new URL('../../src/ui/canvas.js', import.meta.url));
const { store, commit, undo, redo, loadModel, goToDiagram, markSaved, undoLabel } = await import(new URL('../../src/state/store.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));
const { boxEnd, boundaryEnd, contextDiagram, decomposeBox, icomCodes, ports } = await import(new URL('../../src/model/model.js', import.meta.url));
const { portShape } = await import(new URL('../../src/model/geometry.js', import.meta.url));
const { validate } = await import(new URL('../../src/model/validate.js', import.meta.url));

/** The sample with "Plan Production" decomposed once: its child has three
 *  ports (I1 Customer Order, C1 Production Schedule, O1 Work Order). */
function decomposed() {
  loadModel(buildSampleModel());
  markSaved('sample.idef0.json');
  const m = store.model;
  const a0 = m.diagrams[contextDiagram(m).boxes[0].childDiagramId];
  const plan = a0.boxes.find((b) => b.name === 'Plan Production');
  const child = commit('Decompose box', (mm) => decomposeBox(mm, mm.diagrams[a0.id], plan, 3));
  goToDiagram(child.id);
  return { m, a0, child: store.model.diagrams[child.id] };
}

const missing = () => validate(store.model).filter((i) => i.code === 'icom-missing').length;

test('portAt hits a port on its stub (10 units wide) and its circle, in port order, and nothing else', () => {
  const { m, child } = decomposed();
  const [input, control, output] = ports(m, child);
  assert.deepEqual([input.code, control.code, output.code], ['I1', 'C1', 'O1']);
  const s = portShape(input);
  assert.deepEqual(s, { edge: { x: 40, y: 443 }, inner: { x: 66, y: 443 } });
  // Along the stub, on the circle, and just inside the rectangle's width.
  assert.equal(portAt(m, child, s.edge)?.code, 'I1');
  assert.equal(portAt(m, child, { x: 53, y: 443 })?.code, 'I1');
  assert.equal(portAt(m, child, s.inner)?.code, 'I1');
  assert.equal(portAt(m, child, { x: 53, y: 448 })?.code, 'I1');
  assert.equal(portAt(m, child, { x: 53, y: 438 })?.code, 'I1');
  assert.equal(portAt(m, child, { x: 71, y: 445 })?.code, 'I1', 'within the circle\'s slack');
  // Past the rectangle, past the circle, and on the sheet edge away from any port.
  assert.equal(portAt(m, child, { x: 53, y: 449 }), null);
  assert.equal(portAt(m, child, { x: 53, y: 437 }), null);
  assert.equal(portAt(m, child, { x: 73, y: 443 }), null);
  assert.equal(portAt(m, child, { x: 40, y: 200 }), null);
  // The vertical stubs: the control at the top edge, and the output on the right.
  const c = portShape(control), o = portShape(output);
  assert.equal(portAt(m, child, { x: c.edge.x + 4, y: c.edge.y + 13 })?.code, 'C1');
  assert.equal(portAt(m, child, { x: c.edge.x + 6, y: c.edge.y + 13 }), null);
  assert.equal(portAt(m, child, o.inner)?.code, 'O1');
  // The root diagram and A0 have no ports at all.
  assert.equal(portAt(m, contextDiagram(m), { x: 40, y: 443 }), null);
  // A port's spot on the sheet edge is still a boundary anchor for the arrow
  // tool's own flow — the canvas checks the port first, so that never applies.
  assert.deepEqual(anchorAt(child, s.edge), boundaryEnd('left', 0.5));
});

test('an input, control or mechanism port is the arrow\'s source; an output port is its destination', () => {
  const at = boxEnd('bx', 'left', 0.5);
  assert.deepEqual(portArrowEnds({ side: 'left', pos: 0.3 }, at), { from: boundaryEnd('left', 0.3), to: at });
  assert.deepEqual(portArrowEnds({ side: 'top', pos: 0.3 }, at), { from: boundaryEnd('top', 0.3), to: at });
  assert.deepEqual(portArrowEnds({ side: 'bottom', pos: 0.3 }, at), { from: boundaryEnd('bottom', 0.3), to: at });
  const out = boxEnd('bx', 'right', 0.4);
  assert.deepEqual(portArrowEnds({ side: 'right', pos: 0.7 }, out), { from: out, to: boundaryEnd('right', 0.7) });
});

test('connectPort draws the arrow with the port\'s concept and label through one "Connect Port" commit, selects it, and the port is gone', () => {
  const { m, a0, child } = decomposed();
  const [input, , output] = ports(m, child);
  const [first, , last] = child.boxes;
  assert.equal(missing(), 3);
  const arrowsBefore = child.arrows.length;

  const created = connectPort(input, boxEnd(first.id, 'left', 0.5));
  const live = store.model.diagrams[child.id];
  assert.equal(live.arrows.length, arrowsBefore + 1);
  assert.equal(created, live.arrows.at(-1));
  assert.equal(created.label, 'Customer Order');
  assert.equal(created.conceptId, a0.arrows.find((a) => a.label === 'Customer Order').conceptId, 'bound to the port\'s concept, not by text');
  assert.deepEqual(created.from, boundaryEnd('left', 0.5));
  assert.deepEqual(created.to, boxEnd(first.id, 'left', 0.5));
  assert.deepEqual(store.ui.selection, { kind: 'arrow', id: created.id });
  assert.equal(store.ui.pending, null);
  assert.equal(store.ui.hint, 'Connected I1 “Customer Order” to box 1.');
  assert.equal(undoLabel(), 'Connect Port', 'the Mac\'s undo name');
  assert.equal(store.ui.dirty, true);
  assert.deepEqual(ports(store.model, live).map((p) => p.code), ['C1', 'O1']);
  assert.equal(icomCodes(store.model, live)[`${created.id}:from`], 'I1', 'the new arrow takes the parent\'s code');
  assert.equal(missing(), 2);

  // An output port: the box side is the source and the port the destination.
  const out = connectPort(output, boxEnd(last.id, 'right', 0.5));
  assert.deepEqual(out.from, boxEnd(last.id, 'right', 0.5));
  assert.deepEqual(out.to, boundaryEnd('right', 0.5));
  assert.equal(out.label, 'Work Order');
  assert.equal(icomCodes(store.model, store.model.diagrams[child.id])[`${out.id}:to`], 'O1');
  assert.deepEqual(ports(store.model, store.model.diagrams[child.id]).map((p) => p.code), ['C1']);

  // Undo brings the port back; redo connects it again.
  undo();
  assert.deepEqual(ports(store.model, store.model.diagrams[child.id]).map((p) => p.code), ['C1', 'O1']);
  redo();
  assert.deepEqual(ports(store.model, store.model.diagrams[child.id]).map((p) => p.code), ['C1']);
});

test('connectPort refuses a release off any box, a port that is gone, and a box that is gone, with a hint and no change', () => {
  const { m, child } = decomposed();
  const [input, control] = ports(m, child);
  const before = JSON.stringify(store.model);
  const depth = store._undo.length;

  assert.equal(connectPort(input, null), null);
  assert.equal(store.ui.hint, 'Drop the port on a box side to connect it.', 'the Mac\'s cancel hint, word for word');
  assert.equal(connectPort(input, boundaryEnd('left', 0.5)), null, 'the sheet edge is not a box side');
  assert.equal(JSON.stringify(store.model), before);
  assert.equal(store._undo.length, depth);

  assert.equal(connectPort(control, boxEnd('bx_gone', 'top', 0.5)), null);
  assert.equal(store.ui.hint, 'That box or arrow no longer exists.');
  assert.equal(JSON.stringify(store.model), before);

  // Connect the input, then try the stale port object again.
  assert.ok(connectPort(input, boxEnd(child.boxes[0].id, 'left', 0.5)));
  assert.equal(connectPort(input, boxEnd(child.boxes[1].id, 'left', 0.5)), null);
  assert.equal(store.ui.hint, 'That port no longer exists.');
  assert.equal(store.model.diagrams[child.id].arrows.length, 1);
});

test('any box side takes the drop, whatever the role, and no label editor opens afterwards — not even for an unlabelled port', () => {
  const { m, a0, child } = decomposed();
  // Any side (the checks, not the canvas, say whether the role fits it).
  const [input, control] = ports(m, child);
  const wrongWay = connectPort(input, boxEnd(child.boxes[1].id, 'top', 0.4));
  assert.deepEqual(wrongWay.to, boxEnd(child.boxes[1].id, 'top', 0.4));
  assert.equal(wrongWay.label, 'Customer Order');
  // The parent's control unlabelled: its port carries no label and no
  // concept, and connecting it still asks for nothing — the inline editor
  // (which this stand-in DOM could not open) is never touched.
  store.model.diagrams[a0.id].arrows.find((a) => a.id === control.parentArrowId).label = '';
  store.model.diagrams[a0.id].arrows.find((a) => a.id === control.parentArrowId).conceptId = null;
  const live = ports(store.model, store.model.diagrams[child.id]).find((p) => p.code === 'C1');
  assert.equal(live.label, '');
  const unlabelled = connectPort(live, boxEnd(child.boxes[0].id, 'top', 0.5));
  assert.equal(unlabelled.label, '');
  assert.equal(unlabelled.conceptId, null);
  assert.equal(document.activeElement, null, 'nothing took the keyboard');
  assert.equal(store.ui.hint, 'Connected C1 “(unlabelled)” to box 1.');
});

test('a bundled parent entry is one port carrying the bundle, and connecting it binds the arrow to the bundle', () => {
  const { m, a0, child } = decomposed();
  // Customer Order (I1 on Plan Production's left) bundled with Raw Materials.
  const co = a0.arrows.find((a) => a.label === 'Customer Order').conceptId;
  const rm = a0.arrows.find((a) => a.label === 'Raw Materials').conceptId;
  commit('Combine concepts', (mm) => { mm.glossary.push({ id: 'gl_b', term: 'Inputs', kind: 'data', definition: '', members: [co, rm] }); });
  const port = ports(store.model, store.model.diagrams[child.id])[0];
  assert.deepEqual([port.code, port.label, port.conceptId], ['I1', 'Inputs', 'gl_b']);
  const created = connectPort(port, boxEnd(child.boxes[0].id, 'left', 0.5));
  assert.equal(created.label, 'Inputs');
  assert.equal(created.conceptId, 'gl_b');
  assert.equal(missing(), 2);
});
