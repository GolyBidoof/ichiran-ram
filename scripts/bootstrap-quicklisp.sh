#!/bin/bash
# bootstrap-quicklisp.sh - install a workspace copy of quicklisp.
#
# This is the only dependency the RAM path has beyond SBCL itself. Quicklisp is
# what fetches ichiran's Common Lisp libraries (cl-ppcre, postmodern and the
# rest); it is a one-time small download into local-env/quicklisp, and none of it
# needs a database.
#
#   ./scripts/bootstrap-quicklisp.sh
#
# QUICKLISP_HOME overrides the destination, SBCL overrides the sbcl binary.
set -e

cd "$(dirname "$0")/.." || exit 1

DEST="${QUICKLISP_HOME:-$PWD/local-env/quicklisp}"
if [ -f "$DEST/setup.lisp" ]; then
  echo "bootstrap-quicklisp.sh: $DEST already has setup.lisp, nothing to do"
  exit 0
fi

SBCL_BIN="${SBCL:-}"
if [ -z "$SBCL_BIN" ]; then
  if [ -x /opt/homebrew/bin/sbcl ]; then
    SBCL_BIN=/opt/homebrew/bin/sbcl
  else
    SBCL_BIN="$(command -v sbcl 2>/dev/null || true)"
  fi
fi
if [ -z "$SBCL_BIN" ] || [ ! -x "$SBCL_BIN" ]; then
  echo "bootstrap-quicklisp.sh: no sbcl found. Install SBCL, or set SBCL=/path/to/sbcl" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "bootstrap-quicklisp.sh: curl is needed to download the bootstrap file" >&2
  exit 1
fi

tmp="$(mktemp -d /tmp/quicklisp-bootstrap.XXXXXXXX)" || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "bootstrap-quicklisp.sh: downloading quicklisp.lisp"
if ! curl -fsSL -o "$tmp/quicklisp.lisp" https://beta.quicklisp.org/quicklisp.lisp; then
  echo "bootstrap-quicklisp.sh: download failed. Without a network, install quicklisp" >&2
  echo "  yourself and put it at $DEST, or at ~/quicklisp" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
echo "bootstrap-quicklisp.sh: installing into $DEST"
"$SBCL_BIN" --no-userinit --non-interactive \
  --load "$tmp/quicklisp.lisp" \
  --eval "(quicklisp-quickstart:install :path \"$DEST/\")" || exit 1

if [ ! -f "$DEST/setup.lisp" ]; then
  echo "bootstrap-quicklisp.sh: install finished but $DEST/setup.lisp is missing" >&2
  exit 1
fi
echo "bootstrap-quicklisp.sh: quicklisp installed at $DEST"
