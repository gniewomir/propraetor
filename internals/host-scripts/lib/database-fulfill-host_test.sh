#!/usr/bin/env bash
# Offline tests: Database publish binding paths + drop-in shape (ADR-0049 / #189).
# Does not talk to Postgres; stubs ambient dirs and TLS material.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=database-fulfill-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/database-fulfill-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/db-publish.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

HOME_DIR="${TMP}/home"
UNIT_DIR="${TMP}/units"
WORKLOADS_ROOT="${TMP}/workloads"
DATA_ROOT="${TMP}/data"
USER_NAME=""
WL=alpha

mkdir -p "${HOME_DIR}" "${UNIT_DIR}" \
  "${WORKLOADS_ROOT}/${WL}/quadlets" \
  "${DATA_ROOT}/ca" \
  "${DATA_ROOT}/clients/${WL}"
printf 'CA\n' >"${DATA_ROOT}/ca/ca.crt"
printf 'CERT\n' >"${DATA_ROOT}/clients/${WL}/client.crt"
printf 'KEY\n' >"${DATA_ROOT}/clients/${WL}/client.key"
printf '[Container]\nImage=localhost/demo\n' \
  >"${WORKLOADS_ROOT}/${WL}/quadlets/${WL}.container"

database_publish_binding "${WL}" || fail "publish should succeed"

binding="$(workload_database_binding_dir "${WL}")"
[[ -f "${binding}/ca.crt" ]] || fail "expected published ca.crt"
[[ -f "${binding}/client.crt" ]] || fail "expected published client.crt"
[[ -f "${binding}/client.key" ]] || fail "expected published client.key"
[[ -f "${binding}/environment" ]] || fail "expected published environment"
grep -Fx 'PGHOST=database' "${binding}/environment" >/dev/null \
  || fail "environment must set PGHOST=database"
grep -Fx 'PGSSLMODE=verify-full' "${binding}/environment" >/dev/null \
  || fail "environment must set PGSSLMODE=verify-full"
grep -E '^PGPASSWORD=' "${binding}/environment" >/dev/null \
  && fail "published environment must not include a password"
pass "published binding has certs + passwordless env"

dropin="$(workload_database_dropin_path "${WL}.container")"
[[ -f "${dropin}" ]] || fail "expected Setup-owned database drop-in"
grep -Fx "EnvironmentFile=${binding}/environment" "${dropin}" >/dev/null \
  || fail "drop-in must wire EnvironmentFile="
grep -F "Volume=${binding}/ca.crt:/etc/platform-database/ca.crt:ro" "${dropin}" >/dev/null \
  || fail "drop-in must mount ca.crt"
grep -F "Volume=${binding}/client.key:/etc/platform-database/client.key:ro" "${dropin}" >/dev/null \
  || fail "drop-in must mount client.key"
pass "Setup-owned Quadlet drop-in wires env + mounts"

# Manifest claim helper
printf '%s\n' '{"intent":"run","database":true}' >"${TMP}/m.json"
[[ "$(_database_manifest_claims "${TMP}/m.json")" == "1" ]] || fail "true should claim"
printf '%s\n' '{"intent":"run"}' >"${TMP}/m.json"
[[ "$(_database_manifest_claims "${TMP}/m.json")" == "0" ]] || fail "omit should not claim"
pass "manifest claim helper"

echo "All database-fulfill-host offline tests passed."
