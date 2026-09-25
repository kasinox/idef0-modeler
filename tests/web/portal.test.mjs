// The Portal mode promise: under the Portal the bar is mounted above the app,
// and everywhere else nothing about the page changes at all.

import test from 'node:test';
import assert from 'node:assert/strict';
import { installFakeDom, FakeNode } from './support/fake-dom.mjs';

installFakeDom();
const { initPortal, APP_ID } = await import('../../src/portal.js');

/** A `#app` shell with a toolbar already in it, as index.html has. */
function shell() {
  const app = new FakeNode('div');
  app.setAttribute('id', 'app');
  app.appendChild(new FakeNode('header'));
  return app;
}

/** Put (or remove) the meta tag the Portal injects into the copy it serves. */
function portalMeta(id) {
  const root = document.documentElement;
  root.childNodes.length = 0;
  if (id === null) return;
  const meta = new FakeNode('meta');
  meta.setAttribute('name', 'toolkit-portal');
  meta.setAttribute('content', id);
  root.appendChild(meta);
}

test('off the Portal nothing is loaded and nothing is mounted', async () => {
  portalMeta(null);
  const app = shell();
  let loaded = false;
  const id = await initPortal({ mount: app, load: async () => { loaded = true; } });
  assert.equal(id, null);
  assert.equal(loaded, false, 'the bar module is not even fetched');
  assert.equal(app.childNodes.length, 1, 'the shell is untouched');
});

test('another app’s page is not this app’s, either', async () => {
  portalMeta('sysml');
  const app = shell();
  const id = await initPortal({ mount: app, load: async () => assert.fail('must not load') });
  assert.equal(id, null);
  assert.equal(app.childNodes.length, 1);
});

test('under the Portal the bar goes above the shell', async () => {
  portalMeta(APP_ID);
  const app = shell();
  const id = await initPortal({ mount: app, load: async () => {} });
  assert.equal(id, APP_ID);
  const bar = app.childNodes[0];
  assert.equal(bar.tagName, 'SC-PORTAL-BAR', 'first child, so it sits above the toolbar');
  assert.equal(bar.getAttribute('app'), APP_ID);
  assert.equal(app.childNodes[1].tagName, 'HEADER', 'the toolbar keeps its place');
});

test('a bar that will not load leaves a working modeller', async () => {
  portalMeta(APP_ID);
  const app = shell();
  const warn = console.warn;
  console.warn = () => {};
  try {
    const id = await initPortal({ mount: app, load: async () => { throw new Error('offline'); } });
    assert.equal(id, APP_ID, 'the page still knows it is on the Portal');
    assert.equal(app.childNodes.length, 1, 'no half-built bar is left behind');
  } finally {
    console.warn = warn;
  }
});
