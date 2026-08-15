#!/usr/bin/env bash
# Offline contract: Cache Setup ready-wait fails closed on unit failed (ADR-0055 / #221).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETUP="${REPO_ROOT}/internals/host-scripts/lib/cache-setup-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "${SETUP}" ]] || fail "missing ${SETUP}"

grep -Fq 'ActiveState' "${SETUP}" \
  || fail "cache_wait_ready must observe cache-valkey ActiveState"
grep -Fq 'cache-valkey.service failed before ready' "${SETUP}" \
  || fail "cache_wait_ready must fail closed on ActiveState=failed"
grep -Fq 'NetworkAlias=cache' \
  "${REPO_ROOT}/internals/components/cache/systemd/cache.pod" \
  || fail "cache.pod must NetworkAlias=cache"
if grep -Eq '^PublishPort=' \
  "${REPO_ROOT}/internals/components/cache/systemd/cache.pod"; then
  fail "cache.pod must not PublishPort"
fi

echo "All cache-setup-host offline tests passed."
