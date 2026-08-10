#!/usr/bin/env bash
# Lifecycle Test suite runner — Park / Apply-after-Park / Teardown (destructive; opt-in).
# Invoked via ./test.sh lifecycle […] (ADR-0036). See README.md.
# Suite baseline (ADR-0042 / #161 / #177): test Environment only; suite confirm 'teardown'
# after case inventory and before credential / Host work; Teardown via ./teardown.sh
# before each case (Stack absent).
# Requires: terraform; curl; jq; ssh; Provider Credential; Operator Configuration (both paths).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
# shellcheck source=internals/lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=internals/lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=internals/lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=internals/lib/operator/operator-configuration.sh
source "${REPO_ROOT}/internals/lib/operator/operator-configuration.sh"
# shellcheck source=../run-buffered-case.sh
source "${REPO_ROOT}/internals/test/run-buffered-case.sh"
# shellcheck source=lib/baseline.sh
source "${CASE_DIR}/lib/baseline.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

operator_dotenv_load "${REPO_ROOT}" || exit 1
environments_forbid_relocated_root || exit 1

CLI_env=""
CLI_selector=""
cli_operator_parse CLI pos:selector:optional -- "$@" || exit 1
# Fail closed before selecting a non-test workspace (ADR-0042 / #161).
PLATFORM_ENV="$(environment_slug_for "${CLI_env}")" || exit 1
export PLATFORM_ENV
lifecycle_require_test_environment || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1
if [[ -n "${CLI_selector}" ]]; then
  set -- "${CLI_selector}"
else
  set --
fi

export REPO_ROOT STACK_DIR PLATFORM_ENV

ALL_CASES=()
while IFS= read -r case_path; do
  [[ -n "${case_path}" ]] || continue
  ALL_CASES+=("${case_path}")
done < <(find "${CASE_DIR}" -maxdepth 1 -type f -name '[0-9]*.sh' | LC_ALL=C sort)

[[ ${#ALL_CASES[@]} -gt 0 ]] || fail "no Lifecycle Test cases found in ${CASE_DIR}"

CASES=()
if [[ $# -eq 0 ]]; then
  CASES=("${ALL_CASES[@]}")
else
  SELECTOR="$1"
  for case_path in "${ALL_CASES[@]}"; do
    base="$(basename "${case_path}")"
    if [[ "${base}" == *"${SELECTOR}"* ]]; then
      CASES+=("${case_path}")
    fi
  done
  [[ ${#CASES[@]} -gt 0 ]] || fail "no Lifecycle Test matches selector: ${SELECTOR}"
  if [[ ${#CASES[@]} -ne 1 ]]; then
    matched=""
    for case_path in "${CASES[@]}"; do
      matched+=" $(basename "${case_path}")"
    done
    fail "selector ${SELECTOR} matched multiple cases:${matched}"
  fi
fi

echo "Lifecycle Tests (destructive; may leave Stack Parked or empty)."
echo "Environment: ${PLATFORM_ENV}"
echo "Cases: ${#CASES[@]} — see ${CASE_DIR}/README.md"
echo

# Suite confirm before tools / credentials so wrong confirm is Host-free (#177).
lifecycle_confirm_suite_teardown || exit 1

command -v terraform >/dev/null || fail "terraform not found"
command -v curl >/dev/null || fail "curl not found"
command -v jq >/dev/null || fail "jq not found"
command -v ssh >/dev/null || fail "ssh not found"

provider_credential_require || exit 1
operator_configuration_require both || exit 1
[[ -d "${STACK_DIR}" ]] || fail "missing Stack dir ${STACK_DIR}"

for case_path in "${CASES[@]}"; do
  label="$(basename "${case_path}")"
  # Teardown → Stack absent inside the buffered slot (ADR-0042 / #161 / #169).
  run_buffered_case "${label}" "${case_path}" lifecycle_baseline_stack_absent \
    "Baseline: Teardown → Stack absent before ${label}" \
    || fail "Lifecycle Test failed: ${label}"
done

echo "All Lifecycle Tests passed."
