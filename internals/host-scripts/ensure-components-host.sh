#!/usr/bin/env bash
# Host-local half of ensure-components. Invoked after Host delivery unpacks the stage.
# Installs staged Component trees onto the Host Volume, places the staged ACME want-list
# and ACME EnvironmentFile at the Edge-owned handoff paths, places Database admin
# EnvironmentFile when Database is selected, ships host-scripts, then applies one
# Component Setup slot (pre-workloads | post-workloads) — ADR-0043 / ADR-0040 / ADR-0010 /
# ADR-0041 / ADR-0045 / ADR-0049 / #181 / #188.
# Does not install Fabric. No combined "full" mode.
# Usage:
#   ensure-components-host.sh <platform-user> <pre-workloads|post-workloads> [--component <name>]...
set -euo pipefail

USER_NAME="${1:?ensure-components-host requires Platform User}"
shift
SLOT="${1:-}"
[[ -n "${SLOT}" ]] || {
  echo "ensure-components-host: Setup slot required (pre-workloads|post-workloads)" >&2
  exit 1
}
shift
case "${SLOT}" in
  pre-workloads | post-workloads) ;;
  *)
    echo "ensure-components-host: unknown Setup slot '${SLOT}' (want pre-workloads|post-workloads)" >&2
    exit 1
    ;;
esac

COMPONENTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --component)
      [[ $# -ge 2 ]] || {
        echo "ensure-components-host: --component requires a name" >&2
        exit 1
      }
      COMPONENTS+=("$2")
      shift 2
      ;;
    *)
      echo "ensure-components-host: unknown argument: $1 (want --component)" >&2
      exit 1
      ;;
  esac
done

[[ ${#COMPONENTS[@]} -gt 0 ]] || {
  echo "ensure-components-host: at least one --component required" >&2
  exit 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HV_ROOT=/var/lib/host-volume
INTERNALS_ROOT="${HV_ROOT}/internals"
DATA_ROOT="${HV_ROOT}/data"
COMPONENTS_ROOT="${INTERNALS_ROOT}/components"
HOST_SCRIPTS_ROOT="${INTERNALS_ROOT}/host-scripts"
WANT_STAGE="${HERE}/platform-acme-want-list"
WANT_HANDOFF=/tmp/platform-acme-want-list
ACME_ENV_STAGE="${HERE}/platform-acme.env"
ACME_ENV_HANDOFF=/tmp/platform-acme.env
DB_ADMIN_STAGE="${HERE}/platform-database-admin.env"
DB_ADMIN_HANDOFF=/tmp/platform-database-admin.env
SETUP_SCRIPT="${SLOT}.sh"
# shellcheck source=lib/sync-tree-host.sh
source "${HERE}/lib/sync-tree-host.sh"

need_database=0
for name in "${COMPONENTS[@]}"; do
  if [[ "${name}" == "database" ]]; then
    need_database=1
    break
  fi
done

[[ -f "${WANT_STAGE}" ]] || {
  echo "ensure-components: staged ACME FQDN list missing at ${WANT_STAGE}" >&2
  exit 1
}
[[ -f "${ACME_ENV_STAGE}" ]] || {
  echo "ensure-components: staged ACME EnvironmentFile missing at ${ACME_ENV_STAGE}" >&2
  exit 1
}
if [[ "${need_database}" == "1" ]]; then
  [[ -f "${DB_ADMIN_STAGE}" ]] || {
    echo "ensure-components: staged Database admin EnvironmentFile missing at ${DB_ADMIN_STAGE}" >&2
    exit 1
  }
fi
cp "${WANT_STAGE}" "${WANT_HANDOFF}"
cp "${ACME_ENV_STAGE}" "${ACME_ENV_HANDOFF}"
HANDOFF_CLEANUP=("${WANT_HANDOFF}" "${ACME_ENV_HANDOFF}")
if [[ "${need_database}" == "1" ]]; then
  cp "${DB_ADMIN_STAGE}" "${DB_ADMIN_HANDOFF}"
  HANDOFF_CLEANUP+=("${DB_ADMIN_HANDOFF}")
fi
trap 'rm -f "${HANDOFF_CLEANUP[@]}"' EXIT

# Hard cut (ADR-0018 / ADR-0041): retire components/ + components_data/.
rm -rf "${HV_ROOT:?}/components" "${HV_ROOT:?}/components_data"

mkdir -p \
  "${COMPONENTS_ROOT}" \
  "${INTERNALS_ROOT}/workloads" \
  "${HOST_SCRIPTS_ROOT}" \
  "${DATA_ROOT}/components" \
  "${DATA_ROOT}/workloads"

# Host-executable helpers ship under internals/host-scripts (ADR-0041).
[[ -d "${HERE}/lib" ]] || {
  echo "ensure-components: staged host-scripts lib missing" >&2
  exit 1
}
sync_tree_inplace "${HERE}/lib" "${HOST_SCRIPTS_ROOT}/lib"

install_component_tree() {
  local name="$1"
  [[ -d "${HERE}/${name}" ]] || {
    echo "ensure-components: staged Component tree missing: ${name}" >&2
    exit 1
  }
  [[ -f "${HERE}/${name}/pre-workloads.sh" ]] || {
    echo "ensure-components: staged Component Setup missing: ${name}/pre-workloads.sh" >&2
    exit 1
  }
  [[ -f "${HERE}/${name}/post-workloads.sh" ]] || {
    echo "ensure-components: staged Component Setup missing: ${name}/post-workloads.sh" >&2
    exit 1
  }
  sync_tree_inplace "${HERE}/${name}" "${COMPONENTS_ROOT}/${name}"
  chmod a+x \
    "${COMPONENTS_ROOT}/${name}/pre-workloads.sh" \
    "${COMPONENTS_ROOT}/${name}/post-workloads.sh"
  # Hard cut (ADR-0018 / ADR-0043): retire monolithic setup.sh if still present on volume.
  rm -f "${COMPONENTS_ROOT}/${name}/setup.sh"
}

for name in "${COMPONENTS[@]}"; do
  install_component_tree "${name}"
done

# Mount root stays root-owned; everything under it is Platform User–owned.
chown -R "${USER_NAME}:${USER_NAME}" "${INTERNALS_ROOT}" "${DATA_ROOT}"

# Fail closed if Domain FQDN / ACME env handoffs are missing before Edge Component Setup.
[[ -f "${WANT_HANDOFF}" ]] || {
  echo "ensure-components: staged ACME FQDN list missing at ${WANT_HANDOFF}" >&2
  exit 1
}
[[ -f "${ACME_ENV_HANDOFF}" ]] || {
  echo "ensure-components: staged ACME EnvironmentFile missing at ${ACME_ENV_HANDOFF}" >&2
  exit 1
}

for name in "${COMPONENTS[@]}"; do
  [[ -f "${COMPONENTS_ROOT}/${name}/${SETUP_SCRIPT}" ]] || {
    echo "ensure-components: Component Setup missing: ${name}/${SETUP_SCRIPT}" >&2
    exit 1
  }
  echo "Running Component Setup: ${name} (${SLOT})" >&2
  PLATFORM_USER="${USER_NAME}" "${COMPONENTS_ROOT}/${name}/${SETUP_SCRIPT}"
done
