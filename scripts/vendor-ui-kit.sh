#!/bin/sh
# Refresh this repo's vendored copy of the shared UI kit, or check it is current.
#
#   scripts/vendor-ui-kit.sh              # refresh ui-kit/ and SCTheme.swift
#   scripts/vendor-ui-kit.sh --check      # fail if either has drifted
#   UI_KIT_SRC=/path/to/ui-kit scripts/vendor-ui-kit.sh
#
# The kit is vendored so a clone of this repo runs on its own: the web app
# serves ui-kit/css and ui-kit/js over plain HTTP with no build step and no npm
# install. The kit owns the copying — scripts/copy-into.mjs there mirrors the
# directories its package.json calls "files" and writes ui-kit/COPY.md — so
# this script only adds the one copy the kit cannot know about: SwiftPM cannot
# compile a source outside its package, so the Mac target keeps its own copy of
# the kit's generated SCTheme.swift.
#
# --check runs from macos/scripts/build-app.sh, so a stale theme cannot ship
# inside the .app. A clone with no kit beside it is the normal case, not an
# error: the check says it skipped and exits 0. SKIP_UI_KIT_CHECK=1 skips it
# even when the kit is there. Both legs compare by content, so a fresh
# checkout's file times are never mistaken for drift.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="${UI_KIT_SRC:-$(cd "$ROOT/.." && pwd)/ui-kit}"
COPY_INTO="$SRC/scripts/copy-into.mjs"
DEST="$ROOT/ui-kit"
THEME_DEST="$ROOT/macos/Sources/IDEF0Modeler/SCTheme.swift"

mode="refresh"
[ "${1:-}" = "--check" ] && mode="check"

if [ "$mode" = "check" ] && [ "${SKIP_UI_KIT_CHECK:-0}" = "1" ]; then
  echo "ui-kit check: skipped (SKIP_UI_KIT_CHECK=1)"
  exit 0
fi

if [ ! -f "$COPY_INTO" ]; then
  if [ "$mode" = "check" ]; then
    echo "ui-kit check: skipped, no kit at $SRC (the vendored copy is all this repo needs)"
    exit 0
  fi
  echo "no UI kit at $SRC — set UI_KIT_SRC to its checkout" >&2
  exit 2
fi

if [ "$mode" = "check" ]; then
  status=0
  node "$COPY_INTO" --check "$DEST" || status=$?
  # The kit's own check knows nothing about the Mac target's copy.
  if ! cmp -s "$DEST/swift/SCTheme.swift" "$THEME_DEST"; then
    echo "macos/Sources/IDEF0Modeler/SCTheme.swift differs from ui-kit/swift/SCTheme.swift"
    status=1
  fi
  [ "$status" -eq 0 ] || echo "run scripts/vendor-ui-kit.sh to refresh (SKIP_UI_KIT_CHECK=1 builds anyway)" >&2
  exit "$status"
fi

node "$COPY_INTO" "$DEST"
cp "$DEST/swift/SCTheme.swift" "$THEME_DEST"
echo "macos/Sources/IDEF0Modeler/SCTheme.swift: copied from ui-kit/swift"
