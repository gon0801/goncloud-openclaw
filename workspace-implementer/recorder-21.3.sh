#!/bin/sh
# 21.3 recorder shim: pure recorder, no gate, no mutation.
OUT="${REC_OUT:-/Users/dn/lab-21.3/capturas}"
mkdir -p "$OUT"
N=$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')
BODY=$(cat)
MEAS=$(printf 'cwd=%s\ntoplevel=%s\ngitdir=%s\ncommondir=%s\nhead=%s\n' "$PWD" "$(git rev-parse --show-toplevel 2>/dev/null)" "$(git rev-parse --git-dir 2>/dev/null)" "$(git rev-parse --git-common-dir 2>/dev/null)" "$(git rev-parse HEAD 2>/dev/null)")
{
  printf '=== payload %s event=%s ===\n' "$N" "$1"
  printf '%s\n' "$BODY"
  printf '--- measured at hook cwd ---\n%s\n' "$MEAS"
} > "$OUT/payload-$(printf '%02d' $N)-$1.json"
exit 0
