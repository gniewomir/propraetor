#!/usr/bin/env bash
# Offline tests: Cache TLS create-if-missing (ADR-0055 / #221).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=cache-tls-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/cache-tls-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cache-tls.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
DATA_ROOT="${TMP}/data"
USER_NAME=""

cache_tls_ensure || fail "CA/server ensure should succeed"
[[ -f "${DATA_ROOT}/ca/ca.crt" ]] || fail "expected CA cert"
[[ -f "${DATA_ROOT}/server/server.crt" ]] || fail "expected server cert"
# SAN DNS:cache
openssl x509 -noout -ext subjectAltName -in "${DATA_ROOT}/server/server.crt" 2>/dev/null \
  | grep -Fq 'DNS:cache' \
  || openssl x509 -text -noout -in "${DATA_ROOT}/server/server.crt" | grep -Fq 'DNS:cache' \
  || fail "expected server SAN DNS:cache"
pass "CA + server create-if-missing (SAN DNS:cache)"

cache_tls_ensure_admin_client "cacheadmin" || fail "admin client ensure should succeed"
[[ -f "${DATA_ROOT}/admin/client.crt" ]] || fail "expected admin client.crt"
[[ -f "${DATA_ROOT}/admin/client.key" ]] || fail "expected admin client.key"
cn="$(openssl x509 -noout -subject -in "${DATA_ROOT}/admin/client.crt" | sed -n 's/.*CN *= *//p')"
[[ "${cn}" == "cacheadmin" ]] || fail "expected CN=cacheadmin, got '${cn}'"
pass "admin client cert CN=admin username"

# create-if-missing: second call must not rotate
cp "${DATA_ROOT}/admin/client.crt" "${TMP}/client.crt.bak"
cache_tls_ensure_admin_client "cacheadmin" || fail "second admin client ensure should noop"
cmp -s "${TMP}/client.crt.bak" "${DATA_ROOT}/admin/client.crt" \
  || fail "create-if-missing must not replace existing admin client cert"
pass "admin client cert create-if-missing is stable"

# CN mismatch fails closed
if cache_tls_ensure_admin_client "otheradmin" 2>"${TMP}/err-cn"; then
  fail "admin client CN mismatch must fail closed"
fi
grep -Eqi 'CN|admin|match' "${TMP}/err-cn" \
  || fail "CN mismatch rejection unclear: $(cat "${TMP}/err-cn")"
pass "admin client CN mismatch fails closed"

echo "All cache-tls-host offline tests passed."
