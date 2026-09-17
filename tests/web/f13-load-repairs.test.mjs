// DOM-free checks for F13: a load that mints ids the file did not have —
// unbound concepts, or a missing top-level model id — must not look clean.
// Run with:  node --test tests/web/
//
// Coverage gap this file closes (blocking review item): before this, neither
// `unboundCount` nor the two load-time repairs it and the model-id check
// drive (store.js's `dirty`/`hint`) had any test anywhere in the suite.

import { test } from 'node:test';
import assert from 'node:assert/strict';

const memory = new Map();
globalThis.localStorage = {
  getItem: (k) => (memory.has(k) ? memory.get(k) : null),
  setItem: (k, v) => { memory.set(k, String(v)); },
  removeItem: (k) => { memory.delete(k); },
};

const { store, loadModel } = await import(new URL('../../src/state/store.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));
const { bindAll, unboundCount } = await import(new URL('../../src/model/concepts.js', import.meta.url));
const { deserialize, serialize } = await import(new URL('../../src/io/json.js', import.meta.url));

test('unboundCount is zero on a bound sample and equals the number of named elements on a stripped copy', () => {
  const bound = bindAll(buildSampleModel());
  assert.equal(unboundCount(bound), 0);

  // buildSampleModel() itself is never bound — every box/arrow's conceptId
  // is unset — so it already is the "stripped copy" F13 asks for.
  const stripped = buildSampleModel();
  let named = 0;
  for (const dg of Object.values(stripped.diagrams)) {
    for (const b of dg.boxes) if (b.name.trim()) named += 1;
    for (const a of dg.arrows) if (a.label.trim()) named += 1;
  }
  assert.equal(unboundCount(stripped), named);
  assert.ok(named > 0, 'the sample must actually name something for this test to mean anything');
});

test('loadModel dirties the model and leaves a hint when a file needed concepts bound on load', () => {
  memory.clear();
  const model = buildSampleModel();       // unbound, but carries a top-level id already
  loadModel(model, 'unbound.idef0.json');
  assert.equal(store.ui.dirty, true);
  assert.match(store.ui.hint, /concepts? assigned on load/);
  assert.equal(unboundCount(store.model), 0, 'loadModel must still bind everything');
});

test('loadModel dirties the model and leaves a hint when the file had no top-level id', () => {
  memory.clear();
  const raw = JSON.parse(serialize(bindAll(buildSampleModel())));
  delete raw.id;
  const model = deserialize(JSON.stringify(raw));
  loadModel(model, 'noid.idef0.json');
  assert.equal(store.ui.dirty, true);
  assert.match(store.ui.hint, /model had no id/);
  assert.ok(store.model.id, 'a model id must still exist after loading');
  // The in-memory flag that carried the signal from deserialize to loadModel
  // must never reach the saved bytes.
  assert.ok(!serialize(store.model).includes('__idMinted'));
});

test('loadModel reports both repairs when a file lacks concepts and an id', () => {
  memory.clear();
  const raw = JSON.parse(serialize(buildSampleModel()));   // unbound AND...
  delete raw.id;                                           // ...missing its id
  raw.glossary = [];
  for (const d of Object.values(raw.diagrams)) {
    for (const b of d.boxes) b.conceptId = null;
    for (const a of d.arrows) a.conceptId = null;
  }
  const model = deserialize(JSON.stringify(raw));
  loadModel(model, 'bare.idef0.json');
  assert.equal(store.ui.dirty, true);
  assert.match(store.ui.hint, /assigned and a model id generated on load/);
});

test('loadModel leaves a file that already carried concepts and an id clean', () => {
  memory.clear();
  const text = serialize(bindAll(buildSampleModel()));
  const model = deserialize(text);
  loadModel(model, 'clean.idef0.json');
  assert.equal(store.ui.dirty, false);
  assert.equal(store.ui.hint, '');
});
