// The edits a modeller makes by naming things, as operations on a model
// value — the web side of the Mac app's Edits.renameBox / labelArrow
// (macos/Sources/IDEF0Editing/Edits.swift) and Edits.setModelTitle
// (InspectorEdits.swift), ported line for line.
//
// The canvas's inline editor and the inspector both commit through these, so
// the two cannot drift apart in what "rename" means, and the same action
// saves the same JSON in both apps: a name is trimmed, bound to the concept it
// denotes, and carried into the unlocked title of the diagram that details
// the box. DOM-free, so node can exercise it (tests/web/edits.test.mjs).
//
// Where the Swift functions throw `Refusal.noSuchDiagram` / `.noSuchObject`,
// these return false and leave the model as it was; `commit` then records
// nothing. The store's `commit` also makes an unchanged value a no-op, so the
// callers need no such check of their own.
//
// There is no geometry edit here any more (S01): boxes are never placed by
// hand, so nothing types a coordinate or a size. Their order is changed with
// `moveBox` (model.js), which lays the diagram out again.

import { contextDiagram, findBox, renumberNodes } from './model.js';
import { bindBox, relabelArrow, relabelBox } from './concepts.js';

/**
 * Rename a box and bind it to the concept its new name denotes — keeping the
 * concept id, and letting the text drift, where `relabelBox`'s rules call for
 * that (F11) — trimmed, the unlocked child title follows (via renumberNodes,
 * which keeps the old title when the name is empty), and renaming the A-0 box
 * renames the model — unless the name was cleared, when the model keeps its
 * title.
 */
export function renameBox(m, diagramId, boxId, name) {
  const dg = m.diagrams[diagramId];
  const b = findBox(dg, boxId);
  if (!b) return false;
  relabelBox(m, dg, b, name);
  renumberNodes(m);
  if (diagramId === m.rootDiagramId && b.name) m.title = b.name;
  return true;
}

/**
 * Label an arrow and bind it to the concept its label denotes — via
 * `relabelArrow`, so an inherited boundary label kept for §3.3.2.4 or a typo
 * fix on an undefined term does not silently rebind (F11).
 */
export function labelArrow(m, diagramId, arrowId, label) {
  const dg = m.diagrams[diagramId];
  const a = dg?.arrows.find((x) => x.id === arrowId) || null;
  if (!a) return false;
  relabelArrow(m, dg, a, label);
  return true;
}

/**
 * The model title also titles the A-0 diagram, and names its box if the box
 * has no name yet — bound, as every other naming path binds. The title itself
 * is stored as typed, like the other model fields.
 */
export function setModelTitle(m, title) {
  m.title = title;
  const ctx = contextDiagram(m);
  if (!ctx) return;
  ctx.title = title;
  const box = ctx.boxes[0];
  if (box && !box.name && title) {
    box.name = title;
    bindBox(m, box);
  }
}
