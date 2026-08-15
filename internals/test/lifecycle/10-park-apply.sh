#!/usr/bin/env bash
# Lifecycle Test: stable Applied/Parked conditions + Park → Apply Durable round-trip.
# Suite baseline: Stack absent (runner Teardown); this case Applies via ensure_stack_applied.
# Proves repeating Apply/Park are no-ops, Durables keep identities across Park,
# Recreatables restore via normal Apply (Adopt preflight allowed), and Host /
# Reserved IP Cloud Project memberships match their lifecycle classes.
# Leftover Stack state on success: Applied (Host + Durables restored).
# On failure: may leave Parked or mid-Apply — restore with: ./apply.sh
set -euo pipefail

# shellcheck source=lib/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/lib.sh"

[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh lifecycle)"
[[ -d "${STACK_DIR}" ]] || fail "missing Stack dir ${STACK_DIR}"

MARKER_PATH="/host-volume/lifecycle-park-apply.marker"
MARKER_BODY="lifecycle-park-apply-$(date -u +%Y%m%dT%H%M%SZ)-$$"

ensure_stack_applied

PROJECT_ID_BEFORE="$(stack_cloud_project_id)"
[[ -n "${PROJECT_ID_BEFORE}" ]] || fail "Cloud Project not found at provider before Park"
VOLUME_ID_BEFORE="$(stack_host_volume_id)"
[[ -n "${VOLUME_ID_BEFORE}" ]] || fail "Host Volume not found at provider before Park"
DOMAINS_BEFORE="$(stack_domain_names)"

wait_until_ssh_reachable
wait_until_volume_mounted
acceptance_host_session

write_host_volume_file "${MARKER_PATH}" "${MARKER_BODY}"
pass "marker written and synced on Host Volume"

assert_host_present
assert_host_membership present
assert_reserved_ip_membership "${IP}"
assert_durables_in_cloud_project "${IP}"
assert_domains_present "${IP}"

echo "Repeating Apply on Applied Stack (expect empty plan) ..."
assert_apply_noop

echo "Parking Stack (confirming via stdin) ..."
printf 'park\n' | "${REPO_ROOT}/park.sh" --env "${PLATFORM_ENV}"

assert_host_absent
assert_host_membership absent
assert_reserved_ip_present "${IP}"
assert_reserved_ip_membership "${IP}"
assert_durables_in_cloud_project "${IP}"
assert_volume_present
assert_domains_present "${IP}"

PROJECT_ID_PARKED="$(stack_cloud_project_id)"
[[ "${PROJECT_ID_PARKED}" == "${PROJECT_ID_BEFORE}" ]] \
  || fail "Cloud Project id changed across Park: before=${PROJECT_ID_BEFORE} after=${PROJECT_ID_PARKED}"
VOLUME_ID_PARKED="$(stack_host_volume_id)"
[[ "${VOLUME_ID_PARKED}" == "${VOLUME_ID_BEFORE}" ]] \
  || fail "Host Volume id changed across Park: before=${VOLUME_ID_BEFORE} after=${VOLUME_ID_PARKED}"
pass "Durable identities unchanged while Parked (Cloud Project + Host Volume)"

echo "Repeating Park on Parked Stack (expect empty plan) ..."
assert_park_noop

echo "Applying Stack after Park ..."
"${REPO_ROOT}/apply.sh" --yes --env "${PLATFORM_ENV}"

AFTER_IP="$(stack_reserved_ip)"
[[ "${AFTER_IP}" == "${IP}" ]] || fail "Reserved IP changed across Park→Apply: before=${IP} after=${AFTER_IP}"
pass "Reserved IP unchanged across Park→Apply (${IP})"

PROJECT_ID_AFTER="$(stack_cloud_project_id)"
[[ "${PROJECT_ID_AFTER}" == "${PROJECT_ID_BEFORE}" ]] \
  || fail "Cloud Project id changed across Park→Apply: before=${PROJECT_ID_BEFORE} after=${PROJECT_ID_AFTER}"
VOLUME_ID_AFTER="$(stack_host_volume_id)"
[[ "${VOLUME_ID_AFTER}" == "${VOLUME_ID_BEFORE}" ]] \
  || fail "Host Volume id changed across Park→Apply: before=${VOLUME_ID_BEFORE} after=${VOLUME_ID_AFTER}"
pass "Durable identities unchanged across Park→Apply"

DOMAINS_AFTER="$(stack_domain_names)"
[[ "${DOMAINS_AFTER}" == "${DOMAINS_BEFORE}" ]] \
  || fail "Domain set changed across Park→Apply: before=${DOMAINS_BEFORE} after=${DOMAINS_AFTER}"
assert_domains_present "${AFTER_IP}"

export IP="${AFTER_IP}"
wait_until_ssh_reachable
wait_until_volume_mounted

assert_host_present
assert_host_membership present
assert_reserved_ip_membership "${IP}"
assert_durables_in_cloud_project "${IP}"

got="$(host_ssh "cat '${MARKER_PATH}' 2>/dev/null || true")"
[[ "${got}" == "${MARKER_BODY}" ]] || fail "marker missing or changed after Park→Apply (got: '${got}')"
pass "Host Volume marker survived Park→Apply"

echo "Repeating Apply after Park→Apply restore (expect empty plan) ..."
assert_apply_noop

pass "Park → Apply convergence round-trip"
