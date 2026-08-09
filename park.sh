#!/usr/bin/env bash
# Park the Stack — request Recreatable absence through a complete Terraform plan.
# Durables remain configured and protected; the next Apply requests presence again.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Requires: terraform; Provider Credential (DIGITALOCEAN_TOKEN)
# Usage: ./park.sh [--env <slug>]
# Confirm with exact: park
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
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

ABSENCE_VAR=(-var=recreatables_present=false)

fail() { echo "FAIL: $*" >&2; exit 1; }

# Host identity is gone after Park; Reserved IP survives. Drop stale Environment
# known_hosts entries for that IP (ADR-0046). Best-effort — never fail Park.
park_forget_host_keys() {
  local ip=""
  ip="$(terraform output -raw reserved_ip 2>/dev/null || true)"
  [[ -n "${ip}" ]] || return 0
  propraetor_ssh_forget_host "${ip}" || true
}

operator_dotenv_load "${REPO_ROOT}" || exit 1

CLI_env=""
cli_operator_parse CLI -- "$@" || exit 1

command -v terraform >/dev/null || fail "terraform not found"

provider_credential_require || exit 1

cd "${STACK_DIR}"

environment_activate "${STACK_DIR}" "${CLI_env}" || fail "could not select Environment"

adopt_preflight park "${ENVIRONMENT_RAW}" || exit 1

echo "WARNING: Park keeps Durables (Cloud Project, Reserved IP, Host Volume, and Domain)."
echo "         They remain in the provider and continue to bill while Parked."
echo "         Teardown (./teardown.sh) is the full wipe when you intend to stop billing."
echo
echo "Park plan (complete plan with Recreatable presence disabled):"
echo

set +e
terraform plan -detailed-exitcode -input=false "${ABSENCE_VAR[@]}"
plan_rc=$?
set -e

case "${plan_rc}" in
  0)
    echo
    echo "Already Parked (destroy plan empty). Durables still bill if present."
    park_forget_host_keys
    exit 0
    ;;
  1)
    fail "terraform plan failed"
    ;;
  2)
    ;;
  *)
    fail "terraform plan -destroy exited with unexpected code ${plan_rc}"
    ;;
esac

echo
printf "Type exactly 'park' to proceed: "
read -r confirm
[[ "${confirm}" == "park" ]] || fail "aborted (expected exact 'park')"

terraform apply -input=false -auto-approve "${ABSENCE_VAR[@]}"

park_forget_host_keys

echo
echo "Park complete. Durables remain in State/provider and still bill."
echo "To Apply again: ./apply.sh"
