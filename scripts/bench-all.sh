#!/bin/bash
# bench-all.sh — final comparison: cold and warm, database vs RAM snapshot vs
# baked core, over every benchmark corpus. Reports wall time end to end (so the
# cost of STARTING is included) alongside the in-process numbers.
cd "$(dirname "$0")/.." || exit 1
CORPORA="${CORPORA:-data/golden-corpus.txt the visual-novel sample the visual-novel sample}"
echo "== corpus | path | wall-to-first-answer | best-of-3 | per-line =="
for corpus in $CORPORA; do
  for mode in db ram core; do
    out="local-env/scratch/benchall-$mode-$(basename "$corpus" .txt).log"
    if [ "$mode" = core ]; then
      /usr/bin/time -p env MODE=core CORPUS="$corpus" ./scripts/sbcl-wrapped \
        --core local-env/ichiran-serving.core --non-interactive \
        --load /tmp/corebench.lisp --eval '(main)' --eval '(sb-ext:quit)' > "$out" 2>&1
    else
      /usr/bin/time -p env MODE="$mode" CORPUS="$corpus" ./scripts/sbcl-wrapped \
        --dynamic-space-size "$([ "$mode" = db ] && echo 4096 || echo 14336)" \
        --non-interactive --load scripts/bench-vn.lisp --eval '(main)' > "$out" 2>&1
    fi
    line=$(grep -a "^RESULT\|^CORE " "$out" | tail -1)
    real=$(grep -a "^real" "$out" | tail -1 | awk '{print $2}')
    printf '%-22s %-5s %-8ss %s\n' "$(basename "$corpus")" "$mode" "${real:-?}" "$line"
    grep -a "^  runs=" "$out" | tail -1
  done
done
