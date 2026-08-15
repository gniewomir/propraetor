#!/usr/bin/env bash
# Offline tests: Cache publish binding paths + Requires-based claim (ADR-0055 / #222).
# Does not talk to Valkey; stubs ambient dirs and TLS material.
# Seam: cache_publish_binding / cache_unpublish_binding /
#       cache_workload_is_run_claimant / cache_basename_is_claim_safe.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=cache-fulfill-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/cache-fulfill-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cache-publish.XXXXXX")"
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

cache_publish_binding "${WL}" || fail "publish should succeed"

binding="$(workload_cache_binding_dir "${WL}")"
[[ -f "${binding}/ca.crt" ]] || fail "expected published ca.crt"
[[ -f "${binding}/client.crt" ]] || fail "expected published client.crt"
[[ -f "${binding}/client.key" ]] || fail "expected published client.key"
[[ -f "${binding}/environment" ]] || fail "expected published environment"
grep -Fx 'CACHE_HOST=cache' "${binding}/environment" >/dev/null \
  || fail "environment must set CACHE_HOST=cache"
grep -Fx "CACHE_KEY_PREFIX=${WL}:" "${binding}/environment" >/dev/null \
  || fail "environment must set CACHE_KEY_PREFIX=${WL}:"
grep -E '^(CACHE_PASSWORD|CACHE_AUTH|REDIS_PASSWORD)=' "${binding}/environment" >/dev/null \
  && fail "published environment must not include a password"
pass "published binding has certs + passwordless CACHE_* env"

dropin="$(workload_cache_dropin_path "${WL}.container")"
[[ -f "${dropin}" ]] || fail "expected Setup-owned cache drop-in"
grep -Fx "EnvironmentFile=${binding}/environment" "${dropin}" >/dev/null \
  || fail "drop-in must wire EnvironmentFile="
grep -F "Volume=${binding}/ca.crt:/etc/platform-cache/ca.crt:ro" "${dropin}" >/dev/null \
  || fail "drop-in must mount ca.crt"
grep -F "Volume=${binding}/client.key:/etc/platform-cache/client.key:ro" "${dropin}" >/dev/null \
  || fail "drop-in must mount client.key"
pass "Setup-owned Quadlet drop-in wires env + mounts"

# Unpublish clears projection + drop-in; durable client material stays.
cache_unpublish_binding "${WL}" || fail "unpublish should succeed"
[[ ! -e "${binding}" ]] || fail "published binding dir must be removed"
[[ ! -e "${dropin}" ]] || fail "Setup-owned drop-in must be removed"
[[ -f "${DATA_ROOT}/clients/${WL}/client.crt" ]] \
  || fail "durable client cert must remain after unpublish"
pass "unpublish clears projection; durable clients retained"

# Absent-client selection: SoT present stays; SoT gone is selected (#225).
CLIENTS_DIR="${DATA_ROOT}/clients"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/${WL}/manifest.json"
mkdir -p "${CLIENTS_DIR}/beta" "${CLIENTS_DIR}/gone" \
  "${WORKLOADS_ROOT}/beta"
printf '%s\n' '{"intent":"stop"}' >"${WORKLOADS_ROOT}/beta/manifest.json"
printf 'x\n' >"${CLIENTS_DIR}/beta/client.crt"
printf 'x\n' >"${CLIENTS_DIR}/gone/client.crt"
got="$(cache_absent_client_basenames "${CLIENTS_DIR}" "${WORKLOADS_ROOT}" | paste -sd, -)"
[[ "${got}" == "gone" ]] || fail "want only gone selected, got '${got}'"
pass "absent client selection ignores SoT-present basenames"

# Unpublish without SoT clears binding + conventional drop-in leftover.
mkdir -p "${HOME_DIR}/.config/platform/workloads/gone/cache" \
  "${UNIT_DIR}/gone.container.d"
printf 'leftover\n' >"${HOME_DIR}/.config/platform/workloads/gone/cache/environment"
printf 'dropin\n' >"${UNIT_DIR}/gone.container.d/50-platform-cache.conf"
cache_unpublish_binding gone || fail "unpublish without SoT should succeed"
[[ ! -e "${HOME_DIR}/.config/platform/workloads/gone/cache" ]] \
  || fail "binding must clear without SoT"
[[ ! -e "${UNIT_DIR}/gone.container.d/50-platform-cache.conf" ]] \
  || fail "conventional drop-in must clear without SoT"
pass "unpublish without SoT clears binding and conventional drop-in"

# Requires-based claim: Intent-run × Requires cache:true (ADR-0055 / #222).
write_claim_tree() {
  local dir="$1"
  local intent="$2"
  local requires_json="$3"
  mkdir -p "${dir}"
  printf '%s\n' "{\"intent\":\"${intent}\",\"source\":\"internal\"}" >"${dir}/manifest.json"
  printf '%s\n' "${requires_json}" >"${dir}/requires.json"
}

CLAIM="${TMP}/claim-wl"
write_claim_tree "${CLAIM}" run '{ "database": false, "cache": true }'
[[ "$(cache_workload_is_run_claimant "${CLAIM}")" == "1" ]] \
  || fail "Intent run + Requires cache true must claim"
write_claim_tree "${CLAIM}" run '{ "database": false, "cache": false }'
[[ "$(cache_workload_is_run_claimant "${CLAIM}")" == "0" ]] \
  || fail "Intent run + Requires cache false must not claim"
write_claim_tree "${CLAIM}" stop '{ "database": false, "cache": true }'
[[ "$(cache_workload_is_run_claimant "${CLAIM}")" == "0" ]] \
  || fail "Intent stop + Requires cache true must not claim"
write_claim_tree "${CLAIM}" trash '{ "database": false, "cache": true }'
if cache_workload_is_run_claimant "${CLAIM}" >/dev/null 2>&1; then
  fail "retired Intent trash must fail closed"
fi
pass "Requires cache claim is gated on Intent run; trash rejected"

# Manifest must not claim (Requires is SoT).
mkdir -p "${CLAIM}"
printf '%s\n' '{"intent":"run","source":"internal"}' >"${CLAIM}/manifest.json"
printf '%s\n' '{ "database": false, "cache": false }' >"${CLAIM}/requires.json"
[[ "$(cache_workload_is_run_claimant "${CLAIM}")" == "0" ]] \
  || fail "Requires cache:false must not claim"
pass "Requires cache false does not claim"

write_claim_tree "${CLAIM}" run '{ "database": false, "cache": true }'
rm -f "${CLAIM}/requires.json"
if cache_workload_is_run_claimant "${CLAIM}" >/dev/null 2>&1; then
  fail "missing Requires must fail closed for Intent-run"
fi
pass "missing Requires fails closed for Intent-run"

# Glob-unsafe basenames fail closed.
cache_basename_is_claim_safe "alpha" || fail "alpha must be claim-safe"
cache_basename_is_claim_safe "alpha:beta" && fail "colon must fail closed"
cache_basename_is_claim_safe "a*b" && fail "asterisk must fail closed"
cache_basename_is_claim_safe "a?b" && fail "question mark must fail closed"
cache_basename_is_claim_safe "a[b" && fail "open bracket must fail closed"
cache_basename_is_claim_safe "a]b" && fail "close bracket must fail closed"
pass "glob-unsafe basenames fail closed for Cache claims"

# ACL rewrite includes cert-only claimant whitelist (no password / nopass).
# shellcheck source=cache-admin-env-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/cache-admin-env-host.sh"
mkdir -p "${DATA_ROOT}/conf" "${DATA_ROOT}/admin"
printf 'CACHE_ADMIN_USER=cacheadmin\nCACHE_ADMIN_PASSWORD=s3cret\n' \
  >"${DATA_ROOT}/admin/environment"
ADMIN_ENV="${DATA_ROOT}/admin/environment"
printf 'alpha\n' >"${TMP}/claimants"
cache_write_acl_file "${ADMIN_ENV}" "${TMP}/claimants" || fail "ACL write with claimants"
acl="${DATA_ROOT}/conf/users.acl"
grep -Eq '^user default off$' "${acl}" || fail "ACL must disable default"
grep -Eq '^user alpha on resetpass ~alpha:\* resetchannels' "${acl}" \
  || fail "ACL must define cert-only claimant alpha"
grep -F 'nopass' "${acl}" && fail "Workload ACL must not use nopass"
grep -F '+@keyspace' "${acl}" && fail "Workload ACL must not grant +@keyspace"
grep -F '+del' "${acl}" >/dev/null || fail "Workload ACL must whitelist +del"
pass "ACL rewrite publishes cert-only claimant whitelist"

# Intent stop shape: claimant then empty claimants → former user off; client retained.
mkdir -p "${DATA_ROOT}/clients/${WL}"
printf 'CERT\n' >"${DATA_ROOT}/clients/${WL}/client.crt"
: >"${TMP}/no-claimants"
cache_write_acl_file "${ADMIN_ENV}" "${TMP}/no-claimants" || fail "ACL write with zero claimants"
grep -Eq "^user ${WL} off$" "${acl}" \
  || fail "former claimant must be ACL-disabled after Intent stop gather"
[[ -f "${DATA_ROOT}/clients/${WL}/client.crt" ]] \
  || fail "durable client cert must remain when ACL user is off"
pass "zero claimants disables ACL user and retains Persist client"

echo "All cache-fulfill-host offline tests passed."
