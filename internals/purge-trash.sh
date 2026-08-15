#!/usr/bin/env bash
# Purge — permanently remove every Workload whose Intent is trash and its Workload-associated data
# (units, Host Volume Workload tree including Route Declaration SoT). Does not write Edge Route
# interior (Edge Component Setup gather drops fulfillment). Does not delete Domains or
# Domain-scoped certificate material. Does not affect Workloads whose Intent is run or stop.
# Distinct from Orphan Reap (Environment-absence destroy). Names still in the Environment only.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/purge-trash.sh [--env <slug>]
# Optional: PLATFORM_USER=platform
# Requires: Operator Configuration private key path (PROPRAETOR_PRIVATE_KEY_PATH).
# ADR-0041 / #157.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
USER_NAME="${PLATFORM_USER:-platform}"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/purge-trash-host.sh"
UNITS_LIB="${REPO_ROOT}/internals/host-scripts/lib/workload-units-host.sh"
QUADLETS_LIB="${REPO_ROOT}/internals/host-scripts/lib/workload-quadlets-host.sh"
UNIT_CONSUMERS_LIB="${REPO_ROOT}/internals/host-scripts/lib/unit-consumers-host.sh"
ENV_HOST_LIB="${REPO_ROOT}/internals/host-scripts/lib/workload-environment-host.sh"
QUADLET_SESSION_LIB="${REPO_ROOT}/internals/host-scripts/lib/quadlet-user-session.sh"
PATHS_LIB="${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh"
# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
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

operator_dotenv_load "${REPO_ROOT}" || exit 1
operator_configuration_require private || exit 1

CLI_env=""
cli_operator_parse CLI -- "$@" || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1

[[ -f "${HOST_SCRIPT}" ]] || {
  echo "missing ${HOST_SCRIPT}" >&2
  exit 1
}
[[ -f "${UNITS_LIB}" ]] || {
  echo "missing ${UNITS_LIB}" >&2
  exit 1
}
[[ -f "${QUADLETS_LIB}" ]] || {
  echo "missing ${QUADLETS_LIB}" >&2
  exit 1
}
[[ -f "${UNIT_CONSUMERS_LIB}" ]] || {
  echo "missing ${UNIT_CONSUMERS_LIB}" >&2
  exit 1
}
[[ -f "${ENV_HOST_LIB}" ]] || {
  echo "missing ${ENV_HOST_LIB}" >&2
  exit 1
}
[[ -f "${QUADLET_SESSION_LIB}" ]] || {
  echo "missing ${QUADLET_SESSION_LIB}" >&2
  exit 1
}
[[ -f "${PATHS_LIB}" ]] || {
  echo "missing ${PATHS_LIB}" >&2
  exit 1
}

command -v terraform >/dev/null || { echo "terraform not found" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh not found" >&2; exit 1; }

host_session_open verify "${STACK_DIR}" || exit 1
IP="$(host_session_ip)"

STAGE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-purge-trash-stage.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
cp "${HOST_SCRIPT}" "${STAGE}/purge-trash-host.sh"
cp "${UNITS_LIB}" "${STAGE}/workload-units-host.sh"
cp "${QUADLETS_LIB}" "${STAGE}/workload-quadlets-host.sh"
cp "${UNIT_CONSUMERS_LIB}" "${STAGE}/unit-consumers-host.sh"
cp "${ENV_HOST_LIB}" "${STAGE}/workload-environment-host.sh"
cp "${QUADLET_SESSION_LIB}" "${STAGE}/quadlet-user-session.sh"
cp "${PATHS_LIB}" "${STAGE}/host-volume-paths-host.sh"

host_delivery_run "${STAGE}" "/tmp/platform-purge-trash" \
  "PLATFORM_USER=${USER_NAME} bash /tmp/platform-purge-trash/purge-trash-host.sh"

echo "Purge completed on ${IP}."
