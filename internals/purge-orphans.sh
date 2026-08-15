#!/usr/bin/env bash
# Orphan Reap — remove Host Workloads absent from the Environment.
# Discovers Environment Workloads as immediate non-hidden dirs; Host basenames not in that set are
# destroyed (volume trees including Persist, units, EnvironmentFiles). Sole Host destroy path (ADR-0054 / #217).
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/purge-orphans.sh [--env <slug>]
# Optional: PLATFORM_USER=platform
# Requires: Operator Configuration private key path (PROPRAETOR_PRIVATE_KEY_PATH).
# ADR-0047 / ADR-0041 / #156.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
USER_NAME="${PLATFORM_USER:-platform}"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/purge-orphans-host.sh"
UNITS_LIB="${REPO_ROOT}/internals/host-scripts/lib/workload-units-host.sh"
QUADLETS_LIB="${REPO_ROOT}/internals/host-scripts/lib/workload-quadlets-host.sh"
UNIT_CONSUMERS_LIB="${REPO_ROOT}/internals/host-scripts/lib/unit-consumers-host.sh"
ENV_HOST_LIB="${REPO_ROOT}/internals/host-scripts/lib/workload-environment-host.sh"
QUADLET_SESSION_LIB="${REPO_ROOT}/internals/host-scripts/lib/quadlet-user-session.sh"
ORPHAN_LIB="${REPO_ROOT}/internals/host-scripts/lib/orphan-reap-host.sh"
PATHS_LIB="${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh"
# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=lib/environment/environment-workloads.sh
source "${REPO_ROOT}/internals/lib/environment/environment-workloads.sh"
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

for f in "${HOST_SCRIPT}" "${UNITS_LIB}" "${QUADLETS_LIB}" "${UNIT_CONSUMERS_LIB}" \
  "${ENV_HOST_LIB}" "${QUADLET_SESSION_LIB}" "${ORPHAN_LIB}" "${PATHS_LIB}"; do
  [[ -f "${f}" ]] || {
    echo "missing ${f}" >&2
    exit 1
  }
done

command -v terraform >/dev/null || { echo "terraform not found" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh not found" >&2; exit 1; }

host_session_open verify "${STACK_DIR}" || exit 1
IP="$(host_session_ip)"

ENV_DIR="$(environments_dir_for "${PLATFORM_ENV}")" || exit 1

STAGE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-purge-orphans-stage.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT

cp "${HOST_SCRIPT}" "${STAGE}/purge-orphans-host.sh"
cp "${UNITS_LIB}" "${STAGE}/workload-units-host.sh"
cp "${QUADLETS_LIB}" "${STAGE}/workload-quadlets-host.sh"
cp "${UNIT_CONSUMERS_LIB}" "${STAGE}/unit-consumers-host.sh"
cp "${ENV_HOST_LIB}" "${STAGE}/workload-environment-host.sh"
cp "${QUADLET_SESSION_LIB}" "${STAGE}/quadlet-user-session.sh"
cp "${ORPHAN_LIB}" "${STAGE}/orphan-reap-host.sh"
cp "${PATHS_LIB}" "${STAGE}/host-volume-paths-host.sh"

: >"${STAGE}/keep.txt"
while IFS= read -r wl_name; do
  [[ -n "${wl_name}" ]] || continue
  printf '%s\n' "${wl_name}" >>"${STAGE}/keep.txt"
done < <(environment_discover_workloads "${ENV_DIR}")

host_delivery_run "${STAGE}" "/tmp/platform-purge-orphans" \
  "PLATFORM_USER=${USER_NAME} bash /tmp/platform-purge-orphans/purge-orphans-host.sh"

echo "Orphan Reap completed on ${IP}."
