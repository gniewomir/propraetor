#!/usr/bin/env bash
# Host-local Mirror. Invoked by internals/ensure-mirror.sh after Host delivery.
# Materializes each staged Environment Workload onto Host Volume workloads/
# regardless of Source (Environment upsert + resolve Source + Provides directories;
# reserved collisions fail closed). Leaves Host basenames absent from the stage alone.
# Does not apply Intent. Preserves nested Persist under each owner (ADR-0053 /
# ADR-0054 / ADR-0047 / #204 / #215).
# Usage: bash ensure-mirror-host.sh <platform-user>
set -euo pipefail

USER_NAME="${1:?ensure-mirror-host requires Platform User}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_WORKLOADS="${HERE}/workloads"

# shellcheck source=lib/host-volume-paths-host.sh
source "${HERE}/lib/host-volume-paths-host.sh"
# shellcheck source=lib/sync-tree-host.sh
source "${HERE}/lib/sync-tree-host.sh"
# shellcheck source=lib/workload-materialize-host.sh
source "${HERE}/lib/workload-materialize-host.sh"
WORKLOADS_ROOT="$(host_volume_workloads_sot_root)"

[[ -d "${STAGE_WORKLOADS}" ]] || {
  echo "ensure-mirror-host: staged workloads/ missing" >&2
  exit 1
}

mkdir -p "${WORKLOADS_ROOT}"

MAT_TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-mirror-mat.XXXXXX")"
trap 'rm -rf "${MAT_TMP}"' EXIT

for wl_dir in "${STAGE_WORKLOADS}"/*; do
  [[ -d "${wl_dir}" ]] || continue
  wl_name="$(basename "${wl_dir}")"
  [[ "${wl_name}" != .* ]] || continue
  mat_out="${MAT_TMP}/${wl_name}"
  workload_materialize_tree "${wl_dir}" "${mat_out}" || exit 1
  sync_tree_inplace "${mat_out}" "${WORKLOADS_ROOT}/${wl_name}"
  mkdir -p "$(host_volume_workload_persist "${wl_name}")"
done

chown -R "${USER_NAME}:${USER_NAME}" "${WORKLOADS_ROOT}" 2>/dev/null || true
