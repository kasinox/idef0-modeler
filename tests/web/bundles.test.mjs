// S01 structured editing — DOM-free checks of the core behind bundles, ports
// and auto-layout (src/model/model.js, concepts.js, validate.js, geometry.js,
// src/io/json.js), the same cases BundleParityTests.swift pins on the Mac.
// Run with:  node --test tests/web/

import { test } from 'node:test';
import assert from 'node:assert/strict';

const M = await import(new URL('../../src/model/model.js', import.meta.url));
const C = await import(new URL('../../src/model/concepts.js', import.meta.url));
const V = await import(new URL('../../src/model/validate.js', import.meta.url));
const G = await import(new URL('../../src/model/geometry.js', import.meta.url));
const J = await import(new URL('../../src/io/json.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));
const { WORK, BOX_DEFAULT } = await import(new URL('../../src/model/types.js', import.meta.url));

/** The sample, bound and round-tripped through the file, as a load leaves it. */
const sample = () => C.bindAll(J.deserialize(J.serialize(buildSampleModel())));
const byNode = (m, node) => Object.values(m.diagrams).find((d) => d.node === node);
const id = (m, term) => C.findConcept(m, term).id;
const issues = (m, code) => V.validate(m).filter((i) => i.code === code);
const rectOf = (b) => ({ x: b.x, y: b.y, w: b.w, h: b.h });

/* ---------------------------------------------------------------- combine */

test('combineConcepts makes a fresh, sorted glossary entry whose kind follows its members, and rewrites nothing else', () => {
  const m = sample();
  const before = JSON.stringify(m.diagrams);
  const co = id(m, 'Customer Order'), rm = id(m, 'Raw Materials');
  const n = m.glossary.length;
  const b = C.combineConcepts(m, [co, rm], '  Inputs ');
  assert.equal(b.term, 'Inputs');
  assert.equal(b.kind, 'data');
  assert.equal(b.definition, '');
  assert.deepEqual(b.members, [co, rm]);
  assert.match(b.id, /^gl_/);
  assert.equal(m.glossary.length, n + 1);
  assert.deepEqual(m.glossary.map((g) => g.term), [...m.glossary.map((g) => g.term)].sort((p, q) => p.localeCompare(q, 'en-US')));
  assert.equal(JSON.stringify(m.diagrams), before, 'nothing bound to a member moved');
  assert.equal(C.bundleOf(m, co), b);
  assert.equal(C.bundleOf(m, b.id), null);
  assert.equal(C.effectiveConceptId(m, co), b.id);
  assert.equal(C.effectiveConceptId(m, b.id), b.id);
  assert.equal(C.effectiveConceptId(m, id(m, 'Work Order')), id(m, 'Work Order'));
  assert.equal(C.effectiveConceptId(m, null), null);
  assert.equal(C.effectiveConceptId(m, ''), '');
  assert.equal(C.isBundle(b), true);
  assert.equal(C.isBundle(C.conceptById(m, co)), false);

  const mixed = sample();
  const other = C.combineConcepts(mixed, [id(mixed, 'Customer Order'), id(mixed, 'Plant Equipment')], 'Mixed');
  assert.equal(other.kind, 'other');
  assert.deepEqual(issues(mixed, 'bundle-mixed-kind').map((i) => i.message),
    ['Bundle “Mixed” combines concepts of different kinds (data, mechanism). Its members should be of one kind.']);
});

test('combineConcepts refuses fewer than two distinct ids, an unknown id and a member already bundled, changing nothing', () => {
  const m = sample();
  const co = id(m, 'Customer Order'), rm = id(m, 'Raw Materials'), wo = id(m, 'Work Order');
  C.combineConcepts(m, [co, rm], 'Inputs');
  const before = JSON.stringify(m);
  assert.equal(C.combineConcepts(m, [wo], 'Solo'), null);
  assert.equal(C.combineConcepts(m, [wo, wo], 'Twice'), null);
  assert.equal(C.combineConcepts(m, [], 'None'), null);
  assert.equal(C.combineConcepts(m, [wo, 'gl_nope'], 'Unknown'), null);
  assert.equal(C.combineConcepts(m, [wo, ''], 'Blank'), null);
  assert.equal(C.combineConcepts(m, [co, wo], 'Refused'), null);
  assert.equal(JSON.stringify(m), before);
});

test('bundles nest: the effective concept is the outermost; un-combining an inner bundle splices its members into the outer, an outer one frees the inner', () => {
  const m = sample();
  const pristine = J.serialize(m);
  const co = id(m, 'Customer Order'), rm = id(m, 'Raw Materials'), ps = id(m, 'Production Schedule');
  const inner = C.combineConcepts(m, [co, rm], 'Inputs');
  const outer = C.combineConcepts(m, [ps, inner.id], 'Planning Inputs');
  assert.deepEqual(outer.members, [ps, inner.id]);
  assert.equal(C.bundleOf(m, co), inner);
  assert.equal(C.bundleOf(m, inner.id), outer);
  for (const x of [co, rm, ps, inner.id]) assert.equal(C.effectiveConceptId(m, x), outer.id);
  assert.deepEqual([...C.transitiveMembers(m, outer.id)].sort(), [ps, inner.id, co, rm].sort());
  assert.equal(C.combineConcepts(m, [inner.id, co], 'Again'), null, 'a bundle already in a bundle cannot be combined again');

  const innerGone = J.deserialize(J.serialize(m));
  assert.equal(C.uncombineConcept(innerGone, inner.id).id, inner.id);
  assert.equal(C.conceptById(innerGone, inner.id), null);
  assert.deepEqual(C.conceptById(innerGone, outer.id).members, [ps, co, rm]);
  assert.equal(C.effectiveConceptId(innerGone, co), outer.id);

  const outerGone = J.deserialize(J.serialize(m));
  C.uncombineConcept(outerGone, outer.id);
  assert.equal(C.conceptById(outerGone, outer.id), null);
  assert.deepEqual(C.conceptById(outerGone, inner.id).members, [co, rm]);
  assert.equal(C.effectiveConceptId(outerGone, co), inner.id);
  assert.equal(C.effectiveConceptId(outerGone, ps), ps);

  C.uncombineConcept(innerGone, outer.id);
  assert.equal(J.serialize(innerGone), pristine, 'un-combining both is lossless');
});

test('uncombineConcept refuses a plain concept; removeConcept un-combines a bundle and drops a member from its bundle\'s list', () => {
  const m = sample();
  const co = id(m, 'Customer Order'), rm = id(m, 'Raw Materials'), ps = id(m, 'Production Schedule');
  const before = JSON.stringify(m);
  assert.equal(C.uncombineConcept(m, co), null);
  assert.equal(C.uncombineConcept(m, 'gl_nope'), null);
  assert.equal(JSON.stringify(m), before);

  const inner = C.combineConcepts(m, [co, rm], 'Inputs');
  const outer = C.combineConcepts(m, [inner.id, ps], 'Planning Inputs');

  const memberGone = J.deserialize(J.serialize(m));
  assert.equal(C.removeConcept(memberGone, rm).id, rm);
  assert.equal(C.conceptById(memberGone, rm), null);
  assert.deepEqual(C.conceptById(memberGone, inner.id).members, [co]);
  assert.equal(byNode(memberGone, 'A0').arrows.find((a) => a.label === 'Raw Materials').conceptId, rm, 'the dangling id stays');
  assert.deepEqual(issues(memberGone, 'bundle-thin').map((i) => i.message),
    ['Bundle “Inputs” has 1 member(s). A bundle combines at least two concepts (FIPS 183 §3.2.2.3).']);
  assert.equal(issues(memberGone, 'concept-unbound').length, 2);

  const bundleGone = J.deserialize(J.serialize(m));
  assert.equal(C.removeConcept(bundleGone, inner.id).id, inner.id);
  assert.deepEqual(C.conceptById(bundleGone, outer.id).members, [co, rm, ps]);
  assert.equal(C.removeConcept(bundleGone, 'gl_nope'), null);
});

test('uncombineConcept keeps a bundle something denotes as a plain concept, in its place in any outer bundle; removeConcept still removes it', () => {
  const m = sample();
  const co = id(m, 'Customer Order'), rm = id(m, 'Raw Materials'), ps = id(m, 'Production Schedule');
  const inner = C.combineConcepts(m, [co, rm], 'Inputs');
  // An arrow drawn from the bundle's port is bound to the bundle itself.
  const a0 = byNode(m, 'A0');
  const coArrow = a0.arrows.find((a) => a.label === 'Customer Order');
  coArrow.conceptId = inner.id;
  coArrow.label = 'Inputs';

  const kept = J.deserialize(J.serialize(m));
  const glossaryBefore = kept.glossary.length;
  const out = C.uncombineConcept(kept, inner.id);
  assert.equal(out.id, inner.id);
  assert.equal(out.members, undefined, 'the entry comes back with no members');
  const plain = C.conceptById(kept, inner.id);
  assert.ok(plain, 'the entry stays');
  assert.equal(C.isBundle(plain), false);
  assert.deepEqual([plain.term, plain.kind, plain.definition], ['Inputs', 'data', '']);
  assert.equal(kept.glossary.length, glossaryBefore, 'nothing removed');
  assert.equal(C.bundleOf(kept, co), null);
  assert.equal(C.bundleOf(kept, rm), null);
  assert.equal(byNode(kept, 'A0').arrows.find((a) => a.id === coArrow.id).conceptId, inner.id, 'the arrow still denotes a concept');
  assert.deepEqual(issues(kept, 'concept-unbound'), [], 'nothing dangles');
  assert.equal(J.serialize(kept).split('"members"').length, 1, 'the file carries no members list');

  // Nested: the kept entry keeps its place in the outer list, its former
  // members follow it, in order.
  const nested = J.deserialize(J.serialize(m));
  const outer = C.combineConcepts(nested, [ps, inner.id], 'Planning Inputs');
  C.uncombineConcept(nested, inner.id);
  assert.deepEqual(C.conceptById(nested, outer.id).members, [ps, inner.id, co, rm]);
  assert.equal(C.effectiveConceptId(nested, inner.id), outer.id, 'still stands for the outer bundle on the parent');
  assert.equal(C.effectiveConceptId(nested, co), outer.id);
  assert.deepEqual(issues(nested, 'bundle-member-dup'), []);

  // Un-combining the outer bundle afterwards frees the plain survivor too.
  C.uncombineConcept(nested, outer.id);
  assert.equal(C.conceptById(nested, outer.id), null, 'nothing denotes the outer bundle');
  assert.equal(C.bundleOf(nested, inner.id), null);

  // removeConcept is deletion, used or not: the entry goes, and its arrows
  // keep the dangling id for concept-unbound, as removing any concept does.
  const removed = J.deserialize(J.serialize(m));
  const outer2 = C.combineConcepts(removed, [ps, inner.id], 'Planning Inputs');
  assert.equal(C.removeConcept(removed, inner.id).id, inner.id);
  assert.equal(C.conceptById(removed, inner.id), null);
  assert.deepEqual(C.conceptById(removed, outer2.id).members, [ps, co, rm]);
  assert.equal(byNode(removed, 'A0').arrows.find((a) => a.id === coArrow.id).conceptId, inner.id);
  assert.equal(issues(removed, 'concept-unbound').length, 1);
});

/* ------------------------------------------------------- malformed files */

test('a cycle in a hand-edited file ends every walk and is reported once per bundle on it; a concept listed twice is reported each time', () => {
  const m = M.createModel('Loop');
  m.purpose = 'p'; m.viewpoint = 'v';
  m.glossary = [
    { id: 'gA', term: 'A', kind: 'data', definition: '', members: ['gB', 'gX'] },
    { id: 'gB', term: 'B', kind: 'data', definition: '', members: ['gA'] },
    { id: 'gC', term: 'C', kind: 'data', definition: '', members: ['gX', 'gX', 'gY'] },
    { id: 'gX', term: 'X', kind: 'data', definition: '' },
    { id: 'gY', term: 'Y', kind: 'data', definition: '' },
  ];
  // The climb stops where it would visit a bundle again: X → A → B → (A).
  assert.equal(C.effectiveConceptId(m, 'gX'), 'gB');
  assert.equal(C.effectiveConceptId(m, 'gA'), 'gB');
  assert.equal(C.effectiveConceptId(m, 'gB'), 'gA');
  assert.equal(C.bundleOf(m, 'gX').id, 'gA');
  assert.equal(C.transitiveMembers(m, 'gA').has('gA'), true);
  assert.equal(C.transitiveMembers(m, 'gC').has('gC'), false);
  const rows = V.validate(m).filter((i) => i.code.startsWith('bundle-')).map((i) => `${i.code} | ${i.message}`);
  // Errors first, then warnings, as the validator always orders them.
  assert.deepEqual(rows, [
    'bundle-cycle | Bundle “A” contains itself through its members. Un-combine it to break the cycle.',
    'bundle-cycle | Bundle “B” contains itself through its members. Un-combine it to break the cycle.',
    'bundle-member-dup | “X” is a member of both “A” and “C”. A concept belongs to at most one bundle.',
    'bundle-member-dup | Bundle “C” lists “X” more than once.',
    'bundle-thin | Bundle “B” has 1 member(s). A bundle combines at least two concepts (FIPS 183 §3.2.2.3).',
  ]);
  const cycle = V.validate(m).find((i) => i.code === 'bundle-cycle');
  assert.equal(cycle.severity, 'error');
  assert.deepEqual([cycle.diagramId, cycle.kind, cycle.id], [m.rootDiagramId, null, null]);
  m.glossary.push({ id: 'gD', term: 'D', kind: 'data', definition: '', members: ['g_gone', 'gY'] });
  assert.ok(issues(m, 'bundle-thin').map((i) => i.message).includes('Bundle “D” has 1 member(s). A bundle combines at least two concepts (FIPS 183 §3.2.2.3).'));
  assert.equal(C.effectiveConceptId(m, 'g_gone'), 'gD');
});

/* ------------------------------------------------------------------ merge */

test('a merge rewrites every members list de-duplicated, is refused into the bundle\'s own member, absorbs a member merged into its bundle, and hands a bundle\'s members to a plain survivor', () => {
  const m = sample();
  const co = id(m, 'Customer Order'), rm = id(m, 'Raw Materials'), ps = id(m, 'Production Schedule');
  const bundle = C.combineConcepts(m, [co, rm], 'Inputs');

  const rewritten = J.deserialize(J.serialize(m));
  assert.equal(C.renameConcept(rewritten, rm, 'Customer Order').id, co);
  assert.deepEqual(C.conceptById(rewritten, bundle.id).members, [co]);
  assert.equal(C.conceptById(rewritten, rm), null);

  const refused = J.deserialize(J.serialize(m));
  const before = JSON.stringify(refused);
  assert.equal(C.renameConcept(refused, bundle.id, 'Customer Order'), null);
  assert.equal(C.mergeConcepts(refused, bundle.id, co), null);
  assert.equal(JSON.stringify(refused), before);
  const deep = J.deserialize(J.serialize(m));
  const outer = C.combineConcepts(deep, [bundle.id, ps], 'Planning Inputs');
  const deepBefore = JSON.stringify(deep);
  assert.equal(C.mergeConcepts(deep, outer.id, co), null, 'Customer Order sits two levels below');
  assert.equal(JSON.stringify(deep), deepBefore);

  const absorbed = J.deserialize(J.serialize(m));
  assert.equal(C.renameConcept(absorbed, co, 'Inputs').id, bundle.id);
  assert.deepEqual(C.conceptById(absorbed, bundle.id).members, [rm]);
  assert.equal(C.conceptById(absorbed, co), null);
  assert.deepEqual(byNode(absorbed, 'A0').arrows.filter((a) => a.conceptId === bundle.id).map((a) => a.label), ['Inputs']);
  const deepAbsorbed = J.deserialize(J.serialize(deep));
  assert.equal(C.mergeConcepts(deepAbsorbed, co, outer.id).id, outer.id);
  assert.deepEqual(C.conceptById(deepAbsorbed, bundle.id).members, [rm]);
  assert.deepEqual(C.conceptById(deepAbsorbed, outer.id).members, [bundle.id, ps]);
  assert.equal(C.transitiveMembers(deepAbsorbed, outer.id).has(outer.id), false);

  const inherited = J.deserialize(J.serialize(m));
  const components = id(inherited, 'Components');
  assert.equal(C.renameConcept(inherited, bundle.id, 'Components').id, components);
  assert.deepEqual(C.conceptById(inherited, components).members, [co, rm]);
  assert.equal(C.conceptById(inherited, bundle.id), null);
  assert.equal(C.bundleOf(inherited, co).id, components);
});

/* ------------------------------------------------------------------- ICOM */

test('two arrows of one bundle on one box side share one ICOM code, and the child\'s ends pair with it by effective concept', () => {
  const m = sample();
  const co = id(m, 'Customer Order'), rm = id(m, 'Raw Materials');
  const ctx = M.contextDiagram(m);
  const top = ctx.boxes[0];
  assert.deepEqual(M.parentBoxArrows(m, ctx, top).left.map((e) => e.code), ['I1', 'I2']);
  const bundle = C.combineConcepts(m, [co, rm], 'Inputs');
  const left = M.parentBoxArrows(m, ctx, top).left;
  assert.deepEqual(left.map((e) => e.code), ['I1']);
  assert.deepEqual(left[0].arrows.map((a) => a.label), ['Customer Order', 'Raw Materials']);
  assert.equal(left[0].arrow.conceptId, co);

  const a0 = byNode(m, 'A0');
  const codes = M.icomCodes(m, a0);
  const coArrow = a0.arrows.find((a) => a.label === 'Customer Order');
  const rmArrow = a0.arrows.find((a) => a.label === 'Raw Materials');
  assert.equal(codes[`${coArrow.id}:from`], 'I1');
  assert.equal(codes[`${rmArrow.id}:from`], 'I1');
  const p = M.icomPairing(m, a0);
  assert.deepEqual([p.orphans, p.missing, M.ports(m, a0)], [[], [], []]);
  const all = V.validate(m);
  assert.equal(all.some((i) => i.code === 'icom-relabel' || i.code === 'icom-concept-mismatch'), false, 'the unbundled specific is neither a relabel nor a mismatch');
  assert.equal(all.some((i) => i.code.startsWith('bundle-')), false);
  rmArrow.conceptId = bundle.id;
  assert.equal(M.icomCodes(m, a0)[`${rmArrow.id}:from`], 'I1', 'bound to the bundle itself pairs the same way');
});

/* ------------------------------------------------------------------ ports */

test('a freshly decomposed box has one port per parent ICOM entry; connecting one takes its code, disconnecting brings it back', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  const plan = a0.boxes.find((b) => b.name === 'Plan Production');
  assert.deepEqual(M.ports(m, M.contextDiagram(m)), []);
  assert.deepEqual(M.ports(m, a0), []);
  const child = M.decomposeBox(m, a0, plan, 3);
  assert.deepEqual(child.arrows, [], 'decomposing seeds no arrows');
  assert.deepEqual(child.boxes.map((b) => b.number), [1, 2, 3]);
  const co = a0.arrows.find((a) => a.label === 'Customer Order');
  const ps = a0.arrows.find((a) => a.label === 'Production Schedule');
  const wo = a0.arrows.find((a) => a.label === 'Work Order' && a.from.pos === 0.5);
  const ports = M.ports(m, child);
  assert.deepEqual(ports, [
    { side: 'left', pos: 0.5, code: 'I1', label: 'Customer Order', conceptId: co.conceptId, parentArrowId: co.id, role: 'input' },
    { side: 'top', pos: 0.5, code: 'C1', label: 'Production Schedule', conceptId: ps.conceptId, parentArrowId: ps.id, role: 'control' },
    { side: 'right', pos: 0.5, code: 'O1', label: 'Work Order', conceptId: wo.conceptId, parentArrowId: wo.id, role: 'output' },
  ]);
  assert.equal(issues(m, 'icom-missing').length, 3);
  assert.deepEqual(G.portShape(ports[0]), { edge: { x: 40, y: 443 }, inner: { x: 66, y: 443 } });
  assert.deepEqual(G.portShape(ports[1]), { edge: { x: 550, y: 132 }, inner: { x: 550, y: 158 } });
  assert.deepEqual(G.portShape(ports[2]), { edge: { x: 1060, y: 443 }, inner: { x: 1034, y: 443 } });
  const clampedX = WORK.x + 0.02 * WORK.w;
  assert.deepEqual(G.portShape({ side: 'bottom', pos: 0 }), { edge: { x: clampedX, y: 754 }, inner: { x: clampedX, y: 728 } }, 'clamped like any anchor');

  const [first, , last] = child.boxes;
  child.arrows.push(M.newArrow({ label: ports[0].label, conceptId: ports[0].conceptId, from: M.boundaryEnd(ports[0].side, ports[0].pos), to: M.boxEnd(first.id, 'left', 0.5) }));
  child.arrows.push(M.newArrow({ label: ports[2].label, conceptId: ports[2].conceptId, from: M.boxEnd(last.id, 'right', 0.5), to: M.boundaryEnd(ports[2].side, ports[2].pos) }));
  assert.deepEqual(M.ports(m, child).map((p) => p.code), ['C1']);
  assert.deepEqual(Object.values(M.icomCodes(m, child)).sort(), ['I1', 'O1']);
  assert.equal(issues(m, 'icom-missing').length, 1);
  child.arrows.shift();
  assert.deepEqual(M.ports(m, child).map((p) => p.code), ['I1', 'C1']);
});

/* ----------------------------------------------------------------- layout */

test('addBox, removeBox and moveBox keep numbers 1..n and the staircase; layoutBoxes never touches A-0', () => {
  const m = sample();
  const pristine = JSON.stringify(m.diagrams);
  const ctx = M.contextDiagram(m);
  const a0 = byNode(m, 'A0');
  assert.deepEqual(M.sortedBoxes(a0).map(rectOf), M.staircaseLayout(4));

  const added = M.addBox(m, a0);
  assert.equal(added.number, 5);
  assert.deepEqual(M.sortedBoxes(a0).map((b) => b.number), [1, 2, 3, 4, 5]);
  assert.deepEqual(M.sortedBoxes(a0).map(rectOf), M.staircaseLayout(5));
  assert.equal(a0.boxes[a0.boxes.length - 1], added, 'appended, not reordered');
  assert.deepEqual(issues(m, 'box-number-order'), []);

  assert.equal(M.moveBox(m, a0, added.id, -1), true);
  assert.deepEqual(M.sortedBoxes(a0).map((b) => b.name), ['Plan Production', 'Fabricate Components', 'Assemble Product', '', 'Ship Product']);
  assert.deepEqual(M.sortedBoxes(a0).map(rectOf), M.staircaseLayout(5));
  const plan = a0.boxes.find((b) => b.name === 'Plan Production');
  const ship = a0.boxes.find((b) => b.name === 'Ship Product');
  const before = JSON.stringify(m);
  assert.equal(M.moveBox(m, a0, plan.id, -1), false);
  assert.equal(M.moveBox(m, a0, ship.id, 1), false);
  assert.equal(M.moveBox(m, a0, plan.id, 2), false);
  assert.equal(M.moveBox(m, a0, 'bx_nope', 1), false);
  assert.equal(M.moveBox(m, ctx, ctx.boxes[0].id, 1), false);
  assert.equal(JSON.stringify(m), before);

  M.removeBox(m, a0, added.id);
  assert.deepEqual(M.sortedBoxes(a0).map((b) => b.number), [1, 2, 3, 4]);
  assert.deepEqual(M.sortedBoxes(a0).map(rectOf), M.staircaseLayout(4));
  assert.equal(JSON.stringify(m.diagrams), pristine, 'back where the sample started');

  const rootBefore = JSON.stringify(ctx);
  M.layoutBoxes(ctx);
  assert.equal(JSON.stringify(ctx), rootBefore);
  ctx.boxes = [];
  const repaired = M.addBox(m, ctx);
  assert.equal(repaired.number, 0);
  assert.deepEqual(rectOf(repaired), { x: WORK.x + 60, y: WORK.y + 40, w: BOX_DEFAULT.w, h: BOX_DEFAULT.h });

  ship.number = 6;
  ship.x = 20;
  M.layoutBoxes(a0);
  assert.deepEqual(M.sortedBoxes(a0).map((b) => b.number), [1, 2, 3, 6], 'layoutBoxes alone is geometry');
  assert.deepEqual(M.sortedBoxes(a0).map(rectOf), M.staircaseLayout(4));
  M.addBox(m, a0);
  assert.deepEqual(M.sortedBoxes(a0).map((b) => b.number), [1, 2, 3, 4, 5]);
});

/* ------------------------------------------------------------ file format */

test('members is written after definition and before extras, only when non-empty, and reads back as ids', () => {
  const m = sample();
  const co = id(m, 'Customer Order'), rm = id(m, 'Raw Materials');
  const bundle = C.combineConcepts(m, [co, rm], 'Inputs');
  const text = J.serialize(m);
  assert.ok(text.includes(`"definition": "",\n      "members": [\n        "${co}",\n        "${rm}"\n      ]\n    }`));
  assert.equal(text.split('"members"').length, 2, 'only the bundle carries it');
  assert.equal(J.serialize(J.deserialize(text)), text);

  bundle.source = 'ISO';
  const withExtras = J.serialize(m);
  assert.ok(withExtras.includes('      ],\n      "source": "ISO"\n    }'));
  assert.equal(J.serialize(J.deserialize(withExtras)), withExtras);

  const raw = '{"id":"m1","created":"","revised":"","rootDiagramId":"d1","diagrams":{"d1":{"node":"A-0"}},"glossary":['
    + '{"id":"b","term":"B","kind":"data","definition":"","members":[7,"x",null]},'
    + '{"id":"e","term":"E","kind":"data","definition":"","members":[]},'
    + '{"id":"s","term":"S","kind":"data","definition":"","members":"x"}]}';
  const read = J.deserialize(raw);
  assert.deepEqual(read.glossary.map((g) => g.members ?? []), [['7', 'x', 'null'], [], []]);
  assert.deepEqual(read.glossary.map((g) => Object.keys(g).filter((k) => !['id', 'term', 'kind', 'definition', 'members'].includes(k))), [[], [], []]);
  assert.equal(J.serialize(read).split('"members"').length, 2);
});
