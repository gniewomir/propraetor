#!/usr/bin/env bash
# Workload Setup — apply one Workload from the Environment tree on the Host (after Components).
# Idempotent: identical Host Volume SoT bag (and Intent run unit files when required) → noop (ADR-0033).
# Payload assembly: workload_setup_stage_payload; Host apply: workload_setup_apply (#233).
# Host delivery remains the SSH adapter. Edge gathers Routes from SoT (ADR-0040).
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/ensure-workload.sh <workload-name> [--env <slug>]
# Resolves to environments/<slug>/<name>/ (fail closed). Identity = directory basename (ADR-0024).
# Optional: PLATFORM_USER=platform
# Requires: Operator Configuration private key path (PROPRAETOR_PRIVATE_KEY_PATH).
# ADR-0047 / ADR-0041 / #157 / #233.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
USER_NAME="${PLATFORM_USER:-platform}"
# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=lib/artifact/manifest.sh
source "${REPO_ROOT}/internals/lib/artifact/manifest.sh"
# shellcheck source=lib/artifact/source.sh
source "${REPO_ROOT}/internals/lib/artifact/source.sh"
# shellcheck source=lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=lib/ssh.sh
source "${REPO_ROOT}/internals/lib/ssh.sh"
# shellcheck source=lib/host-delivery.sh
source "${REPO_ROOT}/internals/lib/host-delivery.sh"
# shellcheck source=lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=lib/operator/operator-configuration.sh
source "${REPO_ROOT}/internals/lib/operator/operator-configuration.sh"
# shellcheck source=lib/workload/setup.sh
source "${REPO_ROOT}/internals/lib/workload/setup.sh"

operator_dotenv_load "${REPO_ROOT}" || exit 1
operator_configuration_require private || exit 1

CLI_env=""
CLI_workload=""
cli_operator_parse CLI pos:workload:required -- "$@" || {
  echo "Usage: $0 <workload-name> [--env <slug>]" >&2
  exit 1
}
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1
WL_NAME="${CLI_workload}"

# Fail-fast identity before session / stage (same module Host apply uses).
workload_identity_require "${WL_NAME}" || exit 1

ENV_DIR="$(environments_dir_for "${PLATFORM_ENV}")" || exit 1

if [[ "${PROPRAETOR_IDENTITY_PERMISSION_CATALOGS_UNIQUENESS_VALIDATED:-0}" != "1" ]]; then
  # Uniqueness + marker contracts must hold for the whole Environment so
  # downstream Identity behavior can assume a consistent permission catalog.
  environment_identity_permission_catalogs_validate "${ENV_DIR}" || exit 1
fi

MANIFEST_DIR="${ENV_DIR}/${WL_NAME}"
MANIFEST_ABS="${MANIFEST_DIR}/manifest.json"
[[ -d "${MANIFEST_DIR}" ]] || {
  echo "Workload tree not found: ${MANIFEST_DIR}/" >&2
  exit 1
}
[[ -f "${MANIFEST_ABS}" ]] || {
  echo "manifest.json missing in ${MANIFEST_DIR}/" >&2
  exit 1
}
artifact_manifest_validate "${MANIFEST_ABS}" || exit 1
artifact_source_tree_gate "${MANIFEST_DIR}" || exit 1

command -v terraform >/dev/null || { echo "terraform not found" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

host_session_open verify "${STACK_DIR}" || exit 1
IP="$(host_session_ip)"

STAGE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-ensure-workload-stage.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT

RESOLVED_REMOTE_ROOT="/tmp/platform-ensure-workload"
workload_setup_stage_payload "${STAGE}" "${RESOLVED_REMOTE_ROOT}" "${MANIFEST_DIR}" || exit 1

host_delivery_run "${STAGE}" "${RESOLVED_REMOTE_ROOT}" \
  "PLATFORM_USER=${USER_NAME} WL_ENV_RESOLVED=${WL_ENV_RESOLVED_REMOTE} bash ${RESOLVED_REMOTE_ROOT}/ensure-workload-host.sh ${RESOLVED_REMOTE_ROOT}/${WL_NAME}"

echo "Workload Setup finished on ${IP}."
