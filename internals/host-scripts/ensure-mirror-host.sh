#!/usr/bin/env bash
# Host-local Mirror. Invoked by internals/ensure-mirror.sh after Host delivery.
# Projects each staged Environment Workload onto Host Volume workloads/
# regardless of Source (shared projection: materialize + sync + empty Persist).
# Leaves Host basenames absent from the stage alone. Does not apply Intent
# (ADR-0053 / ADR-0054 / ADR-0047 / #204 / #215 / #228).
# Usage: bash ensure-mirror-host.sh <platform-user>
set -euo pipefail

USER_NAME="${1:?ensure-mirror-host requires Platform User}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_WORKLOADS="${HERE}/workloads"

# shellcheck source=lib/host-volume-paths-host.sh
source "${HERE}/lib/host-volume-paths-host.sh"
# shellcheck source=lib/workload-project-host.sh
source "${HERE}/lib/workload-project-host.sh"
WORKLOADS_ROOT="$(host_volume_workloads_sot_root)"

[[ -d "${STAGE_WORKLOADS}" ]] || {
  echo "ensure-mirror-host: staged workloads/ missing" >&2
  exit 1
}

mkdir -p "${WORKLOADS_ROOT}"

for wl_dir in "${STAGE_WORKLOADS}"/*; do
  [[ -d "${wl_dir}" ]] || continue
  wl_name="$(basename "${wl_dir}")"
  [[ "${wl_name}" != .* ]] || continue
  workload_project_to_host "${wl_dir}" "${WORKLOADS_ROOT}/${wl_name}" || exit 1
done

chown -R "${USER_NAME}:${USER_NAME}" "${WORKLOADS_ROOT}" 2>/dev/null || true
