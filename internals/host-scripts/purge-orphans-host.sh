#!/usr/bin/env bash
# Host-local Orphan Reap. Invoked by internals/purge-orphans.sh.
# Removes Host Workloads whose basename is absent from the Environment keep set
# (Host Volume owner tree including Persist, Platform User units, EnvironmentFiles).
# Sole supported Host Workload destroy path — keyed by Environment absence
# (ADR-0054 / ADR-0041 / #156 / #215 / #217).
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP_FILE="${HERE}/keep.txt"

# Staged siblings only (Host delivery packs this payload). No Host Volume dual-read (ADR-0018).
# shellcheck source=host-volume-paths-host.sh
source "${HERE}/host-volume-paths-host.sh"
# shellcheck source=workload-units-host.sh
source "${HERE}/workload-units-host.sh"
# shellcheck source=workload-environment-host.sh
source "${HERE}/workload-environment-host.sh"
# shellcheck source=quadlet-user-session.sh
source "${HERE}/quadlet-user-session.sh"
# shellcheck source=orphan-reap-host.sh
source "${HERE}/orphan-reap-host.sh"
WORKLOADS_ROOT="$(host_volume_workloads_sot_root)"

[[ -f "${KEEP_FILE}" ]] || {
  echo "purge-orphans-host: keep.txt missing" >&2
  exit 1
}

quadlet_user_session_begin

while IFS= read -r WL_NAME; do
  [[ -n "${WL_NAME}" ]] || continue
  environment_configuration_clear "${WL_NAME}"
  workload_units_purge "${WL_NAME}"
  # Whole owner tree (SoT + nested Persist).
  rm -rf "${WORKLOADS_ROOT:?}/${WL_NAME}"
done < <(orphan_reap_absent_basenames "${WORKLOADS_ROOT}" "${KEEP_FILE}")

chown -R "${USER_NAME}:${USER_NAME}" \
  "${WORKLOADS_ROOT}" "${HOME_DIR}/.config" 2>/dev/null || true

quadlet_user_session_reload
