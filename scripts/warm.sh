#!/bin/bash
# warm.sh - control a single long-lived warmed ichiran process, so measurements
# cost seconds instead of paying Quicklisp + dictionary load every time.
#
#   warm.sh start          boot the server (takes ~15s, once)
#   warm.sh send '<form>'  evaluate a form, print its result
#   warm.sh status         is it up?
#   warm.sh stop
#
# Results are appended to local-env/scratch/warm.out; send waits for the
# numbered WARM-RESULT line that answers its request.
set -u
cd "$(dirname "$0")/.." || exit 1
FIFO=local-env/scratch/warm.fifo
OUT=local-env/scratch/warm.out
PIDF=local-env/scratch/warm.pid
HOLDF=local-env/scratch/warm.hold.pid

start() {
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDF"))"; return 0
  fi
  rm -f "$FIFO"; mkfifo "$FIFO" || exit 1
  : > "$OUT"
  # Both the server and the writer that keeps its stdin open are started in
  # their OWN sessions. Starting them as children of the calling shell means an
  # aborted or timed-out call kills the process group, and a dead listener
  # turns every later request into a full-length wait.
  python3 - "$FIFO" "$OUT" "$PIDF" "$HOLDF" <<'PYEOF'
import os, subprocess, sys
fifo, out, pidf, holdf = sys.argv[1:5]
# Prefer the baked core when one has been built: it already contains the
# analyzer and the whole dictionary, so the server reaches WARM-READY in about
# a second and needs no database, instead of re-reading the snapshot and the
# sense layer on every start. WARM_NO_CORE=1 forces the old path.
core = os.environ.get("ICHIRAN_CORE", "local-env/ichiran-serving.core")
if os.path.exists(core) and os.environ.get("WARM_NO_CORE") != "1":
    argv = ["./scripts/sbcl-wrapped", "--core", core, "--non-interactive",
            "--load", "scripts/warm-server.lisp"]
    print("using baked core", core)
else:
    argv = ["./scripts/sbcl-wrapped", "--dynamic-space-size", "14336",
            "--non-interactive", "--load", "scripts/warm-server.lisp"]
# The holder must not inherit stdout/stderr. It lives for ~27 hours, so if
# stdout is a pipe (warm.sh start | tail, or any caller capturing output) the
# pipe never reaches EOF and the caller blocks until the holder dies. That is
# a hang, not a slow start: it happened with a pipe and never without one.
holder = subprocess.Popen(["sh", "-c", "exec sleep 100000 > " + fifo],
                          stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL,
                          start_new_session=True)
open(holdf, "w").write(str(holder.pid))
log = open(out, "ab")
srv = subprocess.Popen(argv,
                       stdin=open(fifo, "r"), stdout=log, stderr=log,
                       start_new_session=True)
open(pidf, "w").write(str(srv.pid))
print("booting pid", srv.pid)
PYEOF
  echo "booting; waiting for WARM-READY ..."
  for _ in $(seq 1 240); do
    if grep -aq "WARM-READY" "$OUT" 2>/dev/null; then echo "ready"; return 0; fi
    if ! kill -0 "$(cat "$PIDF")" 2>/dev/null; then
      echo "server died during boot; tail of $OUT:"; tail -20 "$OUT"; return 1
    fi
    sleep 1
  done
  echo "timed out waiting for ready"; return 1
}

send() {
  [ -f "$PIDF" ] || { echo "not started"; return 1; }
  if ! kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "no warm server running (died or was killed); run: scripts/warm.sh start"
    return 1
  fi
  local before after want
  before=$(grep -ac "^WARM-RESULT-BEGIN" "$OUT" 2>/dev/null | head -1)
  want=$(( ${before:-0} + 1 ))
  printf '%s\n' "$1" > "$FIFO" || return 1
  for _ in $(seq 1 ${WARM_WAIT:-240}); do
    if grep -aq "^WARM-RESULT-END $want$" "$OUT" 2>/dev/null; then
      awk -v n="$want" '
        $0 == "WARM-RESULT-BEGIN " n { inb=1; next }
        $0 == "WARM-RESULT-END " n   { inb=0 }
        inb' "$OUT"
      return 0
    fi
    sleep 0.2
  done
  echo "timeout waiting for result $want"; return 1
}

case "${1:-}" in
  start) start ;;
  send)  send "$2" ;;
  status)
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
      echo "running pid $(cat "$PIDF")"
    else echo "not running"; fi ;;
  stop)
    [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
    [ -f "$HOLDF" ] && kill "$(cat "$HOLDF")" 2>/dev/null
    rm -f "$FIFO" "$PIDF" "$HOLDF"
    echo stopped ;;
  *) echo "usage: warm.sh {start|send '<form>'|status|stop}"; exit 2 ;;
esac
