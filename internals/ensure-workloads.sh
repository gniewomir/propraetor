#!/usr/bin/env bash
# Workload Setup (batch) — apply Setup for every Environment-discovered Workload.
# Discovers Workloads as immediate non-hidden Environment dirs (same as Mirror); invokes singular
# ensure-workload for each so SoT sync + Intent + Environment Configuration stay complete.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/ensure-workloads.sh [--env <slug>]
# Optional: PLATFORM_USER=platform
# Requires: Operator Configuration private key path (PROPRAETOR_PRIVATE_KEY_PATH).
# ADR-0041 / #157.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
ENSURE_WORKLOAD="${REPO_ROOT}/internals/ensure-workload.sh"
# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=lib/environment/environment-workloads.sh
source "${REPO_ROOT}/internals/lib/environment/environment-workloads.sh"
# shellcheck source=host-scripts/lib/workload-identity-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-identity-host.sh"
# shellcheck source=lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=lib/operator/operator-configuration.sh
source "${REPO_ROOT}/internals/lib/operator/operator-configuration.sh"

operator_dotenv_load "${REPO_ROOT}" || exit 1
operator_configuration_require private || exit 1

CLI_env=""
cli_operator_parse CLI -- "$@" || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1

[[ -x "${ENSURE_WORKLOAD}" || -f "${ENSURE_WORKLOAD}" ]] || {
  echo "missing ${ENSURE_WORKLOAD}" >&2
  exit 1
}

ENV_DIR="$(environments_dir_for "${PLATFORM_ENV}")" || exit 1

# Fail-fast Identity permission marker contracts + uniqueness within this
# Environment before applying any workload.
environment_identity_permission_catalogs_validate "${ENV_DIR}" || exit 1
export PROPRAETOR_IDENTITY_PERMISSION_CATALOGS_UNIQUENESS_VALIDATED=1

count=0
while IFS= read -r wl_name; do
  [[ -n "${wl_name}" ]] || continue
  # Child must not inherit the discovery pipe as stdin (would steal remaining names).
  "${ENSURE_WORKLOAD}" "${wl_name}" --env "${PLATFORM_ENV}" </dev/null || exit 1
  count=$((count + 1))
done < <(environment_discover_workloads "${ENV_DIR}")

echo "Workload Setup (batch) finished (${count} Workload(s))."
