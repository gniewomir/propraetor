#!/usr/bin/env bash
# Seam: Acceptance isolation helpers (ADR-0042 / #163) —
# Environment SoT restore to committed truth; tracked Host Volume data/ cleanup + G.
# No live Host: fake REPO_ROOT + ACCEPTANCE_HV_DATA_ROOT.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${CASE_DIR}/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMPDIR_SAFE="${TMPDIR:-/tmp}"
umask 077
TMP="$(mktemp -d "${TMPDIR_SAFE}/acceptance-isolation.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

export REPO_ROOT="${TMP}/repo"
export PLATFORM_ENV="test"
export ACCEPTANCE_HV_DATA_ROOT="${TMP}/hv-data"
mkdir -p "${REPO_ROOT}" "${ACCEPTANCE_HV_DATA_ROOT}"

# Reset trackers between slices (helpers append to globals).
reset_trackers() {
  ACCEPTANCE_WL_TRACKED=()
  ACCEPTANCE_SOT_TRACKED=()
  ACCEPTANCE_DATA_TRACKED=()
}

# --- tracked data/: register, cleanup removes, assert fails on leak ---
reset_trackers
mkdir -p "${ACCEPTANCE_HV_DATA_ROOT}/workloads/fixture-a/persist"
printf 'owned\n' >"${ACCEPTANCE_HV_DATA_ROOT}/workloads/fixture-a/persist/acceptance-owned"
# Preexisting durable must not be touched when untracked.
mkdir -p "${ACCEPTANCE_HV_DATA_ROOT}/workloads/other/persist"
printf 'keep\n' >"${ACCEPTANCE_HV_DATA_ROOT}/workloads/other/persist/state.bin"

acceptance_data_track "workloads/fixture-a/persist/acceptance-owned"
acceptance_wl_cleanup

[[ ! -e "${ACCEPTANCE_HV_DATA_ROOT}/workloads/fixture-a/persist/acceptance-owned" ]] \
  || fail "tracked data/ path must be removed by cleanup"
[[ -f "${ACCEPTANCE_HV_DATA_ROOT}/workloads/other/persist/state.bin" ]] \
  || fail "untracked preexisting data/ must remain"
pass "tracked data/ cleaned; untracked preexisting left alone"

# Assert G: leak after cleanup must fail the owning case.
reset_trackers
mkdir -p "${ACCEPTANCE_HV_DATA_ROOT}/workloads/leaky/persist"
printf 'leak\n' >"${ACCEPTANCE_HV_DATA_ROOT}/workloads/leaky/persist/residue"
acceptance_data_track "workloads/leaky/persist/residue"
# Simulate botched cleanup: remove via helper path but re-create before assert by
# stubbing — call assert directly with path still present.
if ( acceptance_data_assert_gone >/dev/null 2>&1 ); then
  fail "acceptance_data_assert_gone must fail while tracked path exists"
fi
pass "tracked data/ assert fails on leak"

rm -f "${ACCEPTANCE_HV_DATA_ROOT}/workloads/leaky/persist/residue"
acceptance_data_assert_gone
pass "tracked data/ assert passes when path is gone"

# --- non-test: track helpers fail closed (ADR-0042 / #176) ---
reset_trackers
export PLATFORM_ENV="prod"
if ( acceptance_wl_track "should-not-track" >/dev/null 2>&1 ); then
  fail "acceptance_wl_track must fail closed when PLATFORM_ENV≠test"
fi
[[ ${#ACCEPTANCE_WL_TRACKED[@]} -eq 0 ]] \
  || fail "failed acceptance_wl_track must not append names"
if ( acceptance_sot_track "committed-wl/manifest.json" >/dev/null 2>&1 ); then
  fail "acceptance_sot_track must fail closed when PLATFORM_ENV≠test"
fi
[[ ${#ACCEPTANCE_SOT_TRACKED[@]} -eq 0 ]] \
  || fail "failed acceptance_sot_track must not append paths"
# Case-owned Host Volume data/ probes remain allowed on non-test.
mkdir -p "${ACCEPTANCE_HV_DATA_ROOT}/components/edge/persist"
printf 'probe\n' >"${ACCEPTANCE_HV_DATA_ROOT}/components/edge/persist/diagnose-probe"
acceptance_data_track "components/edge/persist/diagnose-probe" \
  || fail "acceptance_data_track must remain allowed when PLATFORM_ENV≠test"
acceptance_wl_cleanup
[[ ! -e "${ACCEPTANCE_HV_DATA_ROOT}/components/edge/persist/diagnose-probe" ]] \
  || fail "non-test acceptance_data_track cleanup must still remove tracked path"
pass "non-test track helpers fail closed; data_track still allowed"
export PLATFORM_ENV="test"

# --- fixture Workload dirs still removed (existing track protocol) ---
reset_trackers
ENV_DIR="${REPO_ROOT}/environments/test"
mkdir -p "${ENV_DIR}/ephemeral-wl"
printf '{ "intent": "run" }\n' >"${ENV_DIR}/ephemeral-wl/manifest.json"
acceptance_wl_track "ephemeral-wl"
acceptance_wl_cleanup
[[ ! -e "${ENV_DIR}/ephemeral-wl" ]] || fail "tracked Workload fixture must be removed"
pass "acceptance_wl_track still removes Environment fixtures"

# --- SoT restore: mutated committed path returns to git HEAD ---
reset_trackers
git -C "${REPO_ROOT}" init -q
git -C "${REPO_ROOT}" config user.email "isolation@test"
git -C "${REPO_ROOT}" config user.name "Isolation Test"
mkdir -p "${ENV_DIR}/committed-wl"
printf '{ "intent": "run" }\n' >"${ENV_DIR}/committed-wl/manifest.json"
git -C "${REPO_ROOT}" add environments/test/committed-wl/manifest.json
git -C "${REPO_ROOT}" -c commit.gpgsign=false commit -q -m "committed SoT"
printf '{ "intent": "trash" }\n' >"${ENV_DIR}/committed-wl/manifest.json"
acceptance_sot_track "committed-wl/manifest.json"
acceptance_wl_cleanup
got="$(cat "${ENV_DIR}/committed-wl/manifest.json")"
[[ "${got}" == '{ "intent": "run" }' ]] \
  || fail "SoT restore must return Intent to committed truth, got: ${got}"
pass "acceptance_sot_track restores committed Environment path from git"

# Deleted committed file is restored.
reset_trackers
rm -f "${ENV_DIR}/committed-wl/manifest.json"
acceptance_sot_track "committed-wl/manifest.json"
acceptance_wl_cleanup
[[ -f "${ENV_DIR}/committed-wl/manifest.json" ]] \
  || fail "SoT restore must recreate deleted committed path"
pass "SoT restore recreates deleted committed path"

# Untracked additive file under a SoT-tracked tree is removed.
reset_trackers
printf 'extra\n' >"${ENV_DIR}/committed-wl/untracked-extra"
acceptance_sot_track "committed-wl"
acceptance_wl_cleanup
[[ ! -e "${ENV_DIR}/committed-wl/untracked-extra" ]] \
  || fail "SoT restore must remove untracked files under tracked path"
[[ -f "${ENV_DIR}/committed-wl/manifest.json" ]] \
  || fail "SoT restore must keep committed files when cleaning untracked"
pass "SoT restore drops untracked files under tracked path"

# data_track rejects escape / absolute paths.
reset_trackers
if ( acceptance_data_track "../etc/passwd" >/dev/null 2>&1 ); then
  fail "acceptance_data_track must reject '..' segments"
fi
if ( acceptance_data_track "/host-volume/x" >/dev/null 2>&1 ); then
  fail "acceptance_data_track must reject absolute paths"
fi
pass "acceptance_data_track rejects unsafe paths"

# Combined: fixture remove + SoT restore + data/ cleanup in one EXIT helper.
reset_trackers
mkdir -p "${ENV_DIR}/combo-fixture"
printf '{ "intent": "run" }\n' >"${ENV_DIR}/combo-fixture/manifest.json"
printf '{ "intent": "stop" }\n' >"${ENV_DIR}/committed-wl/manifest.json"
mkdir -p "${ACCEPTANCE_HV_DATA_ROOT}/workloads/combo-fixture/persist"
printf 'x\n' >"${ACCEPTANCE_HV_DATA_ROOT}/workloads/combo-fixture/persist/acceptance-owned"

acceptance_wl_track "combo-fixture"
acceptance_sot_track "committed-wl/manifest.json"
acceptance_data_track "workloads/combo-fixture/persist/acceptance-owned"
acceptance_wl_cleanup

[[ ! -e "${ENV_DIR}/combo-fixture" ]] || fail "combo: fixture must be gone"
got="$(cat "${ENV_DIR}/committed-wl/manifest.json")"
[[ "${got}" == '{ "intent": "run" }' ]] || fail "combo: SoT must be restored, got: ${got}"
[[ ! -e "${ACCEPTANCE_HV_DATA_ROOT}/workloads/combo-fixture/persist/acceptance-owned" ]] \
  || fail "combo: tracked data/ must be gone"
pass "unified cleanup: fixtures + SoT + tracked data/"

echo "All acceptance isolation helper checks passed."
