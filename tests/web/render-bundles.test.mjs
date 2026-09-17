// S01 rendering — the DOM-free half of src/ui/render.js: `drawnArrows`, the
// one rule both canvases will hit-test by, pinned on the same cases
// RenderTests.swift and RenderParityTests.swift pin on the Mac (the drawing
// itself needs a DOM and is compared through golden-render.json instead).
// Run with:  node --test tests/web/

import { test } from 'node:test';
import assert from 'node:assert/strict';

const RN = await import(new URL('../../src/ui/render.js', import.meta.url));
const M = await import(new URL('../../src/model/model.js', import.meta.url));
const C = await import(new URL('../../src/model/concepts.js', import.meta.url));
const J = await import(new URL('../../src/io/json.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));

/** The sample, bound and round-tripped through the file, as a load leaves it. */
const sample = () => C.bindAll(J.deserialize(J.serialize(buildSampleModel())));
const byNode = (m, node) => Object.values(m.diagrams).find((d) => d.node === node);
const id = (m, term) => C.findConcept(m, term).id;
const arrow = (dg, label) => dg.arrows.find((a) => a.label === label);
const summary = (m, dg) => RN.drawnArrows(m, dg).map((e) => [e.arrow.id, e.label, e.hidden]);

test('drawnArrows draws every arrow of an unbundled diagram as itself, in array order, hiding nothing', () => {
  const m = sample();
  for (const dg of Object.values(m.diagrams)) {
    assert.deepEqual(summary(m, dg), dg.arrows.map((a) => [a.id, a.label, []]));
  }
});

test('a bundle draws once per face pair: the first member in array order, labelled with the bundle\'s term, hides the rest; a member alone keeps its own label', () => {
  const m = sample();
  const ctx = byNode(m, 'A-0'), a0 = byNode(m, 'A0');
  const co = arrow(ctx, 'Customer Order'), rm = arrow(ctx, 'Raw Materials');
  C.combineConcepts(m, [id(m, 'Customer Order'), id(m, 'Raw Materials')], 'Inputs');

  // A-0: both inputs run boundary-left -> the top box's left, at different
  // positions — the same faces, so Raw Materials draws nothing and the one
  // line drawn for the pair reads the bundle's general term.
  const drawn = RN.drawnArrows(m, ctx);
  assert.equal(drawn.length, ctx.arrows.length - 1);
  assert.deepEqual(summary(m, ctx)[0], [co.id, 'Inputs', [rm.id]]);
  assert.equal(drawn[0].arrow, co);
  assert.ok(!drawn.some((e) => e.arrow === rm));
  assert.deepEqual(summary(m, ctx).slice(1), ctx.arrows.slice(2).map((a) => [a.id, a.label, []]));

  // A0: the two branches reach different boxes, so both draw — each alone
  // on its faces, each keeping its own specific label (FIPS 183 §3.2.2.3:
  // the general label on the bundle, the specific ones on its branches).
  assert.deepEqual(summary(m, a0), a0.arrows.map((a) => [a.id, a.label, []]));
  assert.ok(!RN.drawnArrows(m, a0).some((e) => e.label === 'Inputs'));
});

test('the face is the endpoint kinds, boxes and sides — not the positions — and the outermost bundle', () => {
  const m = sample();
  const ctx = byNode(m, 'A-0');
  const co = arrow(ctx, 'Customer Order'), rm = arrow(ctx, 'Raw Materials');
  C.combineConcepts(m, [id(m, 'Customer Order'), id(m, 'Raw Materials')], 'Inputs');
  // Nesting: the outer bundle's term is what the representative reads.
  C.combineConcepts(m, [id(m, 'Inputs'), id(m, 'Production Schedule')], 'Planning Inputs');
  assert.deepEqual(summary(m, ctx)[0], [co.id, 'Planning Inputs', [rm.id]]);
  // A member entering another side is another face: both draw, each alone,
  // each with its own label.
  rm.to = { ...rm.to, side: 'top' };
  assert.deepEqual(summary(m, ctx).slice(0, 2), [[co.id, 'Customer Order', []], [rm.id, 'Raw Materials', []]]);
  rm.to = { ...rm.to, side: 'left' };
  // A member arriving from a box instead of the boundary is another face too.
  rm.from = { type: 'box', boxId: ctx.boxes[0].id, side: 'right', pos: 0.1 };
  assert.deepEqual(summary(m, ctx).slice(0, 2), [[co.id, 'Customer Order', []], [rm.id, 'Raw Materials', []]]);
  // Three on one face: the first is the representative of both others.
  rm.from = { type: 'boundary', side: 'left', pos: 0.7 };
  const ps = arrow(ctx, 'Production Schedule');
  ps.from = { type: 'boundary', side: 'left', pos: 0.9 };
  ps.to = { ...ps.to, side: 'left' };
  assert.deepEqual(summary(m, ctx).find((e) => e[0] === co.id), [co.id, 'Planning Inputs', [rm.id, ps.id]]);
  assert.equal(summary(m, ctx).length, ctx.arrows.length - 2);
});

test('an arrow bound to the bundle itself, or to nothing, is drawn as itself', () => {
  const m = sample();
  const ctx = byNode(m, 'A-0');
  const co = arrow(ctx, 'Customer Order'), rm = arrow(ctx, 'Raw Materials');
  const b = C.combineConcepts(m, [id(m, 'Customer Order'), id(m, 'Raw Materials')], 'Inputs');
  // The general arrow drawn on its own: its effective concept is its own,
  // and the member left alone on the face keeps its specific label.
  co.conceptId = b.id;
  assert.deepEqual(summary(m, ctx).slice(0, 2), [[co.id, 'Customer Order', []], [rm.id, 'Raw Materials', []]]);
  // Unbound arrows never group, whatever their labels.
  co.conceptId = null;
  rm.conceptId = '';
  assert.deepEqual(summary(m, ctx).slice(0, 2), [[co.id, 'Customer Order', []], [rm.id, 'Raw Materials', []]]);
});

test('ports carry the drawing data render.js reads: one per unconnected parent entry, a bundle as one port', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  M.decomposeBox(m, a0, a0.boxes.find((b) => b.name === 'Plan Production'), 3);
  const child = byNode(m, 'A1');
  assert.deepEqual(M.ports(m, child).map((p) => [p.code, p.label, p.side, p.parentArrowId]), [
    ['I1', 'Customer Order', 'left', arrow(a0, 'Customer Order').id],
    ['C1', 'Production Schedule', 'top', arrow(a0, 'Production Schedule').id],
    ['O1', 'Work Order', 'right', a0.arrows.find((a) => a.label === 'Work Order').id],
  ]);
  assert.deepEqual(M.ports(m, byNode(m, 'A-0')), [], 'the context diagram has no parent');
  C.combineConcepts(m, [id(m, 'Customer Order'), id(m, 'Raw Materials')], 'Inputs');
  assert.equal(M.ports(m, child)[0].label, 'Inputs');
});
