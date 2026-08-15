#!/usr/bin/env bash
# Offline tests: shared Component mTLS ensure (ADR-0055 / #229).
# Proves dial+Persist parameterization, separate CAs, admin adapter branch.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=component-tls-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/component-tls-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/component-tls.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
USER_NAME=""

CACHE_PERSIST="${TMP}/cache"
DB_PERSIST="${TMP}/database"

component_tls_ensure cache "${CACHE_PERSIST}" || fail "cache CA/server ensure should succeed"
[[ -f "${CACHE_PERSIST}/ca/ca.crt" ]] || fail "expected cache CA cert"
[[ -f "${CACHE_PERSIST}/server/server.crt" ]] || fail "expected cache server cert"
openssl x509 -noout -ext subjectAltName -in "${CACHE_PERSIST}/server/server.crt" 2>/dev/null \
  | grep -Fq 'DNS:cache' \
  || openssl x509 -text -noout -in "${CACHE_PERSIST}/server/server.crt" | grep -Fq 'DNS:cache' \
  || fail "expected server SAN DNS:cache"
pass "cache CA + server create-if-missing (SAN DNS:cache)"

component_tls_ensure database "${DB_PERSIST}" || fail "database CA/server ensure should succeed"
[[ -f "${DB_PERSIST}/ca/ca.crt" ]] || fail "expected database CA cert"
[[ -f "${DB_PERSIST}/server/server.crt" ]] || fail "expected database server cert"
openssl x509 -noout -ext subjectAltName -in "${DB_PERSIST}/server/server.crt" 2>/dev/null \
  | grep -Fq 'DNS:database' \
  || openssl x509 -text -noout -in "${DB_PERSIST}/server/server.crt" | grep -Fq 'DNS:database' \
  || fail "expected server SAN DNS:database"
pass "database CA + server create-if-missing (SAN DNS:database)"

# Separate Persist roots ⇒ distinct CAs (share code, not CA — ADR-0055).
if cmp -s "${CACHE_PERSIST}/ca/ca.crt" "${DB_PERSIST}/ca/ca.crt"; then
  fail "Cache and Database Persist CAs must not be identical"
fi
cache_ca_cn="$(openssl x509 -noout -subject -in "${CACHE_PERSIST}/ca/ca.crt" | sed -n 's/.*CN *= *//p')"
db_ca_cn="$(openssl x509 -noout -subject -in "${DB_PERSIST}/ca/ca.crt" | sed -n 's/.*CN *= *//p')"
[[ "${cache_ca_cn}" == "propraetor-cache-ca" ]] || fail "expected cache CA CN, got '${cache_ca_cn}'"
[[ "${db_ca_cn}" == "propraetor-database-ca" ]] || fail "expected database CA CN, got '${db_ca_cn}'"
pass "Persist CAs remain separate per Component"

component_tls_ensure_admin_client cache "${CACHE_PERSIST}" "cacheadmin" \
  || fail "admin client ensure should succeed"
[[ -f "${CACHE_PERSIST}/admin/client.crt" ]] || fail "expected admin client.crt"
[[ -f "${CACHE_PERSIST}/admin/client.key" ]] || fail "expected admin client.key"
cn="$(openssl x509 -noout -subject -in "${CACHE_PERSIST}/admin/client.crt" | sed -n 's/.*CN *= *//p')"
[[ "${cn}" == "cacheadmin" ]] || fail "expected CN=cacheadmin, got '${cn}'"
pass "admin client cert CN=admin username"

# create-if-missing: second call must not rotate
cp "${CACHE_PERSIST}/admin/client.crt" "${TMP}/admin.crt.bak"
component_tls_ensure_admin_client cache "${CACHE_PERSIST}" "cacheadmin" \
  || fail "second admin client ensure should noop"
cmp -s "${TMP}/admin.crt.bak" "${CACHE_PERSIST}/admin/client.crt" \
  || fail "create-if-missing must not replace existing admin client cert"
pass "admin client cert create-if-missing is stable"

# CN mismatch fails closed
if component_tls_ensure_admin_client cache "${CACHE_PERSIST}" "otheradmin" 2>"${TMP}/err-cn"; then
  fail "admin client CN mismatch must fail closed"
fi
grep -Eqi 'CN|admin|match' "${TMP}/err-cn" \
  || fail "CN mismatch rejection unclear: $(cat "${TMP}/err-cn")"
pass "admin client CN mismatch fails closed"

component_tls_ensure_client cache "${CACHE_PERSIST}" "alpha" \
  || fail "cache client ensure should succeed"
[[ -f "${CACHE_PERSIST}/clients/alpha/client.crt" ]] || fail "expected cache client.crt"
cn="$(openssl x509 -noout -subject -in "${CACHE_PERSIST}/clients/alpha/client.crt" | sed -n 's/.*CN *= *//p')"
[[ "${cn}" == "alpha" ]] || fail "expected CN=alpha, got '${cn}'"
cp "${CACHE_PERSIST}/clients/alpha/client.crt" "${TMP}/wl-client.crt.bak"
component_tls_ensure_client cache "${CACHE_PERSIST}" "alpha" \
  || fail "second cache client ensure should noop"
cmp -s "${TMP}/wl-client.crt.bak" "${CACHE_PERSIST}/clients/alpha/client.crt" \
  || fail "create-if-missing must not replace existing Workload client cert"
pass "cache Workload client cert CN=basename create-if-missing"

component_tls_ensure_client database "${DB_PERSIST}" "alpha" \
  || fail "database client ensure should succeed"
[[ -f "${DB_PERSIST}/clients/alpha/client.crt" ]] || fail "expected database client.crt"
[[ -f "${DB_PERSIST}/clients/alpha/client.key" ]] || fail "expected database client.key"
cn="$(openssl x509 -noout -subject -in "${DB_PERSIST}/clients/alpha/client.crt" | sed -n 's/.*CN *= *//p')"
[[ "${cn}" == "alpha" ]] || fail "expected CN=alpha, got '${cn}'"
cp "${DB_PERSIST}/clients/alpha/client.crt" "${TMP}/db-client.crt.bak"
component_tls_ensure_client database "${DB_PERSIST}" "alpha" \
  || fail "second database client ensure should noop"
cmp -s "${TMP}/db-client.crt.bak" "${DB_PERSIST}/clients/alpha/client.crt" \
  || fail "create-if-missing must not replace existing database client cert"
pass "database Workload client cert CN=basename create-if-missing"

echo "All component-tls-host offline tests passed."
