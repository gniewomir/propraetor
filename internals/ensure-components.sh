#!/usr/bin/env bash
# Ensure Components on the Host after Initial Host Provisioning.
# Waits for IHP Done (Host is Substrate), ships Component source, host-scripts, the
# ACME want-list, ACME EnvironmentFile, and Database admin credentials via Host
# delivery, then runs one Component Setup slot (pre-workloads | post-workloads).
# Idempotent — re-run freely. Does not run Fabric Setup (see ensure-fabric.sh). No
# combined "full" mode — Deploy (or the caller) runs both slots in order when
# Components must be fully correct (ADR-0043 / #181 / ADR-0049 / #188).
# Environment: omitted / --env default|test → workspace default; --env <slug> otherwise (ADR-0019).
# Usage: ./internals/ensure-components.sh <pre-workloads|post-workloads> [--env <slug>]
# Optional: PLATFORM_USER=platform
# Requires: Operator Configuration private key path (PROPRAETOR_PRIVATE_KEY_PATH).
# Requires: Database admin credentials ROOT_DB_USER / ROOT_DB_PASSWORD (Environment .env or shell).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
USER_NAME="${PLATFORM_USER:-platform}"
COMPONENTS=(edge database)
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-components-host.sh"
# shellcheck source=lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"
# shellcheck source=lib/environment/environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"
# shellcheck source=lib/domains/domains.sh
source "${REPO_ROOT}/internals/lib/domains/domains.sh"
# shellcheck source=lib/acme/acme.sh
source "${REPO_ROOT}/internals/lib/acme/acme.sh"
# shellcheck source=lib/database/database-admin-credentials.sh
source "${REPO_ROOT}/internals/lib/database/database-admin-credentials.sh"
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
CLI_slot=""
cli_operator_parse CLI pos:slot:required -- "$@" || {
  echo "Usage: $0 <pre-workloads|post-workloads> [--env <slug>]" >&2
  exit 1
}
case "${CLI_slot}" in
  pre-workloads | post-workloads) ;;
  *)
    echo "ensure-components: unknown Setup slot '${CLI_slot}' (want pre-workloads|post-workloads)" >&2
    exit 1
    ;;
esac
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

for name in "${COMPONENTS[@]}"; do
  [[ -d "${REPO_ROOT}/internals/components/${name}" ]] || {
    echo "Component tree missing: internals/components/${name}" >&2
    exit 1
  }
  [[ -f "${REPO_ROOT}/internals/components/${name}/pre-workloads.sh" ]] || {
    echo "Component Setup missing: internals/components/${name}/pre-workloads.sh" >&2
    exit 1
  }
  [[ -f "${REPO_ROOT}/internals/components/${name}/post-workloads.sh" ]] || {
    echo "Component Setup missing: internals/components/${name}/post-workloads.sh" >&2
    exit 1
  }
done

# Host-local IHP Done gate (Substrate) before Component Setup — ADR-0040 / ADR-0030.
host_wait_until_ihp_done "${IHP_DONE}" "${USER_NAME}"

STAGE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-ensure-components-stage.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT

# Domain-derived ACME want-list (ADR-0023) + ACME directory / Operator Configuration email (ADR-0045):
# stage into the delivery payload; Host half places Edge handoff paths; Edge Setup installs.
domains_acme_fqdns_for "${PLATFORM_ENV}" >"${STAGE}/platform-acme-want-list"
acme_config_dotenv_for "${PLATFORM_ENV}" >"${STAGE}/platform-acme.env"

# Database admin credentials (ADR-0049 / #188): Environment .env + shell → Postgres EnvironmentFile.
# Not Environment Configuration — never remapped by Binding into Workloads.
database_admin_credentials_dotenv_for \
  "$(environments_dir_for "${PLATFORM_ENV}")" \
  "${STAGE}/platform-database-admin.env"

cp -a "${REPO_ROOT}/internals/host-scripts/lib" "${STAGE}/lib"
cp "${HOST_SCRIPT}" "${STAGE}/ensure-components-host.sh"
for name in "${COMPONENTS[@]}"; do
  cp -a "${REPO_ROOT}/internals/components/${name}" "${STAGE}/${name}"
done

REMOTE_ROOT="/tmp/platform-ensure-components"
remote_cmd="bash ${REMOTE_ROOT}/ensure-components-host.sh ${USER_NAME} ${CLI_slot}"
for name in "${COMPONENTS[@]}"; do
  remote_cmd+=" --component ${name}"
done
host_delivery_run "${STAGE}" "${REMOTE_ROOT}" "${remote_cmd}"

echo "Components ensured (${CLI_slot}) for Platform User '${USER_NAME}' on ${IP}."
