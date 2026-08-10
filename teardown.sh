#!/usr/bin/env bash
# Teardown the Stack — full wipe including all Durables.
# Temporarily unlocks the Durable module and removes the override afterward.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Requires: terraform; Provider Credential (DIGITALOCEAN_TOKEN)
# Usage: ./teardown.sh [--env <slug>]
# Confirm with exact: teardown
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
OVERRIDE="${STACK_DIR}/modules/durables/durable_destroy_override.tf"
OVERRIDE_EXAMPLE="${STACK_DIR}/modules/durables/durable_destroy_override.tf.example"
UNLOCK_VAR=(-var=allow_durable_destroy=true)
# shellcheck source=internals/lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=internals/lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=internals/lib/adopt/adopt.sh
source "${REPO_ROOT}/internals/lib/adopt/adopt.sh"
# shellcheck source=internals/lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=internals/lib/operator/operator-configuration.sh
source "${REPO_ROOT}/internals/lib/operator/operator-configuration.sh"
# shellcheck source=internals/lib/ssh.sh
source "${REPO_ROOT}/internals/lib/ssh.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

remove_override() {
  rm -f "${OVERRIDE}"
}

operator_dotenv_load "${REPO_ROOT}" || exit 1

CLI_env=""
cli_operator_parse CLI -- "$@" || exit 1

command -v terraform >/dev/null || fail "terraform not found"
[[ -f "${OVERRIDE_EXAMPLE}" ]] || fail "missing ${OVERRIDE_EXAMPLE}"

provider_credential_require || exit 1
environments_export_tf_var || exit 1

cd "${STACK_DIR}"

environment_activate "${STACK_DIR}" "${CLI_env}" || fail "could not select Environment"

adopt_preflight teardown "${ENVIRONMENT_RAW}" || exit 1

# Never leave the Durable unlock armed after this script exits.
trap remove_override EXIT

state_addrs=()
while IFS= read -r addr; do
  [[ -z "${addr}" ]] && continue
  state_addrs+=("${addr}")
done < <(terraform state list)

if [[ ${#state_addrs[@]} -eq 0 ]]; then
  echo
  echo "Already empty (State has no addresses). Nothing to Teardown."
  exit 0
fi

cp "${OVERRIDE_EXAMPLE}" "${OVERRIDE}"

echo "WARNING: Teardown permanently removes every Stack-managed resource,"
echo "         including Durables (Cloud Project, Reserved IP, Host Volume, and Domain)."
echo "         Billing for those Durables stops only after this wipe."
echo "         Prefer Park (./park.sh) when you intend to Apply again soon."
echo
echo "Teardown plan (full destroy with Durable unlock):"
echo
echo "State addresses:"
printf '  %s\n' "${state_addrs[@]}"
echo

set +e
terraform plan -destroy -detailed-exitcode -input=false "${UNLOCK_VAR[@]}"
plan_rc=$?
set -e

case "${plan_rc}" in
  0)
    echo
    echo "Already empty (destroy plan empty)."
    exit 0
    ;;
  1)
    fail "terraform plan -destroy failed"
    ;;
  2)
    ;;
  *)
    fail "terraform plan -destroy exited with unexpected code ${plan_rc}"
    ;;
esac

echo
printf "Type exactly 'teardown' to proceed: "
read -r confirm
[[ "${confirm}" == "teardown" ]] || fail "aborted (expected exact 'teardown')"

terraform destroy -input=false -auto-approve "${UNLOCK_VAR[@]}"

# Reserved IP is gone — drop Environment-scoped Host keys (not ~/.ssh/known_hosts).
propraetor_ssh_known_hosts_reset || true

echo
echo "Teardown complete. State should be empty; Durables are gone from the provider."
echo "To Apply again: ./apply.sh"
