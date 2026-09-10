#!/usr/bin/env bash
# Headless screenshot wrapper for Mac node agents.
# Silences Edge CVDisplayLink noise; prints one success line.
set -euo pipefail

usage() {
  echo "usage: shot.sh <output.png> [url]" >&2
  echo "  default url: about:blank" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
OUT="$1"
URL="${2:-about:blank}"

EDGE="${SHOT_EDGE:-/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge}"
if [[ ! -x "$EDGE" ]]; then
  echo "SHOT_FAIL edge not found at $EDGE" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# stderr discarded on purpose: Edge headless floods CVDisplayLinkCreateWithCGDisplay failed
"$EDGE" --headless=new --disable-gpu --window-size=1280,720 --screenshot="$OUT" "$URL" >/dev/null 2>/dev/null || {
  echo "SHOT_FAIL edge exited non-zero" >&2
  exit 1
}

if [[ ! -f "$OUT" ]]; then
  echo "SHOT_FAIL missing png: $OUT" >&2
  exit 1
fi

BYTES=$(wc -c <"$OUT" | tr -d ' ')
if [[ "$BYTES" -le 0 ]]; then
  echo "SHOT_FAIL empty png: $OUT" >&2
  exit 1
fi

W=$(sips -g pixelWidth "$OUT" 2>/dev/null | awk '/pixelWidth/ {print $2}')
H=$(sips -g pixelHeight "$OUT" 2>/dev/null | awk '/pixelHeight/ {print $2}')
if [[ -z "${W:-}" || -z "${H:-}" ]]; then
  echo "SHOT_FAIL could not read dimensions for $OUT" >&2
  exit 1
fi

echo "SHOT_OK $OUT $BYTES ${W}x${H}"
