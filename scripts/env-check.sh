#!/bin/bash
# env-check.sh — assert the perf-work environment is live. Exit 0 = ready.
set -e

echo "== SBCL ==";        command -v sbcl && sbcl --version | head -1
echo "== PostgreSQL ==";  command -v pg_ctl && /opt/homebrew/opt/postgresql@16/bin/pg_isready -h localhost
echo "== quicklisp ==";   ls -d "$HOME/quicklisp" 2>&1
echo "== ichiran symlink =="; ls -l "$HOME/quicklisp/local-projects/ichiran" 2>&1 | sed 's/.*ichiran -> /ichiran -> /'
echo "== pgdump restored =="; PGPASSWORD=password /opt/homebrew/opt/postgresql@16/bin/psql -h localhost -U jmdict -d jmdict -tAc "SELECT count(*) AS entries FROM entry;" 2>&1
echo "== settings.lisp =="; ls -l "$HOME/quicklisp/local-projects/ichiran/settings.lisp" 2>&1 || ls -l "$(pwd)/settings.lisp" 2>&1

echo "ENV_CHECK_DONE"
