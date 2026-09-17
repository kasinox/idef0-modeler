// F88: a staleness check for goldens.html's own fixtures. Each test below
// takes the INPUTS a fixture already recorded (a scenario's ops, a route's
// boxes/from/to/bend, a label case's pts/text, …) and recomputes today's
// output from the CURRENT src/ modules, then compares it to what is
// committed. A mismatch means the fixture is stale: someone changed web
// behaviour without running regen-goldens.sh, so the Swift parity tests are
// now silently comparing against the OLD behaviour rather than today's
// (F87's central risk). Run with:  node --test tests/web/
//
// This needs no DOM: model.js, geometry.js, concepts.js, validate.js,
// json.js, report.js and util.js are all plain data/string code. render.js
// imports the DOM-only `svg` helper from util.js but never calls it from
// `icomRects` — the one export used here — so it loads and runs fine in
// plain Node too; `renderFrame`/`renderBox`/`renderArrow`/`renderDiagram`,
// which do call it, are never invoked. idef0xml.js's `fromXml` genuinely
// needs a DOMParser and stays Chrome-only (XMLInterchangeParityTests, via
// goldens.html) — this file checks only golden-exports.json's toXml/toIdl/
// toMarkdown fields, and skips every field that round-trips through fromXml
// (reimported*, v1/v2/noId legacy-XML cases).
//
// Geometry's random battery is the one exception to "recompute from recorded
// inputs": rnd() is Math.sin-seeded, and Node's and Chrome's V8 builds can
// differ in a transcendental function's last bit (documented in goldens.html
// and in F88's own review). So the *inputs* (boxes, endpoints, bends, …) are
// always read back out of the fixture, never regenerated — only the
// downstream, DOM-free geometry functions (plain arithmetic and comparisons,
// spec-exact across engines) are recomputed and compared.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const FIXTURES = new URL('../../macos/Tests/IDEF0CoreTests/Fixtures/', import.meta.url);
const fixture = (name) => JSON.parse(readFileSync(new URL(name, FIXTURES), 'utf8'));
const fixtureText = (name) => readFileSync(new URL(name, FIXTURES), 'utf8');

const H = await import(new URL('../../macos/scripts/golden-harness.js', import.meta.url));
const M = await import(new URL('../../src/model/model.js', import.meta.url));
const G = await import(new URL('../../src/model/geometry.js', import.meta.url));
const C = await import(new URL('../../src/model/concepts.js', import.meta.url));
const J = await import(new URL('../../src/io/json.js', import.meta.url));
const X = await import(new URL('../../src/io/idef0xml.js', import.meta.url));
const R = await import(new URL('../../src/io/report.js', import.meta.url));
const U = await import(new URL('../../src/util.js', import.meta.url));
const RN = await import(new URL('../../src/ui/render.js', import.meta.url));

const sampleText = fixtureText('sample.idef0.json');
const load = () => C.bindAll(J.deserialize(sampleText));
const fixedIds = H.fixedIdsFor(sampleText);
const normalize = (text) => H.normalize(text, fixedIds);

/** The first difference between two plain JSON-ish values as "path: detail",
 * or null — jsonDiff's algorithm (Support/TestSupport.swift), so a mismatch
 * here reads the same way a Swift parity failure does. Numbers compare
 * within a small relative tolerance, matching every `Math.hypot`-derived
 * field (distances, nearest points) without needing to single them out. */
function diff(expected, actual, path = '$', tol = 1e-9) {
  // JSON.stringify writes NaN/Infinity/-Infinity as null (both when the
  // fixture was recorded and here); a non-finite recomputed number matches a
  // recorded null exactly the way it would if it round-tripped through JSON.
  if (expected === null && typeof actual === 'number' && !Number.isFinite(actual)) return null;
  if (actual === null && typeof expected === 'number' && !Number.isFinite(expected)) return null;
  if (typeof expected === 'number' && typeof actual === 'number') {
    if (Number.isNaN(expected) && Number.isNaN(actual)) return null;
    const scale = Math.max(1, Math.abs(expected), Math.abs(actual));
    return Math.abs(expected - actual) <= tol * scale ? null : `${path}: expected ${expected}, got ${actual}`;
  }
  if (Array.isArray(expected) || Array.isArray(actual)) {
    if (!Array.isArray(expected) || !Array.isArray(actual)) return `${path}: expected array-ness to match`;
    if (expected.length !== actual.length) return `${path}: expected ${expected.length} elements, got ${actual.length}`;
    for (let i = 0; i < expected.length; i += 1) {
      const d = diff(expected[i], actual[i], `${path}[${i}]`, tol);
      if (d) return d;
    }
    return null;
  }
  if (expected && actual && typeof expected === 'object' && typeof actual === 'object') {
    const ek = Object.keys(expected), ak = Object.keys(actual);
    for (const k of ek) if (!ak.includes(k)) return `${path}.${k}: missing`;
    for (const k of ak) if (!ek.includes(k)) return `${path}.${k}: unexpected`;
    for (const k of ek) {
      const d = diff(expected[k], actual[k], `${path}.${k}`, tol);
      if (d) return d;
    }
    return null;
  }
  return expected === actual ? null : `${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
}

/* ================================================================== *
 * golden-scenarios.json / scenarios.json
 * ================================================================== */

test('scenarios.json matches golden-harness.js\'s own scenario list', () => {
  assert.deepEqual(fixture('scenarios.json'), H.scenarios);
});

test('every scenario replays through the current model.js exactly as golden-scenarios.json records', () => {
  const golden = fixture('golden-scenarios.json');
  for (const sc of H.scenarios) {
    const m = load();
    for (const op of sc.ops) H.apply(m, op);
    const actual = JSON.parse(normalize(JSON.stringify(H.computeAll(m))));
    const d = diff(golden[sc.name], actual, sc.name);
    assert.equal(d, null, d ?? '');
  }
});

/* ================================================================== *
 * golden-geometry.json
 * ================================================================== */

test('routePoints and friends reproduce golden-geometry.json\'s 500 recorded routes', () => {
  const { routes } = fixture('golden-geometry.json');
  assert.equal(routes.length, 500);
  for (const [i, c] of routes.entries()) {
    const dg = { boxes: c.boxes, arrows: [] };
    const A = G.anchorOf(dg, c.from), B = G.anchorOf(dg, c.to);
    const pts = G.routePoints(A, B, c.bend, c.boxes);
    const actual = {
      A, B, pts, path: G.pointsToPath(pts), mid: G.longestSegmentMid(pts), len: G.pathLength(pts),
      at25: G.pointAt(pts, 0.25), dist: G.distToPolyline(pts, { x: 550, y: 440 }),
      nearestPt: G.nearestPointOnPolyline(pts, { x: 550, y: 440 }),
    };
    const expected = { A: c.A, B: c.B, pts: c.pts, path: c.path, mid: c.mid, len: c.len, at25: c.at25, dist: c.dist, nearestPt: c.nearestPt };
    const d = diff(expected, actual, `routes[${i}]`);
    assert.equal(d, null, d ?? '');
  }
});

test('nearestSide and pointInRect reproduce golden-geometry.json\'s 200 recorded cases', () => {
  const { nearest } = fixture('golden-geometry.json');
  assert.equal(nearest.length, 200);
  for (const [i, c] of nearest.entries()) {
    const actual = { ns: G.nearestSide(c.rect, c.pt), inRect: G.pointInRect(c.rect, c.pt) };
    const d = diff({ ns: c.ns, inRect: c.inRect }, actual, `nearest[${i}]`);
    assert.equal(d, null, d ?? '');
  }
});

test('staircaseLayout(1..8) matches golden-geometry.json', () => {
  const { staircase } = fixture('golden-geometry.json');
  assert.equal(staircase.length, 8);
  for (const c of staircase) {
    const d = diff(c.rects, M.staircaseLayout(c.n), `staircase[${c.n}]`);
    assert.equal(d, null, d ?? '');
  }
});

test('boxReadingOrder reproduces golden-geometry.json\'s 120 recorded layouts', () => {
  const { reading } = fixture('golden-geometry.json');
  assert.equal(reading.length, 120);
  for (const [i, c] of reading.entries()) {
    const order = M.boxReadingOrder(c.boxes).map((b) => b.id);
    assert.deepEqual(order, c.order, `reading[${i}]`);
  }
});

test('freePos reproduces golden-geometry.json\'s 60 recorded sides', () => {
  const { free } = fixture('golden-geometry.json');
  assert.equal(free.length, 60);
  for (const [i, c] of free.entries()) {
    const dg = { arrows: c.used.map((p) => ({ from: { type: 'boundary', side: 'left', pos: p }, to: { type: 'box', boxId: 'x', side: 'top', pos: 0.5 } })) };
    const pos = M.freePos(dg, (e) => e.type === 'boundary' && e.side === 'left');
    const d = diff(c.pos, pos, `free[${i}]`);
    assert.equal(d, null, d ?? '');
  }
});

/* ================================================================== *
 * golden-lane-groups.json (F61)
 * ================================================================== */

test('routeArrow reproduces every lane group\'s recorded routes', () => {
  const groups = fixture('golden-lane-groups.json');
  assert.equal(groups.length, 4);
  for (const g of groups) {
    const dg = { boxes: g.boxes, arrows: g.arrows };
    for (const a of g.arrows) {
      const d = diff(g.routes[a.id], G.routeArrow(dg, a), `${g.name}.routes.${a.id}`);
      assert.equal(d, null, d ?? '');
    }
  }
});

/* ================================================================== *
 * golden-labels.json (F59, F66)
 * ================================================================== */

test('label placement reproduces the sample\'s own arrows, per diagram', () => {
  const { diagrams } = fixture('golden-labels.json');
  const sample = load();
  for (const entry of diagrams) {
    const dg = H.byNode(sample, entry.node);
    const icomEnds = RN.icomRects(sample, dg);
    const boxes = dg.boxes.map(G.rectOf);
    assert.equal(diff(entry.icomEnds, icomEnds, `${entry.node}.icomEnds`), null);
    assert.equal(diff(entry.boxes, boxes, `${entry.node}.boxes`), null);
    for (const a of entry.arrows) {
      const live = dg.arrows.find((x) => x.id === a.id);
      assert.ok(live, `${entry.node}: arrow ${a.id} still on the sample`);
      const pts = G.routeArrow(dg, live);
      const width = U.textWidth(live.label, 10.5);
      const actual = {
        id: live.id, label: live.label, ldx: live.ldx, ldy: live.ldy, pts,
        auto: G.labelPlacement(pts, live.label, { icomEnds, boxes }),
        base: G.legacyLabelBase(pts),
        displayed: G.labelPosition(pts, live, { icomEnds, boxes }),
      };
      actual.rect = G.labelRect(actual.displayed, width);
      actual.squiggle = G.squigglePoints(pts, actual.displayed, width);
      const d = diff(a, actual, `${entry.node}.${a.id}`);
      assert.equal(d, null, d ?? '');
    }
  }
});

test('label placement reproduces the "dragged" cases (a manually offset label, small and large)', () => {
  const { dragged } = fixture('golden-labels.json');
  const sample = load();
  for (const [i, entry] of dragged.entries()) {
    const dgClone = U.deepClone(H.byNode(sample, 'A0'));
    const a = H.arrowByLabel(dgClone, entry.label);
    a.ldx = entry.ldx; a.ldy = entry.ldy;
    const icomEnds = RN.icomRects(sample, dgClone);
    const boxes = dgClone.boxes.map(G.rectOf);
    const pts = G.routeArrow(dgClone, a);
    const width = U.textWidth(a.label, 10.5);
    const actual = {
      id: a.id, label: a.label, ldx: a.ldx, ldy: a.ldy, pts,
      auto: G.labelPlacement(pts, a.label, { icomEnds, boxes }),
      base: G.legacyLabelBase(pts),
      displayed: G.labelPosition(pts, a, { icomEnds, boxes }),
    };
    actual.rect = G.labelRect(actual.displayed, width);
    actual.squiggle = G.squigglePoints(pts, actual.displayed, width);
    const d = diff(entry, actual, `dragged[${i}]`);
    assert.equal(d, null, d ?? '');
  }
});

test('labelPlacement/labelRect reproduce the hand-built battery cases', () => {
  const { battery } = fixture('golden-labels.json');
  for (const c of battery) {
    const width = U.textWidth(c.text, 10.5);
    const placement = G.labelPlacement(c.pts, c.text, { icomEnds: c.icomEnds, boxes: c.boxes });
    const rect = G.labelRect(placement, width);
    const d = diff({ placement: c.placement, rect: c.rect }, { placement, rect }, c.name);
    assert.equal(d, null, d ?? '');
  }
});

/* ================================================================== *
 * golden-squiggles.json (F66)
 * ================================================================== */

test('squigglePoints/nearestPointOnPolyline reproduce every recorded squiggle case', () => {
  const cases = fixture('golden-squiggles.json');
  for (const c of cases) {
    const actual = { nearest: G.nearestPointOnPolyline(c.pts, c.pos), squiggle: G.squigglePoints(c.pts, c.pos, c.width) };
    const d = diff({ nearest: c.nearest, squiggle: c.squiggle }, actual, c.name);
    assert.equal(d, null, d ?? '');
  }
});

/* ================================================================== *
 * golden-util.json
 * ================================================================== */

test('number formatting reproduces golden-util.json\'s recorded battery', () => {
  const { numbers } = fixture('golden-util.json');
  for (const [i, c] of numbers.entries()) {
    const actual = { s: String(c.v), r10: Math.round(c.v * 10) / 10, round: Math.round(c.v) };
    const d = diff({ s: c.s, r10: c.r10, round: c.round }, actual, `numbers[${i}]`);
    assert.equal(d, null, d ?? '');
  }
});

test('escapeXml/slugify/trim reproduce golden-util.json\'s recorded string battery', () => {
  const { strings } = fixture('golden-util.json');
  for (const [i, c] of strings.entries()) {
    const actual = {
      json: JSON.stringify(c.s), xml: U.escapeXml(c.s), slug: U.slugify(c.s),
      trim: c.s.trim(), collapsed: c.s.trim().replace(/\s+/g, ' ').toLowerCase(),
    };
    const d = diff({ json: c.json, xml: c.xml, slug: c.slug, trim: c.trim, collapsed: c.collapsed }, actual, `strings[${i}]`);
    assert.equal(d, null, d ?? '');
  }
});

test('wrapText reproduces golden-util.json\'s recorded wrap battery', () => {
  const { wraps } = fixture('golden-util.json');
  for (const [i, c] of wraps.entries()) {
    assert.deepEqual(U.wrapText(c.t, c.w, c.fs, c.ml), c.lines, `wraps[${i}]`);
  }
});

test('fitText reproduces golden-util.json\'s recorded fit battery', () => {
  const { fits } = fixture('golden-util.json');
  for (const [i, c] of fits.entries()) {
    assert.equal(U.fitText(c.t, c.w, c.fs), c.s, `fits[${i}]`);
  }
});

// F24: pinned to en-US so this passes the same on every machine regardless of
// locale — matching concepts.js's glossary sort and Swift's jsLocaleCompare.
// (ICU can differ across engines for edge cases; if this ever needs a
// tolerance list, start here rather than dropping the check outright.)
test('localeCompare(\'en-US\') reproduces golden-util.json\'s recorded pairwise battery and sorted list', () => {
  const { locale, sortedTerms } = fixture('golden-util.json');
  for (const [i, [a, b, expected]] of locale.entries()) {
    assert.equal(Math.sign(a.localeCompare(b, 'en-US')), expected, `locale[${i}] (${JSON.stringify(a)} vs ${JSON.stringify(b)})`);
  }
  // Re-sorting an already-sorted list with today's comparator is a no-op only
  // if today's collation still agrees with the recorded order.
  assert.deepEqual([...sortedTerms].sort((a, b) => a.localeCompare(b, 'en-US')), sortedTerms);
});

/* ================================================================== *
 * golden-deserialize.json
 * ================================================================== */

test('deserialize repairs reproduce every recorded case, replayed from its own recorded input', () => {
  const { cases } = fixture('golden-deserialize.json');
  for (const [i, c] of cases.entries()) {
    let actual;
    try {
      const repairs = [];
      const out = normalize(J.serialize(J.deserialize(c.text, { repairs })));
      actual = repairs.length ? { text: c.text, out, repairs: normalize(repairs.join('\n')).split('\n') } : { text: c.text, out };
    } catch (e) {
      actual = { text: c.text, error: e.message };
    }
    const d = diff(c, actual, `cases[${i}]`);
    assert.equal(d, null, d ?? '');
  }
});

test('deserialize rejects every recorded malformed input with the same message', () => {
  const { errors } = fixture('golden-deserialize.json');
  for (const [i, c] of errors.entries()) {
    let error = null;
    try { J.deserialize(c.text); } catch (e) { error = e.message; }
    assert.equal(error, c.error, `errors[${i}]`);
  }
});

/* ================================================================== *
 * golden-exports.json — toXml/toIdl/toMarkdown only; fromXml (idef0xml.js)
 * needs a DOMParser and stays Chrome-only (XMLInterchangeParityTests).
 * ================================================================== */

test('toXml/toIdl/toMarkdown reproduce golden-exports.json\'s writer-only fields', () => {
  const golden = fixture('golden-exports.json');

  const base = load();
  const md = R.toMarkdown(base).replace(/_Generated by IDEF0 Modeler on \d{4}-\d{2}-\d{2}\._/, '_Generated by IDEF0 Modeler on DATE._');
  assert.equal(X.toXml(base), golden.xml, 'xml');
  assert.equal(X.toIdl(base), golden.idl, 'idl');
  assert.equal(md, golden.markdown, 'markdown');

  // F12: refs, a diagram note holding a CR, a full-precision coordinate and
  // unknown top-level members.
  const rich = load();
  const richCtx = M.contextDiagram(rich);
  richCtx.notes = [{ text: 'Line1\rLine2', author: 'Ada' }];
  richCtx.boxes[0].refs = 'SOP-17, Appendix B';
  richCtx.boxes[0].x = 100.123;
  rich.ontologyLinks = ['urn:x', 'urn:y'];
  rich.glossary[0].source = 'ISO 9001';
  assert.equal(X.toXml(rich), golden.xmlRich, 'xmlRich');

  // F21: control characters, an attribute-embedded tab/newline, and a
  // literal CR in text content.
  const ctrl = load();
  const ctrlCtx = M.contextDiagram(ctrl);
  ctrlCtx.boxes[0].note = `a${String.fromCharCode(11)}b${String.fromCharCode(1)}c`;
  ctrlCtx.arrows[0].label = 'CR\rHere';
  ctrl.glossary[0].term = 'Tab\tNL\nEnd';
  assert.equal(X.toXml(ctrl), golden.xmlCtrl, 'xmlCtrl');

  // F25: a quote, a backslash and a newline in quoted IDL fields.
  const idlModel = load();
  const idlCtx = M.contextDiagram(idlModel);
  idlModel.title = 'Model "Q"\\Path';
  idlModel.author = 'A\nB';
  idlCtx.arrows[0].label = 'Order "rush"\nline2';
  idlCtx.boxes[0].name = 'Do "x"\\y';
  assert.equal(X.toIdl(idlModel), golden.idlEscaped, 'idlEscaped');
});
