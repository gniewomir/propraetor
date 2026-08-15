#!/usr/bin/env bash
# Host-local Workload Setup. Invoked by internals/ensure-workload.sh (not an operator entrypoint).
# Usage: PLATFORM_USER=platform [WL_ENV_RESOLVED=…] bash ensure-workload-host.sh /path/to/workload-tree
# Apply lives in workload_setup_apply (tree + env path → applied Workload); this
# entry is the Host delivery adapter only (#233 / ADR-0053 / ADR-0054).
set -euo pipefail

TREE="${1:?workload tree required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Staged payload beside this script. No Host Volume dual-read (ADR-0018).
# shellcheck source=workload-setup-host.sh
source "${HERE}/workload-setup-host.sh"

workload_setup_apply "${TREE}" "${WL_ENV_RESOLVED:-}"
