#!/bin/bash
# ram-parity.sh - require the RAM path's output to be byte-identical to the
# database baseline over the whole golden corpus.
#
# Why this exists: golden-snapshot.sh loads only :ichiran and :ichiran/cli, so
# data/golden-corpus-baseline.json captures the DATABASE path. Nothing
# compared the RAM path against it over the corpus, which left the central
# claim of the RAM work ("same answers, no database") verified only by the
# unit tests and by spot checks on individual lookups. This closes that gap.
#
# Exit 0 = RAM output byte-identical to the baseline. Non-zero = drift.
set -e
cd "$(dirname "$0")/.." || exit 1
BASE="data/golden-corpus-baseline.json"
CUR="$(mktemp /tmp/ram-parity.XXXXXXXX)" || {
  echo "RAM_PARITY_ERROR: mktemp failed"
  exit 2
}
trap 'rm -f "$CUR"' EXIT INT TERM
SNAP="${SNAPSHOT:-local-env/ichiran-int.snap}"

cat > /tmp/ichiran-ram-parity.lisp <<'EOF'
(in-package :cl-user)

(defun main ()
  (let* ((out (uiop:getenv "RAM_PARITY_OUT"))
         (snap (uiop:getenv "RAM_PARITY_SNAP"))
         (sense (or (uiop:getenv "RAM_PARITY_SENSE") "local-env/ichiran-sense.snap"))
         (extras (or (uiop:getenv "ICHIRAN_BAKE_SNAP") "local-env/ichiran-bake.snap"))
         ;; The integer layer, the compact sense layer, and the three sets the
         ;; snapshot format does not carry, exactly as the serving path loads
         ;; them. With the last two files present nothing here needs a database,
         ;; so this gate does not open a socket either: it is the RAM path being
         ;; tested, and a database on the side would only be able to hide a
         ;; lookup that still reaches for one.
         (dbless (and (probe-file sense) (probe-file extras) (fboundp 'ichiran/serve-parallel:load-bake-extras))))
    (let ((ichiran/conn::*no-database* dbless))
      (ichiran/conn:with-db nil
        (ichiran/memdict-compact:memdict-load-int :snapshot snap)
        (if (probe-file sense)
            (ichiran/memdict-compact:memdict-load-sense-snapshot
             sense :int-snapshot snap)
            (ichiran/memdict-compact:memdict-load
             :chunk 200000 :tables '("sense" "gloss" "sense_prop")))
        (when dbless
          (ichiran/serve-parallel:load-bake-extras extras))
        (setf ichiran/dict::*memdict-p* t)))
    (when dbless
      (setf ichiran/conn::*no-database* t))
    ;; settle lazy caches, and wait out the suffix cache's background builder
    (ichiran:romanize "テスト")
    (ignore-errors (ichiran/dict::ensure-suffixes-ready))
    (with-open-file (corpus (asdf:system-relative-pathname :ichiran "data/golden-corpus.txt"))
      (with-open-file (res (merge-pathnames out
                                            (asdf:system-relative-pathname :ichiran "."))
                           :direction :output :if-exists :supersede)
        (loop for line = (read-line corpus nil nil)
              while line
              for text = (string-trim '(#\Space #\Tab #\Newline) line)
              unless (or (zerop (length text)) (char= (char text 0) #\#))
                do (let ((val (handler-case (ichiran:romanize* text :limit 5)
                                (error (e) (list :error (princ-to-string e))))))
                     (princ (jsown:to-json val) res)
                     (terpri res))))))
  (format t "RAM_PARITY_DUMP_OK~%"))
EOF

if [ ! -f "$SNAP" ]; then
  echo "RAM_PARITY_ERROR: no snapshot at $SNAP (run scripts/build-snapshot.sh)"
  exit 2
fi

echo "== ram-parity.sh: dumping golden corpus through the RAM path =="
RAM_PARITY_OUT="$CUR" RAM_PARITY_SNAP="$SNAP" \
scripts/sbcl-wrapped --dynamic-space-size 14336 --non-interactive \
  --eval '(ql:quickload (list :ichiran :ichiran/cli) :silent t)' \
  --load src/memdict-compact.lisp \
  --load src/memdict-int.lisp \
  --load src/memdict-compact-shims.lisp \
  --load src/int-snapshot.lisp \
  --load src/sense-snapshot.lisp \
  --load src/serve-parallel.lisp \
  --load src/bake-extras.lisp \
  --load /tmp/ichiran-ram-parity.lisp \
  --eval '(main)' 2>&1 | tail -3

if [ ! -f "$BASE" ]; then
  echo "RAM_PARITY_ERROR: no baseline at $BASE"
  exit 2
fi

if cmp -s "$BASE" "$CUR"; then
  echo "RAM_PARITY_OK: RAM output byte-identical to the database baseline"
  exit 0
fi

trap - EXIT INT TERM
echo "RAM_PARITY_DRIFT: RAM output differs from the database baseline!"
echo "  baseline: $BASE"
echo "  current : $CUR (kept for inspection)"
exit 1
