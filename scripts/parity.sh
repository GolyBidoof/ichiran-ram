#!/bin/bash
# parity.sh - run the ichiran test suite (see tests.lisp). Exit 0 = parity green.
# Usage: parity.sh [--core FILE]
#
# This gate drives the analyzer against PostgreSQL, so it needs a database. With
# none reachable it skips and says so. The RAM path is covered by ram-parity.sh,
# which needs no database at all.
cd "$(dirname "$0")/.." || exit 1

if ! scripts/db-available.sh; then
  echo "PARITY_SKIPPED: no database reachable at ${ICHIRAN_DB_HOST:-localhost} (${ICHIRAN_DB_NAME:-jmdict})"
  echo "PARITY_SKIPPED: this gate runs the analyzer against PostgreSQL by design."
  echo "PARITY_SKIPPED: the RAM path is covered by ./scripts/ram-parity.sh instead."
  echo "PARITY_SCRIPT_EXIT=0"
  exit 0
fi

timeout_sec="${PARITY_TIMEOUT:-1800}"
echo "== parity.sh: ichiran test suite (timeout ${timeout_sec}s) =="

scripts/sbcl-wrapped --non-interactive \
     --eval '(ql:quickload :ichiran :silent t)' \
     --eval '(in-package :ichiran/test)' \
     --eval "(format t \"~%== running (ichiran/test:run-all-tests) ==~%\")" \
     --eval '(handler-case (progn (ichiran/test:run-all-tests) (format t "~%PARITY_OK~%")) (error (e) (format t "~%PARITY_ERROR: ~a~%" e)))' \
     2>&1 | tail -60

echo "PARITY_SCRIPT_EXIT=${PIPESTATUS[0]}"
