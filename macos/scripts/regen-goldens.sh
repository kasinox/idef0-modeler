#!/bin/sh
# Regenerate the Swift parity fixtures from the web app, headless.
#
#   macos/scripts/regen-goldens.sh
#
# Serves this checkout with fixture_server.py, loads goldens.html in headless
# Chrome, and waits for the page to report that every fixture was written.
# Regenerating re-rolls the sample's random ids; no Swift test depends on them.
#
# F86: fixture_server.py is pointed (via OUT) at a fresh temp staging
# directory rather than Fixtures itself, so a run that fails partway through
# never leaves Fixtures in a mixed state — the previous, known-good set stays
# untouched until a full run succeeds. Only then are the staged files diffed
# against Fixtures, summarised, and copied over.
#
# Exit status is non-zero if Chrome is missing, the page throws (including a
# rejected fixture POST or a failed idempotence check — both now throw instead
# of quietly posting '/__done/ok'), or the run does not finish in time.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIXTURES="$ROOT/macos/Tests/IDEF0CoreTests/Fixtures"
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
PORT=${PORT:-$((8200 + $$ % 700))}

if [ ! -x "$CHROME" ]; then
    echo "Chrome not found at $CHROME (set CHROME=/path/to/chrome)"
    exit 1
fi

LOG=$(mktemp -t goldens-server)
PROFILE=$(mktemp -d -t goldens-chrome)
STAGE=$(mktemp -d -t goldens-stage)

# Only removed on a successful, copied run; kept otherwise so a failure can be
# inspected (see the "regeneration failed" message below).
KEEP_STAGE=1
cleanup() {
    kill "${BROWSER:-}" "$SERVER" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$PROFILE" "$LOG"
    [ "$KEEP_STAGE" = 0 ] && rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

PORT=$PORT OUT=$STAGE python3 "$ROOT/macos/scripts/fixture_server.py" >"$LOG" 2>&1 &
SERVER=$!

i=0
until grep -q "Serving" "$LOG"; do
    i=$((i + 1)); [ $i -gt 50 ] && { echo "fixture server did not start:"; cat "$LOG"; exit 1; }
    sleep 0.1
done

"$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" "http://localhost:$PORT/macos/scripts/goldens.html" >/dev/null 2>&1 &
BROWSER=$!

i=0
until grep -q "GOLDENS-DONE" "$LOG"; do
    i=$((i + 1)); [ $i -gt 600 ] && { echo "goldens.html did not finish within 60s:"; cat "$LOG"; exit 1; }
    sleep 0.1
done

grep "POST /__fixture/" "$LOG" | sed -E 's#.*"POST /__fixture/([^ ]+) HTTP/[0-9.]+" ([0-9]+) .*#\2 \1#' \
    | while read -r status name; do
        if [ "$status" = "200" ]; then echo "staged $name"; else echo "rejected $name ($status)"; fi
    done

if ! grep -q "GOLDENS-DONE ok" "$LOG"; then
    echo "--- regeneration failed ---"
    sed -n '/GOLDENS-DONE/,$p' "$LOG"
    echo "staged files (if any) kept for inspection at $STAGE"
    exit 1
fi

n=$(find "$STAGE" -type f | wc -l | tr -d ' ')
if [ "$n" -eq 0 ]; then
    echo "the page reported success but staged nothing; something is wrong with fixture_server.py or OUT=$STAGE"
    exit 1
fi

echo "--- diff against committed Fixtures ($n staged file(s)) ---"
changed=0
for f in "$STAGE"/*; do
    name=$(basename "$f")
    if [ -f "$FIXTURES/$name" ] && cmp -s "$f" "$FIXTURES/$name"; then
        echo "same:    $name"
    else
        echo "changed: $name"
        changed=$((changed + 1))
    fi
done

mkdir -p "$FIXTURES"
cp "$STAGE"/* "$FIXTURES/"
KEEP_STAGE=0
grep "GOLDENS-DONE" "$LOG"
echo "copied $n file(s) into $FIXTURES ($changed changed, $((n - changed)) unchanged)"
exit 0
