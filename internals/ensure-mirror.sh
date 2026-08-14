#!/usr/bin/env bash
# Mirror — materialize Environment Workloads onto the Host Volume regardless of Source.
# Discovers Workloads as immediate non-hidden Environment dirs (ADR-0033 / ADR-0047);
# Host half: Environment upsert + resolve Source + Provides directories (ADR-0053 / #204).
# Leaves Host orphans alone (see purge-orphans). Does not Apply Intent or ship Fabric/Components.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/ensure-mirror.sh [--env <slug>]
# Optional: PLATFORM_USER=platform
# Requires: Operator Configuration private key path (PROPRAETOR_PRIVATE_KEY_PATH).
# ADR-0053 / ADR-0047 / ADR-0041 / #204.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
USER_NAME="${PLATFORM_USER:-platform}"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-mirror-host.sh"
SYNC_LIB="${REPO_ROOT}/internals/host-scripts/lib/sync-tree-host.sh"
MATERIALIZE_LIB="${REPO_ROOT}/internals/host-scripts/lib/workload-materialize-host.sh"
ARTIFACT_SOURCE_LIB="${REPO_ROOT}/internals/lib/artifact/source.sh"
ARTIFACT_PROVIDES_LIB="${REPO_ROOT}/internals/lib/artifact/provides.sh"
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
# shellcheck source=lib/artifact/source.sh
source "${REPO_ROOT}/internals/lib/artifact/source.sh"

operator_dotenv_load "${REPO_ROOT}" || exit 1
operator_configuration_require private || exit 1

CLI_env=""
cli_operator_parse CLI -- "$@" || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1

[[ -f "${HOST_SCRIPT}" ]] || {
  echo "missing ${HOST_SCRIPT}" >&2
  exit 1
}
[[ -f "${SYNC_LIB}" ]] || {
  echo "missing ${SYNC_LIB}" >&2
  exit 1
}
[[ -f "${MATERIALIZE_LIB}" ]] || {
  echo "missing ${MATERIALIZE_LIB}" >&2
  exit 1
}
[[ -f "${ARTIFACT_SOURCE_LIB}" ]] || {
  echo "missing ${ARTIFACT_SOURCE_LIB}" >&2
  exit 1
}
[[ -f "${ARTIFACT_PROVIDES_LIB}" ]] || {
  echo "missing ${ARTIFACT_PROVIDES_LIB}" >&2
  exit 1
}

command -v terraform >/dev/null || { echo "terraform not found" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh not found" >&2; exit 1; }

host_session_open verify "${STACK_DIR}" || exit 1
IP="$(host_session_ip)"

ENV_DIR="$(environments_dir_for "${PLATFORM_ENV}")" || exit 1

STAGE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-ensure-mirror-stage.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/lib" "${STAGE}/workloads"
cp "${SYNC_LIB}" "${STAGE}/lib/sync-tree-host.sh"
cp "${MATERIALIZE_LIB}" "${STAGE}/lib/workload-materialize-host.sh"
cp "${ARTIFACT_SOURCE_LIB}" "${STAGE}/lib/source.sh"
cp "${ARTIFACT_PROVIDES_LIB}" "${STAGE}/lib/provides.sh"
cp "${HOST_SCRIPT}" "${STAGE}/ensure-mirror-host.sh"

mirrored=0
while IFS= read -r wl_name; do
  [[ -n "${wl_name}" ]] || continue
  src="${ENV_DIR}/${wl_name}"
  artifact_source_tree_gate "${src}" || exit 1
  dest="${STAGE}/workloads/${wl_name}"
  mkdir -p "${dest}"
  cp -a "${src}/." "${dest}/"
  mirrored=$((mirrored + 1))
done < <(environment_discover_workloads "${ENV_DIR}")

host_delivery_run "${STAGE}" "/tmp/platform-ensure-mirror" \
  "bash /tmp/platform-ensure-mirror/ensure-mirror-host.sh ${USER_NAME}"

echo "Mirror completed on ${IP} (${mirrored} Workload(s))."
