#!/usr/bin/env bash
# CLI seam for ./test.sh (ADR-0036 / ADR-0039 / docs/agents/testing.md).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEST_SH="${REPO_ROOT}/test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -x "${TEST_SH}" ]] || fail "missing executable ${TEST_SH}"

run_test_sh() {
  set +e
  OUT="$("${TEST_SH}" "$@" 2>&1)"
  STATUS=$?
  set -e
}

assert_help_and_fail() {
  local label="$1"
  shift
  run_test_sh "$@"
  [[ "${STATUS}" -ne 0 ]] || fail "${label}: expected non-zero exit, got 0"
  [[ "${OUT}" == *"Usage:"* ]] || fail "${label}: expected Usage help, got: ${OUT}"
  pass "${label}"
}

assert_help_and_fail "no args"
assert_help_and_fail "unknown suite" not-a-suite
assert_help_and_fail "suite after --env" --env test acceptance
assert_help_and_fail "unit rejects --env" unit --env test
assert_help_and_fail "unit rejects --env with selector" unit environment_test --env test
assert_help_and_fail "--env missing slug" acceptance --env
assert_help_and_fail "too many positionals" acceptance one two
assert_help_and_fail "selector after flags" acceptance --env test 1100-podman
assert_help_and_fail "unit rejects --from" unit --from 1100
assert_help_and_fail "selector and --from together" acceptance 1100-podman --from 2000
assert_help_and_fail "unknown flag" unit --bogus

# Dispatch reached the unit runner (unknown selector is a suite-level error, not Usage).
run_test_sh unit __no_such_unit_test_selector__
[[ "${STATUS}" -ne 0 ]] || fail "unit unknown selector: expected non-zero"
[[ "${OUT}" != *"Usage:"* ]] || fail "unit unknown selector: should not be dispatcher Usage"
[[ "${OUT}" == *"no Unit Test matches"* || "${OUT}" == *"matches selector"* ]] \
  || fail "unit unknown selector: unexpected output: ${OUT}"
pass "unit dispatches to suite runner"

# --verbose after positionals is accepted by the dispatcher.
run_test_sh unit __no_such_unit_test_selector__ --verbose
[[ "${STATUS}" -ne 0 ]] || fail "unit selector --verbose: expected non-zero"
[[ "${OUT}" != *"Usage:"* ]] || fail "unit selector --verbose: should not be dispatcher Usage"
[[ "${OUT}" == *"no Unit Test matches"* || "${OUT}" == *"matches selector"* ]] \
  || fail "unit selector --verbose: unexpected output: ${OUT}"
pass "unit selector --verbose dispatches"

# Flag before selector is rejected (positionals then flags).
assert_help_and_fail "verbose before selector" unit --verbose __no_such_unit_test_selector__

echo "All ./test.sh CLI checks passed."
