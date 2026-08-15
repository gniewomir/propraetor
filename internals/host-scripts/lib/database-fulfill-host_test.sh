#!/usr/bin/env bash
# Offline tests: Database publish binding paths + Requires-based claim (ADR-0049 / ADR-0053 / #202).
# Does not talk to Postgres; stubs ambient dirs and TLS material.
# Seam: database_publish_binding / database_unpublish_binding /
#       database_absent_client_basenames / database_workload_is_run_claimant.
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
  "${WORKLOADS_ROOT}/${WL}/systemd" \
  "${DATA_ROOT}/ca" \
  "${DATA_ROOT}/clients/${WL}"
printf 'CA\n' >"${DATA_ROOT}/ca/ca.crt"
printf 'CERT\n' >"${DATA_ROOT}/clients/${WL}/client.crt"
printf 'KEY\n' >"${DATA_ROOT}/clients/${WL}/client.key"
printf '[Container]\nImage=localhost/demo\n' \
  >"${WORKLOADS_ROOT}/${WL}/systemd/${WL}.container"

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

# Unpublish clears projection + drop-in; durable client material stays (#190).
database_unpublish_binding "${WL}" || fail "unpublish should succeed"
[[ ! -e "${binding}" ]] || fail "published binding dir must be removed"
[[ ! -e "${dropin}" ]] || fail "Setup-owned drop-in must be removed"
[[ -f "${DATA_ROOT}/clients/${WL}/client.crt" ]] \
  || fail "durable client cert must remain after unpublish"
pass "unpublish clears projection; durable clients retained"

# Absent-client selection: SoT present stays; SoT gone is selected (#191).
CLIENTS_DIR="${DATA_ROOT}/clients"
printf '%s\n' '{"intent":"run","database":true}' >"${WORKLOADS_ROOT}/${WL}/manifest.json"
mkdir -p "${CLIENTS_DIR}/beta" "${CLIENTS_DIR}/gone" \
  "${WORKLOADS_ROOT}/beta"
printf '%s\n' '{"intent":"stop"}' >"${WORKLOADS_ROOT}/beta/manifest.json"
printf 'x\n' >"${CLIENTS_DIR}/beta/client.crt"
printf 'x\n' >"${CLIENTS_DIR}/gone/client.crt"
got="$(database_absent_client_basenames "${CLIENTS_DIR}" "${WORKLOADS_ROOT}" | paste -sd, -)"
[[ "${got}" == "gone" ]] || fail "want only gone selected, got '${got}'"
pass "absent client selection ignores SoT-present basenames"

# Unpublish without SoT clears binding + conventional drop-in leftover.
mkdir -p "${HOME_DIR}/.config/platform/workloads/gone/database" \
  "${UNIT_DIR}/gone.container.d"
printf 'leftover\n' >"${HOME_DIR}/.config/platform/workloads/gone/database/environment"
printf 'dropin\n' >"${UNIT_DIR}/gone.container.d/50-platform-database.conf"
database_unpublish_binding gone || fail "unpublish without SoT should succeed"
[[ ! -e "${HOME_DIR}/.config/platform/workloads/gone/database" ]] \
  || fail "binding must clear without SoT"
[[ ! -e "${UNIT_DIR}/gone.container.d/50-platform-database.conf" ]] \
  || fail "conventional drop-in must clear without SoT"
pass "unpublish without SoT clears binding and conventional drop-in"

# Requires-based claim: Intent-run × Requires database:true (ADR-0053 / #202).
# Manifest does not participate.
write_claim_tree() {
  local dir="$1"
  local intent="$2"
  local database_json="$3"
  mkdir -p "${dir}"
  printf '%s\n' "{\"intent\":\"${intent}\",\"source\":\"internal\"}" >"${dir}/manifest.json"
  printf '%s\n' "${database_json}" >"${dir}/requires.json"
}

CLAIM="${TMP}/claim-wl"
write_claim_tree "${CLAIM}" run '{ "database": true }'
[[ "$(database_workload_is_run_claimant "${CLAIM}")" == "1" ]] \
  || fail "Intent run + Requires database true must claim"
write_claim_tree "${CLAIM}" run '{ "database": false }'
[[ "$(database_workload_is_run_claimant "${CLAIM}")" == "0" ]] \
  || fail "Intent run + Requires database false must not claim"
write_claim_tree "${CLAIM}" stop '{ "database": true }'
[[ "$(database_workload_is_run_claimant "${CLAIM}")" == "0" ]] \
  || fail "Intent stop + Requires database true must not claim"
write_claim_tree "${CLAIM}" trash '{ "database": true }'
[[ "$(database_workload_is_run_claimant "${CLAIM}")" == "0" ]] \
  || fail "Intent trash + Requires database true must not claim"
pass "Requires database claim is gated on Intent run"

# Manifest database must not claim (clean break; retired key).
mkdir -p "${CLAIM}"
printf '%s\n' '{"intent":"run","source":"internal","database":true}' \
  >"${CLAIM}/manifest.json"
printf '%s\n' '{ "database": false }' >"${CLAIM}/requires.json"
[[ "$(database_workload_is_run_claimant "${CLAIM}")" == "0" ]] \
  || fail "Manifest database:true must not claim when Requires is false"
pass "Manifest database does not participate in claim"

write_claim_tree "${CLAIM}" run '{ "database": true }'
rm -f "${CLAIM}/requires.json"
if database_workload_is_run_claimant "${CLAIM}" >/dev/null 2>&1; then
  fail "missing Requires must fail closed for Intent-run"
fi
pass "missing Requires fails closed for Intent-run"

echo "All database-fulfill-host offline tests passed."
