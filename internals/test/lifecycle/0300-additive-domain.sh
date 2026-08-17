#!/usr/bin/env bash
# Lifecycle Test: Applied Additive Domain change is monotonic (ADR-0025 / #62).
# Suite baseline: Stack absent (runner Teardown); this case Applies via ensure_stack_applied.
# Writes an internal domains.override.json (derived from committed Domains), Applies,
# asserts prior identities/memberships survive and the fixture Domain is present, then
# Teardowns with override still present, removes the override, and re-Applies committed.
# Leftover Stack state on success: Applied (committed Domains only; no fixture Durable).
# On failure: may leave Applied with override, empty after Teardown, or mid-Apply —
# remove environments/<slug>/domains.override.json if present, then
# ./apply.sh or ./teardown.sh as needed.
set -euo pipefail

# shellcheck source=lib/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/lib.sh"

[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh lifecycle)"
[[ -d "${STACK_DIR}" ]] || fail "missing Stack dir ${STACK_DIR}"

trap 'remove_domain_override' EXIT

ensure_stack_applied

PROJECT_ID_BEFORE="$(stack_cloud_project_id)"
[[ -n "${PROJECT_ID_BEFORE}" ]] || fail "Cloud Project not found at provider before additive Apply"
VOLUME_ID_BEFORE="$(stack_host_volume_id)"
[[ -n "${VOLUME_ID_BEFORE}" ]] || fail "Host Volume not found at provider before additive Apply"
DOMAINS_BEFORE="$(stack_domain_names)"
[[ -n "${DOMAINS_BEFORE}" ]] || fail "committed Domains empty — additive fixture needs a base apex"

assert_host_present
assert_host_membership present
assert_reserved_ip_membership "${IP}"
assert_durables_in_cloud_project "${IP}"
assert_domains_present "${IP}"

HOST_ID_BEFORE="$(provider_host_by_name_json | jq -r '.id | tostring')"
[[ -n "${HOST_ID_BEFORE}" && "${HOST_ID_BEFORE}" != "null" ]] \
  || fail "Host id missing before additive Apply"

FIXTURE_APEX="$(write_additive_domain_override)"
[[ -n "${FIXTURE_APEX}" ]] || fail "additive Domain fixture apex empty"
pass "wrote Domain override with fixture ${FIXTURE_APEX}"

echo "Applying Additive Domain fixture ${FIXTURE_APEX} ..."
"${REPO_ROOT}/apply.sh" --yes --env "${PLATFORM_ENV}"

AFTER_IP="$(stack_reserved_ip)"
[[ "${AFTER_IP}" == "${IP}" ]] || fail "Reserved IP changed during additive Apply: before=${IP} after=${AFTER_IP}"
pass "Reserved IP unchanged during additive Apply (${IP})"

PROJECT_ID_AFTER="$(stack_cloud_project_id)"
[[ "${PROJECT_ID_AFTER}" == "${PROJECT_ID_BEFORE}" ]] \
  || fail "Cloud Project id changed during additive Apply: before=${PROJECT_ID_BEFORE} after=${PROJECT_ID_AFTER}"
VOLUME_ID_AFTER="$(stack_host_volume_id)"
[[ "${VOLUME_ID_AFTER}" == "${VOLUME_ID_BEFORE}" ]] \
  || fail "Host Volume id changed during additive Apply: before=${VOLUME_ID_BEFORE} after=${VOLUME_ID_AFTER}"
HOST_ID_AFTER="$(provider_host_by_name_json | jq -r '.id | tostring')"
[[ "${HOST_ID_AFTER}" == "${HOST_ID_BEFORE}" ]] \
  || fail "Host id changed during additive Apply: before=${HOST_ID_BEFORE} after=${HOST_ID_AFTER}"
pass "Durable and Host identities unchanged during additive Apply"

DOMAINS_AFTER="$(stack_domain_names)"
echo "${DOMAINS_AFTER}" | grep -Fxq "${FIXTURE_APEX}" \
  || fail "fixture Domain ${FIXTURE_APEX} missing from assignment after additive Apply"
while IFS= read -r zone; do
  [[ -z "${zone}" ]] && continue
  echo "${DOMAINS_AFTER}" | grep -Fxq "${zone}" \
    || fail "prior Domain ${zone} missing after additive Apply"
done <<< "${DOMAINS_BEFORE}"
pass "prior Domains preserved; fixture present in assignment"

assert_host_present
assert_host_membership present
assert_reserved_ip_membership "${IP}"
assert_durables_in_cloud_project "${IP}"
assert_domains_present "${IP}"

echo "Repeating Apply after additive Domain (expect empty plan) ..."
assert_apply_noop

echo "Tearing down Stack with override still present (confirming via stdin) ..."
printf 'teardown\n' | "${REPO_ROOT}/teardown.sh" --env "${PLATFORM_ENV}"

assert_stack_empty
assert_domains_absent "$(printf '%s\n%s\n' "${DOMAINS_BEFORE}" "${FIXTURE_APEX}")"

remove_domain_override
trap - EXIT

echo "Re-Applying committed Domains only ..."
"${REPO_ROOT}/apply.sh" --yes --env "${PLATFORM_ENV}"

RESTORE_IP="$(stack_reserved_ip)"
[[ -n "${RESTORE_IP}" ]] || fail "no reserved_ip after committed re-Apply"
export IP="${RESTORE_IP}"

DOMAINS_RESTORED="$(stack_domain_names)"
echo "${DOMAINS_RESTORED}" | grep -Fxq "${FIXTURE_APEX}" \
  && fail "fixture Domain ${FIXTURE_APEX} still in assignment after committed re-Apply"
while IFS= read -r zone; do
  [[ -z "${zone}" ]] && continue
  echo "${DOMAINS_RESTORED}" | grep -Fxq "${zone}" \
    || fail "committed Domain ${zone} missing after re-Apply"
done <<< "${DOMAINS_BEFORE}"
assert_domains_present "${IP}"
assert_domains_absent "${FIXTURE_APEX}"

assert_host_present
assert_host_membership present
assert_reserved_ip_membership "${IP}"
assert_durables_in_cloud_project "${IP}"

echo "Repeating Apply after committed restore (expect empty plan) ..."
assert_apply_noop

pass "Applied Additive Domain change is monotonic"
