// Checks of the side panels' commit paths (src/ui/panels.js) against the
// stand-in DOM in support/fake-dom.mjs. Run with:  node --test tests/web/
//
// The canvas never draws here — `requestAnimationFrame` never calls back —
// so what is checked is the model each field or button commits and what the
// panel shows afterwards. Modals (support/fake-dom.mjs gives dialog.js enough
// DOM) are answered by finding their input and OK button in `modal-root`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom, settle } from './support/fake-dom.mjs';

installFakeDom();

const {
  renderTree, renderModelProps, renderProps, renderGlossary, renderStatus, combineRefusal,
} = await import(new URL('../../src/ui/panels.js', import.meta.url));
const { store, set, loadModel, goToDiagram, markSaved, undoLabel, undo } = await import(new URL('../../src/state/store.js', import.meta.url));
const { buildSampleModel } = await import(new URL('../../src/model/sample.js', import.meta.url));
const {
  contextDiagram, decomposeBox, findBox, ports, sortedBoxes, staircaseLayout,
} = await import(new URL('../../src/model/model.js', import.meta.url));
const { bundleOf, conceptById, findConcept, isBundle } = await import(new URL('../../src/model/concepts.js', import.meta.url));
const { validate } = await import(new URL('../../src/model/validate.js', import.meta.url));

/* ---------------------------------------------------------- helpers */

/** A fresh sample in the store: A-0 with its box `top`, detailed by A0. */
function fresh() {
  loadModel(buildSampleModel());
  markSaved('sample.idef0.json');                 // no autosave timer left behind
  const m = store.model;
  const root = contextDiagram(m);
  return { root, top: root.boxes[0], a0: m.diagrams[root.boxes[0].childDiagramId] };
}

const host = (id) => document.getElementById(id);
const all = (node, pred) => [...node.walk()].filter(pred);
/** The control of the field labelled `label` in `id`. */
function fieldControl(id, label) {
  const f = all(host(id), (n) => n.getAttribute('class') === 'field' && n.childNodes[0]?.textContent === label)[0];
  assert.ok(f, `field ${label}`);
  return f.childNodes[1];
}
const sections = (id) => all(host(id), (n) => n.tagName === 'H3').map((n) => n.textContent);
const buttons = (id) => all(host(id), (n) => n.tagName === 'BUTTON').map((n) => n.textContent);
const button = (id, text) => {
  const b = all(host(id), (n) => n.tagName === 'BUTTON' && n.textContent === text)[0];
  assert.ok(b, `button ${text}`);
  return b;
};
const statValue = (id, key) => all(host(id), (n) => n.getAttribute('class') === 'kv' && n.childNodes[0]?.textContent === key)[0]?.childNodes[1].textContent;
const type = (control, text) => { control.value = text; control.dispatch('change'); };
const liveBox = (dgId, id) => findBox(store.model.diagrams[dgId], id);
const select = (dgId, kind, id) => { goToDiagram(dgId); set({ selection: { kind, id } }); renderProps(); };
const rectOf = (b) => ({ x: b.x, y: b.y, w: b.w, h: b.h });
const id = (term) => findConcept(store.model, term).id;

/** The glossary row (`.gl-item`) whose term field shows `term`. */
function glossaryRow(term) {
  const row = all(host('glossary'), (n) => n.getAttribute('class') === 'gl-item'
    && n.childNodes[0]?.childNodes[1]?.value === term)[0];
  assert.ok(row, `glossary row ${term}`);
  return row;
}
const rowTick = (row) => row.childNodes[0].childNodes[0];
const rowButtons = (row) => row.childNodes[0].childNodes.filter((n) => n.tagName === 'BUTTON').map((n) => n.textContent);

/** The open modal, or null. */
const modal = () => host('modal-root').querySelector('.modal');
/** Answer the open prompt with `text` (or cancel it) and let the caller resume. */
async function answerPrompt(text) {
  const m = modal();
  assert.ok(m, 'a prompt is open');
  if (text == null) { m.querySelector('.mfoot button').dispatch('click'); } else {
    const input = m.querySelector('input');
    input.value = text;
    m.querySelectorAll('.mfoot button')[1].dispatch('click');
  }
  await settle();
}

/* ------------------------------------------------------- number fields */

test('an emptied number field shows its value again and commits nothing', () => {
  const { a0 } = fresh();
  const arrow = a0.arrows[0];
  select(a0.id, 'arrow', arrow.id);
  const pos = fieldControl('props', 'Position');
  const shown = String(Math.round(arrow.from.pos * 100));
  const before = JSON.stringify(store.model);
  type(pos, '');
  assert.equal(pos.value, shown);
  type(pos, 'abc');
  assert.equal(pos.value, shown);
  assert.equal(JSON.stringify(store.model), before);
  assert.equal(store._undo.length, 0, 'no empty undo step');
});

test('the same number typed again is not committed', () => {
  const { a0 } = fresh();
  const arrow = a0.arrows[0];
  select(a0.id, 'arrow', arrow.id);
  type(fieldControl('props', 'Position'), String(Math.round(arrow.from.pos * 100)));
  assert.equal(store._undo.length, 0);
});

test('an emptied arrow position leaves the end where it was', () => {
  const { a0 } = fresh();
  const arrow = a0.arrows[0];
  select(a0.id, 'arrow', arrow.id);
  const pos = fieldControl('props', 'Position');
  const was = arrow.from.pos;
  type(pos, '');
  assert.equal(store.model.diagrams[a0.id].arrows[0].from.pos, was);
  assert.equal(store._undo.length, 0);
  type(pos, '0');
  assert.equal(store.model.diagrams[a0.id].arrows[0].from.pos, 0.02, 'kept off the corner');
  assert.equal(pos.value, '2');
});

/* --------------------------------------------------------- box order (S01) */

test('the box inspector offers no geometry: Move earlier / Move later reorder the staircase, one undo step each', () => {
  const { a0 } = fresh();
  const fab = a0.boxes[1];
  select(a0.id, 'box', fab.id);
  assert.ok(!sections('props').includes('Geometry'), 'no X/Y/W/H fields');
  assert.ok(sections('props').includes('Order'));
  for (const label of ['X', 'Y', 'Width', 'Height']) {
    assert.equal(all(host('props'), (n) => n.getAttribute('class') === 'field' && n.childNodes[0]?.textContent === label).length, 0, `no ${label} field`);
  }
  assert.equal(button('props', 'Move earlier').disabled, false);
  assert.equal(button('props', 'Move later').disabled, false);

  button('props', 'Move earlier').dispatch('click');
  let live = store.model.diagrams[a0.id];
  assert.deepEqual(sortedBoxes(live).map((b) => b.name), ['Fabricate Components', 'Plan Production', 'Assemble Product', 'Ship Product']);
  assert.deepEqual(sortedBoxes(live).map(rectOf), staircaseLayout(4), 'laid out again in the new order');
  assert.equal(undoLabel(), 'Move Activity', 'the Mac\'s undo name');
  assert.equal(store._undo.length, 1);
  assert.equal(liveBox(a0.id, fab.id).number, 1);

  renderProps();
  assert.equal(button('props', 'Move earlier').disabled, true, 'first box cannot move earlier');
  button('props', 'Move earlier').dispatch('click');
  assert.equal(store._undo.length, 1, 'a disabled move is refused by moveBox too: no-op commit');

  button('props', 'Move later').dispatch('click');
  live = store.model.diagrams[a0.id];
  assert.deepEqual(sortedBoxes(live).map((b) => b.name), ['Plan Production', 'Fabricate Components', 'Assemble Product', 'Ship Product']);
  assert.equal(undoLabel(), 'Move Activity');
  assert.equal(store._undo.length, 2);

  undo(); undo();
  assert.deepEqual(sortedBoxes(store.model.diagrams[a0.id]).map((b) => b.name), ['Plan Production', 'Fabricate Components', 'Assemble Product', 'Ship Product']);
});

test('the last box cannot move later, and the A-0 box moves neither way', () => {
  const { root, top, a0 } = fresh();
  select(a0.id, 'box', a0.boxes[3].id);
  assert.equal(button('props', 'Move earlier').disabled, false);
  assert.equal(button('props', 'Move later').disabled, true);
  select(root.id, 'box', top.id);
  assert.equal(button('props', 'Move earlier').disabled, true);
  assert.equal(button('props', 'Move later').disabled, true);
});

/* ------------------------------------------------------------- naming */

test('the inspector name field trims, retitles the child and the model, and shows the stored name', () => {
  const { root, top, a0 } = fresh();
  select(root.id, 'box', top.id);
  const name = fieldControl('props', 'Name (active verb phrase)');
  type(name, '  Make Widgets  ');
  const m = store.model;
  const b = liveBox(root.id, top.id);
  assert.equal(b.name, 'Make Widgets');
  assert.equal(conceptById(m, b.conceptId)?.term, 'Make Widgets');
  assert.equal(m.title, 'Make Widgets');
  assert.equal(m.diagrams[a0.id].title, 'Make Widgets');
  assert.equal(name.value, 'Make Widgets');

  type(name, '');
  assert.equal(liveBox(root.id, top.id).name, '');
  assert.equal(store.model.title, 'Make Widgets', 'a cleared name leaves the model title');
  assert.equal(store.model.diagrams[a0.id].title, 'Make Widgets', 'and the child title');
});

test('the model title names and binds an unnamed A-0 box', () => {
  const { root, top } = fresh();
  select(root.id, 'box', top.id);
  type(fieldControl('props', 'Name (active verb phrase)'), '');
  renderModelProps();
  type(fieldControl('modelprops', 'Title'), 'Run Plant');
  const b = liveBox(root.id, top.id);
  assert.equal(b.name, 'Run Plant');
  assert.equal(conceptById(store.model, b.conceptId)?.term, 'Run Plant');
  assert.deepEqual(validate(store.model).filter((i) => i.code === 'concept-unbound'), []);
});

test('the arrow label field trims and binds', () => {
  const { a0 } = fresh();
  // Not a boundary arrow: relabelling it exercises plain create-by-text
  // binding. A boundary arrow shares its concept with its ICOM counterpart on
  // A-0 (F11), so relabelling one of those keeps the id and drifts instead —
  // covered in concepts-relabel.test.mjs.
  const arrow = a0.arrows.find((a) => a.label === 'Work Order');
  select(a0.id, 'arrow', arrow.id);
  const label = fieldControl('props', 'Label (noun phrase)');
  type(label, '  Raw Stock ');
  const a = store.model.diagrams[a0.id].arrows.find((x) => x.id === arrow.id);
  assert.equal(a.label, 'Raw Stock');
  assert.equal(conceptById(store.model, a.conceptId)?.term, 'Raw Stock');
  assert.equal(label.value, 'Raw Stock');
});

/* ---------------------------------------------------------------- glossary */

test('Add concept keeps an existing definition when the field is left blank (F15)', () => {
  fresh();
  const before = conceptById(store.model, 'gl1');  // Customer Order, already defined
  assert.ok(before.definition);
  renderGlossary();
  type(fieldControl('glossary', 'Term'), 'customer order');   // same term, different case
  button('glossary', 'Add concept').dispatch('click');
  assert.equal(conceptById(store.model, 'gl1').definition, before.definition);
});

test('Add concept still sets a definition typed for an existing, undefined term', () => {
  const { a0 } = fresh();
  const raw = conceptById(store.model, a0.arrows.find((a) => a.label === 'Raw Materials').conceptId);
  assert.equal(raw.definition, '');
  renderGlossary();
  type(fieldControl('glossary', 'Term'), 'Raw Materials');
  type(fieldControl('glossary', 'Definition'), 'Sheet steel and fasteners bought from suppliers.');
  button('glossary', 'Add concept').dispatch('click');
  assert.equal(conceptById(store.model, raw.id).definition, 'Sheet steel and fasteners bought from suppliers.');
});

test('Remove goes through removeConcept: a member leaves its bundle\'s list as it goes', () => {
  fresh();
  renderGlossary();
  // An unused concept shows ✕; a used one does not.
  assert.deepEqual(rowButtons(glossaryRow('Customer Order')), []);
  type(fieldControl('glossary', 'Term'), 'Spare Part');
  button('glossary', 'Add concept').dispatch('click');
  type(fieldControl('glossary', 'Term'), 'Spare Tool');
  button('glossary', 'Add concept').dispatch('click');
  assert.deepEqual(rowButtons(glossaryRow('Spare Part')), ['✕']);
  const part = id('Spare Part'), tool = id('Spare Tool');
  // Bundle the two by hand (the button flow is covered below), then remove one.
  store.model.glossary.push({ id: 'gl_bx', term: 'Spares', kind: 'data', definition: '', members: [part, tool] });
  renderGlossary();
  assert.deepEqual(rowButtons(glossaryRow('Spare Part')), ['✕'], 'still removable, nested under its bundle');
  glossaryRow('Spare Part').childNodes[0].childNodes.find((n) => n.tagName === 'BUTTON').dispatch('click');
  assert.equal(conceptById(store.model, part), null);
  assert.deepEqual(conceptById(store.model, 'gl_bx').members, [tool], 'dropped from the bundle');
  assert.equal(undoLabel(), 'Remove concept');
});

/* ----------------------------------------------------- combine / un-combine */

test('ticking two glossary rows enables Combine selected; the prompt defaults to the terms joined by " & " and commits combineConcepts', async () => {
  fresh();
  renderGlossary();
  const combine = button('glossary', 'Combine selected (0)');
  assert.equal(combine.disabled, true);
  const co = rowTick(glossaryRow('Customer Order'));
  const rm = rowTick(glossaryRow('Raw Materials'));
  assert.equal(co.disabled, false);
  co.checked = true; co.dispatch('change');
  assert.equal(combine.textContent, 'Combine selected (1)');
  assert.equal(combine.disabled, true, 'one is not enough');
  rm.checked = true; rm.dispatch('change');
  assert.equal(combine.textContent, 'Combine selected (2)');
  assert.equal(combine.disabled, false);

  const undoDepth = store._undo.length;
  combine.dispatch('click');
  const m = modal();
  assert.ok(m, 'the term prompt opened');
  assert.equal(m.querySelector('h2').textContent, 'Combine concepts');
  assert.equal(m.querySelector('input').value, 'Customer Order & Raw Materials', 'members in glossary order');
  await answerPrompt(null);                      // cancel: nothing happens
  assert.equal(store._undo.length, undoDepth);
  assert.equal(modal(), null);

  renderGlossary();
  assert.equal(button('glossary', 'Combine selected (2)').disabled, false, 'ticks survive a redraw');
  button('glossary', 'Combine selected (2)').dispatch('click');
  await answerPrompt('  Inputs ');
  const bundle = findConcept(store.model, 'Inputs');
  assert.ok(isBundle(bundle));
  assert.deepEqual(bundle.members, [id('Customer Order'), id('Raw Materials')]);
  assert.equal(bundle.kind, 'data');
  assert.equal(undoLabel(), 'Combine Concepts', 'the Mac\'s undo name');
  assert.equal(store._undo.length, undoDepth + 1);
  assert.equal(store.ui.hint, 'Combined 2 concepts into “Inputs”.');
  assert.equal(store.ui.dirty, true);

  // The bundle row nests its members, with their own controls and no usable
  // tick, and offers Un-combine; the members are gone from the top level.
  renderGlossary();
  assert.equal(button('glossary', 'Combine selected (0)').disabled, true, 'the ticks were consumed');
  const row = glossaryRow('Inputs');
  assert.deepEqual(rowButtons(row), ['Un-combine']);
  const nested = all(row, (n) => n.getAttribute('class') === 'gl-item').map((n) => n.childNodes[0].childNodes[1].value);
  assert.deepEqual(nested, ['Customer Order', 'Raw Materials']);
  const memberRow = all(row, (n) => n.getAttribute('class') === 'gl-item')[0];
  assert.equal(rowTick(memberRow).disabled, true, 'a member cannot be combined again');
  assert.equal(memberRow.getAttribute('style'), 'margin-left:12px', 'indented');
  const topLevel = host('glossary').childNodes.filter((n) => n.getAttribute?.('class') === 'gl-item').map((n) => n.childNodes[0].childNodes[1].value);
  assert.ok(!topLevel.includes('Customer Order') && topLevel.includes('Inputs'));
  // A member's own term field still renames it (its controls are its own).
  type(memberRow.childNodes[0].childNodes[1], 'Customer Orders');
  assert.equal(conceptById(store.model, id('Customer Orders')).term, 'Customer Orders');
  assert.equal(bundleOf(store.model, id('Customer Orders')).term, 'Inputs');
});

test('Un-combine dissolves the bundle losslessly; a blank term and a refused combination leave a hint and no change', async () => {
  fresh();
  const pristine = JSON.stringify(store.model);
  store.model.glossary.push({ id: 'gl_b', term: 'Inputs', kind: 'data', definition: '', members: [id('Customer Order'), id('Raw Materials')] });
  renderGlossary();
  glossaryRow('Inputs').childNodes[0].childNodes.find((n) => n.tagName === 'BUTTON').dispatch('click');
  await settle();
  assert.equal(modal(), null, 'nothing to confirm');
  assert.equal(JSON.stringify(store.model), pristine);
  assert.equal(undoLabel(), 'Un-combine Concept', 'the Mac\'s undo name');
  assert.equal(store.ui.hint, 'Un-combined “Inputs”; its members stand on their own again.');

  // A blank term is not a bundle.
  renderGlossary();
  for (const t of ['Customer Order', 'Work Order']) { const tick = rowTick(glossaryRow(t)); tick.checked = true; tick.dispatch('change'); }
  const depth = store._undo.length;
  button('glossary', 'Combine selected (2)').dispatch('click');
  await answerPrompt('   ');
  assert.equal(store._undo.length, depth);
  assert.equal(store.ui.hint, 'A bundle needs a term.');

  // A member already in a bundle is refused, naming the bundle.
  store.model.glossary.push({ id: 'gl_c', term: 'Orders', kind: 'data', definition: '', members: [id('Customer Order'), id('Work Order')] });
  renderGlossary();
  assert.equal(combineRefusal(store.model, [id('Customer Order'), id('Quality Standards')]),
    '“Customer Order” is already in the bundle “Orders”. Un-combine that first.');
  assert.equal(combineRefusal(store.model, [id('Quality Standards')]), 'Tick at least two concepts to combine them.');
  assert.equal(combineRefusal(store.model, [id('Quality Standards'), 'gl_nope']), 'One of those concepts is no longer in the glossary.');
  assert.equal(combineRefusal(store.model, [id('Quality Standards'), id('Plant Equipment')]), null);
});

test('un-combining a bundle an arrow denotes directly keeps it as a plain concept, with nothing to confirm', async () => {
  const { a0 } = fresh();
  store.model.glossary.push({ id: 'gl_b', term: 'Inputs', kind: 'data', definition: '', members: [id('Customer Order'), id('Raw Materials')] });
  const co = store.model.diagrams[a0.id].arrows.find((a) => a.label === 'Customer Order');
  co.conceptId = 'gl_b';                          // as an arrow drawn from the bundle's port is bound
  renderGlossary();
  glossaryRow('Inputs').childNodes[0].childNodes.find((n) => n.tagName === 'BUTTON').dispatch('click');
  await settle();
  assert.equal(modal(), null, 'no confirmation: nothing is left dangling');
  const plain = conceptById(store.model, 'gl_b');
  assert.ok(plain, 'the entry stays');
  assert.equal(isBundle(plain), false);
  assert.equal(store.model.diagrams[a0.id].arrows.find((a) => a.id === co.id).conceptId, 'gl_b', 'the arrow still denotes it');
  assert.deepEqual(validate(store.model).filter((i) => i.code === 'concept-unbound'), []);
  assert.equal(undoLabel(), 'Un-combine Concept');
  assert.equal(store.ui.hint, 'Un-combined “Inputs”; its members stand on their own again, and “Inputs” stays as the concept its own arrows denote.');
  renderGlossary();
  assert.deepEqual(rowButtons(glossaryRow('Inputs')), [], 'used, and no longer a bundle: neither Un-combine nor ✕');
  assert.equal(rowTick(glossaryRow('Customer Order')).disabled, false, 'the members are free again');
});

test('a bundle on a cycle (a hand-edited file) is listed at the top level with the bundle-cycle warning, so Un-combine stays reachable', async () => {
  fresh();
  store.model.glossary.push(
    { id: 'gl_ca', term: 'Alpha', kind: 'data', definition: '', members: ['gl_cb'] },
    { id: 'gl_cb', term: 'Beta', kind: 'data', definition: '', members: ['gl_ca'] },
  );
  renderGlossary();
  const topLevel = () => host('glossary').childNodes.filter((n) => n.getAttribute?.('class') === 'gl-item').map((n) => n.childNodes[0].childNodes[1].value);
  assert.ok(topLevel().includes('Alpha') && topLevel().includes('Beta'), 'each is in a bundle, yet nothing above it would reach it');
  assert.ok(topLevel().includes('Customer Order'), 'an ordinary concept in no bundle is listed as ever');
  store.model.glossary.push({ id: 'gl_cc', term: 'Gamma', kind: 'data', definition: '', members: [id('Customer Order'), id('Raw Materials')] });
  renderGlossary();
  assert.ok(!topLevel().includes('Customer Order') && topLevel().includes('Gamma'), 'a member of a bundle not on a cycle is nested only');
  const row = glossaryRow('Alpha');
  assert.deepEqual(rowButtons(row), ['Un-combine']);
  const warning = all(row, (n) => n.tagName === 'P').map((n) => n.textContent);
  assert.ok(warning.includes('⚠ Bundle “Alpha” contains itself through its members. Un-combine it to break the cycle.'), warning.join(' | '));
  // Nested once, and not descended into again.
  assert.ok(warning.includes('Alpha — contains this bundle (cycle)'));
  row.childNodes[0].childNodes.find((n) => n.tagName === 'BUTTON').dispatch('click');
  await settle();
  assert.equal(conceptById(store.model, 'gl_ca'), null, 'unused, so it went');
  assert.equal(undoLabel(), 'Un-combine Concept');
});

/* ----------------------------------------------- arrow inspector: bundles */

test('the arrow inspector shows the bundle an arrow belongs to, with Un-combine, and otherwise offers Combine with… the other concepts on the diagram', async () => {
  const { a0 } = fresh();
  const coArrow = a0.arrows.find((a) => a.label === 'Customer Order');
  select(a0.id, 'arrow', coArrow.id);
  assert.ok(sections('props').includes('Concept'));
  assert.equal(statValue('props', 'Concept'), 'Customer Order');
  assert.equal(statValue('props', 'Bundle'), undefined);
  const pick = fieldControl('props', 'Combine with…');
  assert.equal(pick.tagName, 'SELECT');
  const options = pick.childNodes.map((o) => o.textContent);
  assert.deepEqual(options, ['Choose a concept…', 'Assembled Product', 'Components', 'Finished Product', 'Plant Equipment',
    'Production Schedule', 'Production Staff', 'Quality Standards', 'Raw Materials', 'Shipping Notice', 'Work Order'],
  'every other arrow concept on A0, once, sorted; not the boxes\' activities');

  // Choosing one prompts with "own & other" and combines the two.
  type(pick, id('Raw Materials'));
  assert.equal(modal().querySelector('input').value, 'Customer Order & Raw Materials');
  await answerPrompt('Inputs');
  const bundle = findConcept(store.model, 'Inputs');
  assert.deepEqual(bundle.members, [id('Customer Order'), id('Raw Materials')]);
  assert.equal(undoLabel(), 'Combine Concepts');

  renderProps();
  assert.equal(statValue('props', 'Bundle'), 'Inputs');
  assert.ok(buttons('props').includes('Un-combine'));
  assert.equal(all(host('props'), (n) => n.tagName === 'SELECT' && n.childNodes[0]?.textContent === 'Choose a concept…').length, 0, 'no Combine with… while bundled');

  // A concept already in a bundle is not offered to another arrow.
  select(a0.id, 'arrow', a0.arrows.find((a) => a.label === 'Work Order').id);
  const offered = fieldControl('props', 'Combine with…').childNodes.map((o) => o.textContent);
  assert.ok(!offered.includes('Customer Order') && !offered.includes('Raw Materials'));
  assert.ok(offered.includes('Inputs'), 'the bundle itself can be nested');

  select(a0.id, 'arrow', coArrow.id);
  button('props', 'Un-combine').dispatch('click');
  await settle();
  assert.equal(findConcept(store.model, 'Inputs'), null, 'nothing denoted the bundle itself, so it went');
  assert.equal(undoLabel(), 'Un-combine Concept');
  renderProps();
  assert.equal(statValue('props', 'Bundle'), undefined);
});

test('an arrow bound to a bundle itself shows that bundle and offers Un-combine, which keeps the concept the arrow denotes', async () => {
  const { a0 } = fresh();
  store.model.glossary.push({ id: 'gl_b', term: 'Inputs', kind: 'data', definition: '', members: [id('Customer Order'), id('Raw Materials')] });
  const co = store.model.diagrams[a0.id].arrows.find((a) => a.label === 'Customer Order');
  co.conceptId = 'gl_b';
  select(a0.id, 'arrow', co.id);
  assert.equal(statValue('props', 'Concept'), 'Inputs');
  assert.equal(statValue('props', 'Bundle'), 'Inputs');
  button('props', 'Un-combine').dispatch('click');
  await settle();
  assert.equal(modal(), null, 'nothing to confirm: the concept the arrow denotes stays');
  const plain = conceptById(store.model, 'gl_b');
  assert.equal(plain.term, 'Inputs');
  assert.equal(isBundle(plain), false);
  assert.equal(undoLabel(), 'Un-combine Concept');
  renderProps();
  assert.equal(statValue('props', 'Concept'), 'Inputs');
  assert.equal(statValue('props', 'Bundle'), undefined, 'a plain concept now');
});

/* --------------------------------------------------- arrow inspector on A-0 */

test('an A-0 arrow offers routing and notes, and a tunnel toggle for a box end (F08)', () => {
  const { root, a0 } = fresh();
  const arrow = root.arrows[0];
  select(root.id, 'arrow', arrow.id);
  // FIPS 183 §3.4.2 bars a tunnel only at an unconnected (boundary) end: A-0
  // has no parent to hide it from. This input arrow's box end may still be
  // tunnelled — ordinary notation (§3.3.2.9) that happens to be moot on A-0.
  assert.deepEqual(sections('props').slice(1), ['Concept', 'Tunnelling', 'Routing']);
  assert.ok(buttons('props').includes('Reset bend & label offset'));
  assert.ok(buttons('props').some((t) => t.includes('Reverse direction')));
  type(fieldControl('props', 'Notes'), 'Supplied by purchasing');
  assert.equal(store.model.diagrams[root.id].arrows[0].note, 'Supplied by purchasing');

  select(a0.id, 'arrow', a0.arrows[0].id);
  assert.deepEqual(sections('props').slice(1), ['Concept', 'Tunnelling', 'Routing']);
});

/* ------------------------------------------------------------- ports (S01) */

test('a child diagram with ports reports its unconnected parent concepts in the status bar and the diagram inspector', () => {
  const { a0 } = fresh();
  goToDiagram(a0.id);
  renderStatus();
  const statusText = () => host('statusbar').childNodes.map((n) => n.textContent);
  assert.equal(statusText()[1], '4 boxes · 13 arrows');
  const child = decomposeBox(store.model, a0, a0.boxes[0], 3);
  goToDiagram(child.id);
  assert.equal(ports(store.model, child).length, 3);
  renderStatus();
  assert.equal(statusText()[1], '3 boxes · 0 arrows · 3 parent concepts unconnected');
  assert.match(statusText()[4], /drag a port onto a box side/);
  renderProps();
  const rows = all(host('props'), (n) => n.getAttribute('class') === 'kv').map((n) => `${n.childNodes[0].textContent} ${n.childNodes[1].textContent}`);
  assert.deepEqual(rows.filter((r) => r.endsWith('unconnected')),
    ['I1 Customer Order — unconnected', 'C1 Production Schedule — unconnected', 'O1 Work Order — unconnected']);
  child.arrows.push({ id: 'ar_x', label: 'Customer Order', conceptId: id('Customer Order'), from: { type: 'boundary', side: 'left', pos: 0.5 }, to: { type: 'box', boxId: child.boxes[0].id, side: 'left', pos: 0.5 }, bend: null, ldx: 0, ldy: 0, tunnelFrom: false, tunnelTo: false, note: '' });
  child.arrows.push({ id: 'ar_y', label: 'Production Schedule', conceptId: id('Production Schedule'), from: { type: 'boundary', side: 'top', pos: 0.5 }, to: { type: 'box', boxId: child.boxes[0].id, side: 'top', pos: 0.5 }, bend: null, ldx: 0, ldy: 0, tunnelFrom: false, tunnelTo: false, note: '' });
  renderStatus();
  assert.equal(statusText()[1], '3 boxes · 2 arrows · 1 parent concept unconnected');
});

/* ----------------------------------------------------------- model panel */

test('deepest level counts decomposition depth', () => {
  const { a0 } = fresh();
  renderModelProps();
  assert.equal(statValue('modelprops', 'Deepest level'), '1');
  decomposeBox(store.model, a0, a0.boxes[0], 3);
  renderModelProps();
  assert.equal(statValue('modelprops', 'Deepest level'), '2');
});

/* ------------------------------------------------------------- node tree */

test('the node tree lists a box detailed by an ancestor without descending into it', () => {
  const { a0 } = fresh();
  const child = decomposeBox(store.model, a0, a0.boxes[0], 3);
  child.boxes[0].childDiagramId = a0.id;          // A11 detailed by A0, its own ancestor
  a0.boxes[1].childDiagramId = a0.id;             // A2 detailed by its own diagram
  renderTree();
  const rows = all(host('tree'), (n) => n.getAttribute('class') === 'nn').map((n) => n.textContent);
  assert.deepEqual(rows, ['A0', 'A1', 'A11', 'A12', 'A13', 'A2', 'A3', 'A4']);
});

test('a diagram shared by two boxes is listed under both, as before', () => {
  const { a0 } = fresh();
  const child = decomposeBox(store.model, a0, a0.boxes[0], 3);
  a0.boxes[2].childDiagramId = child.id;
  renderTree();
  const rows = all(host('tree'), (n) => n.getAttribute('class') === 'nn').map((n) => n.textContent);
  // Rows take their node numbers from the diagram they are on, so the shared
  // diagram's boxes read A11-A13 under both boxes.
  assert.deepEqual(rows, ['A0', 'A1', 'A11', 'A12', 'A13', 'A2', 'A3', 'A11', 'A12', 'A13', 'A4']);
});
