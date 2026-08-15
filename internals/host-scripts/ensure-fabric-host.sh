#!/usr/bin/env bash
# Host-local half of ensure-fabric. Invoked after Host delivery unpacks the stage.
# Installs staged Fabric trees onto the Host Volume, ships host-scripts, then applies
# Fabric Setup (ADR-0040 / ADR-0041 / #155). Does not install Components or stage ACME.
# Usage:
#   ensure-fabric-host.sh <platform-user> [--fabric <name>]...
set -euo pipefail

USER_NAME="${1:?ensure-fabric-host requires Platform User}"
shift

FABRIC=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fabric)
      [[ $# -ge 2 ]] || {
        echo "ensure-fabric-host: --fabric requires a name" >&2
        exit 1
      }
      FABRIC+=("$2")
      shift 2
      ;;
    *)
      echo "ensure-fabric-host: unknown argument: $1 (want --fabric)" >&2
      exit 1
      ;;
  esac
done

[[ ${#FABRIC[@]} -gt 0 ]] || {
  echo "ensure-fabric-host: at least one --fabric required" >&2
  exit 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/host-volume-paths-host.sh
source "${HERE}/lib/host-volume-paths-host.sh"
# shellcheck source=lib/sync-tree-host.sh
source "${HERE}/lib/sync-tree-host.sh"
HV_ROOT="$(host_volume_mount_root)"
INTERNALS_ROOT="$(host_volume_sot_root)"
DATA_ROOT="$(host_volume_persist_root)"
HOST_SCRIPTS_ROOT="$(host_volume_host_scripts_root)"

# Hard cut (ADR-0018 / ADR-0041): retire components/ + components_data/.
rm -rf "${HV_ROOT:?}/components" "${HV_ROOT:?}/components_data"

mkdir -p \
  "${INTERNALS_ROOT}" \
  "${HOST_SCRIPTS_ROOT}" \
  "${DATA_ROOT}/fabric"

# Host-executable helpers ship under internals/host-scripts (ADR-0041).
[[ -d "${HERE}/lib" ]] || {
  echo "ensure-fabric: staged host-scripts lib missing" >&2
  exit 1
}
sync_tree_inplace "${HERE}/lib" "${HOST_SCRIPTS_ROOT}/lib"

install_fabric_tree() {
  local name="$1"
  [[ -d "${HERE}/${name}" ]] || {
    echo "ensure-fabric: staged Fabric tree missing: ${name}" >&2
    exit 1
  }
  [[ -f "${HERE}/${name}/setup.sh" ]] || {
    echo "ensure-fabric: staged Fabric Setup missing: ${name}/setup.sh" >&2
    exit 1
  }
  sync_tree_inplace "${HERE}/${name}" "${INTERNALS_ROOT}/${name}"
  chmod a+x "${INTERNALS_ROOT}/${name}/setup.sh"
}

for name in "${FABRIC[@]}"; do
  install_fabric_tree "${name}"
done

# Mount root stays root-owned; everything under it is Platform User–owned.
chown -R "${USER_NAME}:${USER_NAME}" "${INTERNALS_ROOT}" "${DATA_ROOT}"

for name in "${FABRIC[@]}"; do
  echo "Running Fabric Setup: ${name}" >&2
  PLATFORM_USER="${USER_NAME}" "${INTERNALS_ROOT}/${name}/setup.sh"
done
