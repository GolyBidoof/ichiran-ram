#!/bin/bash
# golden-diff.sh — diff current romanize* behavior against the baseline snapshot.
# Exit 0 = byte-identical to baseline (parity contract). Non-zero = drift.
# Usage: golden-diff.sh
cd "$(dirname "$0")/.." || exit 1
BASE="data/golden-corpus-baseline.json"
CUR="/tmp/golden-current.json"

./scripts/golden-snapshot.sh --out "$CUR" >/dev/null 2>&1

if [ ! -f "$BASE" ]; then
  echo "GOLDEN_DIFF_ERROR: no baseline at $BASE — run golden-snapshot.sh first"
  exit 2
fi

if cmp -s "$BASE" "$CUR"; then
  echo "GOLDEN_DIFF_OK: current output byte-identical to baseline"
  rm -f "$CUR"
  exit 0
else
  echo "GOLDEN_DIFF_DRIFT: output differs from baseline!"
  echo "  baseline: $BASE"
  echo "  current : $CUR (kept for inspection)"
  diff <(python3 -m json.tool "$BASE" 2>/dev/null) <(python3 -m json.tool "$CUR" 2>/dev/null) | head -40
  exit 1
fi
