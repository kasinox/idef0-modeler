#!/bin/sh
# Refresh this repo's vendored copies of the shared kits, or check they are current.
#
#   scripts/vendor-kits.sh              # refresh ui-kit/, sync-kit/ and SCTheme.swift
#   scripts/vendor-kits.sh --check      # fail if any of them has drifted
#   UI_KIT_SRC=/path/to/ui-kit SYNC_KIT_SRC=/path/to/sync-kit scripts/vendor-kits.sh
#
# The kits are vendored so a clone of this repo runs on its own: the web app
# serves ui-kit/ and sync-kit/js over plain HTTP with no build step and no npm
# install, and the Portal copies those folders verbatim into its build. Each
# kit owns its own copying — scripts/copy-into.mjs in both mirrors the
# directories its package.json calls "files" and writes COPY.md — so this
# script only chooses the sources, adds the one copy neither kit can know
# about (SwiftPM cannot compile a source outside its package, so the Mac target
# keeps its own copy of the kit's generated SCTheme.swift), and reports on all
# of them together.
#
# --check runs from macos/scripts/build-app.sh, so a stale kit cannot ship
# inside the .app, and from serve.sh as a warning. A clone with no kits beside
# it is the normal case, not an error: the check says it skipped that kit and
# carries on. SKIP_KIT_CHECK=1 skips it entirely. Every leg compares by
# content, so a fresh checkout's file times are never mistaken for drift.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIBLINGS="$(cd "$ROOT/.." && pwd)"
UI_KIT="${UI_KIT_SRC:-$SIBLINGS/ui-kit}"
SYNC_KIT="${SYNC_KIT_SRC:-$SIBLINGS/sync-kit}"
THEME_DEST="$ROOT/macos/Sources/IDEF0Modeler/SCTheme.swift"

mode="refresh"
[ "${1:-}" = "--check" ] && mode="check"

if [ "$mode" = "check" ] && [ "${SKIP_KIT_CHECK:-0}" = "1" ]; then
  echo "kit check: skipped (SKIP_KIT_CHECK=1)"
  exit 0
fi

status=0

# Each kit: run its own copy script, or say why it was skipped.
for kit in "$UI_KIT" "$SYNC_KIT"; do
  name="$(basename "$kit")"
  script="$kit/scripts/copy-into.mjs"
  if [ ! -f "$script" ]; then
    if [ "$mode" = "check" ]; then
      echo "$name check: skipped, none at $kit (the vendored copy is all this repo needs)"
      continue
    fi
    echo "no $name at $kit — set $(echo "$name" | tr 'a-z-' 'A-Z_')_SRC to its checkout" >&2
    exit 2
  fi
  if [ "$mode" = "check" ]; then
    node "$script" --check "$ROOT/$name" || status=$?
  else
    node "$script" "$ROOT/$name"
  fi
done

# The Mac target's copy of SCTheme.swift, which ui-kit's own check cannot see.
if [ -f "$ROOT/ui-kit/swift/SCTheme.swift" ]; then
  if [ "$mode" = "check" ]; then
    if ! cmp -s "$ROOT/ui-kit/swift/SCTheme.swift" "$THEME_DEST"; then
      echo "macos/Sources/IDEF0Modeler/SCTheme.swift differs from ui-kit/swift/SCTheme.swift"
      status=1
    fi
  else
    cp "$ROOT/ui-kit/swift/SCTheme.swift" "$THEME_DEST"
    echo "macos/Sources/IDEF0Modeler/SCTheme.swift: copied from ui-kit/swift"
  fi
fi

[ "$mode" = "check" ] && [ "$status" -ne 0 ] &&
  echo "run scripts/vendor-kits.sh to refresh (SKIP_KIT_CHECK=1 builds anyway)" >&2
exit "$status"
