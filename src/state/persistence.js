// Whether the browser has agreed to keep this app's data.
//
// A browser copy is not a copy until the browser says it will keep it: by
// default everything in localStorage, IndexedDB and the caches sits in
// "best-effort" storage, which the browser is free to evict when the disk runs
// low — quietly, and without asking. `navigator.storage.persist()` asks for
// the other kind. Chrome answers from its own heuristics (an installed app, a
// bookmarked site, enough engagement) without ever showing a prompt; Firefox
// asks the person once and remembers; Safari grants it to a page added to the
// Home Screen. Nothing here blocks, and nothing here fails: a browser that has
// never heard of the API reports "unknown" and the app carries on as it always
// did.
//
// The sync kit is expected to grow a `requestPersistentStorage()` of its own,
// with the state travelling on the sync status event. When it does, this module
// is the one place to change: the rest of the app reads `persistenceState()`.

/** A setting, not a record: which is why it may stay in localStorage. */
const ASKED_KEY = 'idef0-modeler:persistence.asked';

/**
 * The last known answer.
 *
 * `state` is 'persisted' (the browser has promised to keep it), 'at-risk'
 * (best-effort: it may be evicted) or 'unknown' (no API, or not asked yet).
 */
let current = { state: 'unknown', asked: false, supported: false };

/** What the UI should show. Never throws, never waits. */
export function persistenceState() {
  return { ...current };
}

/** One sentence of what to do about it, or null when there is nothing to do. */
export function persistenceAdvice(state = current.state) {
  if (state === 'persisted') return null;
  return onIphone()
    ? 'Add the app to your Home Screen (Share ▸ Add to Home Screen) and this browser will keep your work.'
    : 'Install the app from your browser’s menu and it will keep your work instead of evicting it when space runs short.';
}

/**
 * Ask the browser to keep this app's data, at most once per browser unless
 * `force` says otherwise (turning sync on is the other moment worth asking).
 *
 * Returns the state it settled on. The caller is not expected to await it:
 * `initPersistence` below is the normal entry point, and it hands the answer
 * to a callback whenever it arrives.
 */
export async function requestPersistence({ force = false } = {}) {
  const storage = globalThis.navigator?.storage;
  current.supported = typeof storage?.persisted === 'function';
  if (!current.supported) return (current.state = 'unknown');

  try {
    if (await storage.persisted()) return settle('persisted');
    // Asking again after a refusal cannot help on its own — the answer is the
    // browser's policy, not a dialog — so a refusal is remembered and the
    // prompt is not put in front of the same person on every launch.
    const asked = remembered();
    current.asked = asked;
    if (asked && !force) return settle('at-risk');
    remember();
    return settle(typeof storage.persist === 'function' && (await storage.persist()) ? 'persisted' : 'at-risk');
  } catch {
    // A browser that throws on the question (private windows do) is telling us
    // the data is not being kept.
    return settle('at-risk');
  }
}

/**
 * Ask on launch and tell the app when the answer arrives.
 *
 * Deliberately not awaited by the caller: the first paint must not wait on a
 * question about the disk. `onSettled` runs once, after the browser answers.
 */
export function initPersistence(onSettled = () => {}) {
  requestPersistence().then((state) => onSettled(state)).catch(() => {});
}

function settle(state) {
  current.state = state;
  return state;
}

function remembered() {
  try { return globalThis.localStorage?.getItem(ASKED_KEY) === '1'; } catch { return false; }
}

function remember() {
  current.asked = true;
  try { globalThis.localStorage?.setItem(ASKED_KEY, '1'); } catch { /* a blocked store is not an error */ }
}

/** iPhone and iPad, where the advice is the Home Screen rather than Install. */
function onIphone() {
  const ua = globalThis.navigator?.userAgent ?? '';
  return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && (globalThis.navigator?.maxTouchPoints ?? 0) > 1);
}
