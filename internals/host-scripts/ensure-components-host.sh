#!/usr/bin/env bash
# Host-local half of ensure-components. Invoked after Host delivery unpacks the stage.
# Installs staged Component trees onto the Host Volume, places ACME want-list /
# ACME EnvironmentFile (and Database/Cache admin EnvironmentFiles when selected)
# into the Component Setup handoff root on the Host Volume, ships host-scripts, then
# applies one Component Setup slot (pre-workloads | post-workloads) — ADR-0043 /
# ADR-0040 / ADR-0010 / ADR-0054 / ADR-0045 / ADR-0049 / ADR-0055 / #181 / #188 / #215 / #221.
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
# shellcheck source=lib/host-volume-paths-host.sh
source "${HERE}/lib/host-volume-paths-host.sh"
# shellcheck source=lib/sync-tree-host.sh
source "${HERE}/lib/sync-tree-host.sh"
# shellcheck source=lib/component-handoff-host.sh
source "${HERE}/lib/component-handoff-host.sh"
HV_ROOT="$(host_volume_mount_root)"
COMPONENTS_ROOT="$(host_volume_components_sot_root)"
WORKLOADS_ROOT="$(host_volume_workloads_sot_root)"
HOST_SCRIPTS_ROOT="$(host_volume_host_scripts_root)"
WANT_STAGE="${HERE}/platform-acme-want-list"
ACME_ENV_STAGE="${HERE}/platform-acme.env"
DB_ADMIN_STAGE="${HERE}/platform-database-admin.env"
CACHE_ADMIN_STAGE="${HERE}/platform-cache-admin.env"
SETUP_SCRIPT="${SLOT}.sh"

need_database=0
need_cache=0
for name in "${COMPONENTS[@]}"; do
  if [[ "${name}" == "database" ]]; then
    need_database=1
  fi
  if [[ "${name}" == "cache" ]]; then
    need_cache=1
  fi
done

# Hard cut (ADR-0018 / ADR-0054): retire ADR-0041 Host Volume parents.
# Do not remove components/ — that is the live SoT parent (and handoff sibling).
rm -rf "${HV_ROOT:?}/internals" "${HV_ROOT:?}/data" "${HV_ROOT:?}/components_data"

mkdir -p \
  "${COMPONENTS_ROOT}" \
  "${WORKLOADS_ROOT}" \
  "${HOST_SCRIPTS_ROOT}"

component_handoff_install_acme "${WANT_STAGE}" "${ACME_ENV_STAGE}"
if [[ "${need_database}" == "1" ]]; then
  component_handoff_install_database_admin "${DB_ADMIN_STAGE}"
fi
if [[ "${need_cache}" == "1" ]]; then
  component_handoff_install_cache_admin "${CACHE_ADMIN_STAGE}"
fi

# Host-executable helpers ship under host-scripts/ (ADR-0054).
[[ -d "${HERE}/lib" ]] || {
  echo "ensure-components: staged host-scripts lib missing" >&2
  exit 1
}
sync_tree_inplace "${HERE}/lib" "${HOST_SCRIPTS_ROOT}/lib"

install_component_tree() {
  local name="$1"
  local persist
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
  persist="$(host_volume_component_persist "${name}")"
  mkdir -p "${persist}"
}

for name in "${COMPONENTS[@]}"; do
  install_component_tree "${name}"
done

# Mount root stays root-owned; everything under it is Platform User–owned.
chown -R "${USER_NAME}:${USER_NAME}" \
  "${COMPONENTS_ROOT}" "${WORKLOADS_ROOT}" "${HOST_SCRIPTS_ROOT}"

# Fail closed if ACME handoffs are missing before Component Setup.
component_handoff_require_acme

for name in "${COMPONENTS[@]}"; do
  [[ -f "${COMPONENTS_ROOT}/${name}/${SETUP_SCRIPT}" ]] || {
    echo "ensure-components: Component Setup missing: ${name}/${SETUP_SCRIPT}" >&2
    exit 1
  }
  echo "Running Component Setup: ${name} (${SLOT})" >&2
  PLATFORM_USER="${USER_NAME}" "${COMPONENTS_ROOT}/${name}/${SETUP_SCRIPT}"
done
