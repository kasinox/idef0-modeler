// A stand-in DOM for the UI modules' node tests (panels.js, canvas.js,
// dialog.js): just enough for `el`, `svg` and `clear`, the panels' fields and
// buttons, and the modals — elements with children, attributes, text,
// listeners, the input properties the fields read (`value`, `valueAsNumber`,
// `checked`), a small `querySelector` (tags, classes, attributes, `:not`,
// descendant chains and comma lists) and focus no-ops. Nothing lays out or
// paints: `requestAnimationFrame` never calls back, so the canvas never
// draws; what the tests check is the model each control commits and what
// the panel shows afterwards.
//
// `installFakeDom()` sets the globals (`document`, `window`,
// `requestAnimationFrame`, `localStorage`) and returns the host map, so a
// test can `import` it before the module under test. Import it with a
// top-level `await import(...)` of the module under test AFTER calling it.

export class FakeNode {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.nodeType = 1;
    this.childNodes = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.listeners = new Map();
    this.dataset = {};
    this.style = {};
    this.id = '';
    this._text = '';
    this._value = '';
    this.checked = false;
    this.disabled = false;
    this.hidden = false;
    this.offsetParent = this;
  }
  get firstChild() { return this.childNodes[0] || null; }
  get isConnected() { return true; }
  insertBefore(c, ref) {
    if (c.parentNode) c.parentNode.removeChild(c);
    c.parentNode = this;
    const at = ref ? this.childNodes.indexOf(ref) : -1;
    if (at < 0) this.childNodes.push(c);
    else this.childNodes.splice(at, 0, c);
    return c;
  }
  appendChild(c) {
    if (c.parentNode) c.parentNode.removeChild(c);
    c.parentNode = this;
    this.childNodes.push(c);
    return c;
  }
  append(...cs) { for (const c of cs) this.appendChild(typeof c === 'object' ? c : new FakeText(String(c))); }
  removeChild(c) {
    const i = this.childNodes.indexOf(c);
    if (i >= 0) this.childNodes.splice(i, 1);
    c.parentNode = null;
    return c;
  }
  contains(n) { for (let x = n; x; x = x.parentNode) if (x === this) return true; return false; }
  setAttribute(k, v) { this.attributes.set(k, String(v)); if (k === 'id') this.id = String(v); }
  getAttribute(k) { return this.attributes.has(k) ? this.attributes.get(k) : null; }
  hasAttribute(k) { return this.attributes.has(k); }
  get className() { return this.getAttribute('class') || ''; }
  get textContent() { return this._text + this.childNodes.map((c) => c.textContent).join(''); }
  set textContent(v) { this.childNodes = []; this._text = String(v); }
  get innerHTML() { return this._text; }
  set innerHTML(v) { this.childNodes = []; this._text = String(v); }
  get value() { return this._value; }
  set value(v) { this._value = String(v); }
  /** As a browser reads an `<input type=number>`: NaN unless the text is a valid floating-point number. */
  get valueAsNumber() {
    if (this.getAttribute('type') !== 'number') return NaN;
    return /^-?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$/.test(this._value) ? Number(this._value) : NaN;
  }
  addEventListener(type, fn) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(fn);
  }
  removeEventListener(type, fn) {
    const l = this.listeners.get(type);
    if (l) { const i = l.indexOf(fn); if (i >= 0) l.splice(i, 1); }
  }
  dispatch(type, extra = {}) {
    const ev = { type, target: this, preventDefault() {}, stopPropagation() {}, ...extra };
    for (const fn of [...(this.listeners.get(type) || [])]) fn(ev);
    return ev;
  }
  focus() { document.activeElement = this; }
  blur() { if (document.activeElement === this) document.activeElement = null; }
  select() {}
  /** Every descendant, depth first. */
  *walk() { for (const c of this.childNodes) { if (c.nodeType === 1) { yield c; yield* c.walk(); } } }
  querySelectorAll(sel) { return [...this.walk()].filter((n) => matchesWithin(n, sel, this)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  matches(sel) { return matchesWithin(this, sel, null); }
  closest(sel) { for (let x = this; x; x = x.parentNode) if (x.nodeType === 1 && x.matches(sel)) return x; return null; }
}

export class FakeText {
  constructor(t) { this.nodeType = 3; this.parentNode = null; this.childNodes = []; this.textContent = t; }
}

/* ------------------------------------------------------------ selectors */

const COMPOUND = /^([a-zA-Z][\w-]*|\*)?((?:#[\w-]+|\.[\w-]+|\[[^\]]+\]|:not\([^)]*\))*)$/;

function matchesCompound(n, compound) {
  const m = COMPOUND.exec(compound);
  if (!m) throw new Error(`fake-dom: unsupported selector "${compound}"`);
  const [, tag, rest] = m;
  if (tag && tag !== '*' && n.tagName !== tag.toUpperCase()) return false;
  const parts = rest ? rest.match(/#[\w-]+|\.[\w-]+|\[[^\]]+\]|:not\([^)]*\)/g) || [] : [];
  for (const p of parts) {
    if (p[0] === '#') { if (n.id !== p.slice(1)) return false; continue; }
    if (p[0] === '.') { if (!n.className.split(/\s+/).includes(p.slice(1))) return false; continue; }
    if (p.startsWith(':not(')) { if (matchesCompound(n, p.slice(5, -1))) return false; continue; }
    // Groups: name, the whole `=…` clause, the quote (if any), the value —
    // so the value is the fourth, and the second says whether a value was
    // given at all. Reading the third as the value matched a bare `"` and
    // quietly failed every `[a="b"]` selector.
    const [, name, eq, , val] = /^\[([\w-]+)(=("?)(.*?)\3)?\]$/.exec(p) || [];
    if (!name) throw new Error(`fake-dom: unsupported attribute selector "${p}"`);
    // `disabled`/`hidden`/`checked` are properties on the fake (as `el` sets
    // them), so the attribute test reads those too.
    const has = n.attributes.has(name) || (name in n && typeof n[name] === 'boolean' && n[name]);
    if (eq === undefined) { if (!has) return false; continue; }
    if (n.getAttribute(name) !== val) return false;
  }
  return true;
}

/** Whether `n` matches `selectors` (a comma list of descendant chains),
 *  with ancestor matches confined below `root` when one is given. */
function matchesWithin(n, selectors, root) {
  return selectors.split(',').some((sel) => {
    const chain = sel.trim().split(/\s+/).filter(Boolean);
    if (!chain.length) return false;
    if (!matchesCompound(n, chain[chain.length - 1])) return false;
    let i = chain.length - 2;
    for (let a = n.parentNode; a && a !== root && i >= 0; a = a.parentNode) {
      if (a.nodeType === 1 && matchesCompound(a, chain[i])) i -= 1;
    }
    return i < 0;
  });
}

/* --------------------------------------------------------------- install */

/** Set the globals up and return the `getElementById` host map. */
export function installFakeDom() {
  const hosts = new Map();
  const docListeners = new Map();
  // A real root, so a test can put a `<meta>` where a module looks for one and
  // `document.querySelector` finds it. Empty by default, which is what the
  // panels' and canvas's tests have always seen from `querySelectorAll`.
  const root = new FakeNode('html');
  globalThis.document = {
    activeElement: null,
    documentElement: root,
    body: new FakeNode('body'),
    createElement: (tag) => new FakeNode(tag),
    createElementNS: (_ns, tag) => new FakeNode(tag),
    createTextNode: (t) => new FakeText(t),
    getElementById: (id) => {
      if (!hosts.has(id)) { const n = new FakeNode('div'); n.id = id; hosts.set(id, n); }
      return hosts.get(id);
    },
    querySelector: (sel) => root.querySelector(sel),
    querySelectorAll: (sel) => root.querySelectorAll(sel),
    addEventListener: (type, fn) => { if (!docListeners.has(type)) docListeners.set(type, []); docListeners.get(type).push(fn); },
    removeEventListener: (type, fn) => { const l = docListeners.get(type); if (l) { const i = l.indexOf(fn); if (i >= 0) l.splice(i, 1); } },
  };
  globalThis.window = { addEventListener() {}, removeEventListener() {} };
  globalThis.requestAnimationFrame = () => 0;
  const memory = new Map();
  globalThis.localStorage = {
    getItem: (k) => (memory.has(k) ? memory.get(k) : null),
    setItem: (k, v) => { memory.set(k, String(v)); },
    removeItem: (k) => { memory.delete(k); },
  };
  return hosts;
}

/** Let queued microtasks and zero-delay timers (a modal's answer) settle. */
export const settle = () => new Promise((resolve) => { setTimeout(resolve, 0); });
