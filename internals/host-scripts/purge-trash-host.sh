#!/usr/bin/env bash
# Host-local Purge. Invoked by internals/purge-trash.sh.
# Removes every Workload whose Intent is trash and Workload-associated data
# (SoT-named units from both Host unit directories, Host Volume owner tree including
# Persist, Platform User EnvironmentFile tree and Setup-owned Environment
# Configuration drop-ins). Does not write Edge Route interior — Edge Component Setup
# gather drops fulfillment after SoT is gone (ADR-0040 / ADR-0053 / ADR-0054).
# Does not delete Domains or Domain-scoped certificate material (ADR-0022 / #54).
# Does not rebuild ACME want-list (ADR-0023). Thin Manifest / authored units: ADR-0024.
# Environment Configuration cleanup: ADR-0035.
# Note: Intent trash / Purge product retirement is #217; this script keeps path shape
# aligned with ADR-0054 until then.
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Staged siblings only (Host delivery packs this payload). No Host Volume dual-read (ADR-0018).
# shellcheck source=host-volume-paths-host.sh
source "${HERE}/host-volume-paths-host.sh"
# shellcheck source=workload-units-host.sh
source "${HERE}/workload-units-host.sh"
# shellcheck source=workload-environment-host.sh
source "${HERE}/workload-environment-host.sh"
# shellcheck source=quadlet-user-session.sh
source "${HERE}/quadlet-user-session.sh"
WORKLOADS_ROOT="$(host_volume_workloads_sot_root)"

command -v python3 >/dev/null || {
  echo "python3 required on Host for Purge" >&2
  exit 1
}

quadlet_user_session_begin

if [[ -d "${WORKLOADS_ROOT}" ]]; then
  for wl_dir in "${WORKLOADS_ROOT}"/*; do
    [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
    WL_NAME="$(basename "${wl_dir}")"
    eval "$(python3 - "${wl_dir}/manifest.json" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1]))
intent = m.get("intent") or ""
print(f"P_INTENT={shlex.quote(intent)}")
PY
)"
    [[ "${P_INTENT}" == "trash" ]] || continue

    # Remove Environment Configuration before unit/SoT deletion (needs SoT basenames).
    environment_configuration_clear "${WL_NAME}"

    workload_units_purge "${WL_NAME}"

    rm -rf "${wl_dir}"
  done
fi

chown -R "${USER_NAME}:${USER_NAME}" \
  "${WORKLOADS_ROOT}" "${HOME_DIR}/.config" 2>/dev/null || true

quadlet_user_session_reload
