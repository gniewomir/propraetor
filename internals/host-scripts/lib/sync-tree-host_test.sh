#!/usr/bin/env bash
# Unit tests: sync_tree_inplace preserves dest directory/file inodes (#155)
# and owner Persist (ADR-0054 / #215).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=sync-tree-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/sync-tree-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

inode_of() {
  local path="$1"
  if stat -f %i "${path}" >/dev/null 2>&1; then
    stat -f %i "${path}"
  else
    stat -c %i "${path}"
  fi
}

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/sync-tree.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/src" "${TMP}/dest"
printf 'old\n' >"${TMP}/dest/nginx.conf"
printf 'keep-me\n' >"${TMP}/dest/stale.txt"
printf 'new\n' >"${TMP}/src/nginx.conf"
printf 'extra\n' >"${TMP}/src/extra.conf"
dir_ino="$(inode_of "${TMP}/dest")"
file_ino="$(inode_of "${TMP}/dest/nginx.conf")"

sync_tree_inplace "${TMP}/src" "${TMP}/dest" || fail "sync_tree_inplace failed"

[[ "$(inode_of "${TMP}/dest")" == "${dir_ino}" ]] || fail "dest directory inode changed"
[[ "$(inode_of "${TMP}/dest/nginx.conf")" == "${file_ino}" ]] || fail "nginx.conf inode changed"
grep -Fxq 'new' "${TMP}/dest/nginx.conf" || fail "nginx.conf not updated"
[[ -f "${TMP}/dest/extra.conf" ]] || fail "extra.conf not added"
[[ ! -e "${TMP}/dest/stale.txt" ]] || fail "stale.txt not pruned"
pass "sync_tree_inplace updates in place, adds, and prunes"

# --- Persist under dest survives sync; source persist fails closed ---
mkdir -p "${TMP}/persist-src" "${TMP}/persist-dest/persist/nested"
printf 'durable\n' >"${TMP}/persist-dest/persist/nested/state.bin"
printf 'soT\n' >"${TMP}/persist-dest/manifest.json"
printf 'soT-new\n' >"${TMP}/persist-src/manifest.json"
printf 'gone\n' >"${TMP}/persist-dest/stale-sot.txt"

sync_tree_inplace "${TMP}/persist-src" "${TMP}/persist-dest" \
  || fail "sync with dest Persist must succeed"
grep -Fxq 'soT-new' "${TMP}/persist-dest/manifest.json" || fail "SoT not updated"
[[ ! -e "${TMP}/persist-dest/stale-sot.txt" ]] || fail "non-Persist stale not pruned"
grep -Fxq 'durable' "${TMP}/persist-dest/persist/nested/state.bin" \
  || fail "Persist bytes must survive sync"
pass "sync_tree_inplace preserves dest persist/"

mkdir -p "${TMP}/bad-src/persist"
printf 'nope\n' >"${TMP}/bad-src/persist/x"
mkdir -p "${TMP}/bad-dest"
if sync_tree_inplace "${TMP}/bad-src" "${TMP}/bad-dest" 2>"${TMP}/bad-err"; then
  fail "source persist/ must fail closed"
fi
grep -Eqi 'persist' "${TMP}/bad-err" \
  || fail "source persist rejection unclear: $(cat "${TMP}/bad-err")"
pass "sync_tree_inplace rejects source persist/"

echo "All sync-tree-host offline tests passed."
