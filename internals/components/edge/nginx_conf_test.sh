#!/usr/bin/env bash
# Unit Test: Edge nginx.conf Platform journal emit contract (ADR-0050 / #194).
# Asserts Component source SoT — no live Host / journal round-trip.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CONF="${REPO_ROOT}/internals/components/edge/nginx.conf"
QUADLET="${REPO_ROOT}/internals/components/edge/quadlets/edge-nginx.container"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${CONF}" ]] || fail "missing ${CONF}"
[[ -f "${QUADLET}" ]] || fail "missing ${QUADLET}"

# Strip comments for directive checks.
body="$(grep -vE '^[[:space:]]*#' "${CONF}" || true)"

printf '%s\n' "${body}" | grep -Eq 'error_log[[:space:]]+/dev/stderr([[:space:]]|$)' \
  || fail "error_log must target /dev/stderr (Platform journal)"
pass "error_log → /dev/stderr"

printf '%s\n' "${body}" | grep -Eq 'access_log[[:space:]]+off[[:space:]]*;' \
  || fail "access_log must be off by default"
pass "access_log off"

# Any error_log / access_log target other than /dev/stderr or off is a file destination.
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -n "${line}" ]] || continue
  if printf '%s\n' "${line}" | grep -Eq 'error_log[[:space:]]+' \
    && ! printf '%s\n' "${line}" | grep -Eq 'error_log[[:space:]]+/dev/stderr([[:space:]]|$)'; then
    fail "non-stderr error_log: ${line}"
  fi
  if printf '%s\n' "${line}" | grep -Eq 'access_log[[:space:]]+' \
    && ! printf '%s\n' "${line}" | grep -Eq 'access_log[[:space:]]+off[[:space:]]*;'; then
    fail "access_log not off: ${line}"
  fi
done <<<"${body}"
pass "no file log destinations on error_log/access_log"

if grep -Fi 'Volume=' "${QUADLET}" | grep -Fq '/var/log'; then
  fail "edge-nginx.container must not mount /var/log paths"
fi
pass "edge-nginx.container has no /var/log mounts"

echo "All Edge nginx Platform journal emit checks passed."
