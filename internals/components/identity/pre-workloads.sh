#!/usr/bin/env bash
# Component Setup pre-workloads for Identity (ADR-0057 / #252 / #253).
# Standing ensure + API permission catalog gather into Pocket ID resource server.
# Runs on the Host only. Invoked by ensure-components with slot pre-workloads.
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
SRC="$(cd "$(dirname "$0")" && pwd)"
# Path vocabulary bootstrap (#214). Host Volume SoT segment "internals/" ≠ repo internals/.
# shellcheck source=../../host-scripts/lib/host-volume-paths-host.sh
source "${HV_ROOT:-/host-volume}/host-scripts/lib/host-volume-paths-host.sh"
# shellcheck source=../../host-scripts/lib/identity-setup-host.sh
source "$(host_volume_host_scripts_root)/lib/identity-setup-host.sh"

identity_setup_pre_workloads "${SRC}"
