# Golden staleness (F87, F88)

`tests/web/goldens-staleness.test.mjs` (run with `node --test tests/web/`) is
the preferred place for new golden-staleness coverage going forward. It
recomputes goldens.html's own DOM-free outputs — `golden-scenarios.json`,
`golden-geometry.json`, `golden-util.json`, `golden-labels.json`,
`golden-squiggles.json`, `golden-lane-groups.json`, `golden-deserialize.json`,
and `golden-exports.json`'s `toXml`/`toIdl`/`toMarkdown` fields — from the
CURRENT `src/` modules and fails if today's output no longer matches the
committed fixture. That is what makes a stale golden visible without
regenerating, opening Chrome, or running `swift test` at all.

## What this deliberately does not do

Three Swift test files still carry hand-captured expectations pasted from a
real browser/Node run rather than sourced from a JSON fixture:

- `IDEF0CoreTests/XMLInterchangeParityTests.swift` — the XML reader and
  parse-error batteries (captured from Chrome's `idef0xml.js` / `DOMParser`).
- `IDEF0CoreTests/ReportParityTests.swift` — the edge-model and quirks
  Markdown/HTML bodies (captured from `report.js` under Node).
- `IDEF0CoreTests/ValidateParityTests.swift` — the edge-model's issue list
  (captured from `validate.js` under Node).

F87's proposed fix moves each battery's *inputs* into goldens.html, posts them
as a new `golden-handcases.json`, and has those three Swift files read their
expectations from it instead of literals. That conversion needs to reproduce
the same TODAY-date substitution and id-normalisation the original hand
capture used, on inputs that (for the XML reader) only run in a real
`DOMParser`, so it earns its own careful pass rather than riding along with
this package's test-infrastructure changes. Per this package's scope, those
three files are left untouched here — this note is the pointer for whoever
picks that up next, and `goldens-staleness.test.mjs` is where the DOM-free
half of the same idea (F88) already lives, reusable as a model for it.

The XML reader's error-message cases will still need the prefix-only
comparison (`'XML is not well formed: '`) they use today: a real parser's
error text is engine-specific and changes across Chrome versions.
