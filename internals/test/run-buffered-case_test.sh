#!/usr/bin/env bash
# Unit Test: run_buffered_case quiet-on-pass / dump-on-fail (optional baseline slot).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=run-buffered-case.sh
source "${REPO_ROOT}/internals/test/run-buffered-case.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-buffered-case.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

PASS_CASE="${TMP}/pass.sh"
FAIL_CASE="${TMP}/fail.sh"
cat >"${PASS_CASE}" <<'EOF'
#!/usr/bin/env bash
echo "pass-noise-should-be-hidden"
exit 0
EOF
cat >"${FAIL_CASE}" <<'EOF'
#!/usr/bin/env bash
echo "fail-noise-must-appear"
exit 1
EOF
chmod +x "${PASS_CASE}" "${FAIL_CASE}"

out="$(TEST_VERBOSE=0 run_buffered_case "pass-label" "${PASS_CASE}" 2>&1)" || fail "pass case should return 0"
echo "${out}" | grep -Fq -- '--- pass-label ---' || fail "pass case missing header: ${out}"
echo "${out}" | grep -Fq -- 'pass-noise-should-be-hidden' && fail "pass case leaked buffered output: ${out}"
pass "quiet on pass (header only)"

set +e
out="$(TEST_VERBOSE=0 run_buffered_case "fail-label" "${FAIL_CASE}" 2>&1)"
rc=$?
set -e
[[ ${rc} -ne 0 ]] || fail "fail case should return non-zero"
echo "${out}" | grep -Fq -- '--- fail-label ---' || fail "fail case missing header: ${out}"
echo "${out}" | grep -Fq -- 'fail-noise-must-appear' || fail "fail case did not dump log: ${out}"
pass "dump log on fail"

# TEST_VERBOSE=1 streams live (noise visible even on pass).
out="$(TEST_VERBOSE=1 run_buffered_case "verbose-pass" "${PASS_CASE}" 2>&1)" \
  || fail "verbose pass case should return 0"
echo "${out}" | grep -Fq -- '--- verbose-pass ---' || fail "verbose pass missing header: ${out}"
echo "${out}" | grep -Fq -- 'pass-noise-should-be-hidden' \
  || fail "verbose pass should stream case output: ${out}"
pass "TEST_VERBOSE=1 streams on pass"

# Optional baseline: quiet on pass hides marker + baseline noise.
BASELINE_RECORD="${TMP}/baseline.record"
stub_baseline_ok() {
  echo "baseline-ok" >>"${BASELINE_RECORD}"
  echo "baseline-noise-should-be-hidden"
}

out="$(TEST_VERBOSE=0 run_buffered_case "slot-pass" "${PASS_CASE}" stub_baseline_ok \
  "Baseline: stub before slot-pass" 2>&1)" || fail "slot pass should return 0"
echo "${out}" | grep -Fq -- '--- slot-pass ---' || fail "slot pass missing header: ${out}"
echo "${out}" | grep -Fq -- 'Baseline: stub before slot-pass' \
  && fail "slot pass leaked baseline marker: ${out}"
echo "${out}" | grep -Fq -- 'baseline-noise-should-be-hidden' \
  && fail "slot pass leaked baseline noise: ${out}"
echo "${out}" | grep -Fq -- 'pass-noise-should-be-hidden' \
  && fail "slot pass leaked case noise: ${out}"
grep -Fxq 'baseline-ok' "${BASELINE_RECORD}" || fail "baseline fn must run on slot pass"
pass "quiet on pass hides baseline marker and noise"

# Baseline failure dumps marker + baseline output; case must not run.
CASE_RAN="${TMP}/case.ran"
FAIL_IF_RAN="${TMP}/fail-if-ran.sh"
cat >"${FAIL_IF_RAN}" <<EOF
#!/usr/bin/env bash
touch "${CASE_RAN}"
exit 0
EOF
chmod +x "${FAIL_IF_RAN}"
stub_baseline_fail() {
  echo "baseline-boom"
  return 1
}
set +e
out="$(TEST_VERBOSE=0 run_buffered_case "slot-baseline-fail" "${FAIL_IF_RAN}" stub_baseline_fail \
  "Baseline: stub before slot-baseline-fail" 2>&1)"
rc=$?
set -e
[[ ${rc} -ne 0 ]] || fail "baseline fail should return non-zero"
echo "${out}" | grep -Fq -- 'Baseline: stub before slot-baseline-fail' \
  || fail "baseline fail dump missing marker: ${out}"
echo "${out}" | grep -Fq -- 'baseline-boom' || fail "baseline fail dump missing noise: ${out}"
[[ ! -e "${CASE_RAN}" ]] || fail "case must not run when baseline fails"
pass "dump marker + baseline on baseline fail; skip case"

# Case failure after successful baseline dumps marker + baseline + case.
rm -f "${BASELINE_RECORD}"
stub_baseline_before_case_fail() {
  echo "baseline-ok" >>"${BASELINE_RECORD}"
  echo "baseline-before-case-fail"
}
set +e
out="$(TEST_VERBOSE=0 run_buffered_case "slot-case-fail" "${FAIL_CASE}" stub_baseline_before_case_fail \
  "Baseline: stub before slot-case-fail" 2>&1)"
rc=$?
set -e
[[ ${rc} -ne 0 ]] || fail "case fail after baseline should return non-zero"
echo "${out}" | grep -Fq -- 'Baseline: stub before slot-case-fail' \
  || fail "case fail dump missing marker: ${out}"
echo "${out}" | grep -Fq -- 'baseline-before-case-fail' \
  || fail "case fail dump missing baseline noise: ${out}"
echo "${out}" | grep -Fq -- 'fail-noise-must-appear' \
  || fail "case fail dump missing case noise: ${out}"
grep -Fxq 'baseline-ok' "${BASELINE_RECORD}" || fail "baseline fn must run before failing case"
pass "dump marker + baseline + case on case fail"

# Verbose streams marker + baseline + case on pass.
rm -f "${BASELINE_RECORD}"
out="$(TEST_VERBOSE=1 run_buffered_case "slot-verbose" "${PASS_CASE}" stub_baseline_ok \
  "Baseline: stub before slot-verbose" 2>&1)" \
  || fail "verbose slot pass should return 0"
echo "${out}" | grep -Fq -- 'Baseline: stub before slot-verbose' \
  || fail "verbose slot should stream marker: ${out}"
echo "${out}" | grep -Fq -- 'baseline-noise-should-be-hidden' \
  || fail "verbose slot should stream baseline noise: ${out}"
echo "${out}" | grep -Fq -- 'pass-noise-should-be-hidden' \
  || fail "verbose slot should stream case output: ${out}"
pass "TEST_VERBOSE=1 streams baseline marker and case"

# Optional after_baseline / after_case hooks (Acceptance Environment tree gate).
MID_RECORD="${TMP}/mid.record"
GATE_RECORD="${TMP}/gate.record"
stub_after_baseline() {
  echo "snap-token" | tee -a "${MID_RECORD}"
}
stub_after_case_ok() {
  local mid="$1"
  local case_rc="$2"
  printf 'mid=%s rc=%s\n' "${mid}" "${case_rc}" >>"${GATE_RECORD}"
  [[ "${mid}" == "snap-token" ]] || return 1
  return 0
}
stub_after_case_fail() {
  echo "gate-boom"
  return 1
}

: >"${MID_RECORD}"
: >"${GATE_RECORD}"
out="$(TEST_VERBOSE=0 run_buffered_case "slot-gate-pass" "${PASS_CASE}" stub_baseline_ok \
  "Baseline: gate pass" stub_after_baseline stub_after_case_ok 2>&1)" \
  || fail "gate pass should return 0"
grep -Fxq 'snap-token' "${MID_RECORD}" || fail "after_baseline must run"
grep -Fq 'mid=snap-token rc=0' "${GATE_RECORD}" || fail "after_case must see mid+rc"
echo "${out}" | grep -Fq -- 'gate-boom' && fail "quiet pass leaked gate noise: ${out}"
pass "after_baseline and after_case run on pass"

set +e
out="$(TEST_VERBOSE=0 run_buffered_case "slot-gate-fail" "${PASS_CASE}" stub_baseline_ok \
  "Baseline: gate fail" stub_after_baseline stub_after_case_fail 2>&1)"
rc=$?
set -e
[[ ${rc} -ne 0 ]] || fail "after_case failure must fail the slot"
echo "${out}" | grep -Fq -- 'gate-boom' || fail "after_case failure must dump log: ${out}"
pass "after_case failure fails slot and dumps log"

echo "All run-buffered-case checks passed."
