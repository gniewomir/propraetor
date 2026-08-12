#!/usr/bin/env bash
# Unit Test: Edge nginx.conf Platform journal + Forwarded client identity (ADR-0050 / ADR-0052).
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

# Forwarded client identity (ADR-0052): overwrite bundle in http{}; no append helpers.
printf '%s\n' "${body}" | grep -Eq 'proxy_set_header[[:space:]]+Host[[:space:]]+\$host' \
  || fail "missing proxy_set_header Host \$host"
printf '%s\n' "${body}" | grep -Eq 'proxy_set_header[[:space:]]+X-Real-IP[[:space:]]+\$remote_addr' \
  || fail "missing proxy_set_header X-Real-IP \$remote_addr"
printf '%s\n' "${body}" | grep -Eq 'proxy_set_header[[:space:]]+X-Forwarded-For[[:space:]]+\$remote_addr' \
  || fail "missing proxy_set_header X-Forwarded-For \$remote_addr (overwrite)"
printf '%s\n' "${body}" | grep -Eq 'proxy_set_header[[:space:]]+X-Forwarded-Proto[[:space:]]+\$scheme' \
  || fail "missing proxy_set_header X-Forwarded-Proto \$scheme"
printf '%s\n' "${body}" | grep -Eq 'proxy_set_header[[:space:]]+X-Forwarded-Host[[:space:]]+\$host' \
  || fail "missing proxy_set_header X-Forwarded-Host \$host"
printf '%s\n' "${body}" | grep -Eq 'proxy_set_header[[:space:]]+Forwarded[[:space:]]+' \
  || fail "missing proxy_set_header Forwarded (RFC 7239)"
printf '%s\n' "${body}" | grep -Eq 'map[[:space:]]+\$remote_addr[[:space:]]+\$forwarded_client_for' \
  || fail "missing map \$remote_addr \$forwarded_client_for for RFC 7239 for= quoting"
if printf '%s\n' "${body}" | grep -Eq '\$proxy_add_x_forwarded_for|\$proxy_add_forwarded'; then
  fail "must not append inbound forwarded headers (\$proxy_add_*)"
fi
pass "Forwarded client identity overwrite bundle present; no append helpers"

echo "All Edge nginx Platform journal + Forwarded client identity checks passed."
