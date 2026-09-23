#!/bin/bash
# bench-vn.sh [ram|db] - cold-start benchmark over the corpus in CORPUS
# (default data/golden-corpus.txt; point it at your own text for throughput runs).
# Reports system load, dictionary load, the first (cold) pass, and best-of-3,
# so the cost of STARTING is visible separately from the cost of READING.
cd "$(dirname "$0")/.." || exit 1
MODE="${1:-ram}"
exec env MODE="$MODE" ./scripts/sbcl-wrapped \
  --dynamic-space-size "$([ "$MODE" = ram ] && echo 14336 || echo 4096)" \
  --non-interactive --load scripts/bench-vn.lisp --eval '(main)'
