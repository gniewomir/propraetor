#!/usr/bin/env bash
# Component Setup post-workloads for the Cache (ADR-0055 / #221 / #224 / #225 / #232).
# Standing ensure + Orphan drop (DELUSER/clients/keys). No Declaration re-converge
# solely to undo standing ensure — standing ACL preserves claimants across restart.
# Runs on the Host only. Invoked by ensure-components with slot post-workloads.
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
SRC="$(cd "$(dirname "$0")" && pwd)"
# Path vocabulary bootstrap (#214). Host Volume SoT segment "internals/" ≠ repo internals/.
# shellcheck source=../../host-scripts/lib/host-volume-paths-host.sh
source "${HV_ROOT:-/host-volume}/host-scripts/lib/host-volume-paths-host.sh"
# shellcheck source=../../host-scripts/lib/cache-setup-host.sh
source "$(host_volume_host_scripts_root)/lib/cache-setup-host.sh"

cache_setup_post_workloads "${SRC}"
