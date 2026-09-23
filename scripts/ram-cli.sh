#!/bin/bash
# ram-cli.sh - the ichiran command line, running on the baked core.
#
# Same options as ichiran-cli, but the dictionary is already inside the core, so
# there is no dictionary load and no database:
#
#   ./scripts/ram-cli.sh -i "一覧は最高だぞ"        # romanization + word info
#   ./scripts/ram-cli.sh -f -l 5 "一覧は最高だぞ"   # full split as JSON
#   ./scripts/ram-cli.sh "一覧は最高だぞ"           # romanization only
#   ./scripts/ram-cli.sh -e '(+ 1 2)'              # evaluate Lisp
#
# The core is built by scripts/ram-setup.sh. Override its path with CORE=...
set -e
cd "$(dirname "$0")/.." || exit 1
CORE="${CORE:-local-env/ichiran-serving.core}"

if [ ! -f "$CORE" ]; then
  echo "ram-cli.sh: no core at $CORE" >&2
  echo "  build one with: ./scripts/ram-setup.sh" >&2
  echo "  or use the database path: ichiran-cli $*" >&2
  exit 2
fi

# The arguments travel through a file, so shell quoting never has to survive a
# trip through Lisp.
ARGS="$(mktemp /tmp/ram-cli-args.XXXXXXXX)" || exit 2
trap 'rm -f "$ARGS"' EXIT INT TERM
printf '%s\n' "$@" > "$ARGS"

exec scripts/sbcl-wrapped --core "$CORE" --non-interactive \
  --eval '(ql:quickload :ichiran/cli :silent t)' \
  --eval "(setf sb-ext:*posix-argv*
                (cons \"ichiran-cli\"
                      (with-open-file (s \"$ARGS\")
                        (loop for line = (read-line s nil nil)
                              while line collect line))))" \
  --eval '(ichiran/cli::main)' \
  --eval '(sb-ext:quit)'
