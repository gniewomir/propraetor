#!/usr/bin/env bash
# Component Setup post-workloads for the Edge (ADR-0043 / #181).
# Gather Intent-run Routes → validate → reload if up / start if down → ACME → front-door wait.
# Runs on the Host only. Invoked by ensure-components with slot post-workloads.
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
SRC="$(cd "$(dirname "$0")" && pwd)"
# Path vocabulary bootstrap (#214). Host Volume SoT segment "internals/" ≠ repo internals/.
# shellcheck source=../../host-scripts/lib/host-volume-paths-host.sh
source "${HV_ROOT:-/var/lib/host-volume}/internals/host-scripts/lib/host-volume-paths-host.sh"
# shellcheck source=../../host-scripts/lib/edge-setup-host.sh
source "$(host_volume_host_scripts_root)/lib/edge-setup-host.sh"

edge_setup_post_workloads "${SRC}"
