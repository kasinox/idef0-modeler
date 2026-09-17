// DOM-free checks of src/model/edits.js — the naming edits the canvas and the
// inspector share, mirroring Edits.swift / InspectorEdits.swift
// (EditingTests.swift covers the same rules on the Mac). Run with:
//   node --test tests/web/
//
// Each test builds its own model: the sample (A-0 with one bound box, A0 with
// four boxes on the staircase), bound the way loadModel binds it. There is no
// geometry edit to check any more (S01): boxes are laid out by `moveBox` and
// friends in model.js, covered by bundles.test.mjs.

import { test } from 'node:test';
import assert from 'node:assert/strict';

const edits = await import(new URL('../../src/model/edits.js', import.meta.url));
const { renameBox, labelArrow, setModelTitle } = edits;
const {
  boxEnd, contextDiagram, createModel, decomposeBox, diagramTree, newArrow,
} = await import(new URL('../../src/model/model.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));
const { bindAll, conceptById } = await import(new URL('../../src/model/concepts.js', import.meta.url));
const { validate } = await import(new URL('../../src/model/validate.js', import.meta.url));

/** The sample, bound: its A-0 box `top` is detailed by `a0`. */
function sample() {
  const m = bindAll(buildSampleModel());
  const ctx = contextDiagram(m);
  const top = ctx.boxes[0];
  return { m, ctx, top, a0: m.diagrams[top.childDiagramId] };
}

const unboundIssues = (m) => validate(m).filter((i) => i.code === 'concept-unbound');

/* ------------------------------------------------------------- renameBox */

test('renameBox trims the name, binds its concept, titles the unlocked child and renames the model', () => {
  const { m, ctx, top, a0 } = sample();
  assert.equal(a0.titleLocked, false);
  assert.equal(renameBox(m, ctx.id, top.id, '  Build Widget  '), true);
  assert.equal(top.name, 'Build Widget');
  const c = conceptById(m, top.conceptId);
  assert.equal(c?.term, 'Build Widget', 'bound to the trimmed term');
  assert.equal(c?.kind, 'activity');
  assert.equal(a0.title, 'Build Widget', 'the unlocked child title follows');
  assert.equal(m.title, 'Build Widget', 'renaming the A-0 box renames the model');
  assert.deepEqual(unboundIssues(m), []);
});

test('clearing a decomposed box name keeps the child title and the model title', () => {
  const { m, ctx, top, a0 } = sample();
  assert.equal(renameBox(m, ctx.id, top.id, '   '), true);
  assert.equal(top.name, '');
  assert.equal(top.conceptId, null, 'an empty name denotes nothing');
  assert.equal(a0.title, 'Manufacture Product', 'renumberNodes keeps the old title for an empty name');
  assert.equal(m.title, 'Manufacture Product');
});

test('a child title the modeller locked is not overwritten by a rename', () => {
  const { m, ctx, top, a0 } = sample();
  a0.title = 'Kept';
  a0.titleLocked = true;
  renameBox(m, ctx.id, top.id, 'Assemble Widget');
  assert.equal(a0.title, 'Kept');
  assert.equal(m.title, 'Assemble Widget');
});

test('renaming a box below A-0 retitles its child but leaves the model title alone', () => {
  const { m, a0 } = sample();
  const plan = a0.boxes[0];
  const child = decomposeBox(m, a0, plan, 3);
  assert.equal(child.title, 'Plan Production');
  renameBox(m, a0.id, plan.id, ' Schedule Work ');
  assert.equal(plan.name, 'Schedule Work');
  assert.equal(child.title, 'Schedule Work');
  assert.equal(child.node, 'A1');
  assert.equal(m.title, 'Manufacture Product');
});

test('renameBox on a box or diagram that is gone does nothing and says so', () => {
  const { m, ctx, a0 } = sample();
  const before = JSON.stringify(m);
  assert.equal(renameBox(m, ctx.id, 'no-such-box', 'X'), false);
  assert.equal(renameBox(m, 'no-such-diagram', a0.boxes[0].id, 'X'), false);
  assert.equal(JSON.stringify(m), before);
});

/* ------------------------------------------------------------ labelArrow */

test('labelArrow trims the label and binds a concept of the kind the box side gives it', () => {
  const { m, a0 } = sample();
  // Not the boundary arrows sample.js already gives A0 — every one of those
  // shares its concept with its ICOM counterpart on A-0, so relabelling it
  // keeps the id and drifts instead of rebinding (F11; see
  // concepts-relabel.test.mjs). A fresh, unbound, box-to-box arrow isolates
  // the plain create-by-text path this test means to cover.
  const [plan, fab] = a0.boxes;
  const mech = newArrow({ label: '', from: boxEnd(plan.id, 'right', 0.95), to: boxEnd(fab.id, 'bottom', 0.9) });
  a0.arrows.push(mech);
  assert.equal(labelArrow(m, a0.id, mech.id, '  Machinist '), true);
  assert.equal(mech.label, 'Machinist');
  assert.equal(conceptById(m, mech.conceptId)?.term, 'Machinist');
  assert.equal(conceptById(m, mech.conceptId)?.kind, 'mechanism');

  const data = newArrow({ label: '', from: boxEnd(plan.id, 'right', 0.97), to: boxEnd(fab.id, 'left', 0.9) });
  a0.arrows.push(data);
  labelArrow(m, a0.id, data.id, ' Parts List ');
  assert.equal(data.label, 'Parts List');
  assert.equal(conceptById(m, data.conceptId)?.kind, 'data');
  assert.deepEqual(unboundIssues(m), []);
});

test('clearing a label unbinds the arrow; a missing arrow is refused', () => {
  const { m, a0 } = sample();
  const a = a0.arrows[0];
  labelArrow(m, a0.id, a.id, '');
  assert.equal(a.label, '');
  assert.equal(a.conceptId, null);
  const before = JSON.stringify(m);
  assert.equal(labelArrow(m, a0.id, 'no-such-arrow', 'X'), false);
  assert.equal(JSON.stringify(m), before);
});

/* --------------------------------------------------------- setModelTitle */

test('setModelTitle titles the model and A-0, and names and binds an unnamed A-0 box', () => {
  const m = createModel('Untitled');
  const ctx = contextDiagram(m);
  const box = ctx.boxes[0];
  box.name = '';
  box.conceptId = null;
  setModelTitle(m, 'Run Plant');
  assert.equal(m.title, 'Run Plant');
  assert.equal(ctx.title, 'Run Plant');
  assert.equal(box.name, 'Run Plant');
  assert.equal(conceptById(m, box.conceptId)?.term, 'Run Plant', 'bound, so the saved file carries the concept id');
  assert.deepEqual(unboundIssues(m), []);
});

test('setModelTitle leaves a named A-0 box alone and stores the title as typed', () => {
  const { m, ctx, top } = sample();
  const conceptBefore = top.conceptId;
  setModelTitle(m, '  Plant Baseline ');
  assert.equal(m.title, '  Plant Baseline ', 'the model title is not trimmed, as on the Mac');
  assert.equal(ctx.title, '  Plant Baseline ');
  assert.equal(top.name, 'Manufacture Product');
  assert.equal(top.conceptId, conceptBefore);
});

test('an empty title does not name the A-0 box', () => {
  const m = createModel('Untitled');
  const box = contextDiagram(m).boxes[0];
  box.name = '';
  setModelTitle(m, '');
  assert.equal(m.title, '');
  assert.equal(box.name, '');
});

/* ------------------------------------------------------------ no geometry */

test('edits.js offers no way to type a box position or size (S01)', () => {
  assert.deepEqual(Object.keys(edits).sort(), ['labelArrow', 'renameBox', 'setModelTitle']);
});

/* --------------------------------------------------------- deepest level */

test('the deepest-level statistic is the depth of the decomposition tree, as the Mac shows it', () => {
  const depth = (m) => Math.max(0, ...diagramTree(m).map((n) => n.depth));
  assert.equal(depth(createModel('Only A-0')), 0);
  const { m, a0 } = sample();
  assert.equal(depth(m), 1, 'A-0 = 0, A0 = 1');
  const a1 = decomposeBox(m, a0, a0.boxes[0], 3);
  assert.equal(depth(m), 2, 'A1 is a level below A0');
  decomposeBox(m, a1, a1.boxes[0], 3);
  assert.equal(depth(m), 3);
});
