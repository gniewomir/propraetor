#!/usr/bin/env bash
# Unit Test: ordered-suite inventory (ADR-0056) — list, resolve, slice --from.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=suite-cases.sh
source "${REPO_ROOT}/internals/test/suite-cases.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/suite-cases.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

touch "${TMP}/0100-alpha.sh" "${TMP}/0200-beta.sh" "${TMP}/0300-gamma.sh"

list="$(suite_cases_list "${TMP}")" || fail "list valid NNNN- cases"
got=""
while IFS= read -r p; do
  [[ -n "${p}" ]] || continue
  got+="$(basename "${p}") "
done <<< "${list}"
[[ "${got}" == "0100-alpha.sh 0200-beta.sh 0300-gamma.sh " ]] \
  || fail "list order want 0100 0200 0300, got '${got}'"
pass "list is C-sorted NNNN- paths"

EMPTY="${TMP}/empty"
mkdir -p "${EMPTY}"
if suite_cases_list "${EMPTY}" >/dev/null 2>&1; then
  fail "empty dir must fail"
fi
pass "list fails when empty"

touch "${TMP}/80-legacy.sh"
if suite_cases_list "${TMP}" >/dev/null 2>&1; then
  fail "two-digit prefix must fail"
fi
rm -f "${TMP}/80-legacy.sh"
pass "list rejects non-NNNN- basename"

touch "${TMP}/0100-dup.sh"
if suite_cases_list "${TMP}" >/dev/null 2>&1; then
  fail "duplicate numeric prefix must fail"
fi
rm -f "${TMP}/0100-dup.sh"
pass "list rejects duplicate numeric prefix"

A="${TMP}/0100-alpha.sh"
B="${TMP}/0200-beta.sh"
C="${TMP}/0300-gamma.sh"

r="$(suite_cases_resolve 200 "${A}" "${B}" "${C}")" || fail "resolve 200"
[[ "$(basename "${r}")" == "0200-beta.sh" ]] || fail "200 should be 0200-beta, got ${r}"
pass "all-digits token matches numeric prefix (200 == 0200)"

r="$(suite_cases_resolve 0200 "${A}" "${B}" "${C}")" || fail "resolve 0200"
[[ "$(basename "${r}")" == "0200-beta.sh" ]] || fail "0200 should be 0200-beta"
pass "leading zeros in token are the same prefix"

r="$(suite_cases_resolve beta "${A}" "${B}" "${C}")" || fail "resolve beta"
[[ "$(basename "${r}")" == "0200-beta.sh" ]] || fail "substring beta"
pass "non-digit token is unique basename substring"

if suite_cases_resolve 99 "${A}" "${B}" "${C}" >/dev/null 2>&1; then
  fail "missing prefix must fail"
fi
pass "resolve fails when prefix is absent"

if suite_cases_resolve "0" "${A}" "${B}" "${C}" >/dev/null 2>&1; then
  fail "token 0 must not match 0100/0200/0300"
fi
pass "token 0 is prefix 0, not a substring of 0100"

if suite_cases_resolve a "${A}" "${B}" "${C}" >/dev/null 2>&1; then
  fail "substring a matches alpha and gamma"
fi
pass "ambiguous substring fails"

slice="$(suite_cases_from "${B}" "${A}" "${B}" "${C}")" || fail "from 0200"
got=""
while IFS= read -r p; do
  [[ -n "${p}" ]] || continue
  got+="$(basename "${p}") "
done <<< "${slice}"
[[ "${got}" == "0200-beta.sh 0300-gamma.sh " ]] || fail "from slice want beta gamma, got '${got}'"
pass "--from is inclusive remainder"

if suite_cases_from "${TMP}/nope.sh" "${A}" "${B}" "${C}" >/dev/null 2>&1; then
  fail "from unknown path must fail"
fi
pass "--from fails when start is not in the list"

# Live suite trees after ADR-0056 resequence.
acc_list="$(suite_cases_list "${REPO_ROOT}/internals/test/acceptance")" \
  || fail "acceptance list"
life_list="$(suite_cases_list "${REPO_ROOT}/internals/test/lifecycle")" \
  || fail "lifecycle list"
acc_n=0
life_n=0
acc_first=""
acc_last=""
while IFS= read -r p; do
  [[ -n "${p}" ]] || continue
  acc_n=$((acc_n + 1))
  [[ -n "${acc_first}" ]] || acc_first="$(basename "${p}")"
  acc_last="$(basename "${p}")"
done <<< "${acc_list}"
while IFS= read -r p; do
  [[ -n "${p}" ]] || continue
  life_n=$((life_n + 1))
done <<< "${life_list}"
[[ "${acc_n}" -eq 55 ]] || fail "acceptance case count want 55 got ${acc_n}"
[[ "${life_n}" -eq 6 ]] || fail "lifecycle case count want 6 got ${life_n}"
[[ "${acc_first}" == "0100-host-metadata.sh" ]] || fail "acceptance first want 0100-host-metadata.sh got ${acc_first}"
[[ "${acc_last}" == "5500-cache-operator-console.sh" ]] || fail "acceptance last want 5500-cache-operator-console.sh got ${acc_last}"
pass "live Acceptance/Lifecycle trees are NNNN- unique and layered"

echo "All suite-cases checks passed."
