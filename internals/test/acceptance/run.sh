#!/usr/bin/env bash
# Acceptance Test suite runner — Applied Stack external behavior after Apply (./apply.sh).
# Runs [0-9]*.sh as subprocesses in sort order (fail-fast).
# Invoked via ./test.sh acceptance […] (ADR-0036).
# Suite baseline (ADR-0042 / #162 / #176): Deploy via ensure.sh before each case; non-test
# requires exact 'diagnose <slug>' once at suite start (test/default skips); fixture-class
# cases skipped (full suite) or refused (selector); Environment tree must match HEAD
# on non-test; per-case Environment tree identity gate (minus .ssh/) on all envs.
# Requires: Provider Credential; Operator Configuration private path (and public when Apply runs).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${TEST_DIR}/lib.sh"
# shellcheck source=baseline.sh
source "${TEST_DIR}/baseline.sh"
# shellcheck source=../run-buffered-case.sh
source "${REPO_ROOT}/internals/test/run-buffered-case.sh"
# shellcheck source=internals/lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=internals/lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=internals/lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=internals/lib/operator/operator-configuration.sh
source "${REPO_ROOT}/internals/lib/operator/operator-configuration.sh"

"${REPO_ROOT}/internals/lib/checks/check-stack-names.sh"
"${REPO_ROOT}/internals/lib/checks/check-cloud-init-ascii.sh"
"${REPO_ROOT}/internals/lib/checks/check-ssh-port-twins.sh"
"${REPO_ROOT}/internals/lib/checks/check-domains-config-path.sh"

operator_dotenv_load "${REPO_ROOT}" || exit 1

CLI_env=""
CLI_selector=""
cli_operator_parse CLI pos:selector:optional -- "$@" || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1
acceptance_confirm_diagnose || exit 1
if [[ -n "${CLI_selector}" ]]; then
  set -- "${CLI_selector}"
else
  set --
fi

command -v terraform >/dev/null || fail "terraform not found"
command -v jq >/dev/null || fail "jq not found"
command -v nc >/dev/null || fail "nc not found"
command -v ssh >/dev/null || fail "ssh not found"
command -v ping >/dev/null || fail "ping not found"
command -v curl >/dev/null || fail "curl not found"
provider_credential_require || exit 1
operator_configuration_require private || exit 1

host_session_open verify "${STACK_DIR}" || exit 1
IP="$(host_session_ip)"

RESERVED_IP_JSON="$(do_api_get "/v2/reserved_ips/${IP}" | jq -c '.reserved_ip')"
HOST_ID="$(echo "${RESERVED_IP_JSON}" | jq -r '.droplet.id // empty')"
[[ -n "${HOST_ID}" ]] || fail "Reserved IP ${IP} is not attached to a provider Host"
HOST_JSON="$(do_api_get "/v2/droplets/${HOST_ID}" | jq -c '.droplet')"
[[ -n "${HOST_JSON}" && "${HOST_JSON}" != "null" ]] || fail "Host ${HOST_ID} not found at provider"

export IP RESERVED_IP_JSON HOST_JSON REPO_ROOT PLATFORM_ENV

# Reserved IP survives Host recreate; host keys do not — drop stale entries from the
# Environment-scoped known_hosts store before any SSH case (not ~/.ssh/known_hosts).
propraetor_ssh_forget_host "${IP}"

echo "Checking Reserved IP ${IP} (Environment ${PLATFORM_ENV}) ..."

ALL_CASES=()
while IFS= read -r case_path; do
  [[ -n "${case_path}" ]] || continue
  ALL_CASES+=("${case_path}")
done < <(find "${TEST_DIR}" -maxdepth 1 -type f -name '[0-9]*.sh' | LC_ALL=C sort)

[[ ${#ALL_CASES[@]} -gt 0 ]] || fail "no Acceptance Tests found in ${TEST_DIR}"

CASES=()
if [[ $# -eq 0 ]]; then
  CASES=("${ALL_CASES[@]}")
  FILTERED_CASES=()
  while IFS= read -r case_path; do
    [[ -n "${case_path}" ]] || continue
    FILTERED_CASES+=("${case_path}")
  done < <(acceptance_filter_diagnose_cases "${CASES[@]}")
  CASES=("${FILTERED_CASES[@]}")
  [[ ${#CASES[@]} -gt 0 ]] \
    || fail "no diagnose-runnable Acceptance Tests remain after skipping fixture-class cases"
else
  SELECTOR="$1"
  for case_path in "${ALL_CASES[@]}"; do
    base="$(basename "${case_path}")"
    if [[ "${base}" == *"${SELECTOR}"* ]]; then
      CASES+=("${case_path}")
    fi
  done
  [[ ${#CASES[@]} -gt 0 ]] || fail "no Acceptance Test matches selector: ${SELECTOR}"
  if [[ ${#CASES[@]} -ne 1 ]]; then
    matched=""
    for case_path in "${CASES[@]}"; do
      matched+=" $(basename "${case_path}")"
    done
    fail "selector ${SELECTOR} matched multiple cases:${matched}"
  fi
  acceptance_refuse_if_diagnose_fixture_selector "${CASES[0]}" || exit 1
fi

for case_path in "${CASES[@]}"; do
  label="$(basename "${case_path}")"
  # Deploy ladder to Deployed inside the buffered slot (ADR-0041 / #158 / #162 / #169).
  # After baseline: snapshot Environment tree; after case: assert identical (minus .ssh/).
  run_buffered_case "${label}" "${case_path}" acceptance_baseline_deployed \
    "Baseline: Deploy → Deployed before ${label}" \
    acceptance_env_tree_gate_after_baseline \
    acceptance_env_tree_gate_after_case \
    || fail "Acceptance Test failed: ${label}"
done

echo "All Acceptance Tests passed."
