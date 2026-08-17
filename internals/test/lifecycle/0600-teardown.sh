#!/usr/bin/env bash
# Lifecycle Test: Teardown from Parked wipes Durables and empties State (#65 / ADR-0025).
# Suite baseline: Stack absent (runner Teardown); this case Applies via ensure_stack_applied.
# Case-owned Park first, then Teardown. Applied→Teardown coverage remains in
# 0300-additive-domain.sh / 0400-parked-additive-partial-apply.sh (and 0200) cleanup.
# Leftover Stack state on success: empty (no managed addresses; Durables gone at provider).
# On failure: may leave Applied, Parked, or mid-Teardown — restore with:
#   Prefer Park if Durables remain; full wipe: ./teardown.sh; then ./apply.sh.
set -euo pipefail

# shellcheck source=lib/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/lib.sh"

[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh lifecycle)"
[[ -d "${STACK_DIR}" ]] || fail "missing Stack dir ${STACK_DIR}"

ensure_stack_applied

DOMAINS_BEFORE="$(stack_domain_names)"
PROJECT_ID="$(stack_cloud_project_id)"
[[ -n "${PROJECT_ID}" ]] || fail "Cloud Project not found at provider before Park"

assert_reserved_ip_present "${IP}"
assert_volume_present
assert_domains_present "${IP}"

echo "Parking Stack before Teardown (confirming via stdin) ..."
printf 'park\n' | "${REPO_ROOT}/park.sh" --env "${PLATFORM_ENV}"

assert_host_absent
assert_host_membership absent
assert_reserved_ip_present "${IP}"
assert_reserved_ip_membership "${IP}"
assert_durables_in_cloud_project "${IP}"
assert_volume_present
assert_domains_present "${IP}"
pass "verified Parked before Teardown"

echo "Tearing down Parked Stack (confirming via stdin) ..."
printf 'teardown\n' | "${REPO_ROOT}/teardown.sh" --env "${PLATFORM_ENV}"

assert_reserved_ip_absent "${IP}"
assert_cloud_project_absent "${PROJECT_ID}"
assert_volume_absent
assert_domains_absent "${DOMAINS_BEFORE}"
assert_stack_empty

pass "Teardown from Parked wiped Durables and emptied Stack"
