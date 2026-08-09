#!/usr/bin/env bash
# Host-local Mirror. Invoked by internals/ensure-mirror.sh after Host delivery.
# Upserts staged Workload bags onto Host Volume internals/workloads/
# (dumb copy via sync_tree_inplace). Leaves Host basenames absent from the stage alone.
# Does not validate Manifest content, apply Intent, or touch data/workloads (ADR-0047 / ADR-0041 / #156).
# Usage: bash ensure-mirror-host.sh <platform-user>
set -euo pipefail

USER_NAME="${1:?ensure-mirror-host requires Platform User}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HV_ROOT=/var/lib/host-volume
WORKLOADS_ROOT="${HV_ROOT}/internals/workloads"
STAGE_WORKLOADS="${HERE}/workloads"

# shellcheck source=lib/sync-tree-host.sh
source "${HERE}/lib/sync-tree-host.sh"

[[ -d "${STAGE_WORKLOADS}" ]] || {
  echo "ensure-mirror-host: staged workloads/ missing" >&2
  exit 1
}

mkdir -p "${WORKLOADS_ROOT}"

for wl_dir in "${STAGE_WORKLOADS}"/*; do
  [[ -d "${wl_dir}" ]] || continue
  wl_name="$(basename "${wl_dir}")"
  [[ "${wl_name}" != .* ]] || continue
  sync_tree_inplace "${wl_dir}" "${WORKLOADS_ROOT}/${wl_name}"
done

chown -R "${USER_NAME}:${USER_NAME}" "${WORKLOADS_ROOT}" 2>/dev/null || true
