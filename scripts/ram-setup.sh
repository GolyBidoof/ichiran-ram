#!/bin/bash
# ram-setup.sh - one command to build the RAM dictionary and a serving core.
#
#   ./scripts/ram-setup.sh
#
# It does four things, in order, and stops if any of them fails:
#   1. checks that SBCL, quicklisp and the database are reachable
#   2. writes the dictionary snapshots          (local-env/*.snap)
#   3. bakes the serving core                   (local-env/ichiran-serving.core)
#   4. proves it works by romanizing a sentence from the core, with deliberately
#      wrong database credentials, so a silent fallback to PostgreSQL fails
#
# Afterwards the normal commands pick all of this up automatically:
#   ./scripts/serve-system.sh              # stdin -> romanize, parallel, no DB
#   ./scripts/ram-cli.sh -i "一覧は最高だぞ"  # the CLI on the baked dictionary
#
# Knobs:
#   PRESET=lite      smaller dictionary (kana + senses, ~3.3GB) for an 8-16GB machine
#   FORCE=1          rebuild even if the artifacts are already there
#   SKIP_SNAPSHOT=1  skip step 2      SKIP_CORE=1  skip step 3
#   SKIP_DB_CHECK=1  skip the reachability check in step 1
#   SNAP_OUT=... SENSE_OUT=... CORE_OUT=...  where the artifacts go
set -e
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

PRESET="${PRESET:-full-ram}"
SNAP_OUT="${SNAP_OUT:-local-env/ichiran-int.snap}"
SENSE_OUT="${SENSE_OUT:-local-env/ichiran-sense.snap}"
CORE_OUT="${CORE_OUT:-local-env/ichiran-serving.core}"
DB_HOST="${ICHIRAN_DB_HOST:-localhost}"
DB_USER="${ICHIRAN_DB_USER:-jmdict}"
DB_PASS="${ICHIRAN_DB_PASSWORD:-password}"
DB_NAME="${ICHIRAN_DB_NAME:-jmdict}"

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf '\nram-setup: %s\n' "$*" >&2; exit 2; }

total_ram_gb() {
  if [ -r /proc/meminfo ]; then
    awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}'
  else
    echo 0
  fi
}

# ---------------------------------------------------------------- 1. preflight
step "checking the environment"

if [ ! -x scripts/sbcl-wrapped ]; then
  die "scripts/sbcl-wrapped is missing or not executable"
fi
if ! scripts/sbcl-wrapped --non-interactive \
       --eval '(format t "SETUP_SBCL_OK~%")' 2>/dev/null | grep -q "SETUP_SBCL_OK"; then
  die "SBCL or quicklisp is not usable. Run this to see the details:
  scripts/sbcl-wrapped --non-interactive --eval '(print :ok)'
  Install SBCL and quicklisp, or point the wrapper at them with SBCL=/path/to/sbcl."
fi
say "  SBCL and quicklisp: ok"

if [ "${SKIP_DB_CHECK:-}" != "1" ]; then
  if command -v psql >/dev/null 2>&1; then
    if PGPASSWORD="$DB_PASS" PGCONNECT_TIMEOUT=5 psql -h "$DB_HOST" -U "$DB_USER" \
         -d "$DB_NAME" -tAc 'select 1' >/dev/null 2>&1; then
      say "  database $DB_NAME on $DB_HOST: ok"
    else
      die "cannot reach the database $DB_NAME on $DB_HOST as $DB_USER.
  The snapshot is built from it, so a live database is required for this step.
  Set ICHIRAN_DB_NAME, ICHIRAN_DB_USER, ICHIRAN_DB_PASSWORD and ICHIRAN_DB_HOST,
  start PostgreSQL, or pass SKIP_DB_CHECK=1 to try anyway."
    fi
  else
    say "  psql not found, skipping the database check"
  fi
fi

RAM_GB="$(total_ram_gb)"
if [ "$PRESET" = "full-ram" ] && [ "$RAM_GB" != "0" ] && [ "$RAM_GB" -lt 14 ] 2>/dev/null; then
  die "the full dictionary needs about 16GB of RAM and this machine reports ${RAM_GB}GB.
  Re-run with a smaller dictionary:   PRESET=lite ./scripts/ram-setup.sh"
fi
say "  preset: $PRESET${RAM_GB:+ (${RAM_GB}GB of RAM detected)}"

# ----------------------------------------------------------------- 2. snapshot
step "building the dictionary snapshot"
if [ "${SKIP_SNAPSHOT:-}" = "1" ]; then
  say "  skipped (SKIP_SNAPSHOT=1)"
elif [ -f "$SNAP_OUT" ] && [ -f "$SENSE_OUT" ] && [ "${FORCE:-}" != "1" ]; then
  say "  reusing $SNAP_OUT and $SENSE_OUT (FORCE=1 to rebuild)"
else
  say "  reading the dictionary from PostgreSQL, this takes a few minutes"
  OUT="$SNAP_OUT" SENSE_OUT="$SENSE_OUT" ./scripts/build-snapshot.sh || \
    die "the snapshot build failed, see the output above"
  say "  wrote $SNAP_OUT and $SENSE_OUT"
fi

# --------------------------------------------------------------------- 3. core
step "baking the serving core"
if [ "${SKIP_CORE:-}" = "1" ]; then
  say "  skipped (SKIP_CORE=1)"
elif [ -f "$CORE_OUT" ] && [ "${FORCE:-}" != "1" ]; then
  say "  reusing $CORE_OUT (FORCE=1 to rebuild)"
else
  say "  this is the long step, a few minutes"
  PRESET="$PRESET" SYSTEM=1 ./scripts/build-image.sh --out "$CORE_OUT" || \
    die "the core build failed, see the output above"
  say "  wrote $CORE_OUT"
fi

# ---------------------------------------------------------------- 4. self-test
step "checking that it works"
if [ ! -f "$CORE_OUT" ]; then
  say "  no core to test (SKIP_CORE=1): the snapshot alone is ready"
  say "  serve it with ./scripts/serve-snapshot.sh"
  exit 0
fi
say "  romanizing one sentence from the core with wrong database credentials"
out="$(ICHIRAN_DB_USER=ram_setup_self_test ICHIRAN_DB_PASSWORD=wrong \
       CORE="$CORE_OUT" ./scripts/ram-cli.sh "一覧は最高だぞ" 2>&1)" || {
  printf '%s\n' "$out" >&2
  die "the core did not answer. It is at $CORE_OUT; the output above says why."
}
case "$out" in
  *"ichiran wa"*)
    say "  answered: $(printf '%s\n' "$out" | grep -a "ichiran wa" | head -1)" ;;
  *) printf '%s\n' "$out" >&2
     die "the core answered, but not with the expected romanization" ;;
esac

# --------------------------------------------------------------------- summary
step "done"
say "  core:     $CORE_OUT ($(LC_ALL=C du -h "$CORE_OUT" | cut -f1))"
[ -f "$SNAP_OUT" ] && say "  snapshot: $SNAP_OUT ($(LC_ALL=C du -h "$SNAP_OUT" | cut -f1))"
say ""
say "  Serve it (one text per line on stdin, one result per line on stdout):"
say "    ./scripts/serve-system.sh"
say ""
say "  Or use the CLI on it, exactly like ichiran-cli:"
say "    ./scripts/ram-cli.sh -i \"一覧は最高だぞ\""
say "    ./scripts/ram-cli.sh -f -l 5 \"一覧は最高だぞ\""
say ""
say "  Neither needs PostgreSQL while it runs."
