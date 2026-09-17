// S02 forks and joins — the DOM-free half of src/ui/render.js: `drawnArrows`
// grouping arrows that leave one face (or enter one) for the same effective
// concept into one trunk with branches, the representative rule, the trunk,
// the one label, and the codes a boundary fork writes once. The drawing
// itself is compared through golden-render.json ('render-fork-join');
// Drawing.swift's `SheetDrawing.drawnArrows` is the same function.
// Run with:  node --test tests/web/

import { test } from 'node:test';
import assert from 'node:assert/strict';

const RN = await import(new URL('../../src/ui/render.js', import.meta.url));
const M = await import(new URL('../../src/model/model.js', import.meta.url));
const C = await import(new URL('../../src/model/concepts.js', import.meta.url));
const G = await import(new URL('../../src/model/geometry.js', import.meta.url));
const J = await import(new URL('../../src/io/json.js', import.meta.url));
const U = await import(new URL('../../src/util.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));

const sample = () => C.bindAll(J.deserialize(J.serialize(buildSampleModel())));
const byNode = (m, node) => Object.values(m.diagrams).find((d) => d.node === node);
const box = (dg, name) => dg.boxes.find((b) => b.name === name);
const entryOf = (m, dg, arrow) => RN.drawnArrows(m, dg).find((e) => e.arrow === arrow);
/** The entries for `arrows`, from one `drawnArrows` call, so a group's shared trunk is one object. */
const entriesOf = (m, dg, arrows) => { const drawn = RN.drawnArrows(m, dg); return arrows.map((a) => drawn.find((e) => e.arrow === a)); };
const same = (p, q) => Math.abs(p.x - q.x) < 1e-9 && Math.abs(p.y - q.y) < 1e-9;

test('the sample\'s three Work Orders fork off Plan Production: one trunk, every branch routed from the representative\'s pos, one label', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  const wos = a0.arrows.filter((a) => a.label === 'Work Order');
  assert.equal(wos.length, 3);
  const entries = entriesOf(m, a0, wos);
  const rep = wos[0];                                     // pos 0.5, the lowest on the right side
  assert.deepEqual(entries.map((e) => e.fork), [rep.id, rep.id, rep.id]);
  assert.deepEqual(entries.map((e) => e.join), [null, null, null]);
  for (const e of entries) {
    assert.deepEqual(e.drawn.from, rep.from, 'routed as if its from end sat at the representative\'s pos');
    assert.deepEqual(e.drawn.to, e.arrow.to);
    assert.ok(same(e.pts[0], entries[0].pts[0]));
    assert.equal(e.forkTrunk, entries[0].forkTrunk, 'one trunk object for the group');
    assert.equal(e.joinTrunk, null);
  }
  // The stored ends are untouched: presentation only.
  assert.deepEqual(wos.map((a) => a.from.pos), [0.5, 0.7, 0.88]);
  // The trunk is the leading run every member shares — the horizontal run
  // from the box to the first branch's turn — and the representative's
  // label is placed against it; the branches, reading the same, draw none.
  const trunk = entries[0].forkTrunk;
  assert.ok(trunk.length >= 2);
  assert.ok(same(trunk[0], entries[0].pts[0]));
  assert.equal(trunk[1].y, trunk[0].y, 'the trunk runs straight out of the right side');
  assert.equal(trunk[1].x, Math.min(...entries.map((e) => e.pts[1].x)), 'to the first turn');
  assert.equal(entries[0].labelPath, trunk);
  assert.equal(entries[1].labelPath, null);
  assert.equal(entries[2].labelPath, null);
});

test('a join: two same-concept outputs entering one box top share a trailing trunk, the representative (lowest to.pos) draws the label', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  const j1 = M.newArrow({ label: 'Inspection Report', from: M.boxEnd(box(a0, 'Fabricate Components').id, 'right', 0.8), to: M.boxEnd(box(a0, 'Ship Product').id, 'top', 0.75) });
  const j2 = M.newArrow({ label: 'Inspection Report', from: M.boxEnd(box(a0, 'Assemble Product').id, 'right', 0.8), to: M.boxEnd(box(a0, 'Ship Product').id, 'top', 0.6) });
  a0.arrows.push(j1, j2);
  C.bindAll(m);
  assert.equal(j1.conceptId, j2.conceptId);
  const [e1, e2] = entriesOf(m, a0, [j1, j2]);
  assert.equal(e1.join, j2.id, 'the lowest position on the top side, though later in array order');
  assert.equal(e2.join, j2.id);
  assert.equal(e1.fork, null);
  assert.deepEqual(e1.drawn.to, j2.to);
  assert.ok(same(e1.pts.at(-1), e2.pts.at(-1)), 'one point of entry');
  const trunk = e2.joinTrunk;
  assert.equal(e1.joinTrunk, trunk);
  assert.ok(same(trunk.at(-1), e2.pts.at(-1)), 'the trunk ends at the box');
  assert.equal(e2.labelPath, trunk, 'the representative labels the trunk');
  assert.equal(e1.labelPath, null, 'the branch reads the same, so it draws no label');
  assert.deepEqual(RN.drawnCodes(e1, M.icomCodes(m, a0)), { from: null, to: null });
});

test('a boundary fork: an I1 concept into two boxes forks off one boundary line, and the code is written once, at the trunk', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  const co = a0.arrows.find((a) => a.label === 'Customer Order');
  const copy = M.newArrow({ label: 'Customer Order', from: M.boundaryEnd('left', 0.3), to: M.boxEnd(box(a0, 'Fabricate Components').id, 'left', 0.25), conceptId: 'gl1' });
  a0.arrows.push(copy);
  const codes = M.icomCodes(m, a0);
  assert.equal(codes[`${copy.id}:from`], 'I1', 'rule 14: the fork shares the code');
  const [eCo, eCopy] = entriesOf(m, a0, [co, copy]);
  assert.equal(eCo.fork, co.id);
  assert.equal(eCopy.fork, co.id);
  assert.deepEqual(eCopy.drawn.from, co.from);
  assert.deepEqual(RN.drawnCodes(eCo, codes), { from: 'I1', to: null });
  assert.deepEqual(RN.drawnCodes(eCopy, codes), { from: null, to: null }, 'the representative already writes I1 there');
  // A branch keeps its code where the representative has none to draw.
  assert.deepEqual(RN.drawnCodes(eCopy, { [`${copy.id}:from`]: 'I9' }), { from: 'I9', to: null });
  // icomRects lists exactly the codes drawn: one I1, not two.
  const rects = RN.icomRects(m, a0);
  assert.equal(rects.length, Object.keys(codes).length - 1);
});

test('a branch with a label of its own draws it against its branch alone, after the trunk; a bundle member keeps its specific label that way', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  C.combineConcepts(m, ['Customer Order', 'Raw Materials'].map((t) => C.findConcept(m, t).id), 'Inputs');
  const co = a0.arrows.find((a) => a.label === 'Customer Order'), rm = a0.arrows.find((a) => a.label === 'Raw Materials');
  const [eCo, eRm] = entriesOf(m, a0, [co, rm]);
  assert.equal(eRm.fork, co.id, 'the same left edge, the same bundle: one boundary fork');
  assert.equal(eCo.label, 'Customer Order');
  assert.equal(eRm.label, 'Raw Materials');
  // The boundary trunk here is only the stub before the branches turn, too
  // short for the text: the representative's label falls back to its route.
  assert.ok(G.pathLength(eCo.forkTrunk) < U.textWidth(eCo.label, 10.5));
  assert.equal(eCo.labelPath, eCo.pts);
  const branch = eRm.labelPath;
  assert.ok(branch && branch !== eRm.pts);
  assert.ok(same(branch[0], eRm.forkTrunk.at(-1)), 'the branch starts where the trunk ends');
  assert.ok(same(branch.at(-1), eRm.pts.at(-1)), 'and runs to the arrow\'s own end');
  assert.deepEqual(branch, RN.branchPart(eRm.pts, eRm.forkTrunk, null));
});

test('a horizontal trunk carries the label only when its longest segment is at least the text\'s width; a shorter one hands the label to the representative\'s whole route, clear of the frame', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  // Plan Production's Work Order trunk (94.5 units) carries 'Work Order'.
  const wos = a0.arrows.filter((a) => a.label === 'Work Order');
  const [rep] = entriesOf(m, a0, wos);
  assert.ok(G.longestSegmentMid(rep.forkTrunk).length >= U.textWidth('Work Order', 10.5));
  assert.equal(rep.labelPath, rep.forkTrunk);
  // I1 into boxes 1 and 2 (box 1 by the left edge): the trunk is the 30-unit
  // boundary stub, and a label against it would cross the frame border.
  const co = a0.arrows.find((a) => a.label === 'Customer Order');
  const copy = M.newArrow({ label: 'Customer Order', from: M.boundaryEnd('left', 0.3), to: M.boxEnd(box(a0, 'Fabricate Components').id, 'left', 0.25), conceptId: 'gl1' });
  a0.arrows.push(copy);
  const [eCo, eCopy] = entriesOf(m, a0, [co, copy]);
  assert.ok(G.pathLength(eCo.forkTrunk) < U.textWidth('Customer Order', 10.5));
  assert.equal(eCo.labelPath, eCo.pts, 'the whole route');
  assert.equal(eCopy.labelPath, null, 'still one label for the group');
  const boxes = a0.boxes.map(G.rectOf);
  const onTrunk = G.labelRect(G.labelPlacement(eCo.forkTrunk, 'Customer Order', { boxes }), U.textWidth('Customer Order', 10.5));
  assert.ok(onTrunk.x < 24, 'against the stub the text would start on the frame border');
  const placed = G.labelRect(G.labelPlacement(eCo.labelPath, 'Customer Order', { boxes, icomEnds: RN.icomRects(m, a0) }), U.textWidth('Customer Order', 10.5));
  assert.ok(placed.x >= 24, 'on the route it clears the frame');
  // Exactly the width is enough: the rule is >=, the same in Drawing.swift;
  // a vertical trunk carries the label beside it once it is a line high (16).
  const P = (x, y) => ({ x, y });
  const w = U.textWidth('ab', 10.5);
  const short = [P(0, 0), P(w - 1e-9, 0)], exact = [P(0, 0), P(w, 0)];
  assert.equal(RN.trunkLabelPath(exact, [P(0, 0), P(200, 0)], 'ab'), exact);
  assert.equal(RN.trunkLabelPath(short, [P(0, 0), P(200, 0)], 'ab')[1].x, 200);
  const vertical = [P(0, 0), P(0, 16)], stub = [P(0, 0), P(0, 15.9)];
  assert.equal(RN.trunkLabelPath(vertical, [P(0, 0), P(0, 200)], 'a long label indeed'), vertical);
  assert.equal(RN.trunkLabelPath(stub, [P(0, 0), P(0, 200)], 'ab')[1].y, 200);
  assert.equal(RN.trunkLabelPath([P(0, 0)], [P(0, 0), P(0, 200)], '')[1].y, 200, 'a one-point trunk never carries a label');
});

test('a join into a box top labels its trunk — the short vertical drop carries the label beside it', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  const j1 = M.newArrow({ label: 'Inspection Report', from: M.boxEnd(box(a0, 'Fabricate Components').id, 'right', 0.8), to: M.boxEnd(box(a0, 'Ship Product').id, 'top', 0.75) });
  const j2 = M.newArrow({ label: 'Inspection Report', from: M.boxEnd(box(a0, 'Assemble Product').id, 'right', 0.8), to: M.boxEnd(box(a0, 'Ship Product').id, 'top', 0.6) });
  a0.arrows.push(j1, j2);
  C.bindAll(m);
  const [, e2] = entriesOf(m, a0, [j1, j2]);
  const seg = G.longestSegmentMid(e2.joinTrunk);
  assert.ok(!seg.horizontal && seg.length < U.textWidth('Inspection Report', 10.5) && seg.length >= 16);
  assert.equal(e2.labelPath, e2.joinTrunk);
});

test('a branch left a single point by overlapping trunks labels its whole route, so a dragged label still has a segment to sit on', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  // A second Production Staff arrow between the same faces as the sample's
  // (boundary bottom → Assemble Product bottom), with a label of its own
  // and a lower pos: it is the representative of both the fork and the
  // join, and the sample's arrow is a branch whose trunks cover its route.
  const ps = a0.arrows.find((a) => a.label === 'Production Staff');
  const dup = M.newArrow({ label: 'Shift Crew', from: M.boundaryEnd('bottom', 0.14), to: { ...ps.to, pos: 0.3 }, conceptId: ps.conceptId });
  a0.arrows.push(dup);
  ps.ldx = 7; ps.ldy = -5;                                  // dragged
  const [ePs, eDup] = entriesOf(m, a0, [ps, dup]);
  assert.equal(ePs.fork, dup.id);
  assert.equal(ePs.join, dup.id);
  assert.equal(RN.branchPart(ePs.pts, ePs.forkTrunk, ePs.joinTrunk).length, 1, 'the branch part is one point');
  assert.equal(ePs.labelPath, ePs.pts, 'so the label path is the route');
  assert.ok(ePs.labelPath.length >= 2);
  assert.deepEqual(eDup.labelPath, eDup.pts, 'the representative\'s trunks are its whole route, long enough for the text');
  // Both labels are placed without throwing (legacyLabelBase needs a segment).
  const ctx = { icomEnds: RN.icomRects(m, a0), boxes: a0.boxes.map(G.rectOf) };
  for (const e of [ePs, eDup]) {
    const pos = G.labelPosition(e.labelPath, { ...e.arrow, label: e.label }, ctx);
    assert.ok(Number.isFinite(pos.x) && Number.isFinite(pos.y));
  }
  const P = (x, y) => ({ x, y });
  assert.deepEqual(RN.branchLabelPath([P(70, 0)], [P(0, 0), P(80, 0)]), [P(0, 0), P(80, 0)]);
  assert.deepEqual(RN.branchLabelPath([P(30, 0), P(60, 0)], [P(0, 0), P(80, 0)]), [P(30, 0), P(60, 0)]);
});

test('the representative is the earliest on the face: the lowest stored pos, then array order — parentBoxArrows\'s own rule', () => {
  const m = sample();
  const a0 = byNode(m, 'A0');
  const wos = a0.arrows.filter((a) => a.label === 'Work Order');
  const plan = box(a0, 'Plan Production');
  const entry = M.parentBoxArrows(m, a0, plan).right.find((e) => e.arrows.length === 3);
  assert.equal(entry.arrow, wos[0], 'the ICOM code is numbered by the first');
  assert.equal(entryOf(m, a0, wos[1]).fork, wos[0].id);
  // The last in array order takes the lowest pos: it is the representative now, and the code's.
  wos[2].from = { ...wos[2].from, pos: 0.1 };
  assert.equal(entryOf(m, a0, wos[0]).fork, wos[2].id);
  assert.equal(M.parentBoxArrows(m, a0, plan).right.find((e) => e.arrows.length === 3).arrow, wos[2]);
  assert.deepEqual(entryOf(m, a0, wos[0]).drawn.from, wos[2].from);
  // A tie keeps the earlier in array order.
  wos[2].from = { ...wos[2].from, pos: 0.5 };
  assert.equal(entryOf(m, a0, wos[2]).fork, wos[0].id);
  assert.equal(M.parentBoxArrows(m, a0, plan).right.find((e) => e.arrows.length === 3).arrow, wos[0]);
});

test('the bundle merge takes precedence: a hidden member is not a branch, and a representative alone on its face forks nothing', () => {
  const m = sample();
  const ctx = byNode(m, 'A-0');
  C.combineConcepts(m, ['Customer Order', 'Raw Materials'].map((t) => C.findConcept(m, t).id), 'Inputs');
  const drawn = RN.drawnArrows(m, ctx);
  assert.equal(drawn.length, ctx.arrows.length - 1);
  const rep = drawn[0];
  assert.equal(rep.hidden.length, 1);
  assert.equal(rep.fork, null);
  assert.equal(rep.join, null);
  assert.deepEqual(rep.labelPath, rep.pts, 'an ungrouped arrow labels its whole route');
  // Unbound arrows never group, whatever their faces.
  const a0 = byNode(m, 'A0');
  for (const a of a0.arrows.filter((x) => x.label === 'Work Order')) a.conceptId = null;
  assert.ok(RN.drawnArrows(m, a0).every((e) => e.fork === null || e.arrow.label !== 'Work Order'));
});

test('commonPrefix and branchPart: the shared run of two polylines, and what is left of a route after the trunk', () => {
  const P = (x, y) => ({ x, y });
  const a = [P(0, 0), P(50, 0), P(50, 40)];
  const b = [P(0, 0), P(80, 0), P(80, 90)];
  assert.deepEqual(RN.commonPrefix(a, b), [P(0, 0), P(50, 0)], 'the shorter collinear segment ends the shared run');
  assert.deepEqual(RN.commonPrefix(b, a), [P(0, 0), P(50, 0)]);
  assert.deepEqual(RN.commonPrefix(a, [P(0, 0), P(50, 0), P(50, 40), P(70, 40)]), a, 'a vertex both share carries on');
  assert.deepEqual(RN.commonPrefix(a, [P(0, 0), P(0, 30)]), [P(0, 0)], 'a turn at the start shares only the point');
  assert.deepEqual(RN.commonPrefix(a, [P(1, 1), P(9, 9)]), [P(0, 0)], 'no common first point');
  assert.deepEqual(RN.commonPrefix([], b), []);
  // The branch: from the trunk's end along the route's remaining vertices.
  assert.deepEqual(RN.branchPart(b, [P(0, 0), P(50, 0)], null), [P(50, 0), P(80, 0), P(80, 90)]);
  assert.deepEqual(RN.branchPart(a, [P(0, 0), P(50, 0)], null), [P(50, 0), P(50, 40)], 'no doubled vertex where the trunk ends on one');
  assert.deepEqual(RN.branchPart(a, null, null), a);
  // Before a join trunk, and between both.
  assert.deepEqual(RN.branchPart(b, null, [P(80, 20), P(80, 90)]), [P(0, 0), P(80, 0), P(80, 20)]);
  assert.deepEqual(RN.branchPart(b, [P(0, 0), P(30, 0)], [P(80, 20), P(80, 90)]), [P(30, 0), P(80, 0), P(80, 20)]);
  // Trunks meeting on one segment leave the stretch between them, or a point.
  assert.deepEqual(RN.branchPart(b, [P(0, 0), P(30, 0)], [P(60, 0), P(80, 0), P(80, 90)]), [P(30, 0), P(60, 0)]);
  assert.deepEqual(RN.branchPart(b, [P(0, 0), P(70, 0)], [P(60, 0), P(80, 0), P(80, 90)]), [P(70, 0)]);
  assert.deepEqual(RN.branchPart(b, b, b), [P(80, 90)]);
});
