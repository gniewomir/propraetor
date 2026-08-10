#!/usr/bin/env bash
# Unit Test suite runner — colocated internals/**/*_test.sh (ADR-0036).
# Invoked via ./test.sh unit [<case-selector>]. No --env (dispatcher rejects it).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INTERNALS="${REPO_ROOT}/internals"
# shellcheck source=../run-buffered-case.sh
source "${REPO_ROOT}/internals/test/run-buffered-case.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

ALL_CASES=()
while IFS= read -r case_path; do
  [[ -n "${case_path}" ]] || continue
  ALL_CASES+=("${case_path}")
done < <(find "${INTERNALS}" -type f -name '*_test.sh' | LC_ALL=C sort)

[[ ${#ALL_CASES[@]} -gt 0 ]] || fail "no Unit Tests found under ${INTERNALS}"

CASES=()
if [[ $# -eq 0 ]]; then
  CASES=("${ALL_CASES[@]}")
else
  SELECTOR="$1"
  shift
  [[ $# -eq 0 ]] || fail "unexpected arguments after case-selector"
  for case_path in "${ALL_CASES[@]}"; do
    base="$(basename "${case_path}")"
    # Match basename or full path so selectors like lib/environment_test work.
    if [[ "${base}" == *"${SELECTOR}"* || "${case_path}" == *"${SELECTOR}"* ]]; then
      CASES+=("${case_path}")
    fi
  done
  [[ ${#CASES[@]} -gt 0 ]] || fail "no Unit Test matches selector: ${SELECTOR}"
  if [[ ${#CASES[@]} -ne 1 ]]; then
    matched=""
    for case_path in "${CASES[@]}"; do
      matched+=" ${case_path#"${REPO_ROOT}/"}"
    done
    fail "selector ${SELECTOR} matched multiple cases:${matched}"
  fi
fi

export PROPRAETOR_UNIT_TEST=1
unset PROPRAETOR_ENVIRONMENTS_ROOT

for case_path in "${CASES[@]}"; do
  rel="${case_path#"${REPO_ROOT}/"}"
  run_buffered_case "${rel}" "${case_path}" || fail "Unit Test failed: ${rel}"
done

echo "All Unit Tests passed."
