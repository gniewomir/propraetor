#!/usr/bin/env bash
# Fabric Setup for the Service Network (ADR-0040).
# Idempotent: safe to re-run. Success means Fabric (Service Network) is in the correct state.
# Runs on the Host only (no Stack discovery / SSH). Invoked by ensure-fabric.sh.
# Not a Component — Edge is applied by ensure-components.sh.
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
SRC="$(cd "$(dirname "$0")" && pwd)"
# Path vocabulary bootstrap (#214). Host Volume SoT segment "internals/" ≠ repo internals/.
# shellcheck source=../../host-scripts/lib/host-volume-paths-host.sh
source "${HV_ROOT:-/host-volume}/host-scripts/lib/host-volume-paths-host.sh"
# shellcheck source=../../host-scripts/lib/quadlet-user-session.sh
source "$(host_volume_host_scripts_root)/lib/quadlet-user-session.sh"
# shellcheck source=../../host-scripts/lib/component-units-host.sh
source "$(host_volume_host_scripts_root)/lib/component-units-host.sh"

quadlet_user_session_begin

component_units_install "${SRC}"
chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/.config"

quadlet_user_session_reload

[[ -f "${UNIT_DIR}/service-network.network" ]]
