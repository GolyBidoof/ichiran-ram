#!/bin/bash
# warm.sh — control a single long-lived warmed ichiran process, so measurements
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
  # a writer that never closes, so the server's stdin does not hit EOF
  sleep 100000 > "$FIFO" &
  echo $! > "$HOLDF"
  ./scripts/sbcl-wrapped --dynamic-space-size 14336 --non-interactive \
    --load scripts/warm-server.lisp < "$FIFO" >> "$OUT" 2>&1 &
  echo $! > "$PIDF"
  echo "booting pid $(cat "$PIDF"); waiting for WARM-READY ..."
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
  local before after want
  before=$(grep -ac "WARM-RESULT" "$OUT" 2>/dev/null | head -1)
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
