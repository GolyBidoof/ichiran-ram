#!/bin/bash
# fetch-dictionary.sh - download the prebuilt dictionary instead of building it.
#
#   ./scripts/fetch-dictionary.sh             # the snapshots (platform independent)
#   ./scripts/fetch-dictionary.sh --core      # a baked serving core as well
#
# The core is an SBCL image, so it only loads on the platform and SBCL version it
# was built for: the published one is macOS arm64 with SBCL 2.6.8, and it is the
# only artifact that needs no database at all. The snapshots are raw bytes and
# work on any platform, but today they still open a connection at boot for the
# lookups the RAM layer does not cover yet.
#
# Files land in local-env/ where every other script looks for them. Each download
# is checked against SHA256SUMS from the same release, and an interrupted
# download resumes where it stopped.
#
# Environment:
#   ICHIRAN_RELEASE=tag          release to read from (default dict-v1)
#   ICHIRAN_RELEASE_URL=base     override the whole download base
set -e

cd "$(dirname "$0")/.." || exit 1

TAG="${ICHIRAN_RELEASE:-dict-v1}"
BASE="${ICHIRAN_RELEASE_URL:-https://github.com/GolyBidoof/ichiran-ram/releases/download/$TAG}"

want_core=0
for arg in "$@"; do
  case "$arg" in
    --core|--all) want_core=1 ;;
    --snapshots) want_core=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "fetch-dictionary.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done

assets="ichiran-int.snap.gz ichiran-sense.snap.gz"
[ "$want_core" = 1 ] && assets="$assets ichiran-serving.core.gz"

mkdir -p local-env
cd local-env

echo "== fetch-dictionary.sh: $TAG"
if [ ! -f SHA256SUMS ]; then
  echo "  downloading SHA256SUMS"
  curl -fsSL -o SHA256SUMS "$BASE/SHA256SUMS"
fi

for asset in $assets; do
  plain="${asset%.gz}"
  if [ -f "$plain" ]; then
    echo "  $plain is already here, skipping"
    continue
  fi
  if [ ! -f "$asset" ]; then
    echo "  downloading $asset"
    curl -fL -C - --progress-bar -O "$BASE/$asset"
  else
    echo "  $asset already downloaded, resuming if incomplete"
    curl -fL -C - -s -O "$BASE/$asset" || true
  fi
  expected="$(awk -v a="$asset" '$2 == a {print $1}' SHA256SUMS)"
  actual="$(shasum -a 256 "$asset" | awk '{print $1}')"
  if [ -z "$expected" ]; then
    echo "  SHA256SUMS has no entry for $asset, cannot verify" >&2
    exit 1
  fi
  if [ "$expected" != "$actual" ]; then
    echo "  $asset failed its checksum" >&2
    echo "    expected $expected" >&2
    echo "    got      $actual" >&2
    echo "  Delete local-env/$asset and run again." >&2
    exit 1
  fi
  echo "  checksum ok, unpacking"
  gunzip -f "$asset"
done

echo "== done"
for f in ichiran-int.snap ichiran-sense.snap ichiran-serving.core; do
  [ -f "$f" ] && echo "  local-env/$f  $(LC_ALL=C du -h "$f" | cut -f1)"
done
cat <<'EOF'

Next:
  ./scripts/ichiran-cli -i "一覧は最高だぞ"     # a core is present
  ./scripts/serve-system.sh                    # one text per line, parallel
EOF
