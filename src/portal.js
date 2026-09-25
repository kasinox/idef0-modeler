// Running inside the toolkit Portal.
//
// On the Portal every app is served from one origin under /<id>/ behind one
// Sign in with Google, and each app carries the same slim bar: the app
// switcher, the account, Sign out. The Portal injects a
// `<meta name="toolkit-portal" content="idef0">` into the copy of index.html
// it serves — never into this repo's own page — so the app can tell where it
// is running. `portalApp()` reads that tag and answers null everywhere else:
// opened from a file, from serve.sh, or from any other host, nothing below
// runs and the app is exactly what it was.

import { portalApp } from '../sync-kit/js/portal.js';

/** This app's id on the Portal. The contract in toolkit-app.json fixes it. */
export const APP_ID = 'idef0';

/**
 * Mount the Portal's bar above the app, when there is a Portal.
 *
 * Returns the app id the page is being served as, or null. The bar is a
 * flex item at the top of `#app`, so the shell below it keeps the rest of the
 * viewport and the canvas measures itself as it always did.
 *
 * The element is imported dynamically rather than from a `<script>` tag in
 * index.html because off the Portal it is dead weight: nothing renders it, and
 * a custom element defined for a tag no page contains is a download for
 * nothing. Failure to load it is not failure to run — the modeller works
 * without a bar, so it is logged and stepped over. `load` is that import, as a
 * parameter, so the node tests can mount the bar without a browser to define
 * a custom element in.
 */
export async function initPortal({
  mount = document.getElementById('app'),
  load = () => import('../ui-kit/js/portal-bar.js'),
} = {}) {
  const id = portalApp();
  if (id !== APP_ID || !mount) return id === APP_ID ? id : null;

  try {
    await load();
    const bar = document.createElement('sc-portal-bar');
    bar.setAttribute('app', APP_ID);
    mount.insertBefore(bar, mount.firstChild);
  } catch (e) {
    console.warn('The toolkit bar could not be loaded; the app runs without it.', e);
  }
  return id;
}
