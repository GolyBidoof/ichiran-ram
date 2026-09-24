#!/bin/bash
# db-available.sh - is the PostgreSQL that ichiran expects reachable?
#
# The database-only gates (parity.sh, golden-diff.sh) use this so they can skip
# with a clear message instead of failing when there is no database around. The
# RAM gate, scripts/ram-parity.sh, needs nothing from here and never calls it.
#
# Exit 0 = reachable. Exit 1 = not reachable, or no client tool to ask with.
#
# The connection comes from the same variables the Lisp reads: ICHIRAN_DB_NAME,
# ICHIRAN_DB_USER, ICHIRAN_DB_PASSWORD, ICHIRAN_DB_HOST. There is deliberately no
# port variable, because the Lisp does not read one, and honouring one here would
# report a database the analyzer would never find.
set -u

HOST="${ICHIRAN_DB_HOST:-localhost}"
NAME="${ICHIRAN_DB_NAME:-jmdict}"
USER="${ICHIRAN_DB_USER:-jmdict}"
PASS="${ICHIRAN_DB_PASSWORD:-password}"

command -v psql >/dev/null 2>&1 || exit 1

PGPASSWORD="$PASS" PGCONNECT_TIMEOUT=3 psql -h "$HOST" -U "$USER" -d "$NAME" \
  -tAc 'select 1' >/dev/null 2>&1
