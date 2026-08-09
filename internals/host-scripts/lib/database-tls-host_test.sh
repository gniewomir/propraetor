#!/usr/bin/env bash
# Offline tests: Database client TLS create-if-missing (ADR-0049 / #189).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=database-tls-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/database-tls-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/db-tls.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
DATA_ROOT="${TMP}/data"
USER_NAME=""

database_tls_ensure || fail "CA/server ensure should succeed"
[[ -f "${DATA_ROOT}/ca/ca.crt" ]] || fail "expected CA cert"
[[ -f "${DATA_ROOT}/server/server.crt" ]] || fail "expected server cert"
pass "CA + server create-if-missing"

database_tls_ensure_client "alpha" || fail "client ensure should succeed"
[[ -f "${DATA_ROOT}/clients/alpha/client.crt" ]] || fail "expected client.crt"
[[ -f "${DATA_ROOT}/clients/alpha/client.key" ]] || fail "expected client.key"
cn="$(openssl x509 -noout -subject -in "${DATA_ROOT}/clients/alpha/client.crt" | sed -n 's/.*CN *= *//p')"
[[ "${cn}" == "alpha" ]] || fail "expected CN=alpha, got '${cn}'"
pass "client cert CN=basename"

# create-if-missing: second call must not rotate
cp "${DATA_ROOT}/clients/alpha/client.crt" "${TMP}/client.crt.bak"
database_tls_ensure_client "alpha" || fail "second client ensure should noop"
cmp -s "${TMP}/client.crt.bak" "${DATA_ROOT}/clients/alpha/client.crt" \
  || fail "create-if-missing must not replace existing client cert"
pass "client cert create-if-missing is stable"

echo "All database-tls-host offline tests passed."
