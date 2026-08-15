#!/usr/bin/env bash
# Seam: Acceptance case independence under ADR-0042 / #166 —
# second case fails if the first’s residue remains and restore / Deploy baseline
# are skipped; passes when restore + baseline run between cases.
# No live Host: fake REPO_ROOT, Host root, and ACCEPTANCE_HV_DATA_ROOT.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${CASE_DIR}/lib.sh"
# shellcheck source=baseline.sh
source "${CASE_DIR}/baseline.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMPDIR_SAFE="${TMPDIR:-/tmp}"
umask 077
TMP="$(mktemp -d "${TMPDIR_SAFE}/acceptance-independence.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

export REPO_ROOT="${TMP}/repo"
export PLATFORM_ENV="test"
export ACCEPTANCE_HV_DATA_ROOT="${TMP}/hv-data"
HOST_ROOT="${TMP}/host"
mkdir -p "${REPO_ROOT}/environments/test" "${ACCEPTANCE_HV_DATA_ROOT}" \
  "${HOST_ROOT}/var/lib/propraetor" "${REPO_ROOT}/internals"

git -C "${REPO_ROOT}" init -q
git -C "${REPO_ROOT}" config user.email "independence@test"
git -C "${REPO_ROOT}" config user.name "Independence Test"
# Committed Environment truth: one Workload only.
mkdir -p "${REPO_ROOT}/environments/test/committed-wl"
printf '{ "intent": "run" }\n' >"${REPO_ROOT}/environments/test/committed-wl/manifest.json"
git -C "${REPO_ROOT}" add environments/test/committed-wl/manifest.json
git -C "${REPO_ROOT}/" -c commit.gpgsign=false commit -q -m "committed SoT"

# Stub Deploy: clears Host residue that would survive a case but not a Deploy converge.
cat >"${REPO_ROOT}/internals/ensure.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
rm -f "${HOST_ROOT}/var/lib/propraetor/case-a-host-residue"
exit 0
EOF
chmod +x "${REPO_ROOT}/internals/ensure.sh"

reset_trackers() {
  ACCEPTANCE_WL_TRACKED=()
  ACCEPTANCE_SOT_TRACKED=()
  ACCEPTANCE_DATA_TRACKED=()
}

# Case A (messy): leaves Environment fixture, SoT mutation, Host residue, and
# survive-Deploy data/ — without EXIT restore / tracked data cleanup.
case_a_leave_residue() {
  mkdir -p "${REPO_ROOT}/environments/test/polluter-wl"
  printf '{ "intent": "run" }\n' \
    >"${REPO_ROOT}/environments/test/polluter-wl/manifest.json"
  printf '{ "intent": "trash" }\n' \
    >"${REPO_ROOT}/environments/test/committed-wl/manifest.json"
  printf 'host-leak\n' >"${HOST_ROOT}/var/lib/propraetor/case-a-host-residue"
  mkdir -p "${ACCEPTANCE_HV_DATA_ROOT}/workloads/polluter-wl/persist"
  printf 'durable\n' >"${ACCEPTANCE_HV_DATA_ROOT}/workloads/polluter-wl/persist/owned.bin"
}

# Case A (policy-compliant): same mutations, but track + cleanup on EXIT; Deploy
# baseline is the runner's job between cases (not called here).
case_a_with_restore() {
  reset_trackers
  case_a_leave_residue
  acceptance_wl_track "polluter-wl"
  acceptance_sot_track "committed-wl/manifest.json"
  acceptance_data_track "workloads/polluter-wl/persist/owned.bin"
  acceptance_wl_cleanup
}

# Case B: asserts committed Environment + no Host residue from A.
# Survive-Deploy data/ is case-A-owned (not B's job) — B only checks SoT + Host.
case_b_assert_clean() {
  [[ ! -e "${REPO_ROOT}/environments/test/polluter-wl" ]] \
    || {
      echo "FAIL: Environment fixture polluter-wl still present" >&2
      return 1
    }
  got="$(cat "${REPO_ROOT}/environments/test/committed-wl/manifest.json")"
  [[ "${got}" == '{ "intent": "run" }' ]] \
    || {
      echo "FAIL: committed SoT not restored, got: ${got}" >&2
      return 1
    }
  [[ ! -e "${HOST_ROOT}/var/lib/propraetor/case-a-host-residue" ]] \
    || {
      echo "FAIL: Host residue from case A still present (Deploy baseline skipped?)" >&2
      return 1
    }
}

# --- Counterfactual: A residue + no restore + no Deploy → B fails ---
reset_trackers
case_a_leave_residue
if ( case_b_assert_clean ); then
  fail "case B must fail when case A residue remains and restore/baseline skipped"
fi
pass "case B fails if case A residue remains without restore/baseline"

# --- With SoT restore only: Environment clean, Host residue still fails B ---
reset_trackers
case_a_leave_residue
acceptance_wl_track "polluter-wl"
acceptance_sot_track "committed-wl/manifest.json"
acceptance_data_track "workloads/polluter-wl/persist/owned.bin"
acceptance_wl_cleanup
if ( case_b_assert_clean ); then
  fail "case B must still fail when Deploy baseline skipped (Host residue)"
fi
[[ ! -e "${ACCEPTANCE_HV_DATA_ROOT}/workloads/polluter-wl/persist/owned.bin" ]] \
  || fail "tracked data/ must be cleaned by owning case restore"
pass "SoT/data restore alone is not enough; Host needs Deploy baseline"

# --- Full isolation: A restores + runner Deploy baseline → B passes ---
reset_trackers
# Re-seed Host residue path for a fresh A (cleanup removed data/; SoT restored).
case_a_with_restore
# Simulate runner: Deploy before case B.
acceptance_baseline_deployed
case_b_assert_clean || fail "case B must pass after restore + Deploy baseline"
pass "case B passes when case A restores and Deploy baseline runs"

# --- Runner loop shape: Deploy once per case ---
: >"${TMP}/ensure.count"
cat >"${REPO_ROOT}/internals/ensure.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '1\n' >>"${TMP}/ensure.count"
exit 0
EOF
chmod +x "${REPO_ROOT}/internals/ensure.sh"
for _ in 1 2 3; do
  acceptance_baseline_deployed
done
count="$(wc -l <"${TMP}/ensure.count" | tr -d ' ')"
[[ "${count}" == "3" ]] || fail "Deploy baseline must run once per case (got ${count})"
pass "Deploy baseline invoked once per case in a three-case loop"

echo "All acceptance independence checks passed."
