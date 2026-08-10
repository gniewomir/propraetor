#!/usr/bin/env bash
# Apply the Stack — converge Durables and request Recreatable presence (ADR-0025).
# Plans first; an empty presence plan means Already Applied (stable condition).
# Interactive by default (plan + Terraform apply confirm). Use --yes for automation.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Closed surface: optional --yes and --env only. Specialist surgery stays raw terraform
# in the Stack dir.
# Requires: terraform; Provider Credential; Operator Configuration (both key paths).
# Usage: ./apply.sh [--yes] [--env <slug>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
PRESENCE_VAR=(-var=recreatables_present=true)
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

fail() { echo "FAIL: $*" >&2; exit 1; }

operator_dotenv_load "${REPO_ROOT}" || exit 1

CLI_yes=0
CLI_env=""
cli_operator_parse CLI flag:yes:bool -- "$@" || exit 1
YES=false
[[ "${CLI_yes}" -eq 1 ]] && YES=true

command -v terraform >/dev/null || fail "terraform not found"

"${REPO_ROOT}/internals/lib/checks/check-cloud-init-ascii.sh"
"${REPO_ROOT}/internals/lib/checks/check-ssh-port-twins.sh"
"${REPO_ROOT}/internals/lib/checks/check-domains-config-path.sh"

provider_credential_require || exit 1
operator_configuration_require both || exit 1
operator_configuration_export_host_root_ssh_public_key || exit 1
environments_export_tf_var || exit 1

cd "${STACK_DIR}"

environment_activate "${STACK_DIR}" "${CLI_env}" || fail "could not select Environment"

adopt_preflight apply "${ENVIRONMENT_RAW}" || exit 1

echo "Apply plan (complete plan with Recreatable presence enabled):"
echo

set +e
terraform plan -detailed-exitcode -input=false "${PRESENCE_VAR[@]}"
plan_rc=$?
set -e

case "${plan_rc}" in
  0)
    echo
    echo "Already Applied (presence plan empty)."
    exit 0
    ;;
  1)
    fail "terraform plan failed"
    ;;
  2)
    ;;
  *)
    fail "terraform plan exited with unexpected code ${plan_rc}"
    ;;
esac

if [[ "${YES}" == true ]]; then
  terraform apply -input=false -auto-approve "${PRESENCE_VAR[@]}"
else
  terraform apply "${PRESENCE_VAR[@]}"
fi

echo
echo "Apply complete."
