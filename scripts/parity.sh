#!/bin/bash
# parity.sh — run the ichiran test suite (see tests.lisp). Exit 0 = parity green.
# Usage: parity.sh [--core FILE]
cd "$(dirname "$0")/.." || exit 1

timeout_sec="${PARITY_TIMEOUT:-1800}"
echo "== parity.sh: ichiran test suite (timeout ${timeout_sec}s) =="

scripts/sbcl-wrapped --non-interactive \
     --eval '(ql:quickload :ichiran :silent t)' \
     --eval '(in-package :ichiran/test)' \
     --eval "(format t \"~%== running (ichiran/test:run-all-tests) ==~%\")" \
     --eval '(handler-case (progn (ichiran/test:run-all-tests) (format t "~%PARITY_OK~%")) (error (e) (format t "~%PARITY_ERROR: ~a~%" e)))' \
     2>&1 | tail -60

echo "PARITY_SCRIPT_EXIT=${PIPESTATUS[0]}"
