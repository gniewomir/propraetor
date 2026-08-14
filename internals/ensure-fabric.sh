#!/usr/bin/env bash
# Ensure Fabric on the Host after Initial Host Provisioning.
# Waits for IHP Done (Host is Substrate), ships Fabric source + host-scripts via Host
# delivery, then runs Fabric Setup (Service Network). Idempotent — re-run freely.
# Does not run Component Setup (see ensure-components.sh). ADR-0040 / ADR-0041 / #155.
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/ensure-fabric.sh [--env <slug>]
# Optional: PLATFORM_USER=platform
# Requires: Operator Configuration private key path (PROPRAETOR_PRIVATE_KEY_PATH).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
USER_NAME="${PLATFORM_USER:-platform}"
FABRIC=(fabric)
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-fabric-host.sh"
# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=lib/ssh.sh
source "${REPO_ROOT}/internals/lib/ssh.sh"
# shellcheck source=lib/host-delivery.sh
source "${REPO_ROOT}/internals/lib/host-delivery.sh"
# shellcheck source=lib/ihp.sh
source "${REPO_ROOT}/internals/lib/ihp.sh"
# shellcheck source=lib/operator/operator-dotenv.sh
source "${REPO_ROOT}/internals/lib/operator/operator-dotenv.sh"
# shellcheck source=lib/operator/operator-configuration.sh
source "${REPO_ROOT}/internals/lib/operator/operator-configuration.sh"

operator_dotenv_load "${REPO_ROOT}" || exit 1
operator_configuration_require private || exit 1

CLI_env=""
cli_operator_parse CLI -- "$@" || exit 1
environment_activate "${STACK_DIR}" "${CLI_env}" || exit 1

command -v terraform >/dev/null || { echo "terraform not found" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh not found" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar not found" >&2; exit 1; }

host_session_open verify "${STACK_DIR}" || exit 1
IP="$(host_session_ip)"

IHP_DONE="${REPO_ROOT}/internals/host-scripts/wait-until-ihp-done.sh"
[[ -f "${IHP_DONE}" ]] || {
  echo "missing ${IHP_DONE}" >&2
  exit 1
}
[[ -f "${HOST_SCRIPT}" ]] || {
  echo "missing ${HOST_SCRIPT}" >&2
  exit 1
}

for name in "${FABRIC[@]}"; do
  [[ -d "${REPO_ROOT}/internals/${name}" ]] || {
    echo "Fabric tree missing: internals/${name}" >&2
    exit 1
  }
  [[ -f "${REPO_ROOT}/internals/${name}/setup.sh" ]] || {
    echo "Fabric Setup missing: internals/${name}/setup.sh" >&2
    exit 1
  }
done

# Host-local IHP Done gate (Substrate) before Fabric Setup — ADR-0040 / ADR-0030.
host_wait_until_ihp_done "${IHP_DONE}" "${USER_NAME}"

STAGE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-ensure-fabric-stage.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT

cp -a "${REPO_ROOT}/internals/host-scripts/lib" "${STAGE}/lib"
# Host gather reuses Artifact contract libs (ADR-0053 / #202 / #203).
# Fabric also ships host-scripts/lib and prunes dest extras — keep copies beside helpers.
cp "${REPO_ROOT}/internals/lib/artifact/binding.sh" "${STAGE}/lib/binding.sh"
cp "${REPO_ROOT}/internals/lib/artifact/provides.sh" "${STAGE}/lib/provides.sh"
cp "${REPO_ROOT}/internals/lib/artifact/requires.sh" "${STAGE}/lib/requires.sh"
cp "${HOST_SCRIPT}" "${STAGE}/ensure-fabric-host.sh"
for name in "${FABRIC[@]}"; do
  cp -a "${REPO_ROOT}/internals/${name}" "${STAGE}/${name}"
done

REMOTE_ROOT="/tmp/platform-ensure-fabric"
remote_cmd="bash ${REMOTE_ROOT}/ensure-fabric-host.sh ${USER_NAME}"
for name in "${FABRIC[@]}"; do
  remote_cmd+=" --fabric ${name}"
done
host_delivery_run "${STAGE}" "${REMOTE_ROOT}" "${remote_cmd}"

echo "Fabric ensured for Platform User '${USER_NAME}' on ${IP}."
